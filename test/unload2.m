#include "unload.h"
#include <objc/runtime.h>


@implementation SmallClass
+(void)initialize { } 
+(id)new {
    return class_createInstance(self, 0);
}
-(void)free { object_dispose(self); }
-(void)unload2_instance_method { }
-(void)finalize { }
@end


@implementation BigClass
+(void)initialize { } 
+(id)new {
    return class_createInstance(self, 0);
}
-(void)free { object_dispose(self); }
-(void)finalize { }
-(void)forward:(int)a1:(int)a2 { a1 = a2; }
@end


@interface UnusedClass { id isa; } @end
@implementation UnusedClass @end


@implementation SmallClass (Category) 
-(void)unload2_category_method { }
@end
