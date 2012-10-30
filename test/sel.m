#include "test.h"
#include <string.h>
#include <objc/objc-runtime.h>
#include <objc/objc-auto.h>

int main()
{
    // Make sure @selector values are correctly fixed up
    testassert(@selector(foo) == sel_registerName("foo"));

    // sel_getName recognizes the zero SEL
    testassert(0 == strcmp("<null selector>", sel_getName(0)));

    // sel_getName recognizes GC-ignored SELs
    if (objc_collecting_enabled()) {
        testassert(0 == strcmp("<ignored selector>", 
                               sel_getName(@selector(retain))));
    } else {
        testassert(0 == strcmp("retain", 
                               sel_getName(@selector(retain))));
    }

    // _objc_search_builtins() shouldn't crash on GC-ignored SELs
    union {
        SEL sel;
        const char *ptr;
    } u;
    u.sel = @selector(retain);
    testassert(@selector(retain) == sel_registerName(u.ptr));

    succeed(__FILE__);
}
