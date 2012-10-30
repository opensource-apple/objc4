// TEST_CFLAGS -framework Foundation

#include "test.h"
#include <objc/runtime.h>
#include <objc/objc-internal.h>
#import <Foundation/Foundation.h>

#if __OBJC2__ && __LP64__
/*
 gcc -o taggedPointers.out taggedPointers.m -L/tmp/bbum-products/Release/ -lobjc -undefined dynamic_lookup -framework Foundation -gdwarf-2
 env DYLD_LIBRARY_PATH=/tmp/bbum-products/Release/ DYLD_FRAMEWORK_PATH=/tmp/bbum-products/Release gdb ./taggedPointers.out
 env DYLD_LIBRARY_PATH=/tmp/bbum-products/Debug/ DYLD_FRAMEWORK_PATH=/tmp/bbum-products/Debug gdb ./taggedPointers.out
 */

static BOOL didIt;

#define TAG_VALUE(tagSlot, value) ((id)(1UL | (((uintptr_t)(tagSlot)) << 1) | (((uintptr_t)(value)) << 4)))

@interface TaggedBaseClass
@end

@implementation TaggedBaseClass
+ (void) initialize
{
    ;
}

- (void) instanceMethod
{
    didIt = YES;
}

- (uintptr_t) taggedValue
{
    return (uintptr_t) self >> 4;
}

- (NSRect) stret: (NSRect) aRect
{
    return aRect;
}

- (long double) fpret: (long double) aValue
{
    return aValue;
}


-(void) dealloc {
    fail("TaggedBaseClass dealloc called!");
}

-(id) retain {
    return _objc_rootRetain(self);
}

-(void) release {
    return _objc_rootRelease(self);
}

-(id) autorelease {
    return _objc_rootAutorelease(self);
}

-(uintptr_t) retainCount {
    return _objc_rootRetainCount(self);
}
@end

@interface TaggedSubclass: TaggedBaseClass
@end

@implementation TaggedSubclass
+ (void) initialize
{
    ;
}

- (void) instanceMethod
{
    return [super instanceMethod];
}

- (uintptr_t) taggedValue
{
    return [super taggedValue];
}

- (NSRect) stret: (NSRect) aRect
{
    return [super stret: aRect];
}

- (long double) fpret: (long double) aValue
{
    return [super fpret: aValue];
}
@end

@interface TaggedNSObjectSubclass : NSObject
@end

@implementation TaggedNSObjectSubclass
+ autorelease {
    abort();
}
- autorelease {
    didIt = YES;
    return self;
}
- retain {
    didIt = YES;
    return self;
}
- (oneway void) release {
    didIt = YES;
}

- (void) instanceMethod {
    didIt = YES;
}

- (uintptr_t) taggedValue
{
    return (uintptr_t) self >> 4;
}

- (NSRect) stret: (NSRect) aRect
{
    return aRect;
}

- (long double) fpret: (long double) aValue
{
    return aValue;
}
@end

/*

This class was used prior to integration of tagged numbers into CF.
Now that CF has tagged numbers, the test assumes their presence.
  
@interface TestTaggedNumber:NSNumber
@end
@implementation TestTaggedNumber
+(void) load
{
    _objc_insert_tagged_isa(4, self);
}

+ taggedNumberWithInt: (int) arg
{
    uint64_t value = (uint64_t) arg;
    id returnValue = (id) (((uint64_t) 0x9) | (value << 4));
    return returnValue;
}

- (void)getValue:(void *)value
{
    *(uint64_t *)value = ((uint64_t)self) >> 4;
}

- (const char *)objCType
{
    return "i";
}

- (int)intValue
{
    return (int) (((uint64_t)self) >> 4);
}
@end
*/

