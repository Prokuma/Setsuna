#!/usr/bin/env python3
"""Compile and run the synthesizable RTL test suites with Icarus Verilog."""
import argparse
from collections import Counter
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
             'verilog/core/execute.v', 'verilog/core/iterative_divider.v',
             'verilog/core/core.v', 'verilog/test/core_tb.v'],
    'core_m': ['verilog/core/register_file.v', 'verilog/core/decode.v',
               'verilog/core/execute.v', 'verilog/core/iterative_divider.v',
               'verilog/core/core.v', 'verilog/test/core_div_tb.v'],
    'cache': ['verilog/cache/cache.v', 'verilog/test/cache_tb.v'],
    'peripheral': ['verilog/peripheral/gpio.v', 'verilog/peripheral/uart_tx.v',
                   'verilog/peripheral/peripheral_bus.v', 'verilog/test/peripheral_tb.v'],
    'setsuna': ['verilog/core/register_file.v', 'verilog/core/decode.v',
                'verilog/core/execute.v', 'verilog/core/iterative_divider.v',
                'verilog/core/core.v',
                'verilog/cache/cache.v', 'verilog/peripheral/gpio.v',
                'verilog/peripheral/uart_tx.v', 'verilog/peripheral/peripheral_bus.v',
                'verilog/setsuna.v', 'verilog/test/setsuna_tb.v'],
    'dram_memory': ['verilog/memory/dram_boot_loader.v',
                    'verilog/memory/memory_arbiter.v',
                    'verilog/memory/ddr3_bus_adapter.v',
                    'verilog/memory/dram_memory_subsystem.v',
                    'verilog/test/dram_memory_tb.v'],
    'ddr_cdc': ['verilog/memory/ddr3_command_cdc.v', 'verilog/test/ddr_cdc_tb.v'],
    'dram_boot': ['verilog/memory/dram_boot_loader.v', 'verilog/test/dram_boot_tb.v'],
}


def suite_tools():
    for lock_name in ('oss-cad-suite.lock.json', 'oss-cad-suite-ddr.lock.json'):
        lock_path = ROOT / 'scripts/fpga' / lock_name
        if not lock_path.exists():
            continue
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


