#include "types.h"
#include <inttypes.h>
#include <string.h>
static void csr_write(Cpu *c,unsigned n,uint64_t v) {
    switch(n) {
    case 1:c->csr[3]=(c->csr[3]&~UINT64_C(31))|(v&31);break;
    case 2:c->csr[3]=(c->csr[3]&31)|((v&7)<<5);break;
    case 3:c->csr[3]=v&255;break;
    case 0x301:break; /* fixed ISA */
    case 0x300:
        /* M/U only, no interrupts or virtual memory. WARL MPP accepts U/M. */
        v &= UINT64_C(0x0000000000007888);
        if(((v>>11)&3)!=3) v&=~UINT64_C(0x1800);
        v |= UINT64_C(2)<<32;
        if((v&0x6000)==0x6000) v|=UINT64_C(1)<<63;
        c->csr[n]=v;break;
    case 0x304:case 0x344:c->csr[n]=0;break;
    case 0x305:c->csr[n]=v&~UINT64_C(3);break;
    case 0x341:c->csr[n]=v&~UINT64_C(1);break;
    case 0x306:c->csr[n]=v&7;break;
    case 0xb00:c->cycles=v;break;case 0xb02:c->retired=v;break;
    default:c->csr[n]=v;break;
    }
    if(n>=1 && n<=3) c->csr[0x300]|=UINT64_C(0x8000000000006000);
}
bool write_back(Cpu *c,Stage *s) {
    if(!s->valid) return false;
    if(c->trace) fprintf(c->trace,"{\"cycle\":%"PRIu64",\"pc\":\"0x%016"PRIx64"\",\"insn\":\"0x%08"PRIx32"\",\"trap\":%s,\"cause\":%u,\"wx\":%s,\"wf\":%s,\"rd\":%u,\"value\":\"0x%016"PRIx64"\",\"store\":%s,\"address\":\"0x%016"PRIx64"\",\"data\":\"0x%016"PRIx64"\"}\n",
        c->cycles,s->pc,s->raw,s->trap?"true":"false",s->cause,s->wx?"true":"false",s->wf?"true":"false",s->rd,s->value,s->store?"true":"false",s->addr,s->data);
    if(s->trap) {
        c->csr[0x341]=s->pc;c->csr[0x342]=s->cause;c->csr[0x343]=s->tval;
        uint64_t m=c->csr[0x300];
        c->csr[0x300]=(m&~UINT64_C(0x1888))|((uint64_t)c->privilege<<11)|((m&8)<<4);
        c->privilege=3;c->reserved=false;
        c->pc=c->csr[0x305]&~UINT64_C(3);
        if(!c->pc) {
            c->halted=true;c->status=2;
            snprintf(c->error,sizeof c->error,"unhandled trap %u at 0x%"PRIx64" (tval=0x%"PRIx64")",s->cause,s->pc,s->tval);
        }
        memset(c->pipe,0,sizeof c->pipe);c->waiting_trap=false;c->flushes++;
        return true;
    }
    if(s->csr_write) csr_write(c,s->csr,s->csr_value);
    if(s->insn==0x30200073) {
        uint64_t m=c->csr[0x300];c->privilege=(unsigned)((m>>11)&3);
        c->csr[0x300]=(m&~UINT64_C(0x1888))|((m>>4)&8)|0x80;
    }
    if(s->store) mem_write(c,s->addr,s->size,s->data);
    if((s->insn&127)==0x2f) {
        if((s->insn>>27)==2) {c->reserved=true;c->reservation=s->addr;c->reservation_size=s->size;}
        if((s->insn>>27)==3) c->reserved=false;
    }
    if(s->wx && s->rd) c->x[s->rd]=s->value;
    if(s->wf) c->f[s->rd]=s->value;
    if(s->fp_flags || s->wf) {c->csr[3]|=s->fp_flags;c->csr[0x300]|=UINT64_C(0x8000000000006000);}
    c->retired++;
    if(s->store && c->tohost && s->addr<=c->tohost && c->tohost-s->addr<s->size) {
        uint64_t result=0;mem_read(c,c->tohost,8,&result);
        if(result) {c->exit_value=result;c->status=result==1?0:1;c->halted=true;}
    }
    return false;
}
