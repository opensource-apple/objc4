/* resolve.m
 * Test +resolveClassMethod: and +resolveInstanceMethod:
 */

// TEST_CFLAGS -Wno-deprecated-declarations

/* 
TEST_RUN_OUTPUT
objc\[\d+\]: \+\[Sub resolveClassMethod:lyingClassMethod\] returned YES, but no new implementation of \+\[Sub lyingClassMethod\] was found
objc\[\d+\]: \+\[Sub resolveInstanceMethod:lyingInstanceMethod\] returned YES, but no new implementation of -\[Sub lyingInstanceMethod\] was found
OK: resolve\.m
END
*/
  
#include "test.h"
#include <objc/objc.h>
#include <objc/objc-runtime.h>
#include <unistd.h>

static int state = 0;

@interface Super { id isa; } @end
@interface Sub : Super @end


@implementation Super
+class { return self; }
+(void)initialize { 
    if (self == [Super class]) {
        testassert(state == 1);
        state = 2;
    }
}
+new { return class_createInstance(self, 0); }
-(void)dealloc { object_dispose(self); }
-forward:(SEL)sel :(marg_list)args
{
    if (sel == @selector(missingClassMethod)) {
        testassert(state == 21  ||  state == 25  ||  state == 80);
        if (state == 21) state = 22;
        if (state == 25) state = 26;
        if (state == 80) state = 81;;
        return nil;
    } else if (sel == @selector(lyingClassMethod)) {
        testassert(state == 31  ||  state == 35);
        if (state == 31) state = 32;
        if (state == 35) state = 36;
        return nil;
    } else if (sel == @selector(missingInstanceMethod)) {
        testassert(state == 61  ||  state == 65);
        if (state == 61) state = 62;
        if (state == 65) state = 66;
        return nil;
    } else if (sel == @selector(lyingInstanceMethod)) {
        testassert(state == 71  ||  state == 75);
        if (state == 71) state = 72;
        if (state == 75) state = 76;
        return nil;
    }
    fail("forward:: shouldn't be called (sel %s)", sel_getName(sel));
    return (id)args;  // unused
}
@end


static id classMethod_c(id self, SEL sel)
{
    testassert(state == 4  ||  state == 10);
    if (state == 4) state = 5;
    if (state == 10) state = 11;
    self = (id)sel;  // unused
    return [Super class];
}

static id instanceMethod_c(id self, SEL sel)
{
    testassert(state == 41  ||  state == 50);
    if (state == 41) state = 42;
    if (state == 50) state = 51;
    self = (id)sel;  // unused
    return [Sub class];
}


@implementation Sub

+(void)method2 { } 
+(void)method3 { } 
+(void)method4 { } 
+(void)method5 { } 

+(void)initialize { 
    if (self == [Sub class]) {
        testassert(state == 2);
        state = 3;
    }
}

+(BOOL)resolveClassMethod:(SEL)sel
{
    if (sel == @selector(classMethod)) {
        testassert(state == 3);
        state = 4;
        class_addMethod(self->isa, sel, (IMP)&classMethod_c, "");
        return YES;
    } else if (sel == @selector(missingClassMethod)) {
        testassert(state == 20);
        state = 21;
        return NO;
    } else if (sel == @selector(lyingClassMethod)) {
        testassert(state == 30);
        state = 31;
        return YES;  // lie
    } else {
        fail("+resolveClassMethod: called incorrectly (sel %s)", 
             sel_getName(sel));
        return NO;
    }
}

+(BOOL)resolveInstanceMethod:(SEL)sel
{
    if (sel == @selector(instanceMethod)) {
        testassert(state == 40);
        state = 41;
        class_addMethod(self, sel, (IMP)instanceMethod_c, "");
        return YES;
    } else if (sel == @selector(missingInstanceMethod)) {
        testassert(state == 60);
        state = 61;
        return NO;
    } else if (sel == @selector(lyingInstanceMethod)) {
        testassert(state == 70);
        state = 71;
        return YES;  // lie
    } else {
        fail("+resolveInstanceMethod: called incorrectly (sel %s)", 
             sel_getName(sel));
        return NO;
    }
}

@end

@interface Super (MissingMethods)
+missingClassMethod;
@end

@interface Sub (ResolvedMethods)
+classMethod;
-instanceMethod;
+missingClassMethod;
-missingInstanceMethod;
+lyingClassMethod;
-lyingInstanceMethod;
@end


int main()
{
    Sub *s;
    id ret;
    Class dup = objc_duplicateClass(objc_getClass("Sub"), "Sub_copy", 0);

    // Resolve a class method
    // +initialize should fire first
    state = 1;
    ret = [Sub classMethod];
    testassert(state == 5);
    testassert(ret == [Super class]);

    // Call it again, cached
    // Resolver shouldn't be called again.
    state = 10;
    ret = [Sub classMethod];
    testassert(state == 11);
    testassert(ret == [Super class]);

    _objc_flush_caches([Sub class]->isa);

    // Call a method that won't get resolved
    state = 20;
    ret = [Sub missingClassMethod];
    testassert(state == 22);
    testassert(ret == nil);

    // Call it again, cached
    // Resolver shouldn't be called again.
    state = 25;
    ret = [Sub missingClassMethod];
    testassert(state == 26);
    testassert(ret == nil);

    _objc_flush_caches([Sub class]->isa);

    // Call a method that won't get resolved but the resolver lies about it
    state = 30;
    ret = [Sub lyingClassMethod];
    testassert(state == 32);
    testassert(ret == nil);

    // Call it again, cached
    // Resolver shouldn't be called again.
    state = 35;
    ret = [Sub lyingClassMethod];
    testassert(state == 36);
    testassert(ret == nil);

    _objc_flush_caches([Sub class]->isa);


    // Resolve an instance method
    s = [Sub new];
    state = 40;
    ret = [s instanceMethod];
    testassert(state == 42);
    testassert(ret == [Sub class]);

    // Call it again, cached
    // Resolver shouldn't be called again.    
    state = 50;
    ret = [s instanceMethod];
    testassert(state == 51);
    testassert(ret == [Sub class]);

    _objc_flush_caches([Sub class]);

    // Call a method that won't get resolved
    state = 60;
    ret = [s missingInstanceMethod];
    testassert(state == 62);
    testassert(ret == nil);

    // Call it again, cached
    // Resolver shouldn't be called again.
    state = 65;
    ret = [s missingInstanceMethod];
    testassert(state == 66);
    testassert(ret == nil);

    _objc_flush_caches([Sub class]);
    
    // Call a method that won't get resolved but the resolver lies about it
    state = 70;
    ret = [s lyingInstanceMethod];
    testassert(state == 72);
    testassert(ret == nil);

    // Call it again, cached
    // Resolver shouldn't be called again.
    state = 75;
    ret = [s lyingInstanceMethod];
    testassert(state == 76);
    testassert(ret == nil);

    _objc_flush_caches([Sub class]);

    // Call a missing method on a class that doesn't support resolving
    state = 80;
    ret = [Super missingClassMethod];
    testassert(state == 81);
    testassert(ret == nil);
    [s dealloc];

    // Resolve an instance method on a class duplicated before resolving
    s = [dup new];
    state = 40;
    ret = [s instanceMethod];
    testassert(state == 42);
    testassert(ret == [Sub class]);

    // Call it again, cached
    // Resolver shouldn't be called again.    
    state = 50;
    ret = [s instanceMethod];
    testassert(state == 51);
    testassert(ret == [Sub class]);
    [s dealloc];

    succeed(__FILE__);
    return 0;
}
