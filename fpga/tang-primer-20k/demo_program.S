// RV64I demo loaded at 0x8000_0000.  The six active-low LEDs display a
// binary counter through the GPIO register at 0xf000_0000.
    .section .text
    .globl _start
_start:
    li      x1, 0xf0000000
    // The Dock UART is connected on the calibrated 2:1 DDR build.
    lla     x4, greeting
uart_byte:
    lbu     x5, 0(x4)
    beqz    x5, start_counter
    sb      x5, 16(x1)
    addi    x4, x4, 1
    j       uart_byte
start_counter:
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

greeting:
    .asciz "Setsuna ready\r\n"

// demo_program_sim.hex is the shortened LED-only test fixture.
