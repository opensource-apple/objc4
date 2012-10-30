// TEST_CFLAGS -framework Foundation

#include "test.h"
#include <Foundation/Foundation.h>
#include <objc/runtime.h>

static int values;
static int subs;

static const char *key = "key";


@interface Value : NSObject @end
@interface Super : NSObject @end
@interface Sub : NSObject @end

@implementation Super 
-(id) init
{
    // rdar://8270243 don't lose associations after isa swizzling

    id value = [Value new];
    objc_setAssociatedObject(self, &key, value, OBJC_ASSOCIATION_RETAIN);
    [value release];

    object_setClass(self, [Sub class]);
    
    return self;
}

@end

@implementation Sub
-(void) dealloc 
{
    subs++;
    [super dealloc];
}
-(void) finalize
{
    subs++;
    [super finalize];
}
@end

@implementation Value
-(void) dealloc {
    values++;
    [super dealloc];
}
-(void) finalize {
    values++;
    [super finalize];
}
@end

int main()
{
    int i;
    for (i = 0; i < 100; i++) {
        [[[Super alloc] init] release];
    }

    testcollect();

    testassert(subs > 0);
    testassert(subs == values);

    succeed(__FILE__);
}
