#!/usr/bin/env python3
"""Build pinned upstream RV64GC p-environment tests without modifying their sources."""
import argparse
import hashlib
import json
import pathlib
import platform
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
GROUPS = ('rv64ui', 'rv64um', 'rv64ua', 'rv64uf', 'rv64ud', 'rv64uc')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--sim', default='build/setsuna-sim')
    p.add_argument('--cc', default='riscv64-unknown-elf-gcc')
    p.add_argument('--build-only', action='store_true', help='Build test ELFs without running the simulator')
    p.add_argument('--groups', nargs='+', choices=GROUPS, default=GROUPS)
    args = p.parse_args()
    source = ROOT / 'third_party/riscv-tests'
    sim = pathlib.Path(args.sim).resolve()
    out = sim.parent / 'riscv-tests'
    out.mkdir(parents=True, exist_ok=True)
    if not (source / 'env/p/link.ld').exists():
        p.error('Missing test sources: run make deps')
    results = []
    for group in args.groups:
        frag = (source / 'isa' / group / 'Makefrag').read_text().replace('\\\n', ' ')
        match = re.search(rf'^{group}_sc_tests\s*=\s*(.*)$', frag, re.MULTILINE)
        if not match:
            p.error(f'Cannot parse {group}/Makefrag')
        for name in match[1].split():
            test = f'{group}-p-{name}'
            if group == 'rv64ua' and name in ('amocas_w', 'amocas_d', 'amocas_q'):
                results.append({'test': test, 'status': 'OUT_OF_SCOPE',
                                'reason': 'Requires Zacas, which is not part of RV64GC'})
                (out / (test+'.log')).write_text('OUT_OF_SCOPE: Zacas is not part of RV64GC\n')
                print(f'OUT_OF_SCOPE {test} (Zacas)', flush=True)
                continue
            elf = out / test
            cmd = [args.cc, '-march=rv64g', '-mabi=lp64d', '-static', '-mcmodel=medany',
                   '-fvisibility=hidden', '-nostdlib', '-nostartfiles',
                   '-I' + str(source / 'env/p'), '-I' + str(source / 'isa/macros/scalar'),
                   '-T' + str(source / 'env/p/link.ld'), str(source / 'isa' / group / (name+'.S')),
                   '-o', str(elf)]
            build = subprocess.run(cmd, capture_output=True, text=True)
            log = build.stdout + build.stderr
            status = 'BUILD_ERROR'
            if build.returncode == 0 and args.build_only:
                status = 'BUILT'
            elif build.returncode == 0:
                try:
                    run = subprocess.run([str(sim), '--elf', str(elf),
                                          '--max-cycles', '2000000'], capture_output=True, text=True, timeout=30)
                    log += run.stdout + run.stderr
                    status = {0: 'PASS', 1: 'FAIL', 2: 'ERROR', 3: 'TIMEOUT'}.get(run.returncode, 'ERROR')
                except subprocess.TimeoutExpired:
                    status = 'HOST_TIMEOUT'
            (out / (test+'.log')).write_text(log)
            results.append({'test': test, 'status': status})
            print(f'{status:12} {test}', flush=True)
    report = {'mode': 'build' if args.build_only else 'run',
              'simulator_sha256': None if args.build_only else hashlib.sha256(sim.read_bytes()).hexdigest(),
              'host': platform.platform(), 'machine': platform.machine(),
              'riscv_tests_commit': subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'], text=True).strip(),
              'softfloat_commit': subprocess.check_output(['git','-C',str(ROOT/'third_party/softfloat'),'rev-parse','HEAD'], text=True).strip(),
              'compiler': subprocess.check_output([args.cc,'--version'], text=True).splitlines()[0],
              'results': results}
    (out/('build-results.json' if args.build_only else 'results.json')).write_text(json.dumps(report, indent=2)+'\n')
    passed = sum(r['status']==('BUILT' if args.build_only else 'PASS') for r in results)
    targeted = sum(r['status'] != 'OUT_OF_SCOPE' for r in results)
    print(f'{passed}/{targeted} {"built" if args.build_only else "passed"}; {len(results)-targeted} out of scope; logs: {out}')
    return int(passed != targeted or not targeted)

if __name__ == '__main__':
    sys.exit(main())
