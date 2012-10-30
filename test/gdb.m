#include "test.h"
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

    result = NXMapGet(gdb_objc_realized_classes, "Super");
    testassert(result);
    testassert(result == [Super class]);

    result = NXMapGet(gdb_objc_realized_classes, "DoesNotExist");
    testassert(!result);

#else

    struct objc_class query;
    struct objc_class *result;

    query.name = "Super";
    result = NXHashGet(_objc_debug_class_hash, &query);
    testassert(result);
    testassert(result == [Super class]);

    query.name = "DoesNotExist";
    result = NXHashGet(_objc_debug_class_hash, &query);
    testassert(!result);

#endif

    succeed(__FILE__);
}
