// Define FOUNDATION=1 for NSObject and NSAutoreleasePool
// Define FOUNDATION=0 for _objc_root* and _objc_autoreleasePool*

#if FOUNDATION
#   define PUSH() [[NSAutoreleasePool alloc] init]
#   define POP(p) [(id)p release]
#   define RETAIN(o) [o retain]
#   define RELEASE(o) [o release]
#   define AUTORELEASE(o) [o autorelease]
#else
#   define PUSH() _objc_autoreleasePoolPush()
#   define POP(p) _objc_autoreleasePoolPop(p)
#   define RETAIN(o) _objc_rootRetain((id)o)
#   define RELEASE(o) _objc_rootRelease((id)o)
#   define AUTORELEASE(o) _objc_rootAutorelease((id)o)
#endif

#include "test.h"
#include <objc/objc-internal.h>
#include <Foundation/Foundation.h>

static int state;

#define NESTED_COUNT 8

@interface Deallocator : NSObject @end
@implementation Deallocator
-(void) dealloc 
{
    // testprintf("-[Deallocator %p dealloc]\n", self);
    state++;
    [super dealloc];
}
@end

@interface AutoreleaseDuringDealloc : NSObject @end
@implementation AutoreleaseDuringDealloc
-(void) dealloc
{
    state++;
    AUTORELEASE([[Deallocator alloc] init]);
    [super dealloc];
}
@end

@interface AutoreleasePoolDuringDealloc : NSObject @end
@implementation AutoreleasePoolDuringDealloc
-(void) dealloc
{
    // caller's pool
    for (int i = 0; i < NESTED_COUNT; i++) {
        AUTORELEASE([[Deallocator alloc] init]);
    }

    // local pool, popped
    void *pool = PUSH();
    for (int i = 0; i < NESTED_COUNT; i++) {
        AUTORELEASE([[Deallocator alloc] init]);
    }
    POP(pool);

    // caller's pool again
    for (int i = 0; i < NESTED_COUNT; i++) {
        AUTORELEASE([[Deallocator alloc] init]);
    }

#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
    state += NESTED_COUNT;
#else
    // local pool, not popped
    PUSH();
    for (int i = 0; i < NESTED_COUNT; i++) {
        AUTORELEASE([[Deallocator alloc] init]);
    }
#endif

    [super dealloc];
}
@end

void *nopop_fn(void *arg __unused)
{
    PUSH();
    AUTORELEASE([[Deallocator alloc] init]);
    // pool not popped
    return NULL;
}

void *autorelease_lots_fn(void *singlePool)
{
    // Enough to blow out the stack if AutoreleasePoolPage is recursive.
    const int COUNT = 1024*1024;
    state = 0;

    int p = 0;
    void **pools = (void**)malloc((COUNT+1) * sizeof(void*));
    pools[p++] = PUSH();

    id obj = AUTORELEASE([[Deallocator alloc] init]);

    for (int i = 0; i < COUNT; i++) {
        if (rand() % 1000 == 0  &&  !singlePool) {
            pools[p++] = PUSH();
        } else {
            AUTORELEASE(RETAIN(obj));
        }
    }

    testassert(state == 0);
    while (--p) {
        POP(pools[p]);
    }
    testassert(state == 0);
    POP(pools[0]);
    testassert(state == 1);
    free(pools);

    return NULL;
}

void *pop_fn(void *arg __unused)
{
    void *pool = PUSH();
    AUTORELEASE([[Deallocator alloc] init]);
    POP(pool);
    return NULL;
}

void *nsthread_fn(void *arg)
{
    [NSThread currentThread];
    return pop_fn(arg);
}

