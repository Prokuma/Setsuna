#!/usr/bin/env python3
"""Reproducible Tang Primer 20K Dock simulation, build, and programming flow."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys

from setup import ROOT, LOCK, host_key, install_path, sha256

BOARD = ROOT / 'fpga/tang-primer-20k'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'sim', 'synth', 'build', 'scan', 'detect',
                                           'program', 'load', 'flash'])
    parser.add_argument('--design', choices=['cpu', 'blink'], default='cpu',
                        help='design to test/build/program (default: cpu)')
    parser.add_argument('--led-mode', choices=['gpio', 'status'], default='gpio',
                        help='CPU LED output: program GPIO or boot diagnostics')
    parser.add_argument('--boot-mode', choices=['ddr', 'rom'], default='ddr',
                        help='CPU boot memory: external DDR or internal block ROM')
    parser.add_argument('--cache-lines', type=int, default=256,
                        help='lines in each I/D cache (power of two, default: 256)')
    parser.add_argument('--build-dir', type=Path, default=None)
    parser.add_argument('--serial', help='USB probe serial number, when multiple boards are connected')
    parser.add_argument('--jtag-hz', type=int, default=2500000, help='JTAG clock (default: 2500000 Hz)')
    parser.add_argument('--program', type=Path,
                        help='flat little-endian RV64 binary loaded at 0x80000000 (CPU design)')
    parser.add_argument('--ddr-phy', choices=['portable', 'native'], default='native',
                        help='DDR PHY: experimental fixed-phase or native Gowin DQS (default: native)')
    parser.add_argument('--experimental-load', action='store_true',
                        help='load an existing experimental CPU bitstream into SRAM; no Flash writes')
    args = parser.parse_args()
    if args.cache_lines < 2 or args.cache_lines > 256 or args.cache_lines & (args.cache_lines - 1):
        parser.error('--cache-lines must be a power of two from 2 to 256')
    if args.experimental_load and (args.action != 'load' or args.design != 'cpu'):
        parser.error('--experimental-load requires load --design cpu')
    if args.jtag_hz <= 0:
        parser.error('--jtag-hz must be positive')
    lock = json.loads(LOCK.read_text())
    suite = install_path(lock)
    marker = suite / '.setsuna-install.json'
    expected = {'release': lock['release'], 'host': host_key(), 'sha256': lock['assets'][host_key()]['sha256']}
    if not marker.exists() or json.loads(marker.read_text()) != expected:
        parser.error('Pinned OSS CAD Suite not installed; run make fpga-setup')
    using_ddr = args.design == 'cpu' and args.boot_mode == 'ddr'
    default_out = ROOT / 'build/fpga/tang-primer-20k'
    if args.design == 'cpu' and args.boot_mode == 'rom':
        default_out = default_out / 'rom'
    if args.design == 'cpu' and args.led_mode == 'status':
        default_out = default_out / 'status'
    out = (args.build_dir or default_out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env['PATH'] = str(suite / 'bin') + os.pathsep + env.get('PATH', '')
    # Upstream executable wrappers configure their own libraries and Python.
    history = []

    if args.program and args.design != 'cpu':
        parser.error('--program is only valid with --design cpu')

    program_source = None
    if args.design == 'cpu' and args.program:
        program_source = args.program.expanduser().resolve()
        if not program_source.is_file():
            parser.error(f'program binary not found: {program_source}')
        program_data = program_source.read_bytes()
        if not program_data:
            parser.error('program binary must not be empty')
        if len(program_data) > 96 * 1024:
            parser.error('program binary exceeds the 96 KiB boot-ROM limit')
        padded = program_data + bytes((-len(program_data)) % 8)
        boot_image = out / 'boot_image.hex'
        boot_image.write_text(''.join(
            f'{int.from_bytes(padded[offset:offset+8], "little"):016x}\n'
            for offset in range(0, len(padded), 8)))
        boot_words = len(padded) // 8
    else:
        boot_image = BOARD / 'demo_program.hex'
        boot_words = len([line for line in boot_image.read_text().splitlines() if line.strip()])
    boot_defines = [f'-DSETSUNA_BOOT_IMAGE="{boot_image}"',
                    f'-DSETSUNA_BOOT_WORDS={boot_words}',
                    f'-DSETSUNA_BOOT_FROM_DDR={int(using_ddr)}',
                    f'-DSETSUNA_CACHE_LINES={args.cache_lines}',
                    f'-DSETSUNA_CACHE_INDEX_BITS={args.cache_lines.bit_length() - 1}',
                    f'-DSETSUNA_LED_STATUS={int(args.led_mode == "status")}']

    rtl_sources = sorted((ROOT / 'verilog').glob('**/*.v'))
    rtl_sources = [path for path in rtl_sources if 'test' not in path.parts]
    ddr_upstream = ROOT / 'third_party/ddr3-tang-primer-20k/src/ddr3_controller.v'
    ddr_compatible = out / 'ddr3_controller_yosys.v'
    ddr_sources = []
    if using_ddr:
        ddr_text = ddr_upstream.read_text()
        cast_marker = 'typedef logic [4:0] FIVEB;\n'
        cast_helpers = '''typedef logic [4:0] FIVEB;
    function automatic [7:0] byte_cast(input integer value);
        byte_cast = value[7:0];
    endfunction
    function automatic [3:0] nib_cast(input integer value);
        nib_cast = value[3:0];
    endfunction
    function automatic [4:0] fiveb_cast(input integer value);
        fiveb_cast = value[4:0];
    endfunction
    '''
        if cast_marker not in ddr_text:
            raise SystemExit('Unsupported ddr3_controller revision: typedef marker not found')
        ddr_text = ddr_text.replace(cast_marker, cast_helpers, 1)
        ddr_text = ddr_text.replace("BYTE'(", 'byte_cast(')
        ddr_text = ddr_text.replace("NIB'(", 'nib_cast(')
        ddr_text = ddr_text.replace("FIVEB'(", 'fiveb_cast(')
        # The open-source Gowin cell library does not expose the vendor DLL cell.
        # Keep the controller's documented DDR3-800 nominal delay (25 taps); the
        # board memory test must validate margin on real hardware.
        dll_pattern = (r'`ifdef SIM\n// DLL simulation takes too long.*?'
                       r'\n`endif')
        ddr_text, dll_replacements = re.subn(
            dll_pattern,
            "assign dllstep = 8'd25;\nassign dlllock = 1'b1;",
            ddr_text, count=1, flags=re.DOTALL)
        if dll_replacements != 1:
            raise SystemExit('Unsupported ddr3_controller revision: DLL block not found')
        if args.ddr_phy == 'portable':
            # Apicula cannot place the GW2A DQS/OSER8_MEM/IDES8_MEM primitives yet.
            # Use ordinary supported SERDES cells with a fixed 90-degree write
            # relationship: fclk changes DQ/DM and ck clocks DQS in the data eye.
            # Read capture uses the PLL-related ck clock and must be validated on
            # hardware; --ddr-phy native preserves the upstream calibration logic.
            zq_pattern = (r'\{ZQCL, 5\x27bxxxxx\} : if \(tick\) begin\n'
                          r'\s*state <= WRITE_LEVELING;\n'
                          r'\s*cycle <= 0;\n'
                          r'\s*end')
            zq_replacement = '''{ZQCL, 5'bxxxxx} : if (tick) begin
                state <= IDLE;
                cycle <= 0;
                busy <= 1'b0;
                wlevel_done <= 1'b1;
                rcalib_done <= 1'b1;
            end'''
            ddr_text, zq_replacements = re.subn(zq_pattern, zq_replacement, ddr_text, count=1)
            dqs_pattern = (r'wire \[2:0\] dqs_waddr\[1:0\], dqs_raddr\[1:0\];.*?'
                           r'endgenerate\n\n// 2\*CK speed in/out')
            dqs_replacement = '''// Fixed-phase OSS PHY: the write DQS serializer uses ck, which is
    // 90 degrees after fclk. Read data is sampled with the same PLL-related ck.
    assign rburst = 2'b00;

    // 2*CK speed in/out'''
            ddr_text, dqs_replacements = re.subn(
                dqs_pattern, dqs_replacement, ddr_text, count=1, flags=re.DOTALL)
            ides_pattern = r'\s*IDES8_MEM iser_dq\(.*?\n\s*\);'
            ides_replacement = '''
            reg dq_rise = 0;
            reg dq_fall = 0;
            reg [7:0] dq_shift = 0;
            reg [7:0] dq_sample = 0;
            always @(posedge ck)
                dq_rise <= DDR3_DQ[i1];
            always @(negedge ck)
                dq_fall <= DDR3_DQ[i1];
            always @(posedge ck)
                dq_shift <= {dq_shift[5:0], dq_rise, dq_fall};
            always @(posedge pclk)
                dq_sample <= dq_shift;
            assign dq_in[0][i1] = dq_sample[0];
            assign dq_in[1][i1] = dq_sample[1];
            assign dq_in[2][i1] = dq_sample[2];
            assign dq_in[3][i1] = dq_sample[3];
            assign dq_in[4][i1] = dq_sample[4];
            assign dq_in[5][i1] = dq_sample[5];
            assign dq_in[6][i1] = dq_sample[6];
            assign dq_in[7][i1] = dq_sample[7];'''
            ddr_text, ides_replacements = re.subn(
                ides_pattern, ides_replacement, ddr_text, count=1, flags=re.DOTALL)
            replacements = {
                'OSER8_MEM #(.TCLK_SOURCE("DQSW270")) oser_dq(': 'OSER8 oser_dq(',
                '.FCLK(fclk), .PCLK(pclk), .TCLK(clk_dqsw270[i1/8]), .RESET(~rst_lock_n|| ~dlllock),':
                    '.FCLK(fclk), .PCLK(pclk), .RESET(~rst_lock_n|| ~dlllock),',
                'OSER8_MEM oser_dqs(': 'OSER8 oser_dqs(',
                '.FCLK(fclk), .PCLK(pclk), .TCLK(clk_dqsw[i2]), .RESET(~rst_lock_n),':
                    '.FCLK(ck), .PCLK(pclk), .RESET(~rst_lock_n),',
                'OSER8_MEM #(.TCLK_SOURCE("DQSW270")) oser_dm(': 'OSER8 oser_dm(',
                '.FCLK(fclk), .PCLK(pclk), .TCLK(clk_dqsw270[i2]), .RESET(~rst_lock_n), .Q0(DDR3_DM[i2])':
                    '.FCLK(fclk), .PCLK(pclk), .RESET(~rst_lock_n), .Q0(DDR3_DM[i2])',
            }
            missing = [old for old in replacements if old not in ddr_text]
            if (zq_replacements != 1 or dqs_replacements != 1 or
                    ides_replacements != 1 or missing):
                raise SystemExit('Unsupported ddr3_controller revision: portable PHY markers not found')
            for old, new in replacements.items():
                ddr_text = ddr_text.replace(old, new, 1)
        ddr_compatible.write_text(ddr_text)
        ddr_sources = [ddr_compatible,
                       ROOT / 'third_party/ddr3-tang-primer-20k/src/gowin_rpll/gowin_rpll.v']
    cpu_board_sources = [BOARD / 'tang_primer_20k_ddr3.v', BOARD / 'setsuna_soc.v']
    designs = {
        'cpu': {
            'top': 'tang_primer_20k_soc' if using_ddr else 'tang_primer_20k_rom',
            'test_top': 'tang_primer_20k_soc_tb',
            'sources': rtl_sources + ddr_sources + cpu_board_sources,
            'test_sources': rtl_sources + cpu_board_sources + [BOARD / 'setsuna_soc_tb.v'],
            'bitstream': 'setsuna.fs',
        },
        'blink': {
            'top': 'blink',
            'test_top': 'blink_tb',
            'sources': [BOARD / 'blink.v'],
            'test_sources': [BOARD / 'blink.v', BOARD / 'blink_tb.v'],
            'bitstream': 'blink.fs',
        },
    }
    design = designs[args.design]

    def run(tool, *options, log):
        command = [str(suite / 'bin' / tool), *map(str, options)]
        print('+ ' + shlex.join(command), flush=True)
        history.append(command)
        output = []
        with (out / log).open('w') as stream:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                print(line, end='', flush=True)
                stream.write(line)
                output.append(line)
            status = process.wait()
        if status:
            raise subprocess.CalledProcessError(status, command)
        return ''.join(output)

    def versions():
        result = {}
        for tool, flag in [('yosys', '-V'), ('nextpnr-himbaechel', '--version'),
                           ('openFPGALoader', '--version')]:
            result[tool] = run(tool, flag, log=tool+'-version.log').strip()
        match = re.search(r'v(\d+)\.(\d+)\.(\d+)', result['openFPGALoader'])
        if not match or tuple(map(int, match.groups())) < (0, 9, 0):
            raise SystemExit('Tang Primer 20K requires openFPGALoader >= 0.9.0; see docs/fpga.md.')
        return result

    def simulate():
        simulation = out / (args.design + '_tb.vvp')
        defines = boot_defines if args.design == 'cpu' else []
        run('iverilog', '-g2012', *defines, '-s', design['test_top'], '-o', simulation,
            *design['test_sources'], log='iverilog.log')
        run('vvp', simulation, log='simulation.log')

    def build(route=True):
        # A failed build must not leave an older bitstream eligible for load.
        (out / 'build-manifest.json').unlink(missing_ok=True)
        tool_versions = versions()
        simulate()
        script = out / 'synth.ys'
        define_text = ' '.join(boot_defines) + ' ' if args.design == 'cpu' else ''
        # Yosys 0.69 re-elaborates the already-flattened top at synth_gowin's
        # final hierarchy check when a parameterized OSER8_MEM is present.  Run
        # through map_cells, then perform the remaining safe checks explicitly.
        synth_suffix = (' -run begin:check' if using_ddr else '')
        script.write_text('read_verilog -sv ' + ('-defer ' if not using_ddr else '') + define_text +
                          ' '.join(json.dumps(str(source)) for source in design['sources']) + '\n' +
                          'synth_gowin -top ' + design['top'] + ' -family gw2a' +
                          synth_suffix + '\n' +
                          'setundef -zero\n' +
                          'opt_clean\n' +
                          'stat\n' +
                          'check -noinit\n' +
                          'blackbox =A:whitebox\n' +
                          'write_json ' + json.dumps(str(out / 'synth.json')) + '\n')
        run('yosys', '-s', script, log='yosys.log')
        if not route:
            return
        timing_options = (['--sdc', BOARD / 'clocks.sdc']
                          if using_ddr else [])
        constraints = BOARD / 'board.cst'
        if args.design == 'cpu' and not using_ddr:
            constraints = out / 'rom.cst'
            constraints.write_text('\n'.join(line for line in (BOARD / 'board.cst').read_text().splitlines()
                                             if not line.startswith(('IO_LOC "ddr_', 'IO_PORT "ddr_'))) + '\n')
        run('nextpnr-himbaechel', *timing_options, '--json', out / 'synth.json', '--write', out / 'routed.json',
            '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
            '--vopt', 'cst=' + str(constraints), '--freq', '27', '--seed', '1',
            '--report', out / 'timing.json', log='nextpnr.log')
        bitstream = out / design['bitstream']
        if using_ddr and args.ddr_phy == 'portable':
            raise SystemExit('Portable PHY is experimental: differential CK/DQS pad mapping and '
                             'read capture validation are required before packing/programming.')
        run('gowin_pack', '-c', '-d', 'GW2A-18', '-o', bitstream,
            out / 'routed.json', log='pack.log')
        report = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'suite': expected, 'tool_versions': tool_versions,
                  'design': args.design, 'top': design['top'],
                  'board': 'tangprimer20k', 'device': 'GW2A-LV18PG256C8/I7',
                  'clock_mhz': 27, 'seed': 1,
                  'boot_mode': args.boot_mode, 'led_mode': args.led_mode,
                  'cache_lines': args.cache_lines if args.design == 'cpu' else None,
                  'ddr_phy': args.ddr_phy if using_ddr else None,
                  'timing_constraints': 'clocks.sdc' if using_ddr else None,
                  'program': str(program_source) if program_source else None,
                  'boot_image': str(boot_image), 'boot_words': boot_words,
                  'boot_image_sha256': sha256(boot_image),
                  'sources': {str(p.relative_to(ROOT)): sha256(p) for p in
                              design['test_sources'] + [BOARD/'board.cst', LOCK, Path(__file__)] +
                              ([BOARD/'clocks.sdc', ddr_upstream, ddr_sources[1]]
                               if using_ddr else [])},
                  'bitstream': design['bitstream'],
                  'bitstream_sha256': sha256(bitstream), 'commands': history.copy()}
        (out / 'build-manifest.json').write_text(json.dumps(report, indent=2) + '\n')

    probe = ['-b', 'tangprimer20k', '--freq', str(args.jtag_hz)]
    if args.serial:
        probe += ['--usb-serial-num', args.serial]
    if args.action == 'doctor':
        versions()
        run('gowin_pack', '--help', log='gowin_pack-help.log')
    elif args.action == 'sim':
        simulate()
    elif args.action == 'synth':
        build(route=False)
    elif args.action == 'build':
        build()
    elif args.action == 'scan':
        run('openFPGALoader', '--scan-usb', log='usb-scan.log')
    elif args.action == 'detect':
        run('openFPGALoader', *probe, '--detect', log='detect.log')
    else:
        if args.action == 'load':
            manifest_path = out / 'build-manifest.json'
            if not manifest_path.exists():
                raise SystemExit('No build manifest; run make fpga-build first.')
            manifest = json.loads(manifest_path.read_text())
            if (using_ddr and not args.experimental_load and
                    (manifest.get('ddr_phy') == 'portable' or
                     manifest.get('timing_constraints') != 'clocks.sdc')):
                raise SystemExit('CPU bitstream lacks validated PHY/timing constraints; rebuild required.')
            if args.design == 'cpu' and manifest.get('boot_mode', 'ddr') != args.boot_mode:
                raise SystemExit('Bitstream boot mode differs from requested mode; select the correct build.')
            if args.design == 'cpu' and manifest.get('led_mode', 'gpio') != args.led_mode:
                raise SystemExit('Bitstream LED mode differs from requested mode.')
            if args.design == 'cpu' and manifest.get('cache_lines', 2) != args.cache_lines:
                raise SystemExit('Bitstream cache size differs from requested size.')
            bitstream = out / design['bitstream']
            if (manifest.get('design') != args.design or
                    manifest.get('bitstream') != design['bitstream'] or
                    not bitstream.exists() or
                    manifest.get('bitstream_sha256') != sha256(bitstream)):
                raise SystemExit('Existing bitstream does not match its build manifest; rebuild it.')
            if args.experimental_load:
                print('EXPERIMENTAL SRAM LOAD: DDR differential pads/read capture are unverified; '
                      'the existing CPU image has not met its actual clock timing.', flush=True)
        else:
            # Build current sources before programming so the default cannot use stale RTL.
            build()
        options = ['-f'] if args.action == 'flash' else []
        bitstream = out / design['bitstream']
        log_name = 'program.log' if args.action in ('program', 'load') else 'flash.log'
        run('openFPGALoader', *probe, *options, bitstream, log=log_name)
        (out/'program-manifest.json').write_text(json.dumps({
            'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'mode': args.action, 'design': args.design, 'serial': args.serial,
            'experimental': args.experimental_load,
            'boot_mode': args.boot_mode, 'led_mode': args.led_mode,
            'cache_lines': args.cache_lines if args.design == 'cpu' else None,
            'bitstream': design['bitstream'],
            'bitstream_sha256': sha256(bitstream), 'command': history[-1]}, indent=2)+'\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
