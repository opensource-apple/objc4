/*
TEST_CRASHES
TEST_RUN_OUTPUT
objc1
OK: badCache2.m
OR
crash now
objc\[\d+\]: Method cache corrupted.*
objc\[\d+\]: .*
objc\[\d+\]: .*
objc\[\d+\]: .*
objc\[\d+\]: .*
objc\[\d+\]: Method cache corrupted\.
CRASHED: SIG(ILL|TRAP)
END
*/


#include "test.h"

#if !__OBJC2__

int main()
{
    fprintf(stderr, "objc1\n");
    succeed(__FILE__);
}

#else

#include "testroot.i"

#if __LP64__
typedef uint32_t mask_t;
#else
typedef uint16_t mask_t;
#endif

struct bucket_t {
    void *sel;
    void *imp;
};

struct cache_t {
    struct bucket_t *buckets;
    mask_t mask;
    mask_t occupied;
};

struct class_t {
    void *isa;
    void *supercls;
    struct cache_t cache;
};

@interface Subclass : TestRoot @end
@implementation Subclass @end

int main()
{
    Class cls = [TestRoot class];
    id obj = [cls new];
    [obj self];

    // Test cache::find by clobbering the cache and then adding a method
    struct cache_t *cache = &((__bridge struct class_t *)cls)->cache;
    cache->mask = 0;
    cache->buckets[0].sel = (void*)~0;
    cache->buckets[0].imp = (void*)~0;

    fprintf(stderr, "crash now\n");
    class_addMethod(cls, @selector(fake:o:rama:), nil, nil);

    fail("should have crashed");
}

#endif
