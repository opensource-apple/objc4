// TEST_CONFIG

#include "test.h"
#include <objc/objc-runtime.h>

@interface Super { id isa; } @end
@implementation Super 
+(void)initialize { } 
+class { return self; }
@end

int main()
{
    testassert(!class_isMetaClass([Super class]));
    testassert(class_isMetaClass([Super class]->isa));
    testassert(!class_isMetaClass(nil));
    succeed(__FILE__);
}
