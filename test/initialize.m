// TEST_CONFIG

// initialize.m
// Test basic +initialize behavior
// * +initialize before class method
// * superclass +initialize before subclass +initialize
// * subclass inheritance of superclass implementation
// * messaging during +initialize
#include "test.h"

int state = 0;

@interface Super0 { } @end
@implementation Super0
+(void)initialize {
    fail("objc_getClass() must not trigger +initialize");
}
@end

@interface Super {} @end
@implementation Super 
+(void)initialize {
    testprintf("in [Super initialize]\n");
    testassert(state == 0);
    state = 1;
}
+(void)method { 
    fail("[Super method] shouldn't be called");
}
@end

@interface Sub : Super { } @end
@implementation Sub
+(void)initialize { 
    testprintf("in [Sub initialize]\n");
    testassert(state == 1);
    state = 2;
}
+(void)method { 
    testprintf("in [Sub method]\n");
    testassert(state == 2);
    state = 3;
}
@end


@interface Super2 { } @end
@interface Sub2 : Super2 { } @end

@implementation Super2
+(id)class { return self; }
+(void)initialize { 
    if (self == objc_getClass("Sub2")) {
        testprintf("in [Super2 initialize] of Sub2\n");
        testassert(state == 1);
        state = 2;
    } else if (self == objc_getClass("Super2")) {
        testprintf("in [Super2 initialize] of Super2\n");
        testassert(state == 0);
        state = 1;
    } else {
        fail("in [Super2 initialize] of unknown class");
    }
}
+(void)method { 
    testprintf("in [Super2 method]\n");
    testassert(state == 2);
    state = 3;
}
@end

@implementation Sub2
// nothing here
@end


@interface Super3 { } @end
@interface Sub3 : Super3 { } @end

@implementation Super3
+(id)class { return self; }
+(void)initialize { 
    if (self == [Sub3 class]) {  // this message triggers [Sub3 initialize]
        testprintf("in [Super3 initialize] of Sub3\n");
        testassert(state == 0);
        state = 1;
    } else if (self == [Super3 class]) {
        testprintf("in [Super3 initialize] of Super3\n");
        testassert(state == 1);
        state = 2;
    } else {
        fail("in [Super3 initialize] of unknown class");
    }
}
+(void)method { 
    testprintf("in [Super3 method]\n");
    testassert(state == 2);
    state = 3;
}
@end

@implementation Sub3
// nothing here
@end

int main()
{
    // objc_getClass() must not +initialize anything
    state = 0;
    objc_getClass("Super0");
    testassert(state == 0);

    // initialize superclass, then subclass
    state = 0;
    [Sub method];
    testassert(state == 3);

    // check subclass's inheritance of superclass initialize
    state = 0;
    [Sub2 method];
    testassert(state == 3);

    // check subclass method called from superclass initialize
    state = 0;
    [Sub3 method];
    testassert(state == 3);

    succeed(__FILE__);

    return 0;
}
