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

static int state;

@interface NSObject (WeakInternals)
-(BOOL)_tryRetain;
-(BOOL)_isDeallocating;
@end

@interface Test : NSObject @end
@implementation Test 
-(void)dealloc {
    // The value returned by objc_loadWeak() is now nil, 
    // but the storage is not yet cleared.
    testassert(weak == self);
    testassert(weak2 == self);

    // objc_loadWeak() does not eagerly clear the storage.
    testassert(objc_loadWeakRetained(&weak) == nil);
    testassert(weak != nil);

    // dealloc clears the storage.
    testprintf("Weak references clear during super dealloc\n");
    testassert(weak2 != nil);
    [super dealloc];
    testassert(weak == nil);
    testassert(weak2 == nil);

    did_dealloc = true;
}
@end

@interface CustomTryRetain : Test @end
@implementation CustomTryRetain
-(BOOL)_tryRetain { state++; return [super _tryRetain]; }
@end

@interface CustomIsDeallocating : Test @end
@implementation CustomIsDeallocating
-(BOOL)_isDeallocating { state++; return [super _isDeallocating]; }
@end

@interface CustomAllowsWeakReference : Test @end
@implementation CustomAllowsWeakReference
-(BOOL)allowsWeakReference { state++; return [super allowsWeakReference]; }
@end

@interface CustomRetainWeakReference : Test @end
@implementation CustomRetainWeakReference
-(BOOL)retainWeakReference { state++; return [super retainWeakReference]; }
@end

@interface Crash : NSObject @end
@implementation Crash
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);
    testassert(objc_loadWeakRetained(&weak) == nil);
    testassert(objc_loadWeakRetained(&weak2) == nil);

    testprintf("Weak store crashes while deallocating\n");
    objc_storeWeak(&weak, self);
    fail("objc_storeWeak of deallocating value should have crashed");
    [super dealloc];
}
@end


void cycle(Class cls, Test *obj, Test *obj2)
{
    testprintf("Cycling class %s\n", class_getName(cls));

    id result;

    // state counts calls to custom weak methods
    // Difference test classes have different expected values.
    int storeTarget;
    int loadTarget;
    if (cls == [Test class]) {
        storeTarget = 0;
        loadTarget = 0;
    }
    else if (cls == [CustomTryRetain class] || 
             cls == [CustomRetainWeakReference class])
    {
        storeTarget = 0;
        loadTarget = 1;
    }
    else if (cls == [CustomIsDeallocating class] || 
             cls == [CustomAllowsWeakReference class])
    {
        storeTarget = 1;
        loadTarget = 0;
    }
    else fail("wut");

    testprintf("Weak assignment\n");
    state = 0;
    result = objc_storeWeak(&weak, obj);
    testassert(state == storeTarget);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak assignment to the same value\n");
    state = 0;
    result = objc_storeWeak(&weak, obj);
    testassert(state == storeTarget);
    testassert(result == obj);
    testassert(weak == obj);

    testprintf("Weak load\n");
    state = 0;
    result = objc_loadWeakRetained(&weak);
    if (state != loadTarget) testprintf("state %d target %d\n", state, loadTarget);
    testassert(state == loadTarget);
    testassert(result == obj);
    testassert(result == weak);
    [result release];

    testprintf("Weak assignment to different value\n");
    state = 0;
    result = objc_storeWeak(&weak, obj2);
    testassert(state == storeTarget);
    testassert(result == obj2);
    testassert(weak == obj2);

    testprintf("Weak assignment to NULL\n");
    state = 0;
    result = objc_storeWeak(&weak, NULL);
    testassert(state == 0);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak re-assignment to NULL\n");
    state = 0;
    result = objc_storeWeak(&weak, NULL);
    testassert(state == 0);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak move\n");
    state = 0;
    result = objc_storeWeak(&weak, obj);
    testassert(state == storeTarget);
    testassert(result == obj);
    testassert(weak == obj);
    weak2 = (id)(PAGE_MAX_SIZE-16);
    objc_moveWeak(&weak2, &weak);
    testassert(weak == nil);
    testassert(weak2 == obj);
    objc_storeWeak(&weak2, NULL);

    testprintf("Weak copy\n");
    state = 0;
    result = objc_storeWeak(&weak, obj);
    testassert(state == storeTarget);
    testassert(result == obj);
    testassert(weak == obj);
    weak2 = (id)(PAGE_MAX_SIZE-16);
    objc_copyWeak(&weak2, &weak);
    testassert(weak == obj);
    testassert(weak2 == obj);
    objc_storeWeak(&weak, NULL);
    objc_storeWeak(&weak2, NULL);

    testprintf("Weak clear\n");

    id obj3 = [cls new];

    state = 0;
    result = objc_storeWeak(&weak, obj3);
    testassert(state == storeTarget);
    testassert(result == obj3);
    testassert(weak == obj3);

    state = 0;
    result = objc_storeWeak(&weak2, obj3);
    testassert(state == storeTarget);
    testassert(result == obj3);
    testassert(weak2 == obj3);

    did_dealloc = false;
    [obj3 release];
    testassert(did_dealloc);
    testassert(weak == NULL);
    testassert(weak2 == NULL);
}


void test_class(Class cls)
{
    Test *obj = [cls new];
    Test *obj2 = [cls new];

    for (int i = 0; i < 100000; i++) {
        if (i == 10) leak_mark();
        cycle(cls, obj, obj2);
    }
    // allow some slop for [Test new] inside cycle() 
    // to land in different side table stripes
    leak_check(8192);


    // rdar://14105994
    id weaks[8];
    for (size_t i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        objc_storeWeak(&weaks[i], obj);
    }
    for (size_t i = 0; i < sizeof(weaks)/sizeof(weaks[0]); i++) {
        objc_storeWeak(&weaks[i], nil);
    }
}

int main()
{
    test_class([Test class]);
    test_class([CustomTryRetain class]);
    test_class([CustomIsDeallocating class]);
    test_class([CustomAllowsWeakReference class]);
    test_class([CustomRetainWeakReference class]);


    id result;

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
