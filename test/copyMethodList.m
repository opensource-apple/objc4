// TEST_CONFIG

#include "test.h"
#include <malloc/malloc.h>
#include <objc/objc-runtime.h>

#if __OBJC2__
// methods added by the runtime: +initialize
#   define MC 1  // class methods
#   define MI 0  // instance methods
#else
// no magic
#   define MC 0
#   define MI 0
#endif

@interface SuperMethods { } @end
@implementation SuperMethods
+(BOOL)SuperMethodClass { return NO; } 
+(BOOL)SuperMethodClass2 { return NO; } 
-(BOOL)SuperMethodInstance { return NO; } 
-(BOOL)SuperMethodInstance2 { return NO; } 
@end

@interface SubMethods { } @end
@implementation SubMethods
+(BOOL)SubMethodClass { return NO; } 
+(BOOL)SubMethodClass2 { return NO; } 
-(BOOL)SubMethodInstance { return NO; } 
-(BOOL)SubMethodInstance2 { return NO; } 
@end

@interface SuperMethods (Category) @end
@implementation SuperMethods (Category)
+(BOOL)SuperMethodClass { return YES; } 
+(BOOL)SuperMethodClass2 { return YES; } 
-(BOOL)SuperMethodInstance { return YES; } 
-(BOOL)SuperMethodInstance2 { return YES; } 
@end

@interface SubMethods (Category) @end
@implementation SubMethods (Category)
+(BOOL)SubMethodClass { return YES; } 
+(BOOL)SubMethodClass2 { return YES; } 
-(BOOL)SubMethodInstance { return YES; } 
-(BOOL)SubMethodInstance2 { return YES; } 
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

static void checkReplacement(Method *list, const char *name)
{
    Method first = NULL, second = NULL;
    SEL sel = sel_registerName(name);
    int i;

    testassert(list);

    // Find the methods. There should be two.
    for (i = 0; list[i]; i++) {
        if (method_getName(list[i]) == sel) {
            if (!first) first = list[i];
            else if (!second) second = list[i];
            else testassert(0);
        }
    }

    // Call the methods. The first should be the category (returns YES).
    BOOL isCat;
    isCat = ((BOOL(*)(id, Method))method_invoke)(NULL, first);
    testassert(isCat);
    isCat = ((BOOL(*)(id, Method))method_invoke)(NULL, second);
    testassert(! isCat);
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
    testassert(count == 4+MI);
    // methods[] should be null-terminated
    testassert(methods[4+MI] == NULL);
    // Class and category methods may be mixed in the method list thanks 
    // to linker / shared cache sorting, but a category's replacement should
    // always precede the class's implementation.
    checkReplacement(methods, "SubMethodInstance");
    checkReplacement(methods, "SubMethodInstance2");
    free(methods);

    testprintf("calling class_copyMethodList(SubMethods(meta)) (should be unmethodized)\n");

    count = 100;
    methods = class_copyMethodList(cls->isa, &count);
    testassert(methods);
    testassert(count == 4+MC);
    // methods[] should be null-terminated
    testassert(methods[4+MC] == NULL);
    // Class and category methods may be mixed in the method list thanks 
    // to linker / shared cache sorting, but a category's replacement should
    // always precede the class's implementation.
    checkReplacement(methods, "SubMethodClass");
    checkReplacement(methods, "SubMethodClass2");
    free(methods);

    // Check null-termination - this method list block would be 16 bytes
    // if it weren't for the terminator
    count = 100;
    cls = objc_getClass("FourMethods");
    methods = class_copyMethodList(cls, &count);
    testassert(methods);
    testassert(count == 4+MI);
    testassert(malloc_size(methods) >= (4+MI+1) * sizeof(Method));
    testassert(methods[3+MI] != NULL);
    testassert(methods[4+MI] == NULL);
    free(methods);

    // Check NULL count parameter
    methods = class_copyMethodList(cls, NULL);
    testassert(methods);
    testassert(methods[4+MI] == NULL);
    testassert(methods[3+MI] != NULL);
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
    if (MI == 0) {
        testassert(!methods);
        testassert(count == 0);
    } else {
        testassert(methods);
        testassert(count == MI);
        testassert(methods[MI] == NULL);
        testassert(methods[MI-1] != NULL);
    }

    succeed(__FILE__);
}
