// TEST_CONFIG

#include "test.h"
#include <string.h>
#include <objc/objc-runtime.h>

@interface Super { @public id isa; } @end
@implementation Super 
+(void)initialize { } 
+class { return self; }
@end

@interface Fake { @public id isa; } @end
@implementation Fake
+(void)initialize { } 
+class { return self; }
@end

int main()
{
    id buf[10];
    Super *obj = (Super *)buf;
    buf[0] = [Fake class];

    testassert(obj->isa == [Fake class]);
    testassert(object_setClass(obj, [Super class]) == [Fake class]);
    testassert(obj->isa == [Super class]);
    testassert(object_setClass(nil, [Super class]) == nil);

    bzero(buf, sizeof(buf));
    testassert(object_setClass(obj, [Super class]) == nil);

    testassert(object_getClass(obj) == buf[0]);
    testassert(object_getClass([Super class]) == [Super class]->isa);
    testassert(object_getClass(nil) == Nil);

    testassert(0 == strcmp(object_getClassName(obj), "Super"));
    testassert(0 == strcmp(object_getClassName([Super class]), "Super"));
    testassert(0 == strcmp(object_getClassName(nil), "nil"));
    
    testassert(0 == strcmp(class_getName([Super class]), "Super"));
    testassert(0 == strcmp(class_getName([Super class]->isa), "Super"));
    testassert(0 == strcmp(class_getName(nil), "nil"));

    succeed(__FILE__);
}
