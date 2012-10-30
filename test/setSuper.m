#include "test.h"
#include <objc/runtime.h>

@interface Super1 { id isa; } @end
@implementation Super1
+class { return self; } 
+(void)initialize { } 
+(int)classMethod { return 1; }
-(int)instanceMethod { return 10000; }
@end

@interface Super2 { id isa; } @end
@implementation Super2
+class { return self; }
+(void)initialize { } 
+(int)classMethod { return 2; }
-(int)instanceMethod { return 20000; }
@end

@interface Sub : Super1 @end
@implementation Sub
+new { return class_createInstance(self, 0); }
+(int)classMethod { return [super classMethod] + 100; }
-(int)instanceMethod { return [super instanceMethod] + 1000000; }
@end

int main()
{
    Class cls;
    Sub *obj = [Sub new];

    testassert(101 == [[Sub class] classMethod]);
    testassert(1010000 == [obj instanceMethod]);

    cls = class_setSuperclass([Sub class], [Super2 class]);

    testassert(cls == [Super1 class]);
    testassert(cls->isa == [Super1 class]->isa);

    testassert(102 == [[Sub class] classMethod]);
    testassert(1020000 == [obj instanceMethod]);

    succeed(__FILE__);
}
