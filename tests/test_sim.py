#!/usr/bin/env python3
"""End-to-end regressions using hand-encoded guest code; no cross compiler needed."""
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest

SIM = pathlib.Path(sys.argv.pop(1)).resolve()
BASE = 0x80000000

def i(op, rd, f, rs, imm):
    return op | rd << 7 | f << 12 | rs << 15 | (imm & 4095) << 20

def s(rs, value, off, f=3):
    return 0x23 | (off & 31) << 7 | f << 12 | rs << 15 | value << 20 | (off & 0xfe0) << 20

def branch(rs, rt, off, f=0):
    return 0x63 | (off & 0x800) >> 4 | (off & 30) << 7 | f << 12 | rs << 15 | rt << 20 | (off & 0x7e0) << 20 | (off & 0x1000) << 19

def words(*items):
    return struct.pack('<'+'I'*len(items), *items)

def passed():
    return [i(0x13, 2, 0, 0, 1), s(1, 2, 256)]

def elf(code, memsize=None):
    # One RX PT_LOAD; bare-metal RAM is readable/writable by the execution environment.
    ident = b'\x7fELF\x02\x01\x01' + bytes(9)
    header = ident + struct.pack('<HHIQQQIHHHHHH', 2, 243, 1, BASE, 64, 0, 0, 64, 56, 1, 64, 0, 0)
    ph = struct.pack('<IIQQQQQQ', 1, 5, 120, BASE, BASE, len(code), memsize or len(code), 4)
    return header + ph + code

class SimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_guest(self, data, *, is_elf=False, extra=(), commands=None):
        path = self.root / 'guest'
        path.write_bytes(data)
        trace = self.root / 'trace.jsonl'
        run = subprocess.run([str(SIM), '--elf' if is_elf else '--binary', str(path),
                              '--tohost', hex(BASE+256), '--trace', str(trace),
                              '--max-cycles', '500', *extra], input=commands, text=True,
                             capture_output=True, timeout=10)
        records = [json.loads(l) for l in trace.read_text().splitlines()] if trace.exists() else []
        return run, records

    def test_forwarding_and_x0(self):
        code = words(0x97, i(0x13,0,0,0,5), i(0x13,3,0,0,4), i(0x13,4,0,3,-3), s(1,4,256))
        run, trace = self.run_guest(code)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        self.assertEqual(trace[-1]['data'], '0x0000000000000001')

    def test_load_use_stall_and_store_forwarding(self):
        code = words(0x97, i(0x13,2,0,0,7), s(1,2,128), i(3,3,3,1,128), i(0x13,4,0,3,-6), s(1,4,256))
        run, _ = self.run_guest(code)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        self.assertRegex(run.stdout, r'stalls=[1-9]')

    def test_wrong_path_store_and_illegal_instruction(self):
        code = words(0x97, i(0x13,2,0,0,3), branch(0,0,12), s(1,2,256), 0xffffffff, *passed())
        run, trace = self.run_guest(code)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        self.assertFalse(any(r['trap'] for r in trace))
        self.assertEqual(sum(r['store'] for r in trace), 1)

    def test_precise_memory_exception_squashes_younger_store(self):
        code = words(0x97, i(0x13,5,0,1,64), i(0x73,0,1,5,0x305),
                     i(0x13,2,0,0,3), i(3,3,3,0,0), s(1,2,256))
        code = code.ljust(64,b'\0') + words(*passed())
        run, trace = self.run_guest(code)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        traps = [r for r in trace if r['trap']]
        self.assertEqual([r['cause'] for r in traps], [5])
        self.assertEqual(sum(r['store'] for r in trace), 1)

    def test_instruction_after_older_trap_does_not_retire(self):
        code = words(0x97,i(0x13,5,0,1,64),i(0x73,0,1,5,0x305),0xffffffff,i(0x13,9,0,0,99))
        code = code.ljust(64,b'\0')+words(*passed())
        run, trace = self.run_guest(code)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertFalse(any(r['wx'] and r['rd']==9 for r in trace))

    def test_mixed_compressed_fetch_at_halfword(self):
        code = struct.pack('<H', 1) + words(0x97,*passed())
        # AUIPC is at BASE+2, so use a tohost override at BASE+258.
        run, _ = self.run_guest(code,extra=('--tohost',hex(BASE+258)))
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)

    def test_elf_bss_zero_fill(self):
        code = words(0x97,i(3,3,3,1,128),i(0x13,2,0,3,1),s(1,2,256))
        run, _ = self.run_guest(elf(code,512),is_elf=True)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)

    def test_elf_rejects_bad_headers_segments_and_entry(self):
        valid = elf(words(0x97,*passed()))
        samples = [b'',b'\x7fELF',valid[:80]]
        for offset, fmt, value in [(4,'B',1),(5,'B',2),(18,'H',62),(24,'Q',BASE+1),
                                  (32,'Q',2**64-8),(72,'Q',2**64-8),(96,'Q',2**64-1),
                                  (104,'Q',2**64-1),(80,'Q',0)]:
            image=bytearray(valid);struct.pack_into('<'+fmt,image,offset,value);samples.append(image)
        for data in samples:
            with self.subTest(data=bytes(data[:24])):
                run,_=self.run_guest(data,is_elf=True)
                self.assertEqual(run.returncode,2,run.stdout+run.stderr)

    def test_timeout(self):
        run,_=self.run_guest(words(0x6f))
        self.assertEqual(run.returncode,3)
        self.assertIn('TIMEOUT',run.stdout)

    def test_unhandled_trap(self):
        run,_=self.run_guest(words(0xffffffff))
        self.assertEqual(run.returncode,2)
        self.assertIn('unhandled trap 2',run.stderr)

    def test_debug_breakpoint_step_and_inspection(self):
        run,_=self.run_guest(words(0x97,*passed()),extra=('--debug',),
                            commands='r\nf\ncsr 300\nx 80000000 4\nb 80000004\nc\ns\ndelete\nc\n')
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertIn('breakpoint before retirement',run.stdout)
        self.assertIn('csr[300]',run.stdout)

    def test_debug_eof_is_not_success(self):
        run,_=self.run_guest(words(0x97,*passed()),extra=('--debug',),commands='')
        self.assertEqual(run.returncode,4)

    def test_to_host_failure(self):
        run,_=self.run_guest(words(0x97,i(0x13,2,0,0,3),s(1,2,256)))
        self.assertEqual(run.returncode,1)
        self.assertIn('FAIL',run.stdout)

if __name__=='__main__':
    unittest.main()
