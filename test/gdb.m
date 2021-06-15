// TEST_CFLAGS -Wno-deprecated-declarations

#include "test.h"
#include "testroot.i"
#include <objc/objc-gdb.h>
#include <objc/runtime.h>

#define SwiftV1MangledName4 "_TtC6Swiftt13SwiftV1Class4"
__attribute__((objc_runtime_name(SwiftV1MangledName4)))
@interface SwiftV1Class4 : TestRoot @end
@implementation SwiftV1Class4 @end

int main()
{
    // Class hashes
    Class result;

    // Class should not be realized yet
    // fixme not true during class hash rearrangement
    // result = NXMapGet(gdb_objc_realized_classes, "TestRoot");
    // testassert(!result);

    [TestRoot class];
    // Now class should be realized

    result = (__bridge Class)(NXMapGet(gdb_objc_realized_classes, "TestRoot"));
    testassert(result);
    testassert(result == [TestRoot class]);

    result = (__bridge Class)(NXMapGet(gdb_objc_realized_classes, "DoesNotExist"));
    testassert(!result);

    // Class structure decoding
    
    uintptr_t *maskp = (uintptr_t *)dlsym(RTLD_DEFAULT, "objc_debug_class_rw_data_mask");
    testassert(maskp);
    
    // Raw class names
    testassert(strcmp(objc_debug_class_getNameRaw([SwiftV1Class4 class]), SwiftV1MangledName4) == 0);
    testassert(strcmp(objc_debug_class_getNameRaw([TestRoot class]), "TestRoot") == 0);


    succeed(__FILE__);
}
