#include "types.h"
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
bool cpu_init(Cpu *c,uint64_t base,uint64_t size) {
    memset(c,0,sizeof *c);
    if(!size || size>SIZE_MAX || base>UINT64_MAX-size) return false;
    c->ram=calloc(1,(size_t)size);if(!c->ram) return false;
    c->base=base;c->size=size;c->pc=base;c->privilege=3;
    c->csr[0x301]=UINT64_C(0x800000000010112d); /* RV64 IMAFDC + U */
    c->csr[0x300]=UINT64_C(2)<<32; /* UXL=64, fixed */
    return true;
}
void cpu_destroy(Cpu *c) {free(c->ram);c->ram=NULL;}
static bool dependency(Stage *s,Stage *p) {
    if(!p->valid || p->trap) return false;
    if(p->wx && p->rd && ((s->use_x1 && s->rs1==p->rd)||(s->use_x2 && s->rs2==p->rd))) return true;
    return p->wf && ((s->use_f1 && s->rs1==p->rd)||(s->use_f2 && s->rs2==p->rd)||(s->use_f3 && s->rs3==p->rd));
}
void cpu_cycle(Cpu *c) {
    if(c->halted) return;
    c->cycles++;
    /* Oldest first: only WB mutates architectural state. A fault in MEM
       suppresses younger EX work; a fault in EX suppresses ID/IF work. */
    if(write_back(c,&c->pipe[3]) || c->halted) return;
    Stage next[4]={{0}};
    next[3]=c->pipe[2];memory_access(c,&next[3]);
    if(next[3].valid && next[3].trap) {
        c->waiting_trap=true;c->flushes++;
    } else {
        next[2]=c->pipe[1];execute(c,&next[2]);
        if(next[2].valid && next[2].trap) {c->waiting_trap=true;c->flushes++;}
        else if(next[2].valid && next[2].redirect) {c->pc=next[2].target;c->flushes++;}
        else if(!c->waiting_trap) {
            Stage d=c->pipe[0];if(d.valid) decode(&d);
            /* ALU results forward from EX/MEM; loads need one bubble.
               CSR/fence/atomic instructions drain older work and serialize. */
            bool stall=d.valid && ((c->pipe[1].load && dependency(&d,&c->pipe[1])) ||
                (c->pipe[1].valid && c->pipe[1].serial) || (c->pipe[2].valid && c->pipe[2].serial) ||
                (d.serial && (c->pipe[1].valid || c->pipe[2].valid)));
            if(stall) {next[0]=c->pipe[0];c->stalls++;}
            else {next[1]=d;next[0]=fetch(c);}
        }
    }
    memcpy(c->pipe,next,sizeof next);
}
void cpu_run(Cpu *c,uint64_t limit) {
    uint64_t steps=0;
    while(!c->halted && steps++<limit) cpu_cycle(c);
    if(!c->halted) {c->halted=true;c->status=3;snprintf(c->error,sizeof c->error,"cycle limit reached");}
}
void cpu_dump(const Cpu *c,FILE *out) {
    fprintf(out,"PC(fetch)=%016"PRIx64" privilege=%u cycles=%"PRIu64" retired=%"PRIu64" stalls=%"PRIu64" flushes=%"PRIu64"\n",c->pc,c->privilege,c->cycles,c->retired,c->stalls,c->flushes);
    for(unsigned r=0;r<32;r++) fprintf(out,"x%-2u=%016"PRIx64"%c",r,c->x[r],r%4==3?'\n':' ');
    for(unsigned j=0;j<4;j++) fprintf(out,"%s valid=%u pc=%016"PRIx64" insn=%08"PRIx32" trap=%u\n",(const char*[]){"IF/ID","ID/EX","EX/MEM","MEM/WB"}[j],c->pipe[j].valid,c->pipe[j].pc,c->pipe[j].raw,c->pipe[j].trap);
}
