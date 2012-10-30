#include "test.h"
#include <stdint.h>
#include <objc/runtime.h>

#define OLD 0
#include "ivarSlide.h"

@implementation Base
+(void)initialize { } 
+class { return self; }
+new { return class_createInstance(self, 0); }
-(void)dealloc { object_dispose(self); } 
-(void)finalize { }
@end

@implementation Super @end

@implementation ShrinkingSuper @end

@implementation MoreStrongSuper @end
@implementation LessStrongSuper @end
@implementation MoreWeakSuper @end
@implementation MoreWeak2Super @end
@implementation LessWeakSuper @end
@implementation LessWeak2Super @end
@implementation NoGCChangeSuper @end
@implementation RunsOf15 @end
