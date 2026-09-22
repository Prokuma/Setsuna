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
    parser.add_argument('action', choices=['doctor', 'sim', 'build', 'scan', 'detect',
                                           'program', 'load', 'flash'])
    parser.add_argument('--design', choices=['cpu', 'blink'], default='cpu',
                        help='design to test/build/program (default: cpu)')
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/fpga/tang-primer-20k')
    parser.add_argument('--serial', help='USB probe serial number, when multiple boards are connected')
    parser.add_argument('--jtag-hz', type=int, default=2500000, help='JTAG clock (default: 2500000 Hz)')
    args = parser.parse_args()
    if args.jtag_hz <= 0:
        parser.error('--jtag-hz must be positive')
    lock = json.loads(LOCK.read_text())
    suite = install_path(lock)
    marker = suite / '.setsuna-install.json'
    expected = {'release': lock['release'], 'host': host_key(), 'sha256': lock['assets'][host_key()]['sha256']}
    if not marker.exists() or json.loads(marker.read_text()) != expected:
        parser.error('Pinned OSS CAD Suite not installed; run make fpga-setup')
    out = args.build_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env['PATH'] = str(suite / 'bin') + os.pathsep + env.get('PATH', '')
    # Upstream executable wrappers configure their own libraries and Python.
    history = []

    rtl_sources = sorted((ROOT / 'verilog').glob('**/*.v'))
    rtl_sources = [path for path in rtl_sources if 'test' not in path.parts]
    designs = {
        'cpu': {
            'top': 'tang_primer_20k_soc',
            'test_top': 'tang_primer_20k_soc_tb',
            'sources': rtl_sources + [BOARD / 'setsuna_soc.v'],
            'test_sources': rtl_sources + [BOARD / 'setsuna_soc.v', BOARD / 'setsuna_soc_tb.v'],
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
        run('iverilog', '-g2012', '-s', design['test_top'], '-o', simulation,
            *design['test_sources'], log='iverilog.log')
        run('vvp', simulation, log='simulation.log')

    def build():
        tool_versions = versions()
        simulate()
        script = out / 'synth.ys'
        script.write_text('read_verilog -sv ' +
                          ' '.join(json.dumps(str(source)) for source in design['sources']) + '\n' +
                          'synth_gowin -top ' + design['top'] + ' -family gw2a\n' +
                          'setundef -zero\n' +
                          'opt_clean\n' +
                          'write_json ' + json.dumps(str(out / 'synth.json')) + '\n')
        run('yosys', '-s', script, log='yosys.log')
        run('nextpnr-himbaechel', '--json', out / 'synth.json', '--write', out / 'routed.json',
            '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
            '--vopt', 'cst=' + str(BOARD / 'board.cst'), '--freq', '27', '--seed', '1',
            '--report', out / 'timing.json', log='nextpnr.log')
        bitstream = out / design['bitstream']
        run('gowin_pack', '-c', '-d', 'GW2A-18', '-o', bitstream, out / 'routed.json', log='pack.log')
        report = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'suite': expected, 'tool_versions': tool_versions,
                  'design': args.design, 'top': design['top'],
                  'board': 'tangprimer20k', 'device': 'GW2A-LV18PG256C8/I7',
                  'clock_mhz': 27, 'seed': 1,
                  'sources': {str(p.relative_to(ROOT)): sha256(p) for p in
                              design['test_sources'] + [BOARD/'board.cst', LOCK, Path(__file__)]},
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
            bitstream = out / design['bitstream']
            if (manifest.get('design') != args.design or
                    manifest.get('bitstream') != design['bitstream'] or
                    not bitstream.exists() or
                    manifest.get('bitstream_sha256') != sha256(bitstream)):
                raise SystemExit('Existing bitstream does not match its build manifest; rebuild it.')
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
            'bitstream': design['bitstream'],
            'bitstream_sha256': sha256(bitstream), 'command': history[-1]}, indent=2)+'\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
