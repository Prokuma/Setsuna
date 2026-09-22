// RV64I demo loaded at 0x8000_0000.  The six active-low LEDs display a
// binary counter through the GPIO register at 0xf000_0000.
    .section .text
    .globl _start
_start:
    li      x1, 0xf0000000
    li      x2, 0

display:
    sd      x2, 0(x1)
    lui     x3, 0x400            // hardware-visible delay
delay:
    addi    x3, x3, -1
    bnez    x3, delay
    addi    x2, x2, 1
    andi    x2, x2, 63
    nop
    nop
    j       display

// demo_program_sim.hex uses the same instruction sequence with `li x3, 16`.
