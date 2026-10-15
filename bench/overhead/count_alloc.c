/* Counts heap allocations, for `bench_adapter count`
 * (scripts/bench_overhead.sh). Not part of Muntin; CI runs it
 * once (scripts/check_flare.sh), as a smoke test.
 * Linux and glibc only: built as a shared library and loaded with
 * LD_PRELOAD.
 *
 * It interposes the allocator Mojo code calls (KGEN_CompilerRT_AlignedAlloc
 * and KGEN_CompilerRT_AlignedFree, in Mojo's runtime library) and glibc's
 * malloc family (what C and C++ code such as Flare's FFI wrappers calls),
 * forwards each call to the function it replaces, and adds to
 * `muntin_count`, which the program reads through dlsym. The counters are
 * per thread (dlsym gives the calling thread's): other threads of the
 * process, such as the Mojo runtime's, allocate at times of their own, and
 * process-wide counters picked those allocations up in some runs. malloc, calloc,
 * realloc and free forward to glibc's own implementations (`__libc_*`); the
 * aligned functions to the next definition (dlsym), so each returns what it
 * returns without this library, its argument checks and error codes
 * included.
 *
 * Copies are not counted: Mojo copies a List's bytes in its own loop, not
 * through memcpy, so no interposed function sees them. A copy of the body
 * into a new List allocates its length, so the allocations of LARGE bytes or
 * more count a large body's copies, together with any other allocation that
 * large; `bench_adapter count` checks first that they follow a known number
 * of copies.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>

/* Bytes from which an allocation is also counted as large. */
#define LARGE 65536

enum {
    ALLOCS,            /* new blocks: malloc, calloc, the aligned functions,
                          realloc(NULL, n) and Mojo's allocator */
    ALLOC_BYTES,       /* bytes those asked for */
    FREES,             /* blocks released by free, Mojo's free or
                          realloc(p, 0); not those a moving realloc releases */
    REALLOCS,          /* realloc(p, n) of a block p, n > 0, that succeeded */
    REALLOC_MOVES,     /* those of them that returned another address (the
                          old block is released by realloc itself) */
    LARGE_ALLOCS,      /* new blocks of LARGE bytes or more */
    LARGE_ALLOC_BYTES, /* bytes those asked for */
    LARGE_REALLOCS,    /* reallocs to LARGE bytes or more */
    COUNTERS
};

/* initial-exec: loaded at start-up, the library's TLS is static, so that
 * no access to it calls back into malloc. */
__thread int64_t muntin_count[COUNTERS]
    __attribute__((tls_model("initial-exec")));

static void add(int i, int64_t n) {
    muntin_count[i] += n;
}

static void allocated(size_t n) {
    add(ALLOCS, 1);
    add(ALLOC_BYTES, (int64_t)n);
    if (n >= LARGE) {
        add(LARGE_ALLOCS, 1);
        add(LARGE_ALLOC_BYTES, (int64_t)n);
    }
}

static void *next(const char *name) {
    return dlsym(RTLD_NEXT, name);
}

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);

void *malloc(size_t n) {
    void *p = __libc_malloc(n);
    if (p)
        allocated(n);
    return p;
}

void *calloc(size_t k, size_t n) {
    void *p = __libc_calloc(k, n);
    if (p)
        allocated(k * n);
    return p;
}

void *realloc(void *old, size_t n) {
    void *p = __libc_realloc(old, n);
    if (!old) {
        if (p)
            allocated(n);
    } else if (p) {
        add(REALLOCS, 1);
        if (p != old)
            add(REALLOC_MOVES, 1);
        if (n >= LARGE)
            add(LARGE_REALLOCS, 1);
    } else if (n == 0) {
        add(FREES, 1); /* glibc frees `old` and returns NULL */
    }
    return p;
}

void free(void *p) {
    if (p)
        add(FREES, 1);
    __libc_free(p);
}

typedef void *(*align_fn)(size_t, size_t);
typedef int (*posix_align_fn)(void **, size_t, size_t);

void *aligned_alloc(size_t align, size_t n) {
    static align_fn f;
    if (!f)
        f = (align_fn)next("aligned_alloc");
    void *p = f(align, n);
    if (p)
        allocated(n);
    return p;
}

void *memalign(size_t align, size_t n) {
    static align_fn f;
    if (!f)
        f = (align_fn)next("memalign");
    void *p = f(align, n);
    if (p)
        allocated(n);
    return p;
}

int posix_memalign(void **out, size_t align, size_t n) {
    static posix_align_fn f;
    if (!f)
        f = (posix_align_fn)next("posix_memalign");
    int status = f(out, align, n);
    if (status == 0)
        allocated(n);
    return status;
}

typedef void *(*kgen_alloc_fn)(size_t, size_t);
typedef void (*kgen_free_fn)(void *);

/* KGEN_CompilerRT_AlignedAlloc(alignment, size), as Mojo calls it. */
void *KGEN_CompilerRT_AlignedAlloc(size_t align, size_t n) {
    static kgen_alloc_fn f;
    if (!f)
        f = (kgen_alloc_fn)next("KGEN_CompilerRT_AlignedAlloc");
    void *p = f(align, n);
    if (p)
        allocated(n);
    return p;
}

void KGEN_CompilerRT_AlignedFree(void *p) {
    static kgen_free_fn f;
    if (!f)
        f = (kgen_free_fn)next("KGEN_CompilerRT_AlignedFree");
    if (p)
        add(FREES, 1);
    f(p);
}
