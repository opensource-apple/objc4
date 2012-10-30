/* 
TEST_RUN_OUTPUT
objc\[\d+\]: class `DoesNotExist\' not linked into application
OK: runtime.m
END 
*/


#include "test.h"

#include <string.h>
#include <dlfcn.h>
#include <mach-o/ldsyms.h>
#include <objc/objc-runtime.h>

@interface Super { id isa; } @end
@implementation Super 
+(void)initialize { } 
+class { return self; }
@end

@interface Sub : Super { } @end
@implementation Sub @end


int main()
{
    Class list[100];
    Class *list2;
    unsigned int count, count0, count2;
    unsigned int i;
    int foundSuper;
    int foundSub;
    const char **names;
    Dl_info info;

    [Super class];

    // This shouldn't touch any classes.
    dladdr(&_mh_execute_header, &info);
    names = objc_copyClassNamesForImage(info.dli_fname, &count);
    testassert(names);
    testassert(count == 2);
    testassert(names[count] == NULL);
    foundSuper = 0;
    foundSub = 0;
    for (i = 0; i < count; i++) {
        if (0 == strcmp(names[i], "Super")) foundSuper++;
        if (0 == strcmp(names[i], "Sub")) foundSub++;
    }
    testassert(foundSuper == 1);
    testassert(foundSub == 1);    


    // class Sub hasn't been touched - make sure it's in the class list too
    count0 = objc_getClassList(NULL, 0);
    testassert(count0 >= 2  &&  count0 < 100);

    list[count0-1] = NULL;
    count = objc_getClassList(list, count0-1);
    testassert(list[count0-1] == NULL);
    testassert(count == count0);

    count = objc_getClassList(list, count0);
    testassert(count == count0);
    foundSuper = 0;
    foundSub = 0;
    for (i = 0; i < count; i++) {
        if (0 == strcmp(class_getName(list[i]), "Super")) foundSuper++;
        if (0 == strcmp(class_getName(list[i]), "Sub")) foundSub++;
        // list should be non-meta classes only
        testassert(!class_isMetaClass(list[i]));
    }
    testassert(foundSuper == 1);
    testassert(foundSub == 1);

    // fixme check class handler
    testassert(objc_getClass("Super") == [Super class]);
    testassert(objc_getClass("DoesNotExist") == nil);
    testassert(objc_getClass(NULL) == nil);

    testassert(objc_getMetaClass("Super") == [Super class]->isa);
    testassert(objc_getMetaClass("DoesNotExist") == nil);
    testassert(objc_getMetaClass(NULL) == nil);

    // fixme check class no handler
    testassert(objc_lookUpClass("Super") == [Super class]);
    testassert(objc_lookUpClass("DoesNotExist") == nil);
    testassert(objc_lookUpClass(NULL) == nil);

    list2 = objc_copyClassList(&count2);
    testassert(count2 == count);
    testassert(list2);
    testassert(malloc_size(list2) >= (1+count2) * sizeof(Class));
    for (i = 0; i < count; i++) {
        testassert(list[i] == list2[i]);
    }
    testassert(list2[count] == NULL);
    free(list2);
    free(objc_copyClassList(NULL));

    succeed(__FILE__);
}