def check_board_ddr(iv, vvp, yosys, all_rtl, out):
    board = ROOT / 'fpga/tang-primer-20k'
    sources = [*all_rtl, str(board/'setsuna_soc.v'), str(board/'tang_primer_20k_ddr3.v')]
    for image, message, enable_m in [('demo_program.hex', 'Setsuna ready', 0),
                                      ('ddr_m_smoke.hex', 'Setsuna DDR M PASS', 1)]:
        program = board/image
        words = len(program.read_text().split())
        output = out/(program.stem+'.vvp')
        subprocess.run([str(iv), '-g2012', '-s', 'uart_boot_tb', '-o', str(output),
                        f'-Puart_boot_tb.EXPECTED="{message}"',
                        f'-DSETSUNA_BOOT_IMAGE="{program}"', f'-DSETSUNA_BOOT_WORDS={words}',
                        f'-DSETSUNA_ENABLE_M={enable_m}', *sources, str(board/'uart_boot_tb.v')],
                       cwd=ROOT, check=True, timeout=60)
        subprocess.run([str(vvp), str(output)], cwd=ROOT, check=True, timeout=60)

    upstream = ROOT / 'third_party/gowin-ddr3'
    if not (upstream/'ddr3/ddr3_ctrl.sv').is_file():
        raise SystemExit('gowin-ddr3 submodule missing; run make deps.')
    script = ('read -incdir third_party/gowin-ddr3; read_verilog -lib +/gowin/cells_sim.v; '
              'read_verilog -lib +/gowin/cells_xtra_gw2a.v; '
              'read_verilog -sv -DSETSUNA_GOWIN_DDR3 ' +
              ' '.join(json.dumps(p) for p in [*sources, str(board/'gowin_ddr3_2to1.sv')]) +
              '; hierarchy -check -top tang_primer_20k_soc')
    with (out/'gowin-ddr3-hierarchy.log').open('w') as log:
        subprocess.run([str(yosys), '-p', script], cwd=ROOT, check=True, timeout=60,
                       stdout=log, stderr=subprocess.STDOUT)
    print('PASS: actual 2:1 DDR top elaborates with upstream PHY and Gowin cells')

    for words in (32, 33):
        image = (out/f'boot-map-{words}.hex').resolve()
        # Distinct whole words exercise the address and all data bits.
        image.write_text(''.join(f'{(i*0x9e3779b97f4a7c15) % 2**64:016x}\n' for i in range(words)))
        netlist = image.with_suffix('.json')
        script = ('read_verilog -sv verilog/memory/dram_boot_loader.v; '
                  f'chparam -set IMAGE_WORDS {words} -set IMAGE_FILE {json.dumps(str(image))} dram_boot_loader; '
                  'synth_gowin -top dram_boot_loader -family gw2a; write_json ' + json.dumps(str(netlist)))
        with image.with_suffix('.log').open('w') as log:
            subprocess.run([str(yosys), '-p', script], cwd=ROOT, check=True, timeout=60,
                           stdout=log, stderr=subprocess.STDOUT)
        cells = json.loads(netlist.read_text())['modules']['dram_boot_loader']['cells']
        counts = Counter(cell['type'] for cell in cells.values())
        bram = sum(counts[t] for t in ('SP', 'SPX9', 'SDP', 'SDPX9', 'SDPX9B', 'DP', 'DPX9', 'DPX9B', 'ROM', 'ROMX9'))
        lut = sum(n for t, n in counts.items() if t.startswith('LUT'))
        dff = sum(n for t, n in counts.items() if t.startswith('DFF'))
        if (words == 32 and (bram or not lut)) or (words == 33 and not bram):
            raise SystemExit(f'Unexpected Gowin mapping at {words} words: {counts}')
        print(f'PASS: boot ROM {words} words: BSRAM {bram}, LUT4 {counts["LUT4"]}, total LUT {lut}, DFF {dff}')

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
    if 'cache' in tests:
        mapped_json = (args.build_dir/'cache-gowin.json').resolve()
        mapping_script = ('read_verilog -sv verilog/cache/cache.v; '
                          'synth_gowin -top cache -family gw2a; write_json ' +
                          json.dumps(str(mapped_json)))
        with (args.build_dir/'cache-gowin.log').open('w') as log:
            subprocess.run([str(yosys), '-p', mapping_script], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        mapped_cells = json.loads(mapped_json.read_text())['modules']['cache']['cells']
        brams = sum(cell['type'] in ('SP', 'SPX9', 'SDP', 'SDPX9', 'SDPX9B',
                                    'DP', 'DPX9', 'DPX9B') for cell in mapped_cells.values())
        if brams < 4:
            raise SystemExit('Cache data and tags did not both map to Gowin block RAM')
        print(f'PASS: cache data and tags mapped to {brams} Gowin block RAM cells')
    for test_name, module, filename in [('boot_rom', 'boot_rom', 'demo_program.hex'),
                                        ('dram_boot', 'dram_boot_loader', 'demo_program.hex'),
                                        ('dram_boot', 'dram_boot_loader', 'ddr_m_smoke.hex')]:
        if test_name not in tests:
            continue
        # RTL simulation alone did not detect overlapping zero-fill/$readmemh
        # initialization being resolved differently by Yosys.
        image = ROOT/'fpga/tang-primer-20k'/filename
        words = [int(w, 16) for w in image.read_text().split()]
        stem = f'{module}-{image.stem}-memory'
        memory_json = (args.build_dir/(stem+'.json')).resolve()
        memory_script = (
            f'read_verilog -sv verilog/memory/{module}.v; '
            f'chparam -set IMAGE_WORDS {len(words)} -set IMAGE_FILE {json.dumps(str(image))} {module}; '
            f'hierarchy -top {module}; proc; memory_collect; write_json ' +
            json.dumps(str(memory_json)))
        with (args.build_dir/(stem+'.log')).open('w') as log:
            subprocess.run([str(yosys), '-p', memory_script], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        cells = json.loads(memory_json.read_text())['modules'][module]['cells']
        memories = [c for c in cells.values() if c['type'] == '$mem_v2']
        if len(memories) != 1:
            raise SystemExit('Expected one synthesized boot ROM')
        init = memories[0]['parameters']['INIT']
        actual = [init[len(init)-(i+1)*64:len(init)-i*64] for i in range(len(init)//64)]
        expected = [f'{w:064b}' for w in words] + ['0'*64] * (len(actual)-len(words))
        if actual != expected:
            raise SystemExit('Synthesized ROM initialization differs from program image/padding')
        print(f'PASS: Yosys {module} ROM initialization matches {filename} and zero padding')
    if 'dram_boot' in tests:
        check_board_ddr(iv, vvp, yosys, all_rtl, args.build_dir)
    print(f'PASS: {len(tests)} RTL suites, integrated top compile, and Yosys structural check')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
