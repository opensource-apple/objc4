// TEST_CONFIG

#include "test.h"
#include <stdint.h>
#include <string.h>
#include <objc/objc-runtime.h>

@interface Super { 
  @public
    id isa;
  char superIvar;
}
@end

@implementation Super 
+(void)initialize { } 
+class { return self; }
+new { return class_createInstance(self, 0); }
@end


@interface Sub : Super {
  @public 
    uintptr_t subIvar;
}
@end

@implementation Sub @end

 
int main()
{
    /* 
       Runtime layout of Sub:
         [0] isa
         [1] superIvar
         [2] subIvar
    */
    
    Ivar ivar;
    uintptr_t value;
    Sub *sub = [Sub new];
    sub->subIvar = 10;
    testassert(((uintptr_t *)sub)[2] == 10);

    ivar = class_getInstanceVariable([Sub class], "subIvar");
    testassert(ivar);
    testassert(2*sizeof(intptr_t) == (size_t)ivar_getOffset(ivar));
    testassert(0 == strcmp(ivar_getName(ivar), "subIvar"));
#if __LP64__
    testassert(0 == strcmp(ivar_getTypeEncoding(ivar), "Q"));
#elif __clang__
    testassert(0 == strcmp(ivar_getTypeEncoding(ivar), "L"));
#else
    testassert(0 == strcmp(ivar_getTypeEncoding(ivar), "I"));
#endif

    ivar = class_getInstanceVariable([Super class], "superIvar");
    testassert(ivar);
    testassert(sizeof(intptr_t) == (size_t)ivar_getOffset(ivar));
    testassert(0 == strcmp(ivar_getName(ivar), "superIvar"));
    testassert(0 == strcmp(ivar_getTypeEncoding(ivar), "c"));
    testassert(ivar == class_getInstanceVariable([Sub class], "superIvar"));

    ivar = class_getInstanceVariable([Super class], "subIvar");
    testassert(!ivar);

    ivar = class_getInstanceVariable([Sub class]->isa, "subIvar");
    testassert(!ivar);


    sub->subIvar = 10;
    value = 0;
    object_getInstanceVariable(sub, "subIvar", (void **)&value);
    testassert(value == 10);
    
    object_setInstanceVariable(sub, "subIvar", (void *)11);
    testassert(sub->subIvar == 11);

    ivar = class_getInstanceVariable([Sub class], "subIvar");
    object_setIvar(sub, ivar, (id)12);
    testassert(sub->subIvar == 12);
    testassert((id)12 == object_getIvar(sub, ivar));

    ivar = class_getInstanceVariable([Sub class], "subIvar");
    testassert(ivar == object_getInstanceVariable(sub, "subIvar", NULL));
    

    testassert(NULL == class_getInstanceVariable(NULL, "foo"));
    testassert(NULL == class_getInstanceVariable([Sub class], NULL));
    testassert(NULL == class_getInstanceVariable(NULL, NULL));

    testassert(NULL == object_getIvar(sub, NULL));
    testassert(NULL == object_getIvar(NULL, ivar));
    testassert(NULL == object_getIvar(NULL, NULL));

    testassert(NULL == object_getInstanceVariable(sub, NULL, NULL));
    testassert(NULL == object_getInstanceVariable(NULL, "foo", NULL));
    testassert(NULL == object_getInstanceVariable(NULL, NULL, NULL));
    value = 10;
    testassert(NULL == object_getInstanceVariable(sub, NULL, (void **)&value));
    testassert(value == 0);
    value = 10;
    testassert(NULL == object_getInstanceVariable(NULL, "foo", (void **)&value));
    testassert(value == 0);
    value = 10;
    testassert(NULL == object_getInstanceVariable(NULL, NULL, (void **)&value));
    testassert(value == 0);

    object_setIvar(sub, NULL, NULL);
    object_setIvar(NULL, ivar, NULL);
    object_setIvar(NULL, NULL, NULL);

    testassert(NULL == object_setInstanceVariable(sub, NULL, NULL));
    testassert(NULL == object_setInstanceVariable(NULL, "foo", NULL));
    testassert(NULL == object_setInstanceVariable(NULL, NULL, NULL));

    succeed(__FILE__);
    return 0;
}
