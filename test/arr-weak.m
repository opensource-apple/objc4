// TEST_CFLAGS -framework Foundation
// TEST_CONFIG GC=0

#include "test.h"
#include <Foundation/Foundation.h>

static id weak;
static id weak2;
static bool did_dealloc;

@interface Test : NSObject @end
@implementation Test 
-(void)dealloc {
    testassert(weak == self);
    testassert(weak2 == self);

    testprintf("Weak store fails while deallocating\n");
    id result = objc_storeWeak(&weak, self);
    testassert(result == NULL);
    testassert(weak == NULL);

    testprintf("Weak references clear during super dealloc\n");
    testassert(weak2 != NULL);
    [super dealloc];
    testassert(weak2 == NULL);

    did_dealloc = true;
}
@end

int main()
{
    Test *obj = [Test new];
    Test *obj2 = [Test new];
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

    testprintf("Weak clear\n");

    result = objc_storeWeak(&weak, obj);
    testassert(result == obj);
    testassert(weak == obj);

    result = objc_storeWeak(&weak2, obj);
    testassert(result == obj);
    testassert(weak2 == obj);

    did_dealloc = false;
    [obj release];
    testassert(did_dealloc);
    testassert(weak == NULL);
    testassert(weak2 == NULL);

    succeed(__FILE__);
}
