#include "test.h"
#include <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>

#include "unload.h"

static BOOL hasName(const char * const *names, const char *query)
{
    const char *name;
    while ((name = *names++)) {
        if (strstr(name, query)) return YES;
    }

    return NO;
}

void cycle(void)
{
    int i;
    char buf[100];
    unsigned int imageCount, imageCount0;
    const char **names;
    const char *name;

    names = objc_copyImageNames(&imageCount0);
    testassert(names);
    free(names);

    void *bundle = dlopen("unload2.out", RTLD_LAZY);
    testassert(bundle);

    names = objc_copyImageNames(&imageCount);
    testassert(names);
    testassert(imageCount == imageCount0 + 1);
    testassert(hasName(names, "unload2.out"));
    free(names);

    Class small = objc_getClass("SmallClass");
    Class big = objc_getClass("BigClass");
    testassert(small);
    testassert(big);

    name = class_getImageName(small);
    testassert(name);
    testassert(strstr(name, "unload2.out"));
    name = class_getImageName(big);
    testassert(name);
    testassert(strstr(name, "unload2.out"));

    id o1 = [small new];
    id o2 = [big new];
    testassert(o1);
    testassert(o2);
    
    // give BigClass and BigClass->isa large method caches (4692641)
    for (i = 0; i < 10000; i++) {
        sprintf(buf, "method_%d", i);
        SEL sel = sel_registerName(buf);
        objc_msgSend(o2, sel);
        objc_msgSend(o2->isa, sel);
    }

    [o1 free];
    [o2 free];

    if (objc_collecting_enabled()) objc_collect(OBJC_EXHAUSTIVE_COLLECTION | OBJC_WAIT_UNTIL_DONE);

    int err = dlclose(bundle);
    testassert(err == 0);
    err = dlclose(bundle);
    testassert(err == -1);  // already closed
    
    testassert(!objc_getClass("SmallClass"));
    testassert(!objc_getClass("BigClass"));

    names = objc_copyImageNames(&imageCount);
    testassert(names);
    testassert(imageCount == imageCount0);
    testassert(! hasName(names, "unload2.out"));
    free(names);

    // these selectors came from the bundle
    testassert(0 == strcmp("unload2_instance_method", sel_getName(sel_registerName("unload2_instance_method"))));
    testassert(0 == strcmp("unload2_category_method", sel_getName(sel_registerName("unload2_category_method"))));
}

int main()
{
    // fixme object_dispose() not aggressive enough?
    if (objc_collecting_enabled()) succeed(__FILE__);

    int count = 100;
    
    cycle();
#if __LP64__
    // fixme heap use goes up 512 bytes after the 2nd cycle only - bad or not?
    cycle();
#endif

    leak_mark();
    while (count--) {
        cycle();
    }
    leak_check(0);

    // 5359412 Make sure dylibs with nothing other than image_info can close
    void *dylib = dlopen("unload3.out", RTLD_LAZY);
    testassert(dylib);
    int err = dlclose(dylib);
    testassert(err == 0);
    err = dlclose(dylib);
    testassert(err == -1);  // already closed

    // Make sure dylibs with real objc content cannot close
    dylib = dlopen("unload4.out", RTLD_LAZY);
    testassert(dylib);
    err = dlclose(dylib);
    testassert(err == 0);
    err = dlclose(dylib);
    testassert(err == 0);   // dlopen from libobjc itself
    err = dlclose(dylib);
    testassert(err == -1);  // already closed

    succeed(__FILE__);
}
