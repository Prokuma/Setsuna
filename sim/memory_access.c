#include "types.h"
bool mem_range(const Cpu *c, uint64_t a, uint64_t n) {
    return a >= c->base && n <= c->size && a - c->base <= c->size - n;
}
bool mem_read(Cpu *c, uint64_t a, unsigned n, uint64_t *v) {
    if (!n || n > 8 || !mem_range(c, a, n)) return false;
    *v = 0;
    for (unsigned i = 0; i < n; ++i) *v |= (uint64_t)c->ram[a-c->base+i] << (i*8);
    return true;
}
bool mem_write(Cpu *c, uint64_t a, unsigned n, uint64_t v) {
    if (!n || n > 8 || !mem_range(c, a, n)) return false;
    for (unsigned i = 0; i < n; ++i) c->ram[a-c->base+i] = (uint8_t)(v >> (i*8));
    if (c->reserved && a < c->reservation+c->reservation_size && c->reservation < a+n)
        c->reserved = false;
    return true;
}
void memory_access(Cpu *c, Stage *s) {
    if (!s->valid || s->trap || (!s->load && !s->store)) return;
    unsigned op = s->insn & 127, f3 = (s->insn >> 12) & 7;
    if (!mem_range(c, s->addr, s->size)) { fault(s, s->store ? 7 : 5, s->addr); return; }
    if (op == 0x2f) {
        if (s->addr & (s->size-1)) { fault(s, s->store ? 6 : 4, s->addr); return; }
        uint64_t old = 0, b = s->data;
        mem_read(c, s->addr, s->size, &old);
        uint64_t v = s->size == 4 ? sext(old, 32) : old;
        if (s->size == 4) b = sext((uint32_t)b, 32);
        switch (s->insn >> 27) {
        case 2: s->value = v; return;
        case 3:
            s->value = !(c->reserved && c->reservation == s->addr && c->reservation_size == s->size);
            s->store = !s->value; return;
        case 0: s->data = old+b; break;
        case 1: s->data = b; break;
        case 4: s->data = old^b; break;
        case 8: s->data = old|b; break;
        case 12: s->data = old&b; break;
        case 16: s->data = (int64_t)v < (int64_t)b ? v : b; break;
        case 20: s->data = (int64_t)v > (int64_t)b ? v : b; break;
        case 24: s->data = v < b ? v : b; break;
        case 28: s->data = v > b ? v : b; break;
        default: fault(s, 2, s->raw); return;
        }
        s->value = v;
    } else if (s->load) {
        mem_read(c, s->addr, s->size, &s->value);
        if (s->wf && s->size == 4) s->value |= UINT64_C(0xffffffff00000000);
        else if (!s->wf && f3 < 4) s->value = sext(s->value, s->size*8);
    }
}
