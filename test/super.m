#include "test.h"
#include <objc/objc-runtime.h>

@interface Super { id isa; } @end
@implementation Super 
+class { return self; } 
+(void)initialize { } 
@end

@interface Sub : Super @end
@implementation Sub @end

int main()
{
    id buf[10];
    buf[0] = [Sub class];

    // [super ...] messages are tested in msgSend.m

    testassert(class_getSuperclass([Sub class]) == [Super class]);
    testassert(class_getSuperclass([Sub class]->isa) == [Super class]->isa);
    testassert(class_getSuperclass([Super class]) == Nil);
    testassert(class_getSuperclass([Super class]->isa) == [Super class]);
    testassert(class_getSuperclass(Nil) == Nil);

    succeed(__FILE__);
}
