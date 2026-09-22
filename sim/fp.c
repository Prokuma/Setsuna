#include "types.h"
#include "softfloat.h"
static uint32_t unbox(uint64_t v) {return (v>>32)==UINT32_MAX?(uint32_t)v:0x7fc00000;}
static uint64_t classify(uint64_t x,bool wide) {
    unsigned bits=wide?52:23, max=wide?2047:255;
    unsigned exp=(unsigned)((x>>bits)&max);uint64_t frac=x&((UINT64_C(1)<<bits)-1);
    bool sign=(x>>(wide?63:31))&1;
    unsigned index=exp==max?(frac?((frac>>(bits-1))?9:8):(sign?0:7)):
        exp==0?(frac?(sign?2:5):(sign?3:4)):(sign?1:6);
    return UINT64_C(1)<<index;
}
/* The RISCV SoftFloat specialization supplies canonical NaNs and saturated conversions. */
#define FP_OPS(P,T,A,B,D,SIGN,QNAN) do { \
    T x={A},y={B},z={D},r={0}; \
    switch(group) { \
    case 0x00:r=P##_add(x,y);break; \
    case 0x04:r=P##_sub(x,y);break; \
    case 0x08:r=P##_mul(x,y);break; \
    case 0x0c:r=P##_div(x,y);break; \
    case 0x2c:if(rs2)goto illegal;r=P##_sqrt(x);break; \
    case 0x10: \
        if(rm>2)goto illegal; \
        r.v=(x.v&~(SIGN))|((rm==0?y.v:rm==1?~y.v:x.v^y.v)&(SIGN));break; \
    case 0x14: { \
        if(rm>1)goto illegal; \
        bool nx=(classify(x.v,wide)&0x300)!=0,ny=(classify(y.v,wide)&0x300)!=0; \
        if(P##_isSignalingNaN(x)||P##_isSignalingNaN(y))softfloat_exceptionFlags|=16; \
        if(nx&&ny)r.v=QNAN;else if(nx)r=y;else if(ny)r=x; \
        else if(!(x.v&~(SIGN)) && !(y.v&~(SIGN)))r.v=rm?(x.v&y.v):(x.v|y.v); \
        else r=(P##_lt_quiet(x,y)^!!rm)?x:y; \
        break; } \
    case 0x50: \
        if(rm>2)goto illegal; \
        s->value=rm==2?P##_eq(x,y):rm==1?P##_lt(x,y):P##_le(x,y);goto finish; \
    case 0x60: \
        switch(rs2) { \
        case 0:s->value=sext((uint32_t)P##_to_i32(x,round,true),32);break; \
        case 1:s->value=sext((uint32_t)P##_to_ui32(x,round,true),32);break; \
        case 2:s->value=(uint64_t)P##_to_i64(x,round,true);break; \
        case 3:s->value=P##_to_ui64(x,round,true);break; \
        default:goto illegal; } goto finish; \
    case 0x68: \
        switch(rs2) { \
        case 0:r=i32_to_##P((int32_t)a);break;case 1:r=ui32_to_##P((uint32_t)a);break; \
        case 2:r=i64_to_##P((int64_t)a);break;case 3:r=ui64_to_##P(a);break; \
        default:goto illegal;} break; \
    case 0x70: \
        if(rs2 || rm>1)goto illegal; \
        s->value=rm?classify(x.v,wide):(wide?a:sext((uint32_t)a,32));goto finish; \
    case 0x78:if(rs2 || rm)goto illegal;r.v=a;break; \
    case 0x100: \
        if(op==0x4b || op==0x4f)x.v^=SIGN; \
        if(op==0x47 || op==0x4f)z.v^=SIGN; \
        r=P##_mulAdd(x,y,z);break; \
    default:goto illegal; \
    } s->value=r.v; \
} while(0)
void fp_execute(Cpu *c,Stage *s,uint64_t a,uint64_t b,uint64_t d) {
    unsigned i=s->insn,op=i&127,rm=(i>>12)&7,rs2=(i>>20)&31;
    unsigned fmt=(i>>25)&3,group=op==0x53?(i>>25)&~1u:0x100;
    bool wide=fmt==1;
    if(fmt>1) goto illegal;
    unsigned round=rm==7?(unsigned)((c->csr[3]>>5)&7):rm;
    bool rounding=group<=0x0c || group==0x2c || group==0x20 || group==0x60 || group==0x68 || group==0x100;
    if(rounding && round>4)goto illegal;
    softfloat_roundingMode=rounding?round:0;
    softfloat_detectTininess=softfloat_tininess_afterRounding;
    softfloat_exceptionFlags=0;
    if(group==0x20) {
        if(!wide && rs2==1) {float64_t x={a};s->value=f64_to_f32(x).v;}
        else if(wide && rs2==0) {float32_t x={unbox(a)};s->value=f32_to_f64(x).v;}
        else goto illegal;
    } else if(wide) {
        FP_OPS(f64,float64_t,a,b,d,UINT64_C(0x8000000000000000),UINT64_C(0x7ff8000000000000));
    } else {
        FP_OPS(f32,float32_t,unbox(a),unbox(b),unbox(d),UINT32_C(0x80000000),UINT32_C(0x7fc00000));
    }
    if(s->wf && !wide)s->value|=UINT64_C(0xffffffff00000000);
finish:
    s->fp_flags=softfloat_exceptionFlags;return;
illegal:fault(s,2,s->raw);
}
