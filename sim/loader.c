#include "types.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
static uint64_t le(const uint8_t *p,unsigned n) {
    uint64_t v=0;for(unsigned j=0;j<n;j++)v|=(uint64_t)p[j]<<(8*j);return v;
}
static bool span(uint64_t off,uint64_t n,size_t size) {return off<=size && n<=size-off;}
bool load_image(Cpu *c,const char *path,bool raw,uint64_t addr,uint64_t entry) {
    FILE *f=fopen(path,"rb");uint8_t *buf=NULL;bool ok=false;
    if(!f) {snprintf(c->error,sizeof c->error,"%s: %s",path,strerror(errno));return false;}
    if(fseek(f,0,SEEK_END))goto bad;
    long end=ftell(f);if(end<0 || end>256*1024*1024)goto bad;
    size_t size=(size_t)end;rewind(f);buf=malloc(size?size:1);
    if(!buf || fread(buf,1,size,f)!=size)goto bad;
    if(raw) {
        if(!size || !mem_range(c,addr,size) || !mem_range(c,entry,2) || (entry&1))goto bad;
        memcpy(c->ram+addr-c->base,buf,size);c->pc=entry;ok=true;goto done;
    }
    if(size<64 || memcmp(buf,"\177ELF",4) || buf[4]!=2 || buf[5]!=1 || buf[6]!=1 ||
        le(buf+16,2)!=2 || le(buf+18,2)!=243 || le(buf+20,4)!=1 || le(buf+52,2)!=64)goto bad;
    uint64_t ph=le(buf+32,8),sh=le(buf+40,8),pc=le(buf+24,8);
    unsigned pn=(unsigned)le(buf+56,2),sn=(unsigned)le(buf+60,2);
    if(!pn || le(buf+54,2)!=56 || !span(ph,(uint64_t)pn*56,size) || !mem_range(c,pc,2) || (pc&1))goto bad;
    bool loaded=false,executable_entry=false;
    for(unsigned j=0;j<pn;j++) {
        const uint8_t *p=buf+ph+j*56;
        if(le(p,4)!=1)continue;
        uint64_t off=le(p+8,8),v=le(p+16,8),pa=le(p+24,8),fs=le(p+32,8),ms=le(p+40,8);
        if(pa!=v || fs>ms || !span(off,fs,size) || !mem_range(c,v,ms))goto bad;
        memcpy(c->ram+v-c->base,buf+off,(size_t)fs);memset(c->ram+v-c->base+fs,0,(size_t)(ms-fs));
        loaded=true;
        if((le(p+4,4)&1) && pc>=v && pc-v<ms)executable_entry=true;
    }
    if(!loaded || !executable_entry)goto bad;
    if(sn) {
        if(le(buf+58,2)!=64 || !span(sh,(uint64_t)sn*64,size))goto bad;
        for(unsigned j=0;j<sn;j++) {
            const uint8_t *s=buf+sh+j*64;
            if(le(s+4,4)!=2)continue;
            uint64_t off=le(s+24,8),len=le(s+32,8),link=le(s+40,4);
            if(le(s+56,8)!=24 || len%24 || !span(off,len,size) || link>=sn)goto bad;
            const uint8_t *str=buf+sh+link*64;
            uint64_t so=le(str+24,8),sl=le(str+32,8);
            if(le(str+4,4)!=3 || !span(so,sl,size))goto bad;
            for(uint64_t k=0;k<len;k+=24) {
                const uint8_t *sym=buf+off+k;uint64_t name=le(sym,4);
                if(name>=sl || !memchr(buf+so+name,0,(size_t)(sl-name)))goto bad;
                if(!strcmp((const char*)buf+so+name,"tohost") && le(sym+6,2)) {
                    uint64_t host=le(sym+8,8);if(!mem_range(c,host,8))goto bad;c->tohost=host;
                }
            }
        }
    }
    c->pc=pc;ok=true;goto done;
bad:snprintf(c->error,sizeof c->error,"invalid, unsupported, or out-of-range %s image: %s",raw?"raw":"ELF64 RISC-V",path);
done:free(buf);fclose(f);return ok;
}
