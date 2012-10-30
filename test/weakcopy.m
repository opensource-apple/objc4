#include "test.h"
#include <stdint.h>
#include <string.h>
#include <objc/objc-runtime.h>

@interface Base {
  @public
    id isa;
}
@end
@implementation Base
+(void)initialize { } 
+class { return self; }
@end

@interface Weak : Base {
  @public
    __weak id value;
}
@end
@implementation Weak
@end

int main()
{
    Base *value = class_createInstance([Base class], 0);
    Weak *oldObject = class_createInstance([Weak class], 0);
    oldObject->value = value;
    Weak *newObject = object_copy(oldObject, 0);
    testassert(newObject->value == oldObject->value);
    newObject->value = nil;
    succeed(__FILE__);
    return 0;
}
