#include "types.h"
#include <string.h>
#include <inttypes.h>
void debug(Cpu *c,uint64_t limit) {
    char line[256];uint64_t breakpoint=0;bool has_break=false;
    puts("Debugger: c=continue, s=retire one, t=one cycle, r=registers/pipeline, f=FP,\n"
         "  csr HEX, x HEX [length], b HEX (stop before WB), delete, q=quit");
    while(!c->halted) {
        fputs("setsuna> ",stdout);fflush(stdout);
        if(!fgets(line,sizeof line,stdin) || line[0]=='q') {c->status=4;c->halted=true;break;}
        uint64_t a=0;unsigned n=16;
        if(!strcmp(line,"delete\n"))has_break=false;
        else if(sscanf(line,"b %"SCNx64,&a)==1) {breakpoint=a;has_break=true;}
        else if(sscanf(line,"csr %"SCNx64,&a)==1) {
            if(a<4096)printf("csr[%03"PRIx64"]=%016"PRIx64"\n",a,c->csr[a]);
            else puts("CSR out of range");
        } else if(sscanf(line,"x %"SCNx64" %u",&a,&n)>=1) {
            if(n>256)n=256;
            for(unsigned j=0;j<n;j++) {uint64_t v;if(a>UINT64_MAX-j || !mem_read(c,a+j,1,&v)) {puts(" outside RAM");break;}printf("%02"PRIx64"%c",v,j%16==15?'\n':' ');}puts("");
        } else if(line[0]=='r')cpu_dump(c,stdout);
        else if(line[0]=='f') {for(unsigned j=0;j<32;j++)printf("f%u=%016"PRIx64"\n",j,c->f[j]);}
        else if(line[0]=='c' || line[0]=='s' || line[0]=='t') {
            uint64_t old=c->retired,steps=0;
            do {
                if(line[0]=='c' && has_break && c->pipe[3].valid && c->pipe[3].pc==breakpoint) {puts("breakpoint before retirement; s to step over");break;}
                cpu_cycle(c);steps++;
                if(line[0]=='t' || (line[0]=='s' && c->retired!=old))break;
            } while(!c->halted && steps<limit);
            if(!c->halted && steps==limit)puts("debug execution limit reached");
            cpu_dump(c,stdout);
        } else puts("Unknown command");
    }
}
