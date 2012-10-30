// test.h
// Common definitions for trivial test harness


#ifndef TEST_H
#define TEST_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <libgen.h>
#include <unistd.h>
#include <sys/param.h>
#include <malloc/malloc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/objc-auto.h>
#include <TargetConditionals.h>

static inline void succeed(const char *name)  __attribute__((noreturn));
static inline void succeed(const char *name)
{
    if (name) {
        char path[MAXPATHLEN+1];
        strcpy(path, name);        
        fprintf(stderr, "OK: %s\n", basename(path));
    } else {
        fprintf(stderr, "OK\n");
    }
    exit(0);
}

static inline void fail(const char *msg, ...)   __attribute__((noreturn));
static inline void fail(const char *msg, ...)
{
    va_list v;
    if (msg) {
        fprintf(stderr, "BAD: ");
        va_start(v, msg);
        vfprintf(stderr, msg, v);
        va_end(v);
        fprintf(stderr, "\n");
    } else {
        fprintf(stderr, "BAD\n");
    }
    exit(1);
}

#define testassert(cond) \
    ((void) ((cond) ? (void)0 : __testassert(#cond, __FILE__, __LINE__)))
#define __testassert(cond, file, line) \
    (fail("failed assertion '%s' at %s:%u", cond, __FILE__, __LINE__))

/* time-sensitive assertion, disabled under valgrind */
#define timecheck(name, time, fast, slow)                                    \
    if (getenv("VALGRIND") && 0 != strcmp(getenv("VALGRIND"), "NO")) {  \
        /* valgrind; do nothing */                                      \
    } else if (time > slow) {                                           \
        fprintf(stderr, "SLOW: %s %llu, expected %llu..%llu\n",         \
                name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow)); \
    } else if (time < fast) {                                           \
        fprintf(stderr, "FAST: %s %llu, expected %llu..%llu\n",         \
                name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow)); \
    } else {                                                            \
        testprintf("time: %s %llu, expected %llu..%llu\n",              \
                   name, (uint64_t)(time), (uint64_t)(fast), (uint64_t)(slow)); \
    }


static inline void testprintf(const char *msg, ...)
{
    if (msg  &&  getenv("VERBOSE")) {
        va_list v;
        va_start(v, msg);
        fprintf(stderr, "VERBOSE: ");
        vfprintf(stderr, msg, v);
        va_end(v);
    }
}

// complain to output, but don't fail the test
// Use when warning that some test is being temporarily skipped 
// because of something like a compiler bug.
static inline void testwarn(const char *msg, ...)
{
    if (msg) {
        va_list v;
        va_start(v, msg);
        fprintf(stderr, "WARN: ");
        vfprintf(stderr, msg, v);
        va_end(v);
        fprintf(stderr, "\n");
    }
}

static inline void testnoop() { }

// Run GC. This is a macro to reach as high in the stack as possible.
#ifndef OBJC_NO_GC

#   if __OBJC2__
#       define testexc() 
#   else
#       include <objc/objc-exception.h>
#       define testexc()                                                \
            do {                                                        \
                objc_exception_functions_t table = {0,0,0,0,0,0};       \
                objc_exception_get_functions(&table);                   \
                if (!table.throw_exc) {                                 \
                    table.throw_exc = (typeof(table.throw_exc))abort;   \
                    table.try_enter = (typeof(table.try_enter))testnoop; \
                    table.try_exit  = (typeof(table.try_exit))testnoop; \
                    table.extract   = (typeof(table.extract))abort;     \
                    table.match     = (typeof(table.match))abort;       \
                    objc_exception_set_functions(&table);               \
                }                                                       \
            } while (0)
#   endif

#   define testcollect()                                                \
        do {                                                            \
            if (objc_collectingEnabled()) {                             \
                testexc();                                              \
                objc_clear_stack(0);                                    \
                objc_collect(OBJC_COLLECT_IF_NEEDED|OBJC_WAIT_UNTIL_DONE); \
                objc_collect(OBJC_EXHAUSTIVE_COLLECTION|OBJC_WAIT_UNTIL_DONE);\
                objc_collect(OBJC_EXHAUSTIVE_COLLECTION|OBJC_WAIT_UNTIL_DONE);\
            }                                                           \
            _objc_flush_caches(NULL);                                   \
        } while (0)

#else

#   define testcollect()                        \
    do {                                        \
        _objc_flush_caches(NULL);               \
    } while (0)

#endif


/* Make sure libobjc does not call global operator new. 
   Any test that DOES need to call global operator new must 
   `#define TEST_CALLS_OPERATOR_NEW` before including test.h.
 */
#if __cplusplus  &&  !defined(TEST_CALLS_OPERATOR_NEW)
#import <new>
inline void* operator new(std::size_t) throw (std::bad_alloc) { fail("called global operator new"); }
inline void* operator new[](std::size_t) throw (std::bad_alloc) { fail("called global operator new[]"); }
inline void* operator new(std::size_t, const std::nothrow_t&) throw() { fail("called global operator new(nothrow)"); }
inline void* operator new[](std::size_t, const std::nothrow_t&) throw() { fail("called global operator new[](nothrow)"); }
inline void operator delete(void*) throw() { fail("called global operator delete"); }
inline void operator delete[](void*) throw() { fail("called global operator delete[]"); }
inline void operator delete(void*, const std::nothrow_t&) throw() { fail("called global operator delete(nothrow)"); }
inline void operator delete[](void*, const std::nothrow_t&) throw() { fail("called global operator delete[](nothrow)"); }
#endif


/* Leak checking
   Fails if total malloc memory in use at leak_check(n) 
   is more than n bytes above that at leak_mark().
*/

static inline void leak_recorder(task_t task __unused, void *ctx, unsigned type __unused, vm_range_t *ranges, unsigned count)
{
    size_t *inuse = (size_t *)ctx;
    while (count--) {
        *inuse += ranges[count].size;
    }
}

static inline size_t leak_inuse(void)
{
    size_t total = 0;
    vm_address_t *zones;
    unsigned count;
    malloc_get_all_zones(mach_task_self(), NULL, &zones, &count);
    for (unsigned i = 0; i < count; i++) {
        size_t inuse = 0;
        malloc_zone_t *zone = (malloc_zone_t *)zones[i];
        if (!zone->introspect || !zone->introspect->enumerator) continue;

        zone->introspect->enumerator(mach_task_self(), &inuse, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, NULL, leak_recorder);
        total += inuse;
    }

    return total;
}


static inline void leak_dump_heap(const char *msg)
{
    fprintf(stderr, "%s\n", msg);

    // Make `heap` write to stderr
    int outfd = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);
    pid_t pid = getpid();
    char cmd[256];
    // environment variables reset for iOS simulator use
    sprintf(cmd, "DYLD_LIBRARY_PATH= DYLD_ROOT_PATH= /usr/bin/heap -addresses all %d", (int)pid);
 
    system(cmd);

    dup2(outfd, STDOUT_FILENO);
    close(outfd);
}

