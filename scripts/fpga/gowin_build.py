#!/usr/bin/env python3
"""Run an exported Gowin project; never program or certify DDR timing."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gw-sh', default='gw_sh', help='Gowin EDA command-line executable')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root/'export-manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if sha256(root/name) != expected:
            raise SystemExit(f'Export changed: {name}; export again into a new directory.')
    tool = shutil.which(args.gw_sh)
    if not tool:
        raise SystemExit('gw_sh not found. Install Gowin EDA with GW2A-18C support and pass --gw-sh.')
    report_path = root/'vendor-build-report.json'
    report_path.unlink(missing_ok=True)
    # Insert the host-local absolute ROM path at build time so the exported
    # project can be moved to another machine, including directories with spaces.
    board = (root/'src/fpga/tang-primer-20k/setsuna_soc.v').read_text()
    marker = '`define SETSUNA_BOOT_IMAGE "boot_image.hex"'
    if board.count(marker) != 1:
        raise SystemExit('Cannot resolve boot image path')
    board = board.replace(marker, '`define SETSUNA_BOOT_IMAGE ' +
                          json.dumps((root/'boot_image.hex').as_posix(), ensure_ascii=False))
    (root/'generated').mkdir(exist_ok=True)
    (root/'generated/setsuna_soc.v').write_text(board)
    # Reject a stale bitstream if this invocation fails or produces no output.
    bitstream = root/'impl/pnr/setsuna_ddr.fs'
    bitstream.unlink(missing_ok=True)
    command = [tool, str(root/'project.tcl')]
    with (root/'vendor-build.log').open('w') as stream:
        result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
    report = {'command': command, 'tool_sha256': sha256(Path(tool)),
              'export_manifest_sha256': sha256(root/'export-manifest.json'),
              'exit_code': result.returncode, 'timing_reviewed': False,
              'bitstream_sha256': sha256(bitstream) if result.returncode == 0 and bitstream.exists() else None}
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    if result.returncode or not bitstream.exists():
        raise SystemExit(f'Gowin build did not produce a bitstream; inspect {root/"vendor-build.log"}')
    print(f'Created {bitstream}. Review timing reports before SRAM programming.')


if __name__ == '__main__':
    try:
        main()
    except OSError as error:
        sys.exit(str(error))
