// TEST_CONFIG MEM=gc
// TEST_CFLAGS -framework Foundation

// This test must use CF and test ignoredSelector must not use CF.

#include "test.h"
#include <objc/NSObject.h>

int main()
{
    if (objc_collectingEnabled()) {
        // ARC RR functions don't retain and don't hit the side table.
        __block int count;
        testblock_t testblock = ^{
            for (int i = 0; i < count; i++) {
                id obj = [NSObject new];
                objc_retain(obj);
                objc_retain(obj);
                objc_release(obj);
            }
        };
        count = 100;
        testonthread(testblock);
        testonthread(testblock);
        leak_mark();
        count = 10000000;
        testonthread(testblock);
        leak_check(0);
    }

    succeed(__FILE__);
}
