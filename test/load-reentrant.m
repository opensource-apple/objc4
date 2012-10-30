#include "test.h"
#include <dlfcn.h>

int state1 = 0;
int *state2_p;

@interface One @end
@implementation One
+(void)load 
{
    state1 = 111;

    // Re-entrant +load doesn't get to complete until we do
    void *dlh = dlopen("libload-reentrant2.dylib", RTLD_LAZY);
    testassert(dlh);
    state2_p = (int *)dlsym(dlh, "state2");
    testassert(state2_p);
    testassert(*state2_p == 0);

    state1 = 1;
}
@end

int main()
{
    testassert(state1 == 1  &&  state2_p  &&  *state2_p == 2);
    succeed(__FILE__);
}
