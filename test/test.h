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
#include <malloc/malloc.h>
#include <mach/mach_time.h>
#include <objc/objc-auto.h>

static inline void succeed(const char *msg, ...)  __attribute__((noreturn));
static inline void succeed(const char *msg, ...)
{
    va_list v;
    if (msg) {
        fprintf(stderr, "OK: ");
        va_start(v, msg);
        vfprintf(stderr, msg, v);
        va_end(v);
        fprintf(stderr, "\n");
    } else {
        fprintf(stderr, "OK\n");
    }
    exit(0);
}

static inline int fail(const char *msg, ...)   __attribute__((noreturn));
static inline int fail(const char *msg, ...)
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
    ((void) ((cond) ? 0 : __testassert(#cond, __FILE__, __LINE__)))
#define __testassert(cond, file, line) \
    fail("failed assertion '%s' at %s:%u", cond, __FILE__, __LINE__)

/* time-sensitive assertion, disabled under valgrind */
#define timeassert(cond) \
    testassert((getenv("VALGRIND") && 0 != strcmp(getenv("VALGRIND"), "NO")) || (cond))

static inline void testprintf(const char *msg, ...)
{
    va_list v;
    va_start(v, msg);
    if (getenv("VERBOSE")) vfprintf(stderr, msg, v);
    va_end(v);
}


/* Leak checking
   Fails if total malloc memory in use at leak_check(n) 
   is more than n bytes above that at leak_mark().
*/

static size_t _leak_start;
static inline void leak_mark(void)
{
    malloc_statistics_t stats;
    if (objc_collecting_enabled()) {
        objc_startCollectorThread();
        objc_collect(OBJC_EXHAUSTIVE_COLLECTION|OBJC_WAIT_UNTIL_DONE);
    }
    malloc_zone_statistics(NULL, &stats);
    _leak_start = stats.size_in_use;
}

#define leak_check(n)                                                   \
    do {                                                                \
        const char *_check = getenv("LEAK_CHECK");                      \
        if (_check && 0 == strcmp(_check, "NO")) break;                 \
        if (objc_collecting_enabled()) {                                \
            objc_collect(OBJC_EXHAUSTIVE_COLLECTION|OBJC_WAIT_UNTIL_DONE); \
        }                                                               \
        malloc_statistics_t stats;                                      \
        malloc_zone_statistics(NULL, &stats);                           \
        if (stats.size_in_use > _leak_start + n) {                      \
            if (getenv("HANG_ON_LEAK")) {                               \
                printf("leaks %d\n", getpid());                         \
                while (1) sleep(1);                                     \
            }                                                           \
            fail("%zu bytes leaked at %s:%u",                           \
                 stats.size_in_use - _leak_start, __FILE__, __LINE__);  \
        }                                                               \
    } while (0)

#endif
