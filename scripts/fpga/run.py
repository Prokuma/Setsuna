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
    parser.add_argument('action', choices=['doctor', 'sim', 'build', 'scan', 'detect', 'program', 'flash'])
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
        run('iverilog', '-g2012', '-s', 'blink_tb', '-o', out / 'blink_tb.vvp',
            BOARD / 'blink.v', BOARD / 'blink_tb.v', log='iverilog.log')
        run('vvp', out / 'blink_tb.vvp', log='simulation.log')

    def build():
        tool_versions = versions()
        simulate()
        script = out / 'synth.ys'
        script.write_text('read_verilog ' + json.dumps(str(BOARD / 'blink.v')) + '\n' +
                          'synth_gowin -top blink -family gw2a -json ' +
                          json.dumps(str(out / 'synth.json')) + '\n')
        run('yosys', '-s', script, log='yosys.log')
        run('nextpnr-himbaechel', '--json', out / 'synth.json', '--write', out / 'routed.json',
            '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
            '--vopt', 'cst=' + str(BOARD / 'board.cst'), '--freq', '27', '--seed', '1',
            '--report', out / 'timing.json', log='nextpnr.log')
        run('gowin_pack', '-c', '-d', 'GW2A-18', '-o', out / 'blink.fs', out / 'routed.json', log='pack.log')
        report = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'suite': expected, 'tool_versions': tool_versions,
                  'board': 'tangprimer20k', 'device': 'GW2A-LV18PG256C8/I7',
                  'clock_mhz': 27, 'seed': 1,
                  'sources': {str(p.relative_to(ROOT)): sha256(p) for p in
                              (BOARD/'blink.v', BOARD/'board.cst', BOARD/'blink_tb.v', LOCK, Path(__file__))},
                  'bitstream_sha256': sha256(out/'blink.fs'), 'commands': history.copy()}
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
        # Always build current sources before programming; do not use stale bitstreams.
        build()
        run('openFPGALoader', *probe, '--detect', log='detect.log')
        options = ['-f'] if args.action == 'flash' else []
        run('openFPGALoader', *probe, *options, out/'blink.fs', log=args.action+'.log')
        (out/'program-manifest.json').write_text(json.dumps({
            'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'mode': args.action, 'serial': args.serial,
            'bitstream_sha256': sha256(out/'blink.fs'), 'command': history[-1]}, indent=2)+'\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
