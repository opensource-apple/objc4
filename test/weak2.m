// See instructions in weak.h

#include "test.h"
#include "weak.h"

int state = 0;

#if !defined(EMPTY)

@implementation MissingRoot
+(void) initialize { } 
+(Class) class { return self; }
+(id) alloc { return class_createInstance(self, 0); }
-(id) init { return self; }
-(void) dealloc { object_dispose(self); }
+(int) method { return 10; }
+(void) load { state++; }
@end

@implementation MissingSuper
+(int) method { return 1+[super method]; }
-(id) init { self = [super init]; ivar = 100; return self; }
+(void) load { state++; }
@end

#endif

@implementation NotMissingRoot
+(void) initialize { } 
+(Class) class { return self; }
+(id) alloc { return class_createInstance(self, 0); }
-(id) init { return self; }
-(void) dealloc { object_dispose(self); }
+(int) method { return 20; }
+(void) load { state++; }
@end

@implementation NotMissingSuper
+(int) method { return 1+[super method]; }
-(id) init { self = [super init]; ivar = 200; return self; }
+(void) load { state++; }
@end