static size_t _leak_start;
static inline void leak_mark(void)
{
    testcollect();
    if (getenv("LEAK_HEAP")) {
        leak_dump_heap("HEAP AT leak_mark");
    }
    _leak_start = leak_inuse();
}

#define leak_check(n)                                                   \
    do {                                                                \
        const char *_check = getenv("LEAK_CHECK");                      \
        size_t inuse;                                                   \
        if (_check && 0 == strcmp(_check, "NO")) break;                 \
        testcollect();                                                  \
        if (getenv("LEAK_HEAP")) {                                      \
            leak_dump_heap("HEAP AT leak_check");                       \
        }                                                               \
        inuse = leak_inuse();                                           \
        if (inuse > _leak_start + n) {                                  \
            if (getenv("HANG_ON_LEAK")) {                               \
                printf("leaks %d\n", getpid());                         \
                while (1) sleep(1);                                     \
            }                                                           \
            fprintf(stderr, "BAD: %zu bytes leaked at %s:%u\n",         \
                 inuse - _leak_start, __FILE__, __LINE__);              \
        }                                                               \
    } while (0)

static inline bool is_guardmalloc(void)
{
    const char *env = getenv("GUARDMALLOC");
    return (env  &&  0 == strcmp(env, "YES"));
}

#endif
