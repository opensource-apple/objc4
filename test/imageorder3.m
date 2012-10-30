#include "test.h"
#include "imageorder.h"

static void c3(void) __attribute__((constructor));
static void c3(void)
{
    testassert(state == 3);  // +load before C/C++
    testassert(cstate == 2);
    cstate = 3;
}

@implementation Super (cat3)
+(void) method {
    state = 3;
}
+(void) method3 {
    state = 3;
}
+(void) load {
    testassert(state == 2);
    state = 3;
}
@end
