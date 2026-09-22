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

```sh
make deps
make -j4
make test
make test-riscv
./build/setsuna-sim --elf build/riscv-tests/rv64ui-p-add --debug
```

See [the simulator guide](docs/simulator.md) for dependencies, supported execution
environment, debugging, and known limitations. The public validation baseline is
`riscv-tests`, also used for Kasumi.

`verilog/` remains a skeleton. Tang FPGA work is **planning only** until separately
requested; no board is currently connected and no FPGA tool installation or
hardware verification has been performed.
