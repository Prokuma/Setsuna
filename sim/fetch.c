#include "types.h"
void fault(Stage *s, unsigned cause, uint64_t value) {
    s->trap = true; s->cause = cause; s->tval = value;
    s->wx = s->wf = s->store = s->csr_write = s->redirect = false;
}
Stage fetch(Cpu *c) {
    Stage s = {.valid=true, .pc=c->pc, .len=2};
    uint64_t lo, hi;
    if (c->pc & 1) { fault(&s, 0, c->pc); return s; }
    if (!mem_read(c, c->pc, 2, &lo)) { fault(&s, 1, c->pc); return s; }
    s.raw = (uint32_t)lo;
    if ((lo & 3) == 3) {
        s.len = 4;
        if (!mem_read(c, c->pc+2, 2, &hi)) { fault(&s, 1, c->pc+2); return s; }
        s.raw |= (uint32_t)hi << 16;
        s.insn = s.raw;
    } else s.insn = decompress((uint16_t)lo);
    c->pc += s.len;
    return s;
}
