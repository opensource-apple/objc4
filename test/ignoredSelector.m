#include "test.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/objc-auto.h>

static int state = 0;

@interface Super { id isa; } @end
@implementation Super 
+class { return self; }
+(void)initialize { } 

+normal { state = 1; return self; } 
+normal2 { testassert(0); } 
+retain { state = 2; return self; } 
+release { state = 3; return self; } 
+autorelease { state = 4; return self; } 
+(void)dealloc { state = 5; } 
+(uintptr_t)retainCount { state = 6; return 6; } 
@end

@interface Sub : Super @end
@implementation Sub @end

@interface Sub2 : Super @end
@implementation Sub2 @end

@interface Empty { id isa; } @end
@implementation Empty
+class { return self; }
+(void)initialize { }
+forward:(SEL)sel :(marg_list)margs { 
    (void)sel; (void)margs; 
    state = 1; 
    return nil; 
} 
@end

@interface Empty (Unimplemented)
+normal;
+retain;
+release;
+autorelease;
+(void)dealloc;
+(uintptr_t)retainCount;
@end


#define getImp(sel)  \
    do { \
        sel##Method = class_getClassMethod(cls, @selector(sel)); \
        testassert(sel##Method); \
        testassert(@selector(sel) == method_getName(sel##Method)); \
        sel = method_getImplementation(sel##Method); \
    } while (0)


static IMP normal, normal2, retain, release, autorelease, dealloc, retainCount;
static Method normalMethod, normal2Method, retainMethod, releaseMethod, autoreleaseMethod, deallocMethod, retainCountMethod;

void cycle(Class cls)
{
    id idVal;
    uintptr_t intVal;

    if (objc_collecting_enabled()) {
        // GC: all ignored selectors are identical
        testassert(@selector(retain) == @selector(release)      &&  
                   @selector(retain) == @selector(autorelease)  &&  
                   @selector(retain) == @selector(dealloc)      &&  
                   @selector(retain) == @selector(retainCount)  );
    }
    else {
        // no GC: all ignored selectors are distinct
        testassert(@selector(retain) != @selector(release)      &&  
                   @selector(retain) != @selector(autorelease)  &&  
                   @selector(retain) != @selector(dealloc)      &&  
                   @selector(retain) != @selector(retainCount)  );
    }

    // no ignored selector matches a real selector
    testassert(@selector(normal) != @selector(retain)       &&  
               @selector(normal) != @selector(release)      &&  
               @selector(normal) != @selector(autorelease)  &&  
               @selector(normal) != @selector(dealloc)      &&  
               @selector(normal) != @selector(retainCount)  );

    getImp(normal);
    getImp(normal2);
    getImp(retain);
    getImp(release);
    getImp(autorelease);
    getImp(dealloc);
    getImp(retainCount);

    if (objc_collecting_enabled()) {
        // GC: all ignored selector IMPs are identical
        testassert(retain == release      &&  
                   retain == autorelease  &&  
                   retain == dealloc      &&  
                   retain == retainCount  );
    }
    else {
        // no GC: all ignored selector IMPs are distinct
        testassert(retain != release      &&  
                   retain != autorelease  &&  
                   retain != dealloc      &&  
                   retain != retainCount  );
    }

    // no ignored selector IMP matches a real selector IMP
    testassert(normal != retain       &&  
               normal != release      &&  
               normal != autorelease  &&  
               normal != dealloc      &&  
               normal != retainCount  );
    
    // Test calls via method_invoke

    idVal =         ((id(*)(id, Method))method_invoke)(cls, normalMethod);
    testassert(state == 1);
    testassert(idVal == cls);

    state = 0;
    idVal =         ((id(*)(id, Method))method_invoke)(cls, retainMethod);
    testassert(state == (objc_collecting_enabled() ? 0 : 2));
    testassert(idVal == cls);

    idVal =         ((id(*)(id, Method))method_invoke)(cls, releaseMethod);
    testassert(state == (objc_collecting_enabled() ? 0 : 3));
    testassert(idVal == cls);

    idVal =         ((id(*)(id, Method))method_invoke)(cls, autoreleaseMethod);
    testassert(state == (objc_collecting_enabled() ? 0 : 4));
    testassert(idVal == cls);

    (void)        ((void(*)(id, Method))method_invoke)(cls, deallocMethod);
    testassert(state == (objc_collecting_enabled() ? 0 : 5));

    intVal = ((uintptr_t(*)(id, Method))method_invoke)(cls, retainCountMethod);
    testassert(state == (objc_collecting_enabled() ? 0 : 6));
    testassert(intVal == (objc_collecting_enabled() ? (uintptr_t)cls : 6));


    // Test calls via objc_msgSend

    state = 0;
    idVal  = [cls normal];
    testassert(state == 1);
    testassert(idVal == cls);

    state = 0;
    idVal  = [cls retain];
    testassert(state == (objc_collecting_enabled() ? 0 : 2));
    testassert(idVal == cls);

    idVal  = [cls release];
    testassert(state == (objc_collecting_enabled() ? 0 : 3));
    testassert(idVal == cls);

    idVal  = [cls autorelease];
    testassert(state == (objc_collecting_enabled() ? 0 : 4));
    testassert(idVal == cls);

    (void)   [cls dealloc];
    testassert(state == (objc_collecting_enabled() ? 0 : 5));

    intVal = [cls retainCount];
    testassert(state == (objc_collecting_enabled() ? 0 : 6));
    testassert(intVal == (objc_collecting_enabled() ? (uintptr_t)cls : 6));
}

int main()
{
    Class cls;

    // Test selector API

    testassert(sel_registerName("retain") == @selector(retain));
    testassert(sel_getUid("retain") == @selector(retain));
    if (objc_collecting_enabled()) {
        testassert(0 == strcmp(sel_getName(@selector(retain)), "<ignored selector>"));
    } else {
        testassert(0 == strcmp(sel_getName(@selector(retain)), "retain"));
    }
#if !__OBJC2__
    testassert(sel_isMapped(@selector(retain)));
#endif
    
    cls = [Sub class];
    testassert(cls);
    cycle(cls);

    cls = [Super class];
    testassert(cls);
    cycle(cls);

    if (objc_collecting_enabled()) {
        // rdar://6200570 Method manipulation shouldn't affect ignored methods.

        cls = [Super class];
        testassert(cls);
        cycle(cls);

        method_setImplementation(retainMethod, (IMP)1);
        method_setImplementation(releaseMethod, (IMP)1);
        method_setImplementation(autoreleaseMethod, (IMP)1);
        method_setImplementation(deallocMethod, (IMP)1);
        method_setImplementation(retainCountMethod, (IMP)1);
        cycle(cls);

        testassert(normal2 != dealloc);
        method_exchangeImplementations(retainMethod, releaseMethod);
        method_exchangeImplementations(autoreleaseMethod, retainCountMethod);
        method_exchangeImplementations(deallocMethod, normal2Method);
        cycle(cls);
        // normal2 exchanged with ignored method is now ignored too
        testassert(normal2 == dealloc);

        // replace == replace existing
        class_replaceMethod(cls, @selector(retain), (IMP)1, "");
        class_replaceMethod(cls, @selector(release), (IMP)1, "");
        class_replaceMethod(cls, @selector(autorelease), (IMP)1, "");
        class_replaceMethod(cls, @selector(dealloc), (IMP)1, "");
        class_replaceMethod(cls, @selector(retainCount), (IMP)1, "");
        cycle(cls);

        cls = [Sub class];
        testassert(cls);
        cycle(cls);

        // replace == add override
        class_replaceMethod(cls, @selector(retain), (IMP)1, "");
        class_replaceMethod(cls, @selector(release), (IMP)1, "");
        class_replaceMethod(cls, @selector(autorelease), (IMP)1, "");
        class_replaceMethod(cls, @selector(dealloc), (IMP)1, "");
        class_replaceMethod(cls, @selector(retainCount), (IMP)1, "");
        cycle(cls);

        cls = [Sub2 class];
        testassert(cls);
        cycle(cls);

        class_addMethod(cls, @selector(retain), (IMP)1, "");
        class_addMethod(cls, @selector(release), (IMP)1, "");
        class_addMethod(cls, @selector(autorelease), (IMP)1, "");
        class_addMethod(cls, @selector(dealloc), (IMP)1, "");
        class_addMethod(cls, @selector(retainCount), (IMP)1, "");
        cycle(cls);
    }

    // Test calls via objc_msgSend - ignored selectors are ignored 
    // under GC even if the class provides no implementation for them
    if (objc_collecting_enabled()) {
        Class cls;
        id idVal;
        uintptr_t intVal;

        cls = [Empty class];
        state = 0;

        idVal  = [Empty retain];
        testassert(state == 0);
        testassert(idVal == cls);

        idVal  = [Empty release];
        testassert(state == 0);
        testassert(idVal == cls);

        idVal  = [Empty autorelease];
        testassert(state == 0);
        testassert(idVal == cls);

        (void)   [Empty dealloc];
        testassert(state == 0);

        intVal = [Empty retainCount];
        testassert(state == 0);
        testassert(intVal == (uintptr_t)cls);

        idVal  = [Empty normal];
        testassert(state == 1);
        testassert(idVal == nil);
    }    

    succeed(__FILE__);
}
