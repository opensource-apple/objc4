/* 
TEST_RUN_OUTPUT
objc\[\d+\]: class `SwiftV1Class\' not linked into application
objc\[\d+\]: class `DoesNotExist\' not linked into application
OK: runtime.m
OR
confused by Foundation
OK: runtime.m
END 
*/


#include "test.h"
#include "testroot.i"
#include <string.h>
#include <dlfcn.h>
#include <mach-o/ldsyms.h>
#include <objc/objc-runtime.h>

#if __has_feature(objc_arc)

int main()
{
    testwarn("rdar://11368528 confused by Foundation");
    fprintf(stderr, "confused by Foundation\n");
    succeed(__FILE__);
}

#else

@interface Sub : TestRoot @end
@implementation Sub @end

#if __OBJC2__
#   define TEST_SWIFT 1
#else
#   define TEST_SWIFT 0
#endif

#define SwiftV1MangledName "_TtC6Module12SwiftV1Class"

#if TEST_SWIFT
__attribute__((objc_runtime_name(SwiftV1MangledName)))
@interface SwiftV1Class : TestRoot @end
@implementation SwiftV1Class @end
#endif


int main()
{
    Class list[100];
    Class *list2;
    unsigned int count, count0, count2;
    unsigned int i;
    int foundTestRoot;
    int foundSub;
    int foundSwiftV1;
    const char **names;
    Dl_info info;

    [TestRoot class];

    // This shouldn't touch any classes.
    dladdr(&_mh_execute_header, &info);
    names = objc_copyClassNamesForImage(info.dli_fname, &count);
    testassert(names);
#if TEST_SWIFT
    testassert(count == 3);
#else
    testassert(count == 2);
#endif
    testassert(names[count] == NULL);
    foundTestRoot = 0;
    foundSub = 0;
    foundSwiftV1 = 0;
    for (i = 0; i < count; i++) {
        if (0 == strcmp(names[i], "TestRoot")) foundTestRoot++;
        if (0 == strcmp(names[i], "Sub")) foundSub++;
        if (0 == strcmp(names[i], "Module.SwiftV1Class")) foundSwiftV1++;
    }
    testassert(foundTestRoot == 1);
    testassert(foundSub == 1);
#if TEST_SWIFT
    testassert(foundSwiftV1 == 1);
#endif
    
    
    // class Sub hasn't been touched - make sure it's in the class list too
    count0 = objc_getClassList(NULL, 0);
    testassert(count0 >= 2  &&  count0 < 100);
    
    list[count0-1] = NULL;
    count = objc_getClassList(list, count0-1);
    testassert(list[count0-1] == NULL);
    testassert(count == count0);
    
    count = objc_getClassList(list, count0);
    testassert(count == count0);

    for (i = 0; i < count; i++) {
        testprintf("%s\n", class_getName(list[i]));
    }

    foundTestRoot = 0;
    foundSub = 0;
    foundSwiftV1 = 0;
    for (i = 0; i < count; i++) {
        if (0 == strcmp(class_getName(list[i]), "TestRoot")) foundTestRoot++;
        if (0 == strcmp(class_getName(list[i]), "Sub")) foundSub++;
        if (0 == strcmp(class_getName(list[i]), "Module.SwiftV1Class")) foundSwiftV1++;
        // list should be non-meta classes only
        testassert(!class_isMetaClass(list[i]));
    }
    testassert(foundTestRoot == 1);
    testassert(foundSub == 1);
#if TEST_SWIFT
    testassert(foundSwiftV1 == 1);
#endif

    // fixme check class handler
    testassert(objc_getClass("TestRoot") == [TestRoot class]);
#if TEST_SWIFT
    testassert(objc_getClass("Module.SwiftV1Class") == [SwiftV1Class class]);
    testassert(objc_getClass(SwiftV1MangledName) == [SwiftV1Class class]);
#endif
    testassert(objc_getClass("SwiftV1Class") == nil);
    testassert(objc_getClass("DoesNotExist") == nil);
    testassert(objc_getClass(NULL) == nil);

    testassert(objc_getMetaClass("TestRoot") == object_getClass([TestRoot class]));
#if TEST_SWIFT
    testassert(objc_getMetaClass("Module.SwiftV1Class") == object_getClass([SwiftV1Class class]));
    testassert(objc_getMetaClass(SwiftV1MangledName) == object_getClass([SwiftV1Class class]));
#endif
    testassert(objc_getMetaClass("SwiftV1Class") == nil);
    testassert(objc_getMetaClass("DoesNotExist") == nil);
    testassert(objc_getMetaClass(NULL) == nil);

    // fixme check class no handler
    testassert(objc_lookUpClass("TestRoot") == [TestRoot class]);
#if TEST_SWIFT
    testassert(objc_lookUpClass("Module.SwiftV1Class") == [SwiftV1Class class]);
    testassert(objc_lookUpClass(SwiftV1MangledName) == [SwiftV1Class class]);
#endif
    testassert(objc_lookUpClass("SwiftV1Class") == nil);
    testassert(objc_lookUpClass("DoesNotExist") == nil);
    testassert(objc_lookUpClass(NULL) == nil);

    testassert(! object_isClass(nil));
    testassert(! object_isClass([TestRoot new]));
    testassert(object_isClass([TestRoot class]));
    testassert(object_isClass(object_getClass([TestRoot class])));
    testassert(object_isClass([Sub class]));
    testassert(object_isClass(object_getClass([Sub class])));
#if TEST_SWIFT
    testassert(object_isClass([SwiftV1Class class]));
    testassert(object_isClass(object_getClass([SwiftV1Class class])));
#endif

    list2 = objc_copyClassList(&count2);
    testassert(count2 == count);
    testassert(list2);
    testassert(malloc_size(list2) >= (1+count2) * sizeof(Class));
    for (i = 0; i < count; i++) {
        testassert(list[i] == list2[i]);
    }
    testassert(list2[count] == NULL);
    free(list2);
    free(objc_copyClassList(NULL));

    succeed(__FILE__);
}

#endif
