#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned long n;
static void *(*rm)(size_t); static void *(*rc)(size_t,size_t); static void *(*rr)(void*,size_t);
static int (*rp)(void**,size_t,size_t); static void *(*ra)(size_t,size_t);
static char boot[1<<16]; static size_t bootp;
void *malloc(size_t s){ if(!rm){ rm=dlsym(RTLD_NEXT,"malloc"); if(!rm){void*p=boot+bootp; bootp+=(s+15)&~15; return p;} } n++; return rm(s);}
void *calloc(size_t a,size_t b){ if(!rc){ rc=dlsym(RTLD_NEXT,"calloc"); if(!rc){void*p=boot+bootp; bootp+=(a*b+15)&~15; memset(p,0,a*b); return p;} } n++; return rc(a,b);}
void *realloc(void*p,size_t s){ if(!rr) rr=dlsym(RTLD_NEXT,"realloc"); n++; return rr(p,s);}
int posix_memalign(void**p,size_t a,size_t s){ if(!rp) rp=dlsym(RTLD_NEXT,"posix_memalign"); n++; return rp(p,a,s);}
void *aligned_alloc(size_t a,size_t s){ if(!ra) ra=dlsym(RTLD_NEXT,"aligned_alloc"); n++; return ra(a,s);}
void free(void*p){ static void (*rf)(void*); if((char*)p>=boot && (char*)p<boot+sizeof boot) return; if(!rf) rf=dlsym(RTLD_NEXT,"free"); rf(p);}
__attribute__((destructor)) static void done(void){ fprintf(stderr,"ALLOCS %lu\n", n); }
static unsigned long k;
void *KGEN_CompilerRT_AlignedAlloc(size_t a, size_t s){ static void *(*f)(size_t,size_t); if(!f) f=dlsym(RTLD_NEXT,"KGEN_CompilerRT_AlignedAlloc"); k++; return f(a,s);}
__attribute__((destructor)) static void done2(void){ fprintf(stderr,"KGEN %lu\n", k); }
