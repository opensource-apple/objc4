// TEST_CFLAGS -framework Foundation

#include "test.h"
#include <objc/runtime.h>
#import <Foundation/Foundation.h>

#include <Block_private.h>

#if !__clang__  &&  !__llvm__
    // gcc will never support struct-return marking
#   define STRET_OK 0
#elif !clang
// llvm-gcc waiting for rdar://8143947
#   define STRET_OK 0
#else
#   define STRET_OK 1
#endif

typedef uint32_t (*funcptr)();

typedef struct BigStruct {
    unsigned int datums[200];
} BigStruct;

@interface Foo:NSObject
@end
@implementation Foo
- (BigStruct) methodThatReturnsBigStruct: (BigStruct) b
{
    return b;
}
@end

@interface Foo(bar)
- (int) boo: (int) a;
- (BigStruct) structThatIsBig: (BigStruct) b;
- (BigStruct) methodThatReturnsBigStruct: (BigStruct) b;
- (float) methodThatReturnsFloat: (float) aFloat;
@end

typedef uint32_t (*FuncPtr)(id, SEL);
typedef BigStruct (*BigStructFuncPtr)(id, SEL, BigStruct);
typedef float (*FloatFuncPtr)(id, SEL, float);

BigStruct bigfunc(BigStruct a) {
    return a;
}

@interface Deallocator : NSObject @end
@implementation Deallocator
-(void) methodThatNobodyElseCalls1 { }
-(void) methodThatNobodyElseCalls2 { }
-(id) retain {
    _objc_flush_caches([Deallocator class]);
    [self methodThatNobodyElseCalls1];
    return [super retain];
}
-(void) dealloc {
    _objc_flush_caches([Deallocator class]);
    [self methodThatNobodyElseCalls2];
    [super dealloc];
}
@end

/* Code copied from objc-block-trampolines.m to test Block innards */
typedef enum {
    ReturnValueInRegisterArgumentMode,
    ReturnValueOnStackArgumentMode,
    
    ArgumentModeMax
} ArgumentMode;

static ArgumentMode _argumentModeForBlock(void *block) {
    ArgumentMode aMode = ReturnValueInRegisterArgumentMode;
    if ( _Block_use_stret(block) )
        aMode = ReturnValueOnStackArgumentMode;
    
    return aMode;
}
/* End copied code */

