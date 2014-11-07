// TEST_CONFIG MEM=mrc,gc

#include "test.h"
#include <objc/NSObject.h>

@interface Test : NSObject {
    char bytes[16-sizeof(void*)];
}
@end
@implementation Test
@end


int main()
{
    id o1 = [Test new];
    id o2 = object_copy(o1, 16);
    testassert(malloc_size(o1) == 16);
    testassert(malloc_size(o2) == 32);
    succeed(__FILE__);
}
