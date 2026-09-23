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
    'boot_rom': ['verilog/memory/boot_rom.v', 'verilog/test/boot_rom_tb.v'],
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
    'dram_memory': ['verilog/memory/dram_boot_loader.v',
                    'verilog/memory/memory_arbiter.v',
                    'verilog/memory/ddr3_bus_adapter.v',
                    'verilog/memory/dram_memory_subsystem.v',
                    'verilog/test/dram_memory_tb.v'],
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
    if 'boot_rom' in tests:
        # RTL simulation alone did not detect overlapping zero-fill/$readmemh
        # initialization being resolved differently by Yosys.
        memory_json = (args.build_dir/'boot-rom-memory.json').resolve()
        memory_script = (
            'read_verilog -sv verilog/memory/boot_rom.v; '
            'chparam -set IMAGE_WORDS 6 -set IMAGE_FILE '
            '"fpga/tang-primer-20k/demo_program_sim.hex" boot_rom; '
            'hierarchy -top boot_rom; proc; memory_collect; write_json ' +
            json.dumps(str(memory_json)))
        with (args.build_dir/'boot-rom-memory.log').open('w') as log:
            subprocess.run([str(yosys), '-p', memory_script], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        cells = json.loads(memory_json.read_text())['modules']['boot_rom']['cells']
        memories = [c for c in cells.values() if c['type'] == '$mem_v2']
        if len(memories) != 1:
            raise SystemExit('Expected one synthesized boot ROM')
        init = memories[0]['parameters']['INIT']
        words = [int(w, 16) for w in
                 (ROOT/'fpga/tang-primer-20k/demo_program_sim.hex').read_text().split()]
        actual = [init[len(init)-(i+1)*64:len(init)-i*64] for i in range(len(init)//64)]
        expected = [f'{w:064b}' for w in words] + ['0'*64] * (len(actual)-len(words))
        if actual != expected:
            raise SystemExit('Synthesized ROM initialization differs from program image/padding')
        print('PASS: synthesized ROM contains exact program image and zero padding')
    print(f'PASS: {len(tests)} RTL suites, integrated top compile, and Yosys structural check')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
