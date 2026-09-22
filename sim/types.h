#ifndef SETSUNA_TYPES_H
#define SETSUNA_TYPES_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#define RAM_BASE UINT64_C(0x80000000)
#define RAM_SIZE (64u * 1024u * 1024u)
typedef struct {
    bool valid, wx, wf, load, store, serial, redirect, trap, csr_write;
    bool use_x1, use_x2, use_f1, use_f2, use_f3;
    unsigned rd, rs1, rs2, rs3, size, len, cause, csr, fp_flags;
    uint32_t insn, raw;
    uint64_t pc, value, addr, data, target, tval, csr_value;
} Stage;
typedef struct {
    uint64_t x[32], f[32], csr[4096], pc, cycles, retired, stalls, flushes;
    uint64_t base, size, tohost, reservation, reservation_size, exit_value;
    unsigned privilege;
    uint8_t *ram;
    Stage pipe[4]; /* IF/ID, ID/EX, EX/MEM, MEM/WB */
    bool halted, waiting_trap, reserved;
    int status;
    FILE *trace;
    char error[256];
} Cpu;
static inline uint64_t sext(uint64_t v, unsigned n) {
    uint64_t s = UINT64_C(1) << (n - 1); return (v ^ s) - s;
}
bool cpu_init(Cpu *, uint64_t, uint64_t);
void cpu_destroy(Cpu *);
void cpu_cycle(Cpu *);
void cpu_run(Cpu *, uint64_t);
void cpu_dump(const Cpu *, FILE *);
void debug(Cpu *, uint64_t);
bool mem_read(Cpu *, uint64_t, unsigned, uint64_t *);
bool mem_write(Cpu *, uint64_t, unsigned, uint64_t);
bool mem_range(const Cpu *, uint64_t, uint64_t);
bool load_image(Cpu *, const char *, bool, uint64_t, uint64_t);
Stage fetch(Cpu *);
void decode(Stage *);
void execute(Cpu *, Stage *);
void memory_access(Cpu *, Stage *);
bool write_back(Cpu *, Stage *);
void fp_execute(Cpu *, Stage *, uint64_t, uint64_t, uint64_t);
uint32_t decompress(uint16_t);
void fault(Stage *, unsigned, uint64_t);
uint64_t operand(Cpu *, unsigned, bool);
#endif
