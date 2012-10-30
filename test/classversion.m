#include "test.h"
#include <objc/objc-runtime.h>

@interface Super { id isa; } @end
@implementation Super 
+class { return self; }
+(void)initialize { }
@end

int main()
{
    Class cls = [Super class];
    testassert(class_getVersion(cls) == 0);
    testassert(class_getVersion(cls->isa) > 5);
    class_setVersion(cls, 100);
    testassert(class_getVersion(cls) == 100);

    testassert(class_getVersion(Nil) == 0);
    class_setVersion(Nil, 100);

    succeed(__FILE__);
}
