#include "test.h"
#include <malloc/malloc.h>
#include <objc/objc-runtime.h>

@interface SuperMethods { } @end
@implementation SuperMethods
+(void)SuperMethodClass { } 
+(void)SuperMethodClass2 { } 
-(void)SuperMethodInstance { } 
-(void)SuperMethodInstance2 { } 
@end

@interface SubMethods { } @end
@implementation SubMethods
+(void)SubMethodClass { } 
+(void)SubMethodClass2 { } 
-(void)SubMethodInstance { } 
-(void)SubMethodInstance2 { } 
@end

@interface SuperMethods (Category) @end
@implementation SuperMethods (Category)
+(void)SuperMethodClassCat { } 
+(void)SuperMethodClassCat2 { } 
-(void)SuperMethodInstanceCat { } 
-(void)SuperMethodInstanceCat2 { } 
@end

@interface SubMethods (Category) @end
@implementation SubMethods (Category)
+(void)SubMethodClassCat { } 
+(void)SubMethodClassCat2 { } 
-(void)SubMethodInstanceCat { } 
-(void)SubMethodInstanceCat2 { } 
@end


@interface FourMethods @end
@implementation FourMethods
-(void)one { }
-(void)two { }
-(void)three { }
-(void)four { }
@end

@interface NoMethods @end
@implementation NoMethods @end

static int isNamed(Method m, const char *name)
{
    return (method_getName(m) == sel_registerName(name));
}

int main()
{
    // Class SubMethods has not yet been touched, so runtime must attach 
    // the lazy categories
    Method *methods;
    unsigned int count;
    Class cls;

    cls = objc_getClass("SubMethods");
    testassert(cls);

    testprintf("calling class_copyMethodList(SubMethods) (should be unmethodized)\n");

    count = 100;
    methods = class_copyMethodList(cls, &count);
    testassert(methods);
    testassert(count == 4);
    // First two methods should be the category methods, 
    // followed by the class methods
    testassert((isNamed(methods[0], "SubMethodInstanceCat")  &&  
                isNamed(methods[1], "SubMethodInstanceCat2"))  
               ||
               (isNamed(methods[1], "SubMethodInstanceCat")  &&  
                isNamed(methods[0], "SubMethodInstanceCat2")));
    testassert((isNamed(methods[2], "SubMethodInstance")  &&  
                isNamed(methods[3], "SubMethodInstance2"))  
               ||
               (isNamed(methods[3], "SubMethodInstance")  &&  
                isNamed(methods[2], "SubMethodInstance2")));
    // methods[] should be null-terminated
    testassert(methods[4] == NULL);
    free(methods);

    testprintf("calling class_copyMethodList(SubMethods(meta)) (should be unmethodized)\n");

    count = 100;
    methods = class_copyMethodList(cls->isa, &count);
    testassert(methods);
    testassert(count == 4);
    // First two methods should be the category methods, 
    // followed by the class methods
    testassert((isNamed(methods[0], "SubMethodClassCat")  &&  
                isNamed(methods[1], "SubMethodClassCat2"))  
               ||
               (isNamed(methods[1], "SubMethodClassCat")  &&  
                isNamed(methods[0], "SubMethodClassCat2")));
    testassert((isNamed(methods[2], "SubMethodClass")  &&  
                isNamed(methods[3], "SubMethodClass2"))  
               ||
               (isNamed(methods[3], "SubMethodClass")  &&  
                isNamed(methods[2], "SubMethodClass2")));
    // methods[] should be null-terminated
    testassert(methods[4] == NULL);
    free(methods);

    // Check null-termination - this method list block would be 16 bytes
    // if it weren't for the terminator
    count = 100;
    cls = objc_getClass("FourMethods");
    methods = class_copyMethodList(cls, &count);
    testassert(methods);
    testassert(count == 4);
    testassert(malloc_size(methods) >= 5 * sizeof(Method));
    testassert(methods[3] != NULL);
    testassert(methods[4] == NULL);
    free(methods);

    // Check NULL count parameter
    methods = class_copyMethodList(cls, NULL);
    testassert(methods);
    testassert(methods[4] == NULL);
    testassert(methods[3] != NULL);
    free(methods);

    // Check NULL class parameter
    count = 100;
    methods = class_copyMethodList(NULL, &count);
    testassert(!methods);
    testassert(count == 0);
    
    // Check NULL class and count
    methods = class_copyMethodList(NULL, NULL);
    testassert(!methods);

    // Check class with no methods
    count = 100;
    cls = objc_getClass("NoMethods");
    methods = class_copyMethodList(cls, &count);
    testassert(!methods);
    testassert(count == 0);

    succeed(__FILE__);
}