int main () {
#if __llvm__  &&  !__clang__
    // edit STRET_OK above when you remove this
    testwarn("<rdar://8143947> struct-return blocks not yet integrated in llvm-gcc");
#endif

    // make sure the bits are in place
    int (^registerReturn)() = ^(){ return 42; };
    ArgumentMode aMode;
    
    aMode = _argumentModeForBlock(registerReturn);
    testassert(aMode == ReturnValueInRegisterArgumentMode);

#if STRET_OK
    BigStruct (^stackReturn)() = ^() { BigStruct k; return k; };
    aMode = _argumentModeForBlock(stackReturn);
    testassert(aMode == ReturnValueOnStackArgumentMode);
#endif
        
#define TEST_QUANTITY 100000
    static FuncPtr funcArray[TEST_QUANTITY];

    uint32_t i;
    for(i = 0; i<TEST_QUANTITY; i++) {
        uint32_t (^block)(id self) = ^uint32_t(id self) {
            testassert((vm_address_t) self == (vm_address_t) i);
            return i;
        };
        block = Block_copy(block);
        
        funcArray[i] =  (FuncPtr) imp_implementationWithBlock(block);
        
        testassert(block((id)(uintptr_t) i) == i);
        
        void *blockFromIMPResult = imp_getBlock((IMP)funcArray[i]);
        testassert(blockFromIMPResult == block);
        
        Block_release(block);
    }
    
    for(i = 0; i<TEST_QUANTITY; i++) {
        uint32_t result = funcArray[i]((id)(uintptr_t) i, 0);
        testassert(i == result);
    }
    
    for(i = 0; i < TEST_QUANTITY; i= i + 3) {
	imp_removeBlock((IMP)funcArray[i]);
	void *shouldBeNull = imp_getBlock((IMP)funcArray[i]);
	assert(shouldBeNull == NULL);
    }
    
    for(i = 0; i < TEST_QUANTITY; i= i + 3) {
        uint32_t j = i * i;
        
        uint32_t (^block)(id self) = ^uint32_t(id self) {
            uint32_t value = (uint32_t)(uintptr_t) self;
            testassert(j == value);
            return j;
        };
        funcArray[i] =  (FuncPtr) imp_implementationWithBlock(block);
        
        testassert(block((id)(uintptr_t)j) == j);
        testassert(funcArray[i]((id)(uintptr_t)j, 0) == j);
    }
    
    for(i = 0; i < TEST_QUANTITY; i= i + 3) {
        uint32_t j = i * i;
        uint32_t result = funcArray[i]((id)(uintptr_t) j, 0);
        testassert(j == result);
    }
    
    int (^implBlock)(id, int);
    
    implBlock = ^(id self __attribute__((unused)), int a){
        return -1 * a;
    };
    
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    
    IMP methodImp = imp_implementationWithBlock(implBlock);
    
    BOOL success = class_addMethod([Foo class], @selector(boo:), methodImp, "i@:i");
    if (!success) {
        fprintf(stdout, "class_addMethod failed\n");
        abort();
    }
    Foo *f = [Foo new];
    int (*impF)(id self, SEL _cmd, int x) = (int(*)(id, SEL, int)) [Foo instanceMethodForSelector: @selector(boo:)];
    
    int x = impF(f, @selector(boo:), -42);
    
    testassert(x == 42);
    testassert([f boo: -42] == 42);

#if STRET_OK
    BigStruct a;
    for(i=0; i<200; i++)
        a.datums[i] = i;    
    
    // slightly more straightforward here
    __block unsigned int state = 0;
    BigStruct (^structBlock)(id, BigStruct) = ^BigStruct(id self __attribute__((unused)), BigStruct c) {
        state++;
        return c;
    };
    BigStruct blockDirect = structBlock(nil, a);
    testassert(!memcmp(&a, &blockDirect, sizeof(BigStruct)));
    testassert(state==1);
    
    IMP bigStructIMP = imp_implementationWithBlock(structBlock);
    
    class_addMethod([Foo class], @selector(structThatIsBig:), bigStructIMP, "oh, type strings, how I hate thee. Fortunately, the runtime doesn't generally care.");
    
    BigStruct b;
    
    BigStructFuncPtr bFunc;
    
    b = bigfunc(a);
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    b = bigfunc(a);
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    
    bFunc = (BigStructFuncPtr) [Foo instanceMethodForSelector: @selector(methodThatReturnsBigStruct:)];
    
    b = bFunc(f, @selector(methodThatReturnsBigStruct:), a);
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    
    b = [f methodThatReturnsBigStruct: a];
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    
    bFunc = (BigStructFuncPtr) [Foo instanceMethodForSelector: @selector(structThatIsBig:)];
    
    b = bFunc(f, @selector(structThatIsBig:), a);
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    testassert(state==2);
    
    b = [f structThatIsBig: a];
    testassert(!memcmp(&a, &b, sizeof(BigStruct)));
    testassert(state==3);
// STRET_OK
#endif
    

    IMP floatIMP = imp_implementationWithBlock(^float (id self __attribute__((unused)), float aFloat ) {
        return aFloat;
    });
    class_addMethod([Foo class], @selector(methodThatReturnsFloat:), floatIMP, "ooh.. type string unspecified again... oh noe... runtime might punish. not.");
    
    float e = (float)0.001;
    float retF = (float)[f methodThatReturnsFloat: 37.1212f];
    testassert( ((retF - e) < 37.1212) && ((retF + e) > 37.1212) );


    // Make sure imp_implementationWithBlock() and imp_removeBlock() 
    // don't deadlock while calling Block_copy() and Block_release()
    Deallocator *dead = [[Deallocator alloc] init];
    IMP deadlockImp = imp_implementationWithBlock(^{ [dead self]; });
    [dead release];
    imp_removeBlock(deadlockImp);

    [p drain];
    succeed(__FILE__);
}

