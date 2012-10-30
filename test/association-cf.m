// TEST_CFLAGS -framework CoreFoundation

#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>

#include "test.h"

int main()
{
    // rdar://6164781 setAssociatedObject on pure-CF object crashes LP64

    id obj;
    CFArrayRef array = CFArrayCreate(0, 0, 0, 0);
    testassert(array);

    testassert(! objc_getClass("NSCFArray"));

    objc_setAssociatedObject((id)array, (void*)1, (id)array, OBJC_ASSOCIATION_ASSIGN);

    obj = objc_getAssociatedObject((id)array, (void*)1);
    testassert(obj == (id)array);

    CFRelease(array);

    succeed(__FILE__);
}
