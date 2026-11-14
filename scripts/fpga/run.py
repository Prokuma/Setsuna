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

from setup import ROOT, LOCK, DDR_LOCK, host_key, install_path, sha256

BOARD = ROOT / 'fpga/tang-primer-20k'


# The CPU and controller clock aliases can change when Yosys flattens the top.
DDR_CLOCKS = (
    (27, {'clk', 'ddr_boot.command_bridge.source_clk'}),
    (108, {'ddr_boot.controller_clk', 'ddr_boot.command_bridge.controller_clk'}),
)


def verify_ddr_timing(fmax, log):
    applied = {}
    if re.search(r'(?im)^ERROR:|\b[1-9][0-9]* hold/min time violation|\bunconstrained\b|'
                 r'clock[^\n]*(?:not found|no match|does not match)', log):
        raise SystemExit('2:1 DDR timing log contains a violation or missing constraint.')
    for mhz, aliases in DDR_CLOCKS:
        explicit = [(name, float(freq)) for name, freq in re.findall(
            r"constraining clock net '([^']+)' to ([\d.]+) MHz", log)
            if name in aliases]
        clocks = [fmax[name] for name in aliases if name in fmax]
        if (len(explicit) != 1 or abs(explicit[0][1] - mhz) >= 0.02 or
                len(clocks) != 1 or abs(clocks[0]['constraint'] - mhz) >= 0.02 or
                not clocks[0]['achieved'] >= clocks[0]['constraint']):
            raise SystemExit(f'2:1 DDR timing not met or SDC not applied for {mhz} MHz.')
        applied[explicit[0][0]] = explicit[0][1]
    return {'applied_sdc_mhz': applied, 'hold_violations': False, 'unconstrained_warnings': False}


