# Setsuna, The 64bit RISC-V Implementation by using Verilog HDL
My new project of self-implemented RISC-V for my future research.
Setsuna is a Japanese word that means 'at that instant'.
This name from 'Yuki Setsuna' that is name of a charactors of 'Love Live! Nijigasaki School Idol Club'.

## The Goals
- Target date: **March 2027** (updated from September 2023).
- Establish an FPGA development and verification workflow for Sipeed Tang boards,
  initially targeting Tang Primer 20K + Dock, on an Apple Silicon (ARM) Mac.
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
| [third_party/oss-cad-suite-build](https://github.com/YosysHQ/oss-cad-suite-build) | FPGA toolchain build definitions; tools installed from checksum-pinned official releases | `1caab788c6369cf81e75fcbb44722839e94b8163` |

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

## RTL

`verilog/` now contains the first hardware migration milestone: a synthesizable
five-stage RV64IM pipeline, separate instruction/data write-back caches, and a
peripheral bus with GPIO and UART TX. The core handles forwarding, load-use
stalls, memory wait states, branch flushes, and precise stop/trap behavior.

```sh
make test-rtl
```

The test command runs nine self-checking suites (including the core's iterative
RV64M divider, cache, peripherals, DDR clock-domain crossing and boot readback, and the
integrated `setsuna` top), then runs a
Yosys structural check. See
[the RTL guide](docs/rtl.md) for the bus/MMIO contracts and the exact migration
status. RV64GC migration is still in progress: C/A/F/D, CSR/trap execution, and
multiplier timing improvements remain to be implemented.

## Tang Primer 20K Dock

The FPGA smoke test uses the official **OSS CAD Suite 2026-09-22** release,
pinned by platform-specific SHA-256 checksums. Setup supports ARM64/x86-64 macOS
and Linux; ARM Mac synthesis and SRAM programming have been verified on hardware.
Prerequisites: Git, Make, curl, and Python 3.12+ (or a version with
`tarfile.data_filter` backported). See [the FPGA guide](docs/fpga.md) for details.

```sh
make deps
make fpga-setup    # download, verify, and install locally under .tools/
make fpga-doctor   # inspect actual tool versions
make fpga-synth    # test and synthesize the CPU plus DDR3 controller
make fpga-pack     # synthesize and report packed resources, without placement
make fpga-build    # additionally place/route and generate setsuna.fs
make fpga-scan     # list connected USB probes
make fpga-detect   # read the FPGA's JTAG ID
make fpga-program  # rebuild current CPU RTL and load SRAM (volatile)
make fpga-load     # load the last verified build without rebuilding
```

Select the boot backend at build time (default: DDR):

```sh
make fpga-sim FPGA_BOOT=rom
make fpga-build FPGA_BOOT=rom
make fpga-load FPGA_BOOT=rom
make fpga-sim FPGA_BOOT=ddr
```

ROM boot runs at 27 MHz directly from internal block memory at `0x80000000`,
without the DDR controller or its PLL. It is a read-only diagnostic backend;
programs requiring writable RAM/stack need the DDR backend. Both modes accept
`FPGA_PROGRAM=program.bin`. ROM builds are isolated under
`build/fpga/tang-primer-20k/rom/`; the load command checks the recorded boot mode.

Connect the Dock's JTAG USB port and allow the accessory when macOS prompts.
The default FPGA design copies a boot image into the onboard 128 MiB DDR3 and
reads every word back before releasing the Setsuna RV64IM core at `0x80000000`.
The CPU runs at 27 MHz and crosses to the 99.5625 MHz DDR controller through a
single-command handshake bridge. Readback mismatch or timeout keeps the CPU in reset.
Its demo displays a six-bit binary
counter through GPIO MMIO. A flat little-endian binary can be selected with
`make fpga-build FPGA_PROGRAM=program.bin`. Outputs and logs are in
`build/fpga/tang-primer-20k/`. Use `FPGA_DESIGN=blink` or the `fpga-blink-*`
targets for the independent toolchain smoke test. `make fpga-flash` programs
persistent Flash; it replaces the existing Flash contents.

The CPU+DDR design with M enabled and DDR diagnostic LEDs reaches nextpnr packing
at 17,874 LUT4s (86%), 10/46 BSRAMs, and 4/12 MULT36X36 DSPs, but the pinned
open-source nextpnr database has no placeable `DQS` BEL and stops before routing.
`make fpga-pack` stops before placement and writes `packed.json`; it produces no
programmable image or successful-build manifest.
An experimental `FPGA_ARGS="--ddr-phy portable"` backend replaces the unsupported
PHY cells and reaches placement/routing, but differential pads, read alignment,
and timing at the actual DDR clocks remain unvalidated. Its packing
and normal programming are blocked. An explicit experimental SRAM load is available
for saved images; see the guide. The standalone blink flow remains programmable.
See the FPGA guide for the exact limitation and logs.

To export a relocatable native-DDR project for a separately installed Gowin EDA:

```sh
make fpga-export-gowin  # default output: build/fpga/gowin-ddr (must be empty)
python3 build/fpga/gowin-ddr/build.py --gw-sh /path/to/IDE/bin/gw_sh
```

This alternative preserves the upstream DLL/calibration logic and never programs
hardware. Export is verified locally; the proprietary synthesis/place-and-route
flow remains unverified until Gowin EDA is available. Review its timing reports
before loading any resulting bitstream. See [the FPGA guide](docs/fpga.md).

## Claude Code GitHub Actions

`.github/workflows/` contains two [Claude Code](https://github.com/anthropics/claude-code-action)
workflows:

- `claude.yml`: responds when `@claude` appears in an issue, issue/PR comment,
  or PR review. It fetches only `third_party/softfloat` and `third_party/riscv-tests`
  so that `make -j4` and `make test` can run; FPGA tools and RTL simulators are not
  installed on the runner.
- `claude-code-review.yml`: reviews non-draft pull requests on open/update,
  following the checklist in `AGENTS.md`.

Setup (once per repository):

1. Install the [Claude GitHub App](https://github.com/apps/claude) on this repository.
2. Add the repository secret `CLAUDE_CODE_OAUTH_TOKEN` (generate it locally with
   `claude setup-token`). To use an API key instead, add `ANTHROPIC_API_KEY` and
   replace `claude_code_oauth_token:` with `anthropic_api_key:` in both workflows.
3. Workflows run from the default branch, so merge them into `main` before use.
