# Setsuna, The 64bit RISC-V Implementation by using Verilog HDL
My new project of self-implemented RISC-V for my future research.
Setsuna is a Japanese word that means 'at that instant'.
This name from 'Yuki Setsuna' that is name of a charactors of 'Love Live! Nijigasaki School Idol Club'.

## The Goals
- Target date: **March 2027** (updated from September 2023).
- Establish an FPGA development and verification workflow for Sipeed Tang boards,
  initially targeting Tang Nano 20K, on an Apple Silicon (ARM) Mac.
- Complete `sim` as a standalone RV64GC emulator, primarily written in C, with a
  textbook five-stage pipeline (IF / ID / EX / MEM / WB).
- Load a user-selected binary, run public RISC-V test programs, provide debugging
  facilities, and build with Make or CMake.
- Retain improved branch prediction and deeper pipelines compared with
  [Kasumi](https://github.com/Prokuma/Kasumi) as subsequent research directions;
  the initial simulator uses the five-stage baseline.

## Development plan

See [the development plan](docs/development-plan.md) for the simulator scope,
acceptance criteria, ARM Mac / Tang toolchain candidates, and proposed milestones.

## Simulator

`sim/` now contains a C17 RV64GC bare-metal emulator with an explicit five-stage
pipeline, ELF64/raw loading, a CLI debugger, and retirement tracing.

### Prerequisites

- Git, Make, and a C17 compiler (Apple Clang on ARM Mac, or GCC/Clang with
  128-bit integer support on a little-endian host).
- Python 3 for the test scripts.
- `riscv64-unknown-elf-gcc` on `PATH` to build the public RISC-V test binaries.
  This cross compiler is not required to build the simulator or run `make test`.
  The ARM Mac validation used Apple Clang 21 and RISC-V GCC 11.1.0.

### Fetch external projects

External sources are Git submodules. Their exact revisions are recorded in this
repository; `riscv-tests/env` is a nested submodule and must also be initialized.

```sh
git clone --branch alpha-v1 --recurse-submodules https://github.com/Prokuma/Setsuna.git
cd Setsuna
```

For an existing checkout, after pulling or switching branches:

```sh
git submodule update --init --recursive
# Equivalent convenience target:
make deps
```

| Submodule | Purpose | Pinned revision |
| --- | --- | --- |
| [third_party/softfloat](https://github.com/ucb-bar/berkeley-softfloat-3) | C floating-point operations with the RISC-V specialization | `a0c6494cdc11865811dec815d5c0049fba9d82a8` |
| [third_party/riscv-tests](https://github.com/riscv-software-src/riscv-tests) | Public ISA tests, including its nested `env` dependency | `d44511022b356a341a2430cfd65f894b77c35f36` |

Use `git submodule status --recursive` to inspect the checked-out revisions.
`make deps` checks out the recorded commits; it does not follow upstream's latest
branch. Source changes in dependencies should be committed upstream and the
corresponding submodule revision updated explicitly in Setsuna.

### Build SoftFloat and the simulator

```sh
make -j4 softfloat  # builds build/softfloat/softfloat.a using the host C compiler
make -j4           # builds build/setsuna-sim; also builds SoftFloat if needed
make test          # local regressions, no RISC-V cross compiler needed
```

The SoftFloat build reuses its upstream `Linux-RISCV64-GCC/Makefile` for the source
list and RISCV specialization, with Setsuna's platform header and host compiler
command. It builds a **native ARM Mac library**, not a RISC-V executable; no Linux
VM or RISC-V host is needed. Objects and the library are placed under `build/`,
leaving the submodule source tree untouched.

### Build and run riscv-tests

```sh
make riscv-tests   # cross-compiles test ELFs only, without running the simulator
make test-riscv    # builds the simulator and test ELFs, then runs the tests
```

The test builder uses the upstream assembly sources, macros, `env/p` startup
environment, and linker script without modifying them. It invokes the RISC-V GCC
driver with `-march=rv64g -mabi=lp64d -static -mcmodel=medany -nostdlib -nostartfiles`;
the upstream compressed-instruction test enables C itself. The selected groups
are `rv64ui`, `rv64um`, `rv64ua`, `rv64uf`, `rv64ud`, and `rv64uc`. The three Zacas
tests in `rv64ua` are reported as out of scope because they are not RV64GC.

ELFs and logs are written to `build/riscv-tests/`. Build-only results are recorded
in `build-results.json`; execution results are recorded in `results.json`.
To select a cross compiler or a subset of tests:

```sh
python3 scripts/riscv_tests.py --build-only --cc /path/to/riscv64-unknown-elf-gcc --groups rv64ui rv64um
```

### Run a binary

```sh
./build/setsuna-sim --elf build/riscv-tests/rv64ui-p-add --debug
./build/setsuna-sim --elf program.elf --trace trace.jsonl
```

See [the simulator guide](docs/simulator.md) for dependencies, supported execution
environment, debugging, and known limitations. The public validation baseline is
`riscv-tests`, also used for Kasumi.

`verilog/` remains a skeleton. Tang FPGA work is **planning only** until separately
requested; no board is currently connected and no FPGA tool installation or
hardware verification has been performed.
