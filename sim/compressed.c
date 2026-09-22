#include "types.h"
static uint32_t it(unsigned op,unsigned rd,unsigned f,unsigned r,uint32_t imm) {
    return op|(rd<<7)|(f<<12)|(r<<15)|((imm&4095)<<20);
}
static uint32_t rt(unsigned op,unsigned rd,unsigned f,unsigned a,unsigned b,unsigned f7) {
    return op|(rd<<7)|(f<<12)|(a<<15)|(b<<20)|(f7<<25);
}
static uint32_t st(unsigned op,unsigned f,unsigned a,unsigned b,uint32_t n) {
    return op|((n&31)<<7)|(f<<12)|(a<<15)|(b<<20)|((n&0xfe0)<<20);
}
uint32_t decompress(uint16_t x) {
    unsigned q=x&3, f=x>>13, rd=(x>>7)&31, r2=(x>>2)&31;
    unsigned a=8+((x>>7)&7), b=8+((x>>2)&7);
    uint32_t n=(uint32_t)sext(((x>>2)&31)|((x>>7)&32),6);
    if(q==0) {
        if(f==0) {
            n=((x>>7)&15)<<6|((x>>11)&3)<<4|((x>>5)&1)<<3|((x>>6)&1)<<2;
            return n ? it(0x13,b,0,2,n) : 0;
        }
        if(f==2 || f==6) n=((x>>10)&7)<<3|((x>>6)&1)<<2|((x>>5)&1)<<6;
        else n=((x>>10)&7)<<3|((x>>5)&3)<<6;
        switch(f) {
        case 1:return it(0x07,b,3,a,n); case 2:return it(3,b,2,a,n); case 3:return it(3,b,3,a,n);
        case 5:return st(0x27,3,a,b,n); case 6:return st(0x23,2,a,b,n); case 7:return st(0x23,3,a,b,n);
        default:return 0;
        }
    }
    if(q==1) switch(f) {
    case 0:return it(0x13,rd,0,rd,n);
    case 1:return rd ? it(0x1b,rd,0,rd,n) : 0;
    case 2:return it(0x13,rd,0,0,n);
    case 3:
        if(rd==2) {n=(uint32_t)sext(((x>>12)&1)<<9|((x>>6)&1)<<4|((x>>5)&1)<<6|((x>>3)&3)<<7|((x>>2)&1)<<5,10); return n?it(0x13,2,0,2,n):0;}
        return n ? 0x37|(rd<<7)|(n<<12) : 0; /* rd=x0 is a HINT */
    case 4: {
        unsigned sub=(x>>10)&3;
        if(sub<2) return it(0x13,a,5,a,(n&63)|(sub?0x400:0));
        if(sub==2) return it(0x13,a,7,a,n);
        sub=(x>>5)&3;
        if(x&0x1000) return sub<2?rt(0x3b,a,0,a,b,sub?0:32):0;
        return rt(0x33,a,(unsigned[]){0,4,6,7}[sub],a,b,sub?0:32);
    }
    case 5:
        n=(uint32_t)sext(((x>>12)&1)<<11|((x>>11)&1)<<4|((x>>9)&3)<<8|((x>>8)&1)<<10|((x>>7)&1)<<6|((x>>6)&1)<<7|((x>>3)&7)<<1|((x>>2)&1)<<5,12);
        return 0x6f|((n&0x100000)<<11)|((n&0x7fe)<<20)|((n&0x800)<<9)|(n&0xff000);
    case 6: case 7:
        n=(uint32_t)sext(((x>>12)&1)<<8|((x>>10)&3)<<3|((x>>5)&3)<<6|((x>>3)&3)<<1|((x>>2)&1)<<5,9);
        return 0x63|((n&0x800)>>4)|((n&0x1e)<<7)|((f==7)<<12)|(a<<15)|((n&0x7e0)<<20)|((n&0x1000)<<19);
    }
    if(q==2) switch(f) {
    case 0:return it(0x13,rd,1,rd,n&63);
    case 1: case 3:
        n=((x>>12)&1)<<5|((x>>5)&3)<<3|((x>>2)&7)<<6;
        return (f==1 || rd)?it(f==1?7:3,rd,3,2,n):0;
    case 2:
        n=((x>>12)&1)<<5|((x>>4)&7)<<2|((x>>2)&3)<<6;
        return rd?it(3,rd,2,2,n):0;
    case 4:
        if(!(x&0x1000)) return r2?rt(0x33,rd,0,0,r2,0):(rd?it(0x67,0,0,rd,0):0);
        if(!rd && !r2) return 0x00100073;
        return r2?rt(0x33,rd,0,rd,r2,0):it(0x67,1,0,rd,0);
    case 5: case 7:
        n=((x>>10)&7)<<3|((x>>7)&7)<<6;
        return st(f==5?0x27:0x23,3,2,r2,n);
    case 6:
        n=((x>>9)&15)<<2|((x>>7)&3)<<6;
        return st(0x23,2,2,r2,n);
    }
    return 0;
}
