// TEST_CONFIG MEM=mrc
// TEST_CRASHES
/*
TEST_RUN_OUTPUT
objc\[\d+\]: Cannot form weak reference to instance \(0x[0-9a-f]+\) of class Crash. It is possible that this object was over-released, or is in the process of deallocation.
CRASHED: SIG(ILL|TRAP)
END
*/

#include "test.h"

#include <Foundation/NSObject.h>

static id weak;
static id weak2;
static bool did_dealloc;

@interface Test : NSObject @end
@implementation Test 
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);

    testprintf("Weak references clear during super dealloc\n");
    testassert(weak2 != NULL);
    [super dealloc];
    testassert(weak2 == NULL);

    did_dealloc = true;
}
@end

@interface Crash : NSObject @end
@implementation Crash
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);

    testprintf("Weak store crashes while deallocating\n");
    objc_storeWeak(&weak, self);
    fail("objc_storeWeak of deallocating value should have crashed");
    [super dealloc];
}
@end


void cycle(Test *obj, Test *obj2)
{
    id result;

    testprintf("Weak assignment\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak assignment to the same value\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak assignment to different value\n");
    result = objc_storeWeak(&weak, obj2);
    testassert(result == obj2);
    testassert(weak == obj2);

    testprintf("Weak assignment to NULL\n");
    result = objc_storeWeak(&weak, NULL);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak re-assignment to NULL\n");
    result = objc_storeWeak(&weak, NULL);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak move\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);
    weak2 = (id)(PAGE_SIZE-16);
    objc_moveWeak(&weak2, &weak);
    testassert(weak == nil);
    testassert(weak2 == obj);
    objc_storeWeak(&weak2, NULL);

    testprintf("Weak copy\n");
    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);
    weak2 = (id)(PAGE_SIZE-16);
    objc_copyWeak(&weak2, &weak);
    testassert(weak == obj);
    testassert(weak2 == obj);
    objc_storeWeak(&weak, NULL);
    objc_storeWeak(&weak2, NULL);

    testprintf("Weak clear\n");

    id obj3 = [Test new];

    result = objc_storeWeak(&weak, obj3);
    testassert(result == obj3);
    testassert(weak == obj3);

    result = objc_storeWeak(&weak2, obj3);
    testassert(result == obj3);
    testassert(weak2 == obj3);

    did_dealloc = false;
    [obj3 release];
    testassert(did_dealloc);
    testassert(weak == NULL);
    testassert(weak2 == NULL);
}


int main()
{
    Test *obj = [Test new];
    Test *obj2 = [Test new];
    id result;

    for (int i = 0; i < 100000; i++) {
        if (i == 10) leak_mark();
        cycle(obj, obj2);
    }
    // allow some slop for [Test new] inside cycle() 
    // to land in different side table stripes
    leak_check(3072);


    // rdar://14105994
    id weaks[8];
    for (size_t i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        objc_storeWeak(&weaks[i], obj);
    }
    for (size_t i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        objc_storeWeak(&weaks[i], nil);
    }


    Crash *obj3 = [Crash new];
    result = objc_storeWeak(&weak, obj3);
    testassert(result == obj3);
    testassert(weak == obj3);

    result = objc_storeWeak(&weak2, obj3);
    testassert(result == obj3);
    testassert(weak2 == obj3);

    [obj3 release];
    fail("should have crashed in -[Crash dealloc]");
}
