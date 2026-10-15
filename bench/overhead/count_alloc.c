/* Counts heap allocations, for `bench_adapter count`
 * (scripts/bench_overhead.sh). Not part of Muntin and not run by CI.
 * Linux and glibc only: built as a shared library and loaded with
 * LD_PRELOAD.
 *
 * It interposes the allocator Mojo code calls (KGEN_CompilerRT_AlignedAlloc
 * and KGEN_CompilerRT_AlignedFree, in Mojo's runtime library) and glibc's
 * malloc family (what C and C++ code such as Flare's FFI wrappers calls),
 * forwards each call and adds to `muntin_count`, which the program reads
 * through dlsym.
 *
 * Copies are not counted: Mojo copies a List's bytes in its own loop, not
 * through memcpy, so no interposed function sees them. A copy of the body
 * into a new List allocates its length, though, so the allocations of
 * LARGE bytes or more count the body copies of a large body, together with
 * any other allocation that large.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>

/* Bytes from which an allocation is also counted as large. */
#define LARGE 65536

enum {
    ALLOCS,      /* allocations, both allocators, reallocations included */
    ALLOC_BYTES, /* bytes they asked for */
    FREES,       /* frees of a non-null pointer */
    LARGE_ALLOCS,
    LARGE_ALLOC_BYTES,
    COUNTERS
};

int64_t muntin_count[COUNTERS];

static void add(int i, int64_t n) {
    __atomic_fetch_add(&muntin_count[i], n, __ATOMIC_RELAXED);
}

static void allocated(size_t n) {
    add(ALLOCS, 1);
    add(ALLOC_BYTES, (int64_t)n);
    if (n >= LARGE) {
        add(LARGE_ALLOCS, 1);
        add(LARGE_ALLOC_BYTES, (int64_t)n);
    }
}

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);
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
    if (p)
        allocated(n);
    return p;
}

void *aligned_alloc(size_t align, size_t n) {
    void *p = __libc_memalign(align, n);
    if (p)
        allocated(n);
    return p;
}

void *memalign(size_t align, size_t n) {
    return aligned_alloc(align, n);
}

int posix_memalign(void **out, size_t align, size_t n) {
    void *p = __libc_memalign(align, n);
    if (!p)
        return 12; /* ENOMEM */
    allocated(n);
    *out = p;
    return 0;
}

void free(void *p) {
    if (p)
        add(FREES, 1);
    __libc_free(p);
}

typedef void *(*alloc_fn)(size_t, size_t);
typedef void (*free_fn)(void *);

/* KGEN_CompilerRT_AlignedAlloc(alignment, size), as Mojo calls it. */
void *KGEN_CompilerRT_AlignedAlloc(size_t align, size_t n) {
    static alloc_fn next;
    if (!next)
        next = (alloc_fn)dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedAlloc");
    void *p = next(align, n);
    if (p)
        allocated(n);
    return p;
}

void KGEN_CompilerRT_AlignedFree(void *p) {
    static free_fn next;
    if (!next)
        next = (free_fn)dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedFree");
    if (p)
        add(FREES, 1);
    next(p);
}
