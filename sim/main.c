#include "types.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>
#include <sys/stat.h>
static void usage(void) {
    puts("Usage: setsuna-sim (--elf FILE | --binary FILE) [options]\n"
         "  --load-address N  raw load address (default 0x80000000)\n"
         "  --entry N         raw entry PC (default load address)\n"
         "  --tohost N        override tohost address (ELF symbols auto-detected)\n"
         "  --max-cycles N    cycle limit (default 10000000)\n"
         "  --trace FILE      retirement JSONL trace\n"
         "  --debug           interactive debugger\n"
         "  --dump            show final CPU state\n"
         "  --help            show help\n"
         "Exit: 0=tohost pass, 1=tohost fail, 2=trap/input error, 3=timeout, 4=debugger quit");
}
static bool number(const char *s,uint64_t *v) {
    char *end;errno=0;if(!*s || *s=='-')return false;
    *v=strtoull(s,&end,0);return !errno && !*end;
}
int main(int argc,char **argv) {
    const char *path=NULL,*trace=NULL;bool raw=false,dbg=false,dump=false,has_entry=false,has_host=false;
    uint64_t addr=RAM_BASE,entry=RAM_BASE,host=0,limit=10000000;
    for(int n=1;n<argc;n++) {
        const char *a=argv[n];
        if(!strcmp(a,"--help")) {usage();return 0;}
        if(!strcmp(a,"--debug")) {dbg=true;continue;}
        if(!strcmp(a,"--dump")) {dump=true;continue;}
        if(n+1==argc)goto bad;
        const char *v=argv[++n];
        if(!strcmp(a,"--elf") || !strcmp(a,"--binary")) {if(path)goto bad;path=v;raw=!strcmp(a,"--binary");}
        else if(!strcmp(a,"--trace"))trace=v;
        else if(!strcmp(a,"--load-address")) {if(!number(v,&addr))goto bad;}
        else if(!strcmp(a,"--entry")) {has_entry=true;if(!number(v,&entry))goto bad;}
        else if(!strcmp(a,"--tohost")) {has_host=true;if(!number(v,&host))goto bad;}
        else if(!strcmp(a,"--max-cycles")) {if(!number(v,&limit)||!limit)goto bad;}
        else goto bad;
    }
    if(!path || (!raw && has_entry))goto bad;
    Cpu c;if(!cpu_init(&c,RAM_BASE,RAM_SIZE)) {fputs("RAM allocation failed\n",stderr);return 2;}
    if(!load_image(&c,path,raw,addr,has_entry?entry:addr)) {fprintf(stderr,"%s\n",c.error);cpu_destroy(&c);return 2;}
    if(has_host) {
        if(!mem_range(&c,host,8)) {fputs("tohost outside RAM\n",stderr);cpu_destroy(&c);return 2;}
        c.tohost=host;
    }
    if(trace) {
        struct stat image_stat, trace_stat;
        if(!strcmp(trace,path) || (!stat(path,&image_stat) && !stat(trace,&trace_stat) &&
            image_stat.st_dev==trace_stat.st_dev && image_stat.st_ino==trace_stat.st_ino)) {
            fputs("trace must not overwrite image\n",stderr);cpu_destroy(&c);return 2;
        }
        c.trace=fopen(trace,"w");if(!c.trace) {perror(trace);cpu_destroy(&c);return 2;}
    }
    if(dbg)debug(&c,limit);else cpu_run(&c,limit);
    printf("%s tohost=0x%"PRIx64" cycles=%"PRIu64" retired=%"PRIu64" stalls=%"PRIu64" flushes=%"PRIu64"\n",
        c.status==0?"PASS":c.status==1?"FAIL":c.status==3?"TIMEOUT":c.status==4?"QUIT":"ERROR",c.exit_value,c.cycles,c.retired,c.stalls,c.flushes);
    if(*c.error)fprintf(stderr,"%s\n",c.error);
    if(dump || c.status==2)cpu_dump(&c,stderr);
    if(c.trace && fclose(c.trace)) {perror("trace");c.status=2;}
    int result=c.status;cpu_destroy(&c);return result;
bad:usage();return 2;
}
