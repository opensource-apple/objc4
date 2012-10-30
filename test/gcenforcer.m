#include "test.h"
#include <objc/objc-auto.h>
#include <dlfcn.h>

int main()
{
    int i;
    for (i = 0; i < 1000; i++) {
        testassert(dlopen_preflight("libsupportsgc.dylib"));
        testassert(dlopen_preflight("libnoobjc.dylib"));
        
        if (objc_collecting_enabled()) {
            testassert(dlopen_preflight("librequiresgc.dylib"));
            testassert(! dlopen_preflight("libnogc.dylib"));
        } else {
            testassert(! dlopen_preflight("librequiresgc.dylib"));
            testassert(dlopen_preflight("libnogc.dylib"));
        }
    }

    succeed(__FILE__);
}
