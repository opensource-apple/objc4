#include "test.h"
#include "weak.h"

// Subclass of superclass that isn't there
@interface MyMissingSuper : MissingSuper
+(int) method;
@end
@implementation MyMissingSuper
+(int) method { return 1+[super method]; }
+(void) load { state++; }
@end

// Subclass of subclass of superclass that isn't there
@interface MyMissingSub : MyMissingSuper
+(int) method;
@end
@implementation MyMissingSub
+(int) method { return 1+[super method]; }
+(void) load { state++; }
@end

// Subclass of real superclass 
@interface MyNotMissingSuper : NotMissingSuper
+(int) method;
@end
@implementation MyNotMissingSuper
+(int) method { return 1+[super method]; }
+(void) load { state++; }
@end

// Subclass of subclass of superclass that isn't there
@interface MyNotMissingSub : MyNotMissingSuper
+(int) method;
@end
@implementation MyNotMissingSub
+(int) method { return 1+[super method]; }
+(void) load { state++; }
@end

// Categories on all of the above
@interface MissingRoot (MissingRootExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MissingRoot (MissingRootExtras)
+(void)load { state++; }
+(int) cat_method { return 40; }
@end

@interface MissingSuper (MissingSuperExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MissingSuper (MissingSuperExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end

@interface MyMissingSuper (MyMissingSuperExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MyMissingSuper (MyMissingSuperExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end

@interface MyMissingSub (MyMissingSubExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MyMissingSub (MyMissingSubExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end


@interface NotMissingRoot (NotMissingRootExtras)
+(void)load;
+(int) cat_method;
@end
@implementation NotMissingRoot (NotMissingRootExtras)
+(void)load { state++; }
+(int) cat_method { return 30; }
@end

@interface NotMissingSuper (NotMissingSuperExtras)
+(void)load;
+(int) cat_method;
@end
@implementation NotMissingSuper (NotMissingSuperExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end

@interface MyNotMissingSuper (MyNotMissingSuperExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MyNotMissingSuper (MyNotMissingSuperExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end

@interface MyNotMissingSub (MyNotMissingSubExtras)
+(void)load;
+(int) cat_method;
@end
@implementation MyNotMissingSub (MyNotMissingSubExtras)
+(void)load { state++; }
+(int) cat_method { return 1+[super cat_method]; }
@end


static BOOL classInList(Class *classes, const char *name)
{
    Class *cp;
    for (cp = classes; *cp; cp++) {
        if (0 == strcmp(class_getName(*cp), name)) return YES;
    }
    return NO;
}

static BOOL classInNameList(const char **names, const char *name)
{
    const char **cp;
    for (cp = names; *cp; cp++) {
        if (0 == strcmp(*cp, name)) return YES;
    }
    return NO;
}

int main()
{
    // DYLD_IMAGE_SUFFIX=_empty loads the weak-missing version
    BOOL weakMissing = NO;
    if (getenv("DYLD_IMAGE_SUFFIX")) weakMissing = YES;

    // class and category +load methods
    if (weakMissing) testassert(state == 8);
    else testassert(state == 16);
    state = 0;

    // classes
    testassert([NotMissingRoot class]);
    testassert([NotMissingSuper class]);
    testassert([MyNotMissingSuper class]);
    testassert([MyNotMissingSub class]);
    if (weakMissing) {
        testassert(! [MissingRoot class]);
        testassert(! [MissingSuper class]);
        testassert(! [MyMissingSuper class]);
        testassert(! [MyMissingSub class]);
    } else {
        testassert([MissingRoot class]);
        testassert([MissingSuper class]);
        testassert([MyMissingSuper class]);
        testassert([MyMissingSub class]);
    }
    
    // objc_getClass
    testassert(objc_getClass("NotMissingRoot"));
    testassert(objc_getClass("NotMissingSuper"));
    testassert(objc_getClass("MyNotMissingSuper"));
    testassert(objc_getClass("MyNotMissingSub"));
    if (weakMissing) {
        testassert(! objc_getClass("MissingRoot"));
        testassert(! objc_getClass("MissingSuper"));
        testassert(! objc_getClass("MyMissingSuper"));
        testassert(! objc_getClass("MyMissingSub"));
    } else {
        testassert(objc_getClass("MissingRoot"));
        testassert(objc_getClass("MissingSuper"));
        testassert(objc_getClass("MyMissingSuper"));
        testassert(objc_getClass("MyMissingSub"));
    }

    // class list
    Class classes[100];
    int count = objc_getClassList(classes, 99);
    classes[count] = NULL;
    testassert(classInList(classes, "NotMissingRoot"));
    testassert(classInList(classes, "NotMissingSuper"));
    testassert(classInList(classes, "MyNotMissingSuper"));
    testassert(classInList(classes, "MyNotMissingSub"));
    if (weakMissing) {
        testassert(! classInList(classes, "MissingRoot"));
        testassert(! classInList(classes, "MissingSuper"));
        testassert(! classInList(classes, "MyMissingSuper"));
        testassert(! classInList(classes, "MyMissingSub"));
    } else {
        testassert(classInList(classes, "MissingRoot"));
        testassert(classInList(classes, "MissingSuper"));
        testassert(classInList(classes, "MyMissingSuper"));
        testassert(classInList(classes, "MyMissingSub"));
    }

    // class name list
    const char *image = class_getImageName(objc_getClass("NotMissingRoot"));
    testassert(image);
    const char **names = objc_copyClassNamesForImage(image, NULL);
    testassert(names);
    testassert(classInNameList(names, "NotMissingRoot"));
    testassert(classInNameList(names, "NotMissingSuper"));
    if (weakMissing) {
        testassert(! classInNameList(names, "MissingRoot"));
        testassert(! classInNameList(names, "MissingSuper"));
    } else {
        testassert(classInNameList(names, "MissingRoot"));
        testassert(classInNameList(names, "MissingSuper"));
    }
    free(names);

    image = class_getImageName(objc_getClass("MyNotMissingSub"));
    testassert(image);
    names = objc_copyClassNamesForImage(image, NULL);
    testassert(names);
    testassert(classInNameList(names, "MyNotMissingSuper"));
    testassert(classInNameList(names, "MyNotMissingSub"));
    if (weakMissing) {
        testassert(! classInNameList(names, "MyMissingSuper"));
        testassert(! classInNameList(names, "MyMissingSub"));
    } else {
        testassert(classInNameList(names, "MyMissingSuper"));
        testassert(classInNameList(names, "MyMissingSub"));
    }
    free(names);
    
    // methods
    testassert(20 == [NotMissingRoot method]);
    testassert(21 == [NotMissingSuper method]);
    testassert(22 == [MyNotMissingSuper method]);
    testassert(23 == [MyNotMissingSub method]);
    if (weakMissing) {
        testassert(0 == [MissingRoot method]);
        testassert(0 == [MissingSuper method]);
        testassert(0 == [MyMissingSuper method]);
        testassert(0 == [MyMissingSub method]);
    } else {
        testassert(10 == [MissingRoot method]);
        testassert(11 == [MissingSuper method]);
        testassert(12 == [MyMissingSuper method]);
        testassert(13 == [MyMissingSub method]);
    }
    
    // category methods
    testassert(30 == [NotMissingRoot cat_method]);
    testassert(31 == [NotMissingSuper cat_method]);
    testassert(32 == [MyNotMissingSuper cat_method]);
    testassert(33 == [MyNotMissingSub cat_method]);
    if (weakMissing) {
        testassert(0 == [MissingRoot cat_method]);
        testassert(0 == [MissingSuper cat_method]);
        testassert(0 == [MyMissingSuper cat_method]);
        testassert(0 == [MyMissingSub cat_method]);
    } else {
        testassert(40 == [MissingRoot cat_method]);
        testassert(41 == [MissingSuper cat_method]);
        testassert(42 == [MyMissingSuper cat_method]);
        testassert(43 == [MyMissingSub cat_method]);
    }

    // allocations and ivars
    id obj;
    NotMissingSuper *obj2;
    MissingSuper *obj3;
    testassert((obj = [[NotMissingRoot alloc] init])); 
    free(obj);
    testassert((obj2 = [[NotMissingSuper alloc] init]));
    testassert(obj2->ivar == 200); free(obj2);
    testassert((obj2 = [[MyNotMissingSuper alloc] init]));
    testassert(obj2->ivar == 200); free(obj2);
    testassert((obj2 = [[MyNotMissingSub alloc] init]));
    testassert(obj2->ivar == 200); free(obj2);
    if (weakMissing) {
        testassert(! [[MissingRoot alloc] init]);
        testassert(! [[MissingSuper alloc] init]);
        testassert(! [[MyMissingSuper alloc] init]);
        testassert(! [[MyMissingSub alloc] init]);
    } else {
        testassert((obj = [[MissingRoot alloc] init])); 
        free(obj);
        testassert((obj3 = [[MissingSuper alloc] init])); 
        testassert(obj3->ivar == 100); free(obj3);
        testassert((obj3 = [[MyMissingSuper alloc] init])); 
        testassert(obj3->ivar == 100); free(obj3);
        testassert((obj3 = [[MyMissingSub alloc] init])); 
        testassert(obj3->ivar == 100); free(obj3);
    }

    if (weakMissing) succeed("weak-missing");
    else succeed("weak-not-missing");
    return 0;
}