def verify_ddr_dependency(path):
    status = subprocess.check_output(
        ['git', 'submodule', 'status', '--', str(path.relative_to(ROOT))],
        cwd=ROOT, text=True)
    if not re.fullmatch(r' [0-9a-f]{40} [^\n]+\n', status):
        raise SystemExit('gowin-ddr3 is not at its pinned revision; run make deps.')
    if subprocess.check_output(
            ['git', '-C', str(path), 'status', '--porcelain'], text=True):
        raise SystemExit('gowin-ddr3 contains local changes; use the clean pinned revision.')
    return status.split()[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'sim', 'synth', 'pack', 'build', 'scan', 'detect',
                                           'program', 'load', 'flash'])
    parser.add_argument('--design', choices=['cpu', 'blink'], default='cpu',
                        help='design to test/build/program (default: cpu)')
    parser.add_argument('--led-mode', choices=['gpio', 'status', 'ddr'], default='gpio',
                        help='LED output: program GPIO, CPU status, or DDR boot diagnostics')
    parser.add_argument('--boot-mode', choices=['ddr', 'rom'], default='ddr',
                        help='CPU boot memory: external DDR or internal block ROM')
    parser.add_argument('--cache-lines', type=int, default=256,
                        help='lines in each I/D cache (power of two, default: 256)')
    m_options = parser.add_mutually_exclusive_group()
    m_options.add_argument('--disable-m', action='store_true', help='build RV64I without M')
    m_options.add_argument('--enable-m', action='store_true', help='include RV64M arithmetic')
    parser.add_argument('--build-dir', type=Path, default=None)
    parser.add_argument('--seed', type=int, default=1, help='nextpnr placement seed')
    parser.add_argument('--router', choices=['default', 'router1', 'router2'], default='default',
                        help='nextpnr routing algorithm')
    parser.add_argument('--serial', help='USB probe serial number, when multiple boards are connected')
    parser.add_argument('--jtag-hz', type=int, default=2500000, help='JTAG clock (default: 2500000 Hz)')
    parser.add_argument('--program', type=Path,
                        help='flat little-endian RV64 binary loaded at 0x80000000 (CPU design)')
    parser.add_argument('--ddr-phy', choices=['gowin-ddr3', 'portable', 'native'], default='gowin-ddr3',
                        help='DDR PHY (default: calibrated OSS gowin-ddr3)')
    parser.add_argument('--experimental-load', action='store_true',
                        help='load an existing experimental CPU bitstream into SRAM; no Flash writes')
    args = parser.parse_args()
    if args.cache_lines < 2 or args.cache_lines > 256 or args.cache_lines & (args.cache_lines - 1):
        parser.error('--cache-lines must be a power of two from 2 to 256')
    if args.experimental_load and (args.action != 'load' or args.design != 'cpu' or
                                   args.boot_mode != 'ddr' or args.ddr_phy != 'portable'):
        parser.error('--experimental-load requires load --design cpu --boot-mode ddr --ddr-phy portable')
    if args.jtag_hz <= 0:
        parser.error('--jtag-hz must be positive')
    if args.led_mode == 'ddr' and (args.design != 'cpu' or args.boot_mode != 'ddr'):
        parser.error('--led-mode ddr requires --design cpu --boot-mode ddr')
    using_ddr = args.design == 'cpu' and args.boot_mode == 'ddr'
    using_2to1 = using_ddr and args.ddr_phy == 'gowin-ddr3'
    enable_m = args.enable_m or (not args.disable_m and not using_2to1)
    lock_path = DDR_LOCK if using_2to1 else LOCK
    lock = json.loads(lock_path.read_text())
    suite = install_path(lock)
    marker = suite / '.setsuna-install.json'
    expected = {'release': lock['release'], 'host': host_key(), 'sha256': lock['assets'][host_key()]['sha256']}
    if not marker.exists() or json.loads(marker.read_text()) != expected:
        parser.error('Pinned OSS CAD Suite not installed; run make fpga-setup '
                     f'FPGA_DESIGN={args.design} FPGA_BOOT={args.boot_mode} FPGA_PHY={args.ddr_phy}')
    default_out = ROOT / 'build/fpga/tang-primer-20k'
    if args.design == 'cpu' and args.boot_mode == 'rom':
        default_out = default_out / 'rom'
    if args.design == 'cpu' and args.led_mode == 'status':
        default_out = default_out / 'status'
    if args.design == 'cpu' and args.led_mode == 'ddr':
        default_out = default_out / 'ddr-status'
    if using_ddr and not using_2to1 and not args.experimental_load:
        default_out = default_out / args.ddr_phy
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
                    f'-DSETSUNA_ENABLE_M={int(enable_m)}',
                    f'-DSETSUNA_LED_STATUS={dict(gpio=0, status=1, ddr=2)[args.led_mode]}']

    rtl_sources = sorted((ROOT / 'verilog').glob('**/*.v'))
    rtl_sources = [path for path in rtl_sources if 'test' not in path.parts]
    ddr_upstream = ROOT / 'third_party/ddr3-tang-primer-20k/src/ddr3_controller.v'
    ddr_compatible = out / 'ddr3_controller_yosys.v'
    ddr_sources = []
    if using_ddr and not using_2to1:
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
    upstream_2to1 = ROOT / 'third_party/gowin-ddr3'
    wrapper_2to1 = BOARD / 'gowin_ddr3_2to1.sv'
    upstream_cst = upstream_2to1 / 'examples/tang-primer-20k.cst'
    clock_constraints = BOARD / ('clocks-2to1.sdc' if using_2to1 else 'clocks.sdc')
    ddr_revision = None
    if using_2to1 and args.action in ('doctor', 'synth', 'pack', 'build', 'program', 'flash'):
        ddr_revision = verify_ddr_dependency(upstream_2to1)
        print(f'gowin-ddr3: {ddr_revision}', flush=True)
        if not upstream_cst.is_file():
            parser.error('gowin-ddr3 submodule unavailable; run make deps')
        ddr_sources = [wrapper_2to1]
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

    def build(route=True, pack_only=False):
        # A failed build must not leave an older bitstream eligible for load.
        (out / 'build-manifest.json').unlink(missing_ok=True)
        tool_versions = versions()
        simulate()
        script = out / 'synth.ys'
        define_text = ' '.join(boot_defines) + ' ' if args.design == 'cpu' else ''
        if using_2to1:
            define_text += "-DSETSUNA_GOWIN_DDR3 "
        includes = 'read -incdir third_party/gowin-ddr3\n' if using_2to1 else ""
        # Yosys 0.69 re-elaborates the already-flattened top at synth_gowin's
        # final hierarchy check when a parameterized OSER8_MEM is present.  Run
        # through map_cells, then perform the remaining safe checks explicitly.
        synth_suffix = (' -run begin:check' if using_ddr and not using_2to1 else '')
        script.write_text(includes + 'read_verilog -sv ' + ('-defer ' if not using_ddr else '') + define_text +
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
        if using_ddr:
            mapped_top = json.loads((out / 'synth.json').read_text())['modules'][design['top']]
            sdc_text = clock_constraints.read_text()
            for kind, name in re.findall(r'get_(nets|ports) \{([^}]+)\}', sdc_text):
                if name not in mapped_top['netnames' if kind == 'nets' else 'ports']:
                    raise SystemExit(f'DDR timing constraint matches no {kind}: {name}')
        if not route:
            return
        timing_options = (['--sdc', clock_constraints]
                          if using_ddr else [])
        constraints = BOARD / 'board.cst'
        if using_2to1:
            # Preserve the upstream electrical settings and differential pairs.
            constraints = out / 'board-2to1.cst'
            base = (BOARD / 'board.cst').read_text().splitlines()
            dock_leds = [line for line in base if line.startswith(('IO_LOC "led_n', 'IO_PORT "led_n'))]
            upstream_lines = upstream_cst.read_text().splitlines()
            constraints.write_text('\n'.join(dock_leds + [
                re.sub(r'("ddr_)ba(\[)', r'\1bank\2', line)
                for line in upstream_lines
                if not line.startswith(('IO_LOC "led"', 'IO_PORT "led"'))
            ]) + '\n')
        if args.design == 'cpu' and not using_ddr:
            constraints = out / 'rom.cst'
            constraints.write_text('\n'.join(line for line in (BOARD / 'board.cst').read_text().splitlines()
                                             if not line.startswith(('IO_LOC "ddr_', 'IO_PORT "ddr_'))) + '\n')
        route_options = (['--pack-only'] if pack_only else ['--report', out / 'timing.json'])
        netlist_output = out / ('packed.json' if pack_only else 'routed.json')
        pnr_log = run('nextpnr-himbaechel', *timing_options, '--json', out / 'synth.json', '--write', netlist_output,
            '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
            '--vopt', 'cst=' + str(constraints), '--freq', '27', '--seed', str(args.seed),
            '--router', args.router,
            *route_options, log='nextpnr.log')
        if pack_only:
            return
        bitstream = out / design['bitstream']
        if using_ddr and args.ddr_phy == 'portable':
            raise SystemExit('Portable PHY is experimental: differential CK/DQS pad mapping and '
                             'read capture validation are required before packing/programming.')
        if using_2to1:
            fmax = json.loads((out / 'timing.json').read_text())['fmax']
            timing_check = verify_ddr_timing(fmax, pnr_log)
        run('gowin_pack', '-c', '-d', 'GW2A-18', '-o', bitstream,
            out / 'routed.json', log='pack.log')
        report = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'suite': expected, 'tool_versions': tool_versions,
                  'design': args.design, 'top': design['top'],
                  'board': 'tangprimer20k', 'device': 'GW2A-LV18PG256C8/I7',
                  'clock_mhz': 27, 'seed': args.seed, 'router': args.router,
                  'ddr_controller_clock_mhz': (108 if using_2to1 else 99.5625) if using_ddr else None,
                  'ddr_clock_cdc': using_ddr,
                  'routed_fmax': fmax if using_2to1 else None,
                  'ddr_revision': ddr_revision,
                  'ddr_timing_check': timing_check if using_2to1 else None,
                  'nextpnr_log_sha256': sha256(out / 'nextpnr.log') if using_2to1 else None,
                  'timing_json_sha256': sha256(out / 'timing.json') if using_2to1 else None,
                  'boot_readback_enabled': using_ddr,
                  'boot_mode': args.boot_mode, 'led_mode': args.led_mode,
                  'cache_lines': args.cache_lines if args.design == 'cpu' else None,
                  'enable_m': enable_m if args.design == 'cpu' else None,
                  'ddr_phy': args.ddr_phy if using_ddr else None,
                  'timing_constraints': clock_constraints.name if using_ddr else None,
                  'program': str(program_source) if program_source else None,
                  'boot_image': str(boot_image), 'boot_words': boot_words,
                  'boot_image_sha256': sha256(boot_image),
                  'sources': {str(p.relative_to(ROOT)): sha256(p) for p in
                              design['test_sources'] + [BOARD/'board.cst', lock_path, Path(__file__)] +
                              ([clock_constraints, wrapper_2to1, upstream_cst] +
                                sorted((upstream_2to1/'ddr3').rglob('*.sv')) if using_2to1 else
                                [clock_constraints, ddr_upstream, ddr_sources[1]] if using_ddr else [])},
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
    elif args.action == 'pack':
        build(pack_only=True)
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
                     manifest.get('timing_constraints') != clock_constraints.name or
                     not manifest.get('ddr_clock_cdc') or
                     not manifest.get('boot_readback_enabled'))):
                raise SystemExit('CPU bitstream lacks validated PHY/timing constraints; rebuild required.')
            if using_ddr and manifest.get('ddr_phy') != args.ddr_phy:
                raise SystemExit('Bitstream DDR PHY differs from requested PHY.')
            if using_2to1 and manifest.get('suite') != expected:
                raise SystemExit('Bitstream does not use the pinned 2:1 toolchain.')
            if using_2to1:
                log_path, timing_path = out / 'nextpnr.log', out / 'timing.json'
                if any(not path.is_file() or sha256(path) != manifest.get(key)
                       for path, key in ((log_path, 'nextpnr_log_sha256'),
                                         (timing_path, 'timing_json_sha256'))):
                    raise SystemExit('DDR timing evidence missing or changed; rebuild required.')
                fmax = json.loads(timing_path.read_text())['fmax']
                check = verify_ddr_timing(fmax, log_path.read_text())
                if fmax != manifest.get('routed_fmax') or check != manifest.get('ddr_timing_check'):
                    raise SystemExit('DDR timing evidence differs from manifest; rebuild required.')
            if args.design == 'cpu' and manifest.get('boot_mode', 'ddr') != args.boot_mode:
                raise SystemExit('Bitstream boot mode differs from requested mode; select the correct build.')
            if args.design == 'cpu' and manifest.get('led_mode', 'gpio') != args.led_mode:
                raise SystemExit('Bitstream LED mode differs from requested mode.')
            if args.design == 'cpu' and manifest.get('cache_lines', 2) != args.cache_lines:
                raise SystemExit('Bitstream cache size differs from requested size.')
            if args.design == 'cpu' and manifest.get('enable_m', False) != enable_m:
                raise SystemExit('Bitstream M-extension mode differs from requested mode.')
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
        options = ['-f'] if args.action == 'flash' else ['--write-sram']
        bitstream = out / design['bitstream']
        log_name = 'program.log' if args.action in ('program', 'load') else 'flash.log'
        run('openFPGALoader', *probe, *options, bitstream, log=log_name)
        (out/'program-manifest.json').write_text(json.dumps({
            'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'mode': args.action, 'design': args.design, 'serial': args.serial,
            'experimental': args.experimental_load,
            'ddr_phy': args.ddr_phy if using_ddr else None,
            'boot_mode': args.boot_mode, 'led_mode': args.led_mode,
            'cache_lines': args.cache_lines if args.design == 'cpu' else None,
            'enable_m': enable_m if args.design == 'cpu' else None,
            'bitstream': design['bitstream'],
            'bitstream_sha256': sha256(bitstream), 'command': history[-1]}, indent=2)+'\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
