#include "test.h"

#import <Foundation/Foundation.h>

@interface Sub : NSObject { } @end
@implementation Sub 
+allocWithZone:(NSZone *)zone { 
    testprintf("in +[Sub alloc]\n");
    return [super allocWithZone:zone];
    }
-(void)dealloc { 
    testprintf("in -[Sub dealloc]\n");
    [super dealloc];
}
@end

int main()
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    [[Sub new] autorelease];
    [pool release];

    succeed(__FILE__);
}
