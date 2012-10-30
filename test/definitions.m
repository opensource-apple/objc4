// TEST_CONFIG

// DO NOT include anything else here
#include <objc/objc.h>
// DO NOT include anything else here
Class c = Nil;
SEL s;
IMP i;
id o = nil;
BOOL b = YES;
BOOL b2 = NO;
__strong void *p;


#include "test.h"

int main()
{
    testassert(YES);
    testassert(!NO);
    testassert(!nil);
    testassert(!Nil);

    succeed(__FILE__);
}