void testTaggedNumber()
{
    NSNumber *taggedPointer = [NSNumber numberWithInt: 1234];
    int result;
    
    testassert( CFGetTypeID(taggedPointer) == CFNumberGetTypeID() );
    
    CFNumberGetValue((CFNumberRef) taggedPointer, kCFNumberIntType, &result);
    testassert(result == 1234);

    testassert(((uintptr_t)taggedPointer) & 0x1); // make sure it is really tagged

    // do some generic object-y things to the taggedPointer instance
    CFRetain(taggedPointer);
    CFRelease(taggedPointer);
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject: taggedPointer forKey: @"fred"];
    testassert(taggedPointer == [dict objectForKey: @"fred"]);
    [dict setObject: @"bob" forKey: taggedPointer];
    testassert([@"bob" isEqualToString: [dict objectForKey: taggedPointer]]);
    
    NSNumber *i12345 = [NSNumber numberWithInt: 12345];
    NSNumber *i12346 = [NSNumber numberWithInt: 12346];
    NSNumber *i12347 = [NSNumber numberWithInt: 12347];
    
    NSArray *anArray = [NSArray arrayWithObjects: i12345, i12346, i12347, nil];
    testassert([anArray count] == 3);
    testassert([anArray indexOfObject: i12346] == 1);
    
    NSSet *aSet = [NSSet setWithObjects: i12345, i12346, i12347, nil];
    testassert([aSet count] == 3);
    testassert([aSet containsObject: i12346]);
    
    [taggedPointer performSelector: @selector(intValue)];
    testassert(![taggedPointer isProxy]);
    testassert([taggedPointer isKindOfClass: [NSNumber class]]);
    testassert([taggedPointer respondsToSelector: @selector(intValue)]);
    
    [taggedPointer description];
}

void testGenericTaggedPointer(uint8_t tagSlot, const char *classname)
{
    Class cls = objc_getClass(classname);
    testassert(cls);

    id taggedPointer = TAG_VALUE(tagSlot, 1234);
    testassert(object_getClass(taggedPointer) == cls);
    testassert([taggedPointer taggedValue] == 1234);

    didIt = NO;
    [taggedPointer instanceMethod];
    testassert(didIt);    
    
    NSRect originalRect = NSMakeRect(1.0, 2.0, 3.0, 4.0);
    testassert(NSEqualRects(originalRect, [taggedPointer stret: originalRect]));
    
    long double value = 3.14156789;
    testassert(value == [taggedPointer fpret: value]);

    if (!objc_collectingEnabled()) {
        // Tagged pointers should bypass refcount tables and autorelease pools
        leak_mark();
        for (uintptr_t i = 0; i < 10000; i++) {
            id o = TAG_VALUE(tagSlot, i);
            testassert(object_getClass(o) == cls);

            [o release];  testassert([o retainCount] != 0);
            [o release];  testassert([o retainCount] != 0);
            CFRelease(o);  testassert([o retainCount] != 0);
            CFRelease(o);  testassert([o retainCount] != 0);
            [o retain];
            [o retain];
            [o retain];
            CFRetain(o);
            CFRetain(o);
            CFRetain(o);
            [o autorelease];
        }
        leak_check(0);
    }
}

int main()
{
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    
    _objc_insert_tagged_isa(5, objc_getClass("TaggedBaseClass"));
    testGenericTaggedPointer(5, "TaggedBaseClass");
    
    _objc_insert_tagged_isa(2, objc_getClass("TaggedSubclass"));
    testGenericTaggedPointer(2, "TaggedSubclass");
    
    _objc_insert_tagged_isa(3, objc_getClass("TaggedNSObjectSubclass"));
    testGenericTaggedPointer(3, "TaggedNSObjectSubclass");
    
    testTaggedNumber(); // should be tested by CF... our tests are wrong, wrong, wrong.
    [p release];

    succeed(__FILE__);
}

// OBJC2 && __LP64__
#else
// not (OBJC2 && __LP64__)

    // Tagged pointers not supported. Crash if an NSNumber actually 
    // is a tagged pointer (which means this test is out of date).

int main() {
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    testassert(*(id *)[NSNumber numberWithInt:1234]);
    [p release];
    
    succeed(__FILE__);
}

#endif
