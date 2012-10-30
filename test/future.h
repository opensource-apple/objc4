#include "test.h"

@interface Super { id isa; } 
+class;
@end

@interface Sub1 : Super
+(int)method;
+(Class)classref;
@end

@interface Sub2 : Super
+(int)method;
+(Class)classref;
@end

@interface SubSub1 : Sub1 @end

@interface SubSub2 : Sub2 @end
