// TEST_CFLAGS -Wno-deprecated-declarations

#include "test.h"

#if TARGET_OS_IPHONE

int main()
{
    succeed(__FILE__);
}

#else

#include <objc/objc-gdb.h>
#include <objc/runtime.h>

@interface Super { @public id isa; } @end
@implementation Super 
+(void)initialize { } 
+class { return self; }
@end


int main()
{
    // Class hashes
#if __OBJC2__

    Class result;

    // Class should not be realized yet
    // fixme not true during class hash rearrangement
    // result = NXMapGet(gdb_objc_realized_classes, "Super");
    // testassert(!result);

    [Super class];
    // Now class should be realized

    result = (Class)NXMapGet(gdb_objc_realized_classes, "Super");
    testassert(result);
    testassert(result == [Super class]);

    result = (Class)NXMapGet(gdb_objc_realized_classes, "DoesNotExist");
    testassert(!result);

#else

    struct objc_class query;
    Class result;

    query.name = "Super";
    result = (Class)NXHashGet(_objc_debug_class_hash, &query);
    testassert(result);
    testassert((id)result == [Super class]);

    query.name = "DoesNotExist";
    result = (Class)NXHashGet(_objc_debug_class_hash, &query);
    testassert(!result);

#endif

    succeed(__FILE__);
}

#endif
