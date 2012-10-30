#include "test.h"
#include "imageorder.h"

static void c2(void) __attribute__((constructor));
static void c2(void)
{
    testassert(state == 2);  // +load before C/C++
    testassert(cstate == 1);
    cstate = 2;
}

@implementation Super (cat2)
+(void) method {
    fail("+[Super(cat2) method] not replaced!");
}
+(void) method2 {
    state = 2;
}
+(void) load {
    testassert(state == 1);
    state = 2;
}
@end
