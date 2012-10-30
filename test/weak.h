#include "test.h"
#include <objc/runtime.h>

extern int state;

@interface MissingRoot {
    id isa;
}
+(void) initialize;
+(Class) class;
+(id) alloc;
-(id) init;
+(int) method;
@end

@interface MissingSuper : MissingRoot {
  @public
    int ivar;
}
@end


@interface NotMissingRoot {
    id isa;
}
+(void) initialize;
+(Class) class;
+(id) alloc;
-(id) init;
+(int) method;
@end

@interface NotMissingSuper : NotMissingRoot {
  @public
    int unused[100];
    int ivar;
}
@end
