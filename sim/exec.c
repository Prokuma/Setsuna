#include "types.h"
#include <limits.h>

uint64_t operand(Cpu *c, unsigned r, bool fp) {
    if (!fp && !r) return 0;
    Stage *s=&c->pipe[2];
    if(s->valid && !s->trap && !s->load && s->rd==r && (fp?s->wf:s->wx)) return s->value;
    return fp?c->f[r]:c->x[r];
}
static bool csr_read(Cpu *c,unsigned n,uint64_t *v) {
    if (((n>>8)&3)>c->privilege) return false;
    if(n>=1 && n<=3) {
        if(!(c->csr[0x300]&0x6000)) return false;
        *v=n==1?c->csr[3]&31:n==2?(c->csr[3]>>5)&7:c->csr[3]; return true;
    }
    switch(n) {
    case 0xc00: case 0xc01: case 0xc02:
        if(c->privilege!=3 && !(c->csr[0x306]&(1u<<(n-0xc00)))) return false;
        *v=n==0xc02?c->retired:c->cycles; return true;
    case 0xb00:*v=c->cycles;return true;
    case 0xb02:*v=c->retired;return true;
    case 0xf11:case 0xf12:case 0xf13:case 0xf14:case 0xf15:*v=0;return true;
    case 0x300:case 0x301:case 0x304:case 0x305:case 0x306:
    case 0x340:case 0x341:case 0x342:case 0x343:case 0x344:
        *v=c->csr[n];return true;
    default:return false; /* no S-mode/PMP/RNMI: startup probes trap normally */
    }
}
static uint64_t divide(uint64_t a,uint64_t b,unsigned f,bool word) {
    if(word) {a=sext((uint32_t)a,32); b=sext((uint32_t)b,32);}
    if(f==5 || f==7) {
        if(word) {a=(uint32_t)a;b=(uint32_t)b;}
        return f==5?(b?a/b:UINT64_MAX):(b?a%b:a);
    }
    int64_t x=(int64_t)a,y=(int64_t)b;
    if(!y) return f==4?UINT64_MAX:a;
    if(x==INT64_MIN && y==-1) return f==4?a:0;
    return (uint64_t)(f==4?x/y:x%y);
}
void execute(Cpu *c,Stage *s) {
    if(!s->valid || s->trap) return;
    uint32_t i=s->insn; unsigned op=i&127,f=(i>>12)&7,f7=i>>25;
    uint64_t a=operand(c,s->rs1,false),b=operand(c,s->rs2,false),imm=sext(i>>20,12),v=0;
    bool word=op==0x1b || op==0x3b;
    switch(op) {
    case 0x37:v=sext(i&0xfffff000,32);break;
    case 0x17:v=s->pc+sext(i&0xfffff000,32);break;
    case 0x6f:
        imm=sext(((i>>31)<<20)|(i&0xff000)|((i>>9)&0x800)|((i>>20)&0x7fe),21);
        s->redirect=true;s->target=s->pc+imm;v=s->pc+s->len;break;
    case 0x67:
        if(f) goto illegal;
        s->redirect=true;s->target=(a+imm)&~UINT64_C(1);v=s->pc+s->len;break;
    case 0x63:
        imm=sext(((i>>31)<<12)|((i<<4)&0x800)|((i>>20)&0x7e0)|((i>>7)&0x1e),13);
        switch(f) {
        case 0:v=a==b;break; case 1:v=a!=b;break;
        case 4:v=(int64_t)a<(int64_t)b;break;case 5:v=(int64_t)a>=(int64_t)b;break;
        case 6:v=a<b;break;case 7:v=a>=b;break;default:goto illegal;
        }
        s->redirect=v!=0;s->target=s->pc+imm;break;
    case 0x03:case 0x07:case 0x23:case 0x27:
        if(op==3 && f==7) goto illegal;
        if(op==0x23 && f>3) goto illegal;
        if((op==7 || op==0x27) && (f<2 || f>3 || !(c->csr[0x300]&0x6000))) goto illegal;
        if(s->store) imm=sext(((i>>20)&0xfe0)|((i>>7)&31),12);
        s->addr=a+imm;s->data=op==0x27?operand(c,s->rs2,true):b;break;
    case 0x2f:
        if(f!=2 && f!=3) goto illegal;
        if((i>>27)==2 && s->rs2) goto illegal;
        s->addr=a;s->data=b;break;
    case 0x13:case 0x1b:
        if(word && f!=0 && f!=1 && f!=5) goto illegal;
        switch(f) {
        case 0:v=a+imm;break;
        case 2:v=(int64_t)a<(int64_t)imm;break;case 3:v=a<imm;break;
        case 4:v=a^imm;break;case 6:v=a|imm;break;case 7:v=a&imm;break;
        case 1:
            if((word?i>>25:i>>26)!=0) goto illegal;
            v=a<<((i>>20)&(word?31:63));break;
        case 5:
            if((word?i>>25:i>>26)!=0 && (word?i>>25:i>>26)!=(word?32u:16u)) goto illegal;
            if(word) a=sext((uint32_t)a,32);
            v=(i&0x40000000)?(uint64_t)((int64_t)a>>((i>>20)&(word?31:63))):(word?(uint32_t)a:a)>>((i>>20)&(word?31:63));break;
        }
        break;
    case 0x33:case 0x3b:
        if(f7==1) {
            if(word && f>0 && f<4) goto illegal;
            if(f>=4) v=divide(a,b,f,word);
            else if(f==0) v=a*b;
            else {
                /* Clang/GCC 128-bit integer extension, also available on ARM64. */
                __uint128_t p=(__uint128_t)a*b;
                v=(uint64_t)(p>>64);
                if((f==1 || f==2) && (a>>63)) v-=b;
                if(f==1 && (b>>63)) v-=a;
            }
            break;
        }
        if(f7!=0 && !(f7==32 && (f==0 || f==5))) goto illegal;
        if(word && f!=0 && f!=1 && f!=5) goto illegal;
        switch(f) {
        case 0:v=f7?a-b:a+b;break;
        case 1:v=a<<(b&(word?31:63));break;
        case 2:v=(int64_t)a<(int64_t)b;break;case 3:v=a<b;break;
        case 4:v=a^b;break;
        case 5:
            if(word) a=sext((uint32_t)a,32);
            v=f7?(uint64_t)((int64_t)a>>(b&(word?31:63))):(word?(uint32_t)a:a)>>(b&(word?31:63));break;
        case 6:v=a|b;break;case 7:v=a&b;break;
        }
        break;
    case 0x0f:
        if(f>1) goto illegal;
        if(f==1) {s->redirect=true;s->target=s->pc+s->len;}
        break;
    case 0x73:
        if(!f) {
            if(i==0x00000073) {fault(s,8+c->privilege,0);return;}
            if(i==0x00100073) {fault(s,3,s->pc);return;}
            if(i==0x30200073 && c->privilege==3) {s->redirect=true;s->target=c->csr[0x341];break;}
            if(i==0x10500073 && c->privilege==3) break; /* no interrupts modeled */
            goto illegal;
        }
        if(f==4) goto illegal;
        s->csr=i>>20;
        if(!csr_read(c,s->csr,&v)) goto illegal;
        a=f>=5?s->rs1:a;
        s->csr_write=(f&3)==1 || s->rs1!=0;
        if(s->csr_write && (s->csr>>10)==3) goto illegal;
        s->csr_value=(f&3)==1?a:(f&3)==2?v|a:v&~a;
        break;
    case 0x43:case 0x47:case 0x4b:case 0x4f:case 0x53:
        if(!(c->csr[0x300]&0x6000)) goto illegal;
        fp_execute(c,s,s->use_x1?a:operand(c,s->rs1,true),operand(c,s->rs2,true),operand(c,s->rs3,true));return;
    default:goto illegal;
    }
    s->value=word?sext((uint32_t)v,32):v;
    return;
illegal: fault(s,2,s->raw);
}
