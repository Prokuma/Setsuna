// RV64IM smoke test: execute MUL, DIV and REM from the DDR boot image.
    .section .text
    .globl _start
_start:
    li   t0, 19
    li   t1, 7
    mul  t2, t0, t1
    li   t3, 133
    bne  t2, t3, fail
    div  t2, t0, t1
    li   t3, 2
    bne  t2, t3, fail
    rem  t2, t0, t1
    li   t3, 5
    bne  t2, t3, fail
    lla  a0, ok_message
    j    send
fail:
    lla  a0, fail_message
send:
    li   t0, 0xf0000000
next:
    lbu  t1, 0(a0)
    beqz t1, done
    sb   t1, 16(t0)
    addi a0, a0, 1
    j    next
done:
    j    done
ok_message:
    .asciz "Setsuna DDR M PASS\r\n"
fail_message:
    .asciz "Setsuna DDR M FAIL\r\n"
