#include "test.h"
#include <objc/runtime.h>
#include <string.h>
#ifndef OBJC_NO_GC
#include <objc/objc-auto.h>
#include <auto_zone.h>
#endif

@protocol Proto
-(void) instanceMethod;
+(void) classMethod;
@optional
-(void) instanceMethod2;
+(void) classMethod2;
@end

@protocol Proto2
-(void) instanceMethod;
+(void) classMethod;
@optional
-(void) instanceMethod2;
+(void) classMethod_that_does_not_exist;
@end

@protocol Proto3
-(void) instanceMethod;
+(void) classMethod_that_does_not_exist;
@optional
-(void) instanceMethod2;
+(void) classMethod2;
@end

@interface Super { @public id isa; } @end
@implementation Super 
+(void)initialize { } 
+class { return self; }
+(id) new { return class_createInstance(self, 0); }
-(void) free { object_dispose(self); }

+(void) classMethod { fail("+[Super classMethod] called"); }
+(void) classMethod2 { fail("+[Super classMethod2] called"); }
-(void) instanceMethod { fail("-[Super instanceMethod] called"); }
-(void) instanceMethod2 { fail("-[Super instanceMethod2] called"); }
@end

@interface WeakSuper : Super { __weak id weakIvar; } @end
@implementation WeakSuper @end

static int state;

static void instance_fn(id self, SEL _cmd __attribute__((unused)))
{
    testassert(!class_isMetaClass(self->isa));
    state++;
}

static void class_fn(id self, SEL _cmd __attribute__((unused)))
{
    testassert(class_isMetaClass(self->isa));
    state++;
}

