#include "test.h"
#include "imageorder.h"
#include <objc/runtime.h>
#include <dlfcn.h>

int main()
{
    // +load methods and C static initializers
    testassert(state == 3);
    testassert(cstate == 3);

    Class cls = objc_getClass("Super");
    testassert(cls);

    // make sure all categories arrived
    state = -1;
    [Super method0];
    testassert(state == 0);
    [Super method1];
    testassert(state == 1);
    [Super method2];
    testassert(state == 2);
    [Super method3];
    testassert(state == 3);

    // make sure imageorder3.out is the last category to attach
    state = 0;
    [Super method];
    testassert(state == 3);

    succeed(__FILE__);
}
