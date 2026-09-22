#include "types.h"
void decode(Stage *s) {
    if (s->trap) return;
    uint32_t i=s->insn; unsigned op=i&127, f3=(i>>12)&7;
    s->rd=(i>>7)&31; s->rs1=(i>>15)&31; s->rs2=(i>>20)&31; s->rs3=i>>27;
    switch(op) {
    case 0x37: case 0x17: case 0x6f: s->wx=true; break;
    case 0x67: case 0x13: case 0x1b: s->wx=s->use_x1=true; break;
    case 0x33: case 0x3b: s->wx=s->use_x1=s->use_x2=true; break;
    case 0x63: s->use_x1=s->use_x2=true; break;
    case 0x03: s->wx=s->use_x1=s->load=true; s->size=1u<<(f3&3); break;
    case 0x23: s->store=s->use_x1=s->use_x2=true; s->size=1u<<(f3&3); break;
    case 0x07: s->wf=s->use_x1=s->load=true; s->size=1u<<(f3&3); break;
    case 0x27: s->store=s->use_x1=s->use_f2=true; s->size=1u<<(f3&3); break;
    case 0x2f:
        s->wx=s->use_x1=s->load=s->serial=true; s->size=1u<<(f3&3);
        s->store=s->use_x2=(i>>27)!=2; break;
    case 0x0f: s->serial=true; break;
    case 0x73: s->serial=true; s->wx=f3!=0; s->use_x1=f3 && f3<4; break;
    case 0x43: case 0x47: case 0x4b: case 0x4f:
        s->wf=s->use_f1=s->use_f2=s->use_f3=true; break;
    case 0x53: {
        unsigned group=(i>>25)&~1u;
        s->wf=true; s->use_f1=true;
        s->use_f2=(group<=0x14 || group==0x50);
        if (group==0x60 || group==0x70 || group==0x50) {s->wf=false;s->wx=true;}
        if (group==0x68 || group==0x78) {s->use_f1=false;s->use_x1=true;}
        break;
    }
    default: fault(s,2,s->raw); break;
    }
}
