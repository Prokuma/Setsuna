#!/usr/bin/env python3
"""Export a relocatable native-DDR project for Gowin EDA (no programming)."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from setup import ROOT, sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'build/fpga/gowin-ddr')
    parser.add_argument('--program', type=Path, help='flat RV64 binary, entry 0x80000000')
    parser.add_argument('--cache-lines', type=int, default=256)
    parser.add_argument('--disable-m', action='store_true')
    parser.add_argument('--led-mode', choices=['gpio', 'status', 'ddr'], default='ddr')
    args = parser.parse_args()
    if args.cache_lines < 2 or args.cache_lines > 256 or args.cache_lines & (args.cache_lines - 1):
        parser.error('--cache-lines must be a power of two from 2 to 256')
    out = args.output.resolve()
    if out == ROOT or ROOT.is_relative_to(out):
        parser.error('--output must not be the repository or its ancestor')
    # Never overwrite an existing project with vendor reports or manual edits.
    if out.exists() and any(out.iterdir()):
        parser.error('output is not empty; choose a new output directory')
    if args.program:
        data = args.program.read_bytes()
        if not data or len(data) > 96 * 1024:
            parser.error('program must contain 1..98304 bytes')
        data += bytes((-len(data)) % 8)
        image = ''.join(f'{int.from_bytes(data[i:i+8], "little"):016x}\n'
                        for i in range(0, len(data), 8))
    else:
        image = (ROOT/'fpga/tang-primer-20k/demo_program.hex').read_text()
    words = len(image.split())
    files = sorted(p for p in (ROOT/'verilog').rglob('*.v') if 'test' not in p.parts)
    files += [ROOT/'fpga/tang-primer-20k/setsuna_soc.v',
              ROOT/'fpga/tang-primer-20k/tang_primer_20k_ddr3.v',
              ROOT/'third_party/ddr3-tang-primer-20k/src/ddr3_controller.v',
              ROOT/'third_party/ddr3-tang-primer-20k/src/gowin_rpll/gowin_rpll.v']
    # Preserve the actual vendor DLL and calibration code, without OSS patches.
    for source in files:
        target = out/'src'/source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    (out/'boot_image.hex').write_text(image)
    shutil.copyfile(ROOT/'fpga/tang-primer-20k/board.cst', out/'board.cst')
    with (out/'board.cst').open('a') as stream:
        stream.write('\nINS_LOC "ddr_boot/physical_memory/hardware_phy/pll/rpll_inst" PLL_L[0];\n')
    shutil.copyfile(ROOT/'scripts/fpga/gowin_build.py', out/'build.py')
    shutil.copyfile(ROOT/'third_party/ddr3-tang-primer-20k/LICENSE', out/'DDR-CONTROLLER-LICENSE')
    overrides = {'SETSUNA_BOOT_IMAGE': '"boot_image.hex"', 'SETSUNA_BOOT_WORDS': str(words),
                 'SETSUNA_LED_STATUS': str(dict(gpio=0, status=1, ddr=2)[args.led_mode]),
                 'SETSUNA_BOOT_FROM_DDR': '1', 'SETSUNA_CACHE_LINES': str(args.cache_lines),
                 'SETSUNA_CACHE_INDEX_BITS': str(args.cache_lines.bit_length()-1),
                 'SETSUNA_ENABLE_M': str(int(not args.disable_m))}
    board = out/'src/fpga/tang-primer-20k/setsuna_soc.v'
    text = board.read_text()
    for key, value in overrides.items():
        text, count = re.subn(r'^`define ' + key + r' .*$', f'`define {key} {value}', text,
                             count=1, flags=re.MULTILINE)
        if count != 1:
            raise SystemExit(f'Cannot set board configuration: {key}')
    board.write_text(text)
    (out/'clocks.sdc').write_text('''# Native DDR clocks. CPU remains on the board's 27 MHz clock.
create_clock -name cpu -period 37.037037 [get_ports {clk}]
create_clock -name ddr_fast -period 2.510986 [get_pins {ddr_boot/physical_memory/hardware_phy/pll/rpll_inst/CLKOUT}]
create_clock -name ddr_phase -period 2.510986 -waveform {0.6277465 1.8832395} [get_pins {ddr_boot/physical_memory/hardware_phy/pll/rpll_inst/CLKOUTP}]
create_generated_clock -name controller -source [get_pins {ddr_boot/physical_memory/hardware_phy/pll/rpll_inst/CLKOUT}] -divide_by 4 [get_pins {ddr_boot/physical_memory/hardware_phy/pll/rpll_inst/CLKOUTD}]
# CDC bundled payloads and external DDR setup/hold require timing review.
# No blanket false-path exceptions hide those paths.
''')
    commands = ['cd [file dirname [file normalize [info script]]]',
                'set_device -name GW2A-18C GW2A-LV18PG256C8/I7',
                'set_option -synthesis_tool gowinsynthesis',
                'set_option -top_module tang_primer_20k_soc',
                'set_option -output_base_name setsuna_ddr',
                'set_option -verilog_std sysv2017',
                'set_option -use_sspi_as_gpio 1']
    for source in files:
        relative = Path('src')/source.relative_to(ROOT)
        if source.name == 'setsuna_soc.v':
            relative = Path('generated/setsuna_soc.v')
        commands.append(f'add_file -type verilog {{{relative.as_posix()}}}')
    commands += ['add_file -type cst {board.cst}', 'add_file -type sdc {clocks.sdc}', 'run all']
    (out/'project.tcl').write_text('\n'.join(commands)+'\n')
    (out/'README.txt').write_text('''Native DDR project for Tang Primer 20K + Dock.
Requires a separately installed/licensed Gowin EDA with GW2A-18C support.
Build: python3 build.py --gw-sh /path/to/IDE/bin/gw_sh
This runs synthesis/place-and-route only. It never programs hardware.
Review vendor setup/hold, CDC, unconstrained-path and DDR I/O timing reports.
A .fs file by itself does not prove timing closure or hardware operation.
LEDs 0..5 (active-low), default ddr mode:
PHY initialized, readback started, boot verified, CPU fetched, failure/trap, heartbeat.
Error codes in RTL: 1 mismatch, 2 write/init timeout, 3 read timeout.
The original upstream DLL/write-leveling/read-calibration logic is retained.
The proprietary tool flow has not been validated until it runs on your host.
''')
    manifest = {'device': 'GW2A-LV18PG256C8/I7', 'vendor_family': 'GW2A-18C',
                'cache_lines': args.cache_lines, 'enable_m': not args.disable_m,
                'led_mode': args.led_mode, 'boot_words': words,
                'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
                'upstream_commit': subprocess.check_output(['git', '-C', str(ROOT/'third_party/ddr3-tang-primer-20k'),
                                                            'rev-parse', 'HEAD'], text=True).strip(),
                'source_hashes': {str(p.relative_to(ROOT)): sha256(p) for p in files},
                'files': {p.relative_to(out).as_posix(): sha256(p) for p in sorted(out.rglob('*')) if p.is_file()}}
    (out/'export-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Exported native DDR sources to {out}')
    print('Gowin EDA build and timing closure have NOT been run by export.')


if __name__ == '__main__':
    main()
