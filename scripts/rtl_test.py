#!/usr/bin/env python3
"""Compile and run the synthesizable RTL test suites with Icarus Verilog."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = {
    'core': ['verilog/core/register_file.v', 'verilog/core/decode.v',
             'verilog/core/execute.v', 'verilog/core/core.v', 'verilog/test/core_tb.v'],
    'cache': ['verilog/cache/cache.v', 'verilog/test/cache_tb.v'],
    'peripheral': ['verilog/peripheral/gpio.v', 'verilog/peripheral/uart_tx.v',
                   'verilog/peripheral/peripheral_bus.v', 'verilog/test/peripheral_tb.v'],
    'setsuna': ['verilog/core/register_file.v', 'verilog/core/decode.v',
                'verilog/core/execute.v', 'verilog/core/core.v',
                'verilog/cache/cache.v', 'verilog/peripheral/gpio.v',
                'verilog/peripheral/uart_tx.v', 'verilog/peripheral/peripheral_bus.v',
                'verilog/setsuna.v', 'verilog/test/setsuna_tb.v'],
}


def suite_tools():
    lock_path = ROOT / 'scripts/fpga/oss-cad-suite.lock.json'
    if lock_path.exists():
        lock = json.loads(lock_path.read_text())
        system = {'Darwin': 'darwin', 'Linux': 'linux'}.get(platform.system())
        machine = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64'}.get(platform.machine())
        if system and machine:
            root = ROOT / '.tools/oss-cad-suite' / lock['release'] / (system+'-'+machine) / 'oss-cad-suite/bin'
            if all((root/tool).exists() for tool in ('iverilog', 'vvp', 'yosys')):
                return root/'iverilog', root/'vvp', root/'yosys'
    iv = shutil.which('iverilog')
    vvp = shutil.which('vvp')
    yosys = shutil.which('yosys')
    if not iv or not vvp or not yosys:
        raise SystemExit('Icarus Verilog/Yosys not found; run make fpga-setup or install iverilog, vvp, and yosys.')
    return Path(iv), Path(vvp), Path(yosys)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tests', nargs='*', choices=sorted(TESTS))
    parser.add_argument('--build-dir', type=Path, default=ROOT/'build/rtl-tests')
    args = parser.parse_args()
    tests = args.tests or sorted(TESTS)
    iv, vvp, yosys = suite_tools()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    for name in tests:
        output = args.build_dir / (name+'.vvp')
        compile_command = [str(iv), '-g2012', '-Wall', '-s', name+'_tb', '-o', str(output)]
        compile_command += [str(ROOT/path) for path in TESTS[name]]
        print('+', ' '.join(compile_command), flush=True)
        subprocess.run(compile_command, cwd=ROOT, check=True, timeout=60)
        subprocess.run([str(vvp), str(output)], cwd=ROOT, check=True, timeout=60)
    # Compile the integrated top independently to catch interface drift.
    all_rtl = sorted(str(path) for path in (ROOT/'verilog').glob('**/*.v') if 'test' not in path.parts)
    subprocess.run([str(iv), '-g2012', '-Wall', '-s', 'setsuna', '-tnull', *all_rtl],
                   check=True, timeout=60)
    yosys_script = ('read_verilog -sv ' + ' '.join(all_rtl) +
                    '; hierarchy -check -top setsuna; proc; check')
    with (args.build_dir/'yosys-check.log').open('w') as log:
        subprocess.run([str(yosys), '-p', yosys_script], stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=60)
    print(f'PASS: {len(tests)} RTL suites, integrated top compile, and Yosys structural check')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
