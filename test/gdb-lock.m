#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "test.h"

// gcc -arch ppc -arch i386 -arch x86_64 -x objective-c gdb-lock.m -framework Foundation
// CONFIG GC RR

#if __cplusplus
extern "C" 
#endif
   BOOL gdb_objc_isRuntimeLocked();

@interface Foo : NSObject
@end
@implementation Foo
- (void) foo;
{
}

- (void) test: __attribute__((unused)) sender
{
    unsigned int x = 0;
    Method foo = class_getInstanceMethod([Foo class], @selector(foo));
    IMP fooIMP = method_getImplementation(foo);
    const char *fooTypes = method_getTypeEncoding(foo);
    while(1) {
        NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
        char newSELName[100];
        sprintf(newSELName, "a%u", x++);
        SEL newSEL = sel_registerName(newSELName);
        class_addMethod([Foo class], newSEL, fooIMP, fooTypes);
        [self performSelector: newSEL];
        [p drain];
    }
}
@end

int main() {
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    [NSThread detachNewThreadSelector: @selector(test:) toTarget: [Foo new] withObject: nil];
    unsigned int x = 0;
    unsigned int lockCount = 0;
    while(1) {
        if (gdb_objc_isRuntimeLocked())
            lockCount++;
        x++;
        if (x > 1000000)
            break;
    }
    if (lockCount < 10) {
        fail("Runtime not locked very much.");
    }
    [p drain];

    succeed(__FILE__);
    
    return 0;
}