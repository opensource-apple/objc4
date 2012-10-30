#include "test.h"
#include <objc/objc-runtime.h>
#import <Foundation/Foundation.h>

@interface Foo:NSObject
@end
@implementation Foo
@end

extern Class gdb_class_getClass(Class cls);

int main()
{
#if __OBJC2__
    testassert(gdb_class_getClass([Foo class]) == [Foo class]);
#endif

    succeed(__FILE__);
}