static void cycle(void)
{    
    Class cls;
    BOOL ok;
    
    testassert(!objc_getClass("Sub"));
    testassert([Super class]);

    // Test subclass with bells and whistles
    
    cls = objc_allocateClassPair([Super class], "Sub", 0);
    testassert(cls);
#ifndef OBJC_NO_GC
    if (objc_collecting_enabled()) {
        testassert(auto_zone_size(auto_zone(), cls));
        testassert(auto_zone_size(auto_zone(), cls->isa));
    }
#endif
    
    class_addMethod(cls, @selector(instanceMethod), 
                    (IMP)&instance_fn, "v@:");
    class_addMethod(cls->isa, @selector(classMethod), 
                    (IMP)&class_fn, "v@:");

    ok = class_addProtocol(cls, @protocol(Proto));
    testassert(ok);
    ok = class_addProtocol(cls, @protocol(Proto));
    testassert(!ok);

#ifndef __LP64__
# define size 4
# define align 2
#else
#define size 8
# define align 3
#endif

    ok = class_addIvar(cls, "ivar", 4, 2, "i");
    testassert(ok);
    ok = class_addIvar(cls, "ivarid", size, align, "@");
    testassert(ok);
    ok = class_addIvar(cls, "ivaridstar", size, align, "^@");
    testassert(ok);
    ok = class_addIvar(cls, "ivar", 4, 2, "i");
    testassert(!ok);
    ok = class_addIvar(cls->isa, "classvar", 4, 2, "i");
    testassert(!ok);

    objc_registerClassPair(cls);

    
    testassert(cls == [cls class]);
    testassert(cls == objc_getClass("Sub"));

    testassert(!class_isMetaClass(cls));
    testassert(class_isMetaClass(cls->isa));

    testassert(class_getSuperclass(cls) == [Super class]);
    testassert(class_getSuperclass(cls->isa) == [Super class]->isa);

    testassert(class_getInstanceSize(cls) >= sizeof(Class) + 4 + 2*size);
    testassert(class_conformsToProtocol(cls, @protocol(Proto)));

    if (objc_collecting_enabled()) {
        testassert(0 == strcmp(class_getIvarLayout(cls), "\x01\x12"));
        testassert(NULL == class_getWeakIvarLayout(cls));
    }

    class_addMethod(cls, @selector(instanceMethod2), 
                    (IMP)&instance_fn, "v@:");
    class_addMethod(cls->isa, @selector(classMethod2), 
                    (IMP)&class_fn, "v@:");

    ok = class_addIvar(cls, "ivar2", 4, 4, "i");
    testassert(!ok);
    ok = class_addIvar(cls->isa, "classvar2", 4, 4, "i");
    testassert(!ok);

    ok = class_addProtocol(cls, @protocol(Proto2));
    testassert(ok);
    ok = class_addProtocol(cls, @protocol(Proto2));
    testassert(!ok);
    ok = class_addProtocol(cls, @protocol(Proto));
    testassert(!ok);

    // note: adding more methods here causes a false leak check failure
    state = 0;
    [cls classMethod];
    [cls classMethod2];
    testassert(state == 2);

    id obj = [cls new];
    state = 0;
    [obj instanceMethod];
    [obj instanceMethod2];
    testassert(state == 2);
    [obj free];


    // Test ivar layouts of sub-subclass
    Class cls2 = objc_allocateClassPair(cls, "SubSub", 0);
    testassert(cls2);
    
    ok = class_addIvar(cls2, "ivarid2", size, align, "@");
    testassert(ok);
    ok = class_addIvar(cls2, "idarray", 16*sizeof(id), align, "[16@]");
    testassert(ok);
    ok = class_addIvar(cls2, "intarray", 16*sizeof(void*), align, "[16^]");
    testassert(ok);    

    objc_registerClassPair(cls2);

    if (objc_collecting_enabled()) {
        testassert(0 == strcmp((char *)class_getIvarLayout(cls2), "\x01\x1f\x04\xf0\x10"));
        testassert(NULL == class_getWeakIvarLayout(cls2));
    }

    objc_disposeClassPair(cls2);
    
    objc_disposeClassPair(cls);
    
    testassert(!objc_getClass("Sub"));


    // Test unmodified ivar layouts

    cls = objc_allocateClassPair([Super class], "Sub2", 0);
    testassert(cls);
    objc_registerClassPair(cls);
    if (objc_collecting_enabled()) {
        const char *l1, *l2;
        l1 = class_getIvarLayout([Super class]);
        l2 = class_getIvarLayout(cls);
        testassert(l1 == l2  ||  0 == strcmp(l1, l2));
        l1 = class_getWeakIvarLayout([Super class]);
        l2 = class_getWeakIvarLayout(cls);
        testassert(l1 == l2  ||  0 == strcmp(l1, l2));
    }
    objc_disposeClassPair(cls);

    cls = objc_allocateClassPair([WeakSuper class], "Sub3", 0);
    testassert(cls);
    objc_registerClassPair(cls);
    if (objc_collecting_enabled()) {
        const char *l1, *l2;
        l1 = class_getIvarLayout([WeakSuper class]);
        l2 = class_getIvarLayout(cls);
        testassert(l1 == l2  ||  0 == strcmp(l1, l2));
        l1 = class_getWeakIvarLayout([WeakSuper class]);
        l2 = class_getWeakIvarLayout(cls);
        testassert(l1 == l2  ||  0 == strcmp(l1, l2));
    }
    objc_disposeClassPair(cls);

    // Test layout setters
    if (objc_collecting_enabled()) {
        cls = objc_allocateClassPair([Super class], "Sub4", 0);
        testassert(cls);
        class_setIvarLayout(cls, "foo");
        class_setWeakIvarLayout(cls, NULL);
        objc_registerClassPair(cls);
        testassert(0 == strcmp("foo", class_getIvarLayout(cls)));
        testassert(NULL == class_getWeakIvarLayout(cls));
        objc_disposeClassPair(cls);

        cls = objc_allocateClassPair([Super class], "Sub5", 0);
        testassert(cls);
        class_setIvarLayout(cls, NULL);
        class_setWeakIvarLayout(cls, "bar");
        objc_registerClassPair(cls);
        testassert(NULL == class_getIvarLayout(cls));
        testassert(0 == strcmp("bar", class_getWeakIvarLayout(cls)));
        objc_disposeClassPair(cls);
    }
}

int main()
{
    int count = 100;
    cycle();
    leak_mark();
    while (count--) {
        cycle();
    }
    leak_check(0);

    succeed(__FILE__);
}
