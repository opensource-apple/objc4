// clang -objc-arr -print-ivar-layout
/*
TEST_DISABLED
TEST_CONFIG GC=0 CC=clang
TEST_BUILD
    clang -c $DIR/MRRBase.m $DIR/MRRARR.m
    libtool -static MRRBase.o MRRARR.o -framework Foundation -o libMRR.a
    clang -fobjc-arr -c $DIR/ARRBase.m $DIR/ARRMRR.m
    libtool -static ARRBase.o ARRMRR.o -framework Foundation -o libARR.a
    $C{COMPILE} -fobjc-arr $DIR/ARRLayouts.m -L . -lMRR -lARR -framework Foundation -o ARRLayouts.out
END
*/

#include "test.h"
#import <stdio.h>
#import <assert.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ARRMRR.h"
#import "MRRARR.h"

@interface NSObject (Layouts)
+ (const char *)strongLayout;
+ (const char *)weakLayout;
@end

void printlayout(const char *name, const uint8_t *layout)
{
    printf("%s: ", name);

    if (!layout) { 
        printf("NULL\n");
        return;
    }

    const uint8_t *c;
    for (c = layout; *c; c++) {
        printf("%02x ", *c);
    }

    printf("00\n");
}

@implementation NSObject (Layouts)

+ (const char *)strongLayout {
    const uint8_t *layout = class_getIvarLayout(self);
    // printlayout("strong", layout);
    return (const char *)layout;
}

+ (const char *)weakLayout {
    const uint8_t *weakLayout = class_getWeakIvarLayout(self);
    // printlayout("weak", weakLayout);
    return (const char *)weakLayout;
}

+ (Ivar)instanceVariable:(const char *)name {
    return class_getInstanceVariable(self, name);
}

@end

int main (int argc  __unused, const char * argv[] __unused) {
    // Under ARR, layout strings are relative to the class' own ivars.
    assert(strcmp([ARRBase strongLayout], "\x11\x20") == 0);
    assert(strcmp([ARRBase weakLayout], "\x31") == 0);
    assert([MRRBase strongLayout] == NULL);
    assert([MRRBase weakLayout] == NULL);
    assert(strcmp([ARRMRR strongLayout], "\x01") == 0);
    assert([ARRMRR weakLayout] == NULL);
    assert([MRRARR strongLayout] == NULL);
    assert([MRRARR weakLayout] == NULL);
    
    // now check consistency between dynamic accessors and KVC, etc.
    ARRMRR *am = [ARRMRR new];
    MRRARR *ma = [MRRARR new];

    NSString *am_description = [[NSString alloc] initWithFormat:@"%s %p", "ARRMRR", am];
    NSString *ma_description = [[NSString alloc] initWithFormat:@"%s %p", "MRRARR", ma];

    am.number = M_PI;
    object_setIvar(am, [ARRMRR instanceVariable:"object"], am_description);
    assert(CFGetRetainCount(objc_unretainedPointer(am_description)) == 1);
    am.pointer = @selector(ARRMRR);
    object_setIvar(am, [ARRMRR instanceVariable:"delegate"], ma);
    assert(CFGetRetainCount(objc_unretainedPointer(ma)) == 1);
    
    ma.number = M_E;
    object_setIvar(ma, [MRRARR instanceVariable:"object"], ma_description);
    assert(CFGetRetainCount(objc_unretainedPointer(ma_description)) == 2);
    ma.pointer = @selector(MRRARR);
    ma.delegate = am;
    object_setIvar(ma, [MRRARR instanceVariable:"delegate"], am);
    assert(CFGetRetainCount(objc_unretainedPointer(am)) == 1);
    
    succeed(__FILE__);
    return 0;
}
