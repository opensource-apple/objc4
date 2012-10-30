/*
TEST_BUILD
    $C{COMPILE} $DIR/cacheflush0.m -o cacheflush0.dylib -dynamiclib
    $C{COMPILE} $DIR/cacheflush2.m -x none cacheflush0.dylib -o cacheflush2.dylib -dynamiclib
    $C{COMPILE} $DIR/cacheflush3.m -x none cacheflush0.dylib -o cacheflush3.dylib -dynamiclib
    $C{COMPILE} $DIR/cacheflush.m  -x none cacheflush0.dylib -o cacheflush.out
END
*/

#include "test.h"
#include <objc/runtime.h>
#include <dlfcn.h>

#include "cacheflush.h"

@interface Sub : Super @end
@implementation Sub @end


int main()
{
    uintptr_t buf[10];
    uintptr_t buf2[10];
    buf[0] = (uintptr_t)[Super class];
    buf2[0] = (uintptr_t)[Sub class];

    // Fill method cache
    testassert(1 == [Super classMethod]);
    testassert(1 == [(Super *)buf instanceMethod]);
    testassert(1 == [Super classMethod]);
    testassert(1 == [(Super *)buf instanceMethod]);

    testassert(1 == [Sub classMethod]);
    testassert(1 == [(Sub *)buf2 instanceMethod]);
    testassert(1 == [Sub classMethod]);
    testassert(1 == [(Sub *)buf2 instanceMethod]);

    // Dynamically load a category
    dlopen("cacheflush2.dylib", 0);

    // Make sure old cache results are gone
    testassert(2 == [Super classMethod]);
    testassert(2 == [(Super *)buf instanceMethod]);

    testassert(2 == [Sub classMethod]);
    testassert(2 == [(Sub *)buf2 instanceMethod]);

    // Dynamically load another category
    dlopen("cacheflush3.dylib", 0);

    // Make sure old cache results are gone
    testassert(3 == [Super classMethod]);
    testassert(3 == [(Super *)buf instanceMethod]);

    testassert(3 == [Sub classMethod]);
    testassert(3 == [(Sub *)buf2 instanceMethod]);

    // fixme test subclasses

    // fixme test objc_flush_caches(), class_addMethod(), class_addMethods()

    succeed(__FILE__);
}