void cycle(void)
{
    // Normal autorelease.
    testprintf("-- Normal autorelease.\n");
    {
        void *pool = PUSH();
        state = 0;
        AUTORELEASE([[Deallocator alloc] init]);
        testassert(state == 0);
        POP(pool);
        testassert(state == 1);
    }

    // Autorelease during dealloc during autoreleasepool-pop.
    // That autorelease is handled by the popping pool, not the one above it.
    testprintf("-- Autorelease during dealloc during autoreleasepool-pop.\n");
    {
        void *pool = PUSH();
        state = 0;
        AUTORELEASE([[AutoreleaseDuringDealloc alloc] init]);
        testassert(state == 0);
        POP(pool);
        testassert(state == 2);
    }

    // Autorelease pool during dealloc during autoreleasepool-pop.
    testprintf("-- Autorelease pool during dealloc during autoreleasepool-pop.\n");
    {
        void *pool = PUSH();
        state = 0;
        AUTORELEASE([[AutoreleasePoolDuringDealloc alloc] init]);
        testassert(state == 0);
        POP(pool);
        testassert(state == 4 * NESTED_COUNT);
    }

    // Top-level thread pool popped normally.
    testprintf("-- Thread-level pool popped normally.\n");
    {
        state = 0;
        pthread_t th;
        pthread_create(&th, NULL, &pop_fn, NULL);
        pthread_join(th, NULL);
        testassert(state == 1);
    }

    // Top-level thread pool not popped.
    // The runtime should clean it up.
#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
#else
    testprintf("-- Thread-level pool not popped.\n");
    {
        state = 0;
        pthread_t th;
        pthread_create(&th, NULL, &nopop_fn, NULL);
        pthread_join(th, NULL);
        testassert(state == 1);
    }
#endif

    // Intermediate pool not popped.
    // Popping the containing pool should clean up the skipped pool first.
#if FOUNDATION
    {
        static bool warned;
        if (!warned) testwarn("rdar://7138159 NSAutoreleasePool leaks");
        warned = true;
    }
#else
    testprintf("-- Intermediate pool not popped.\n");
    {
        void *pool = PUSH();
        void *pool2 = PUSH();
        AUTORELEASE([[Deallocator alloc] init]);
        state = 0;
        (void)pool2; // pool2 not popped
        POP(pool);
        testassert(state == 1);
    }
#endif


#if !FOUNDATION
    // NSThread calls NSPopAutoreleasePool(0)
    // rdar://9167170 but that currently breaks CF
    {
        static bool warned;
        if (!warned) testwarn("rdar://9167170 ignore NSPopAutoreleasePool(0)");
        warned = true;
    }
    /*
    testprintf("-- pop(0).\n");
    {
        PUSH();
        state = 0;
        AUTORELEASE([[AutoreleaseDuringDealloc alloc] init]);
        testassert(state == 0);
        POP(0);
        testassert(state == 2);
    }
    */
#endif
}

int main()
{
    // inflate the refcount side table so it doesn't show up in leak checks
    {
        int count = 10000;
        id *objs = (id *)malloc(count*sizeof(id));
        for (int i = 0; i < count; i++) {
            objs[i] = RETAIN([NSObject new]);
        }
        for (int i = 0; i < count; i++) {
            RELEASE(objs[i]);
            RELEASE(objs[i]);
        }
        free(objs);
    }

#if FOUNDATION
    // inflate NSAutoreleasePool's instance cache
    {
        int count = 32;
        id *objs = (id *)malloc(count * sizeof(id));
        for (int i = 0; i < count; i++) {
            objs[i] = [[NSAutoreleasePool alloc] init];
        }
        for (int i = 0; i < count; i++) {
            [objs[count-i-1] release];
        }
        
        free(objs);
    }
#endif


    pthread_attr_t smallstack;
    pthread_attr_init(&smallstack);
    pthread_attr_setstacksize(&smallstack, 4096*4);

    for (int i = 0; i < 100; i++) {
        cycle();
    }

    leak_mark();

    for (int i = 0; i < 1000; i++) {
        cycle();
    }

    leak_check(0);

    // Large autorelease stack.
    // Do this only once because it's slow.
    testprintf("-- Large autorelease stack.\n");
    {
        // limit stack size: autorelease pop should not be recursive
        pthread_t th;
        pthread_create(&th, &smallstack, &autorelease_lots_fn, NULL);
        pthread_join(th, NULL);
    }

    // Single large autorelease pool.
    // Do this only once because it's slow.
    testprintf("-- Large autorelease pool.\n");
    {
        // limit stack size: autorelease pop should not be recursive
        pthread_t th;
        pthread_create(&th, &smallstack, &autorelease_lots_fn, (void*)1);
        pthread_join(th, NULL);
    }

    testwarn("rdar://9158789 leak slop due to false in-use from malloc");
    leak_check(8192 /* should be 0 */);


    // NSThread.
    // Can't leak check this because it's too noisy.
    testprintf("-- NSThread.\n");
    {
        pthread_t th;
        pthread_create(&th, &smallstack, &nsthread_fn, 0);
        pthread_join(th, NULL);
    }
    
    // NO LEAK CHECK HERE

    succeed(NAME);
}
