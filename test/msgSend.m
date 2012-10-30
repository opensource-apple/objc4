#include "test.h"
#include <objc/objc.h>
#include <objc/objc-runtime.h>

@interface Super { id isa; } 
+class;
@end

@interface Sub : Super @end

static int state = 0;

#if defined(__ppc__)  ||  defined(__ppc64__)
// On ppc and ppc64, methods must be called with r12==IMP (i.e. indirect function call convention)
#define CHECK_R12(cls) \
do { \
    IMP val; \
    __asm__ volatile ("mr %[val], r12\n" : [val] "=r" (val)); \
    testassert(val == method_getImplementation(class_getClassMethod([cls class], _cmd))); \
} while (0);
#else
#define CHECK_R12(cls) do {/* empty */} while (0)
#endif


#define CHECK_ARGS(cls, sel) \
do { \
    testassert(self == [cls class]); \
    testassert(_cmd == sel_registerName(#sel "::::::::::::::::::::::::::::"));\
    testassert(i1 == 1); \
    testassert(i2 == 2); \
    testassert(i3 == 3); \
    testassert(i4 == 4); \
    testassert(i5 == 5); \
    testassert(i6 == 6); \
    testassert(i7 == 7); \
    testassert(i8 == 8); \
    testassert(i9 == 9); \
    testassert(i10 == 10); \
    testassert(i11 == 11); \
    testassert(i12 == 12); \
    testassert(i13 == 13); \
    testassert(f1 == 1.0); \
    testassert(f2 == 2.0); \
    testassert(f3 == 3.0); \
    testassert(f4 == 4.0); \
    testassert(f5 == 5.0); \
    testassert(f6 == 6.0); \
    testassert(f7 == 7.0); \
    testassert(f8 == 8.0); \
    testassert(f9 == 9.0); \
    testassert(f10 == 10.0); \
    testassert(f11 == 11.0); \
    testassert(f12 == 12.0); \
    testassert(f13 == 13.0); \
    testassert(f14 == 14.0); \
    testassert(f15 == 15.0); \
} while (0) 

struct stret {
    int a;
    int b;
    int c;
    int d;
    int e;
    int pad[32];  // force stack return on ppc64
};

BOOL stret_equal(struct stret a, struct stret b)
{
    return (a.a == b.a  &&  
            a.b == b.b  &&  
            a.c == b.c  &&  
            a.d == b.d  &&  
            a.e == b.e);
}

id ID_RESULT = (id)0x12345678;
long long LL_RESULT = __LONG_LONG_MAX__ - 2LL*__INT_MAX__;
struct stret STRET_RESULT = {1, 2, 3, 4, 5, {0}};
double FP_RESULT = __DBL_MIN__ + __DBL_EPSILON__;
long double LFP_RESULT = __LDBL_MIN__ + __LDBL_EPSILON__;


@implementation Super
+class { return self; }
+(void)initialize { } 

+(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_R12(Super);
    if (state == 10) CHECK_ARGS(Sub, idret);
    else CHECK_ARGS(Super, idret);
    state = 1;
    return ID_RESULT;
}

+(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_R12(Super);
    if (state == 10) CHECK_ARGS(Sub, llret);
    else CHECK_ARGS(Super, llret);
    state = 2;
    return LL_RESULT;
}

+(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_R12(Super);
    if (state == 10) CHECK_ARGS(Sub, stret);
    else CHECK_ARGS(Super, stret);
    state = 3;
    return STRET_RESULT;
}

+(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_R12(Super);
    if (state == 10) CHECK_ARGS(Sub, fpret);
    else CHECK_ARGS(Super, fpret);
    state = 4;
    return FP_RESULT;
}

+(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    CHECK_R12(Super);
    if (state == 10) CHECK_ARGS(Sub, lfpret);
    else CHECK_ARGS(Super, lfpret);
    state = 5;
    return LFP_RESULT;
}


-(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("-idret called instead of +idret");
    CHECK_ARGS(Super, idret);
}

-(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("-llret called instead of +llret");
    CHECK_ARGS(Super, llret);
}

-(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("-stret called instead of +stret");
    CHECK_ARGS(Super, stret);
}

-(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("-fpret called instead of +fpret");
    CHECK_ARGS(Super, fpret);
}

-(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    fail("-lfpret called instead of +lfpret");
    CHECK_ARGS(Super, lfpret);
}

@end


@implementation Sub

+(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    id result;
    CHECK_R12(Sub);
    CHECK_ARGS(Sub, idret);
    state = 10;
    result = [super idret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 1);
    testassert(result == ID_RESULT);
    state = 11;
    return result;
}

+(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long long result;
    CHECK_R12(Sub);
    CHECK_ARGS(Sub, llret);
    state = 10;
    result = [super llret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 2);
    testassert(result == LL_RESULT);
    state = 12;
    return result;
}

+(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    struct stret result;
    CHECK_R12(Sub);
    CHECK_ARGS(Sub, stret);
    state = 10;
    result = [super stret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 3);
    testassert(stret_equal(result, STRET_RESULT));
    state = 13;
    return result;
}

+(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    double result;
    CHECK_R12(Sub);
    CHECK_ARGS(Sub, fpret);
    state = 10;
    result = [super fpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 4);
    testassert(result == FP_RESULT);
    state = 14;
    return result;
}

+(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long double result;
    CHECK_R12(Sub);
    CHECK_ARGS(Sub, lfpret);
    state = 10;
    result = [super lfpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 5);
    testassert(result == LFP_RESULT);
    state = 15;
    return result;
}



// performance-test code (do nothing for better comparability)

+(id)idret_perf
{
    return ID_RESULT;
}

+(long long)llret_perf
{
    return LL_RESULT;
}

+(struct stret)stret_perf
{
    return STRET_RESULT;
}

+(double)fpret_perf
{
    return FP_RESULT;
}

+(long double)lfpret_perf
{
    return LFP_RESULT;
}
@end


int main()
{
    int i;

    id idval;
    long long llval;
    struct stret stretval;
    double fpval;
    long double lfpval;

    uint64_t startTime;
    uint64_t totalTime;
    uint64_t targetTime;

    Method idmethod;
    Method llmethod;
    Method stretmethod;
    Method fpmethod;
    Method lfpmethod;

    id (*idfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    long long (*llfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    struct stret (*stretfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    double (*fpfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);
    long double (*lfpfn)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double);

    struct stret zero = {0, 0, 0, 0, 0, {0}};

    // get +initialize out of the way
    [Sub class];

    idmethod = class_getClassMethod([Super class], @selector(idret::::::::::::::::::::::::::::));
    testassert(idmethod);
    llmethod = class_getClassMethod([Super class], @selector(llret::::::::::::::::::::::::::::));
    testassert(llmethod);
    stretmethod = class_getClassMethod([Super class], @selector(stret::::::::::::::::::::::::::::));
    testassert(stretmethod);
    fpmethod = class_getClassMethod([Super class], @selector(fpret::::::::::::::::::::::::::::));
    testassert(fpmethod);
    lfpmethod = class_getClassMethod([Super class], @selector(lfpret::::::::::::::::::::::::::::));
    testassert(lfpmethod);

    idfn = (id (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    llfn = (long long (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    stretfn = (struct stret (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke_stret;
    fpfn = (double (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;
    lfpfn = (long double (*)(id, Method, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double)) method_invoke;

    // message uncached 
    // message uncached long long
    // message uncached stret
    // message uncached fpret
    // message uncached fpret long double
    // message cached 
    // message cached long long
    // message cached stret
    // message cached fpret
    // message cached fpret long double
    // fixme verify that uncached lookup didn't happen the 2nd time?
    for (i = 0; i < 5; i++) {
        state = 0;
        idval = nil;
        idval = [Sub idret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 11);
        testassert(idval == ID_RESULT);
        
        llval = 0;
        llval = [Sub llret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 12);
        testassert(llval == LL_RESULT);
        
        stretval = zero;
        stretval = [Sub stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 13);
        testassert(stret_equal(stretval, STRET_RESULT));
        
        fpval = 0;
        fpval = [Sub fpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 14);
        testassert(fpval == FP_RESULT);
        
        lfpval = 0;
        lfpval = [Sub lfpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 15);
        testassert(lfpval == LFP_RESULT);
    }

    // cached message performance
    // catches failure to cache or (abi=2) failure to fixup (#5584187)
    // fixme unless they all fail
    // `.align 4` matches loop alignment to make -O0 work
#define COUNT 1000000
    [Sub idret_perf];
    startTime = mach_absolute_time();
    asm(".align 4");
    for (i = 0; i < COUNT; i++) {
        [Sub idret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("idret %llu\n", totalTime);
    targetTime = totalTime;

    [Sub llret_perf];
    startTime = mach_absolute_time();
    asm(".align 4");
    for (i = 0; i < COUNT; i++) {
        [Sub llret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("llret %llu\n", totalTime);
    timeassert(totalTime > targetTime * 0.8  &&  totalTime < targetTime * 2.0);
        
    [Sub stret_perf];
    startTime = mach_absolute_time();
    asm(".align 4");
    for (i = 0; i < COUNT; i++) {
        [Sub stret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("stret %llu\n", totalTime);
    timeassert(totalTime > targetTime * 0.8  &&  totalTime < targetTime * 5.0);
        
    [Sub fpret_perf];
    startTime = mach_absolute_time();
    asm(".align 4");
    for (i = 0; i < COUNT; i++) {        
        [Sub fpret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("fpret %llu\n", totalTime);
    timeassert(totalTime > targetTime * 0.8  &&  totalTime < targetTime * 2.0);
        
    [Sub lfpret_perf];
    startTime = mach_absolute_time();
    asm(".align 4");
    for (i = 0; i < COUNT; i++) {
        [Sub lfpret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("lfpret %llu\n", totalTime);
    timeassert(totalTime > targetTime * 0.8  &&  totalTime < targetTime * 2.0);
#undef COUNT

    // method_invoke 
    // method_invoke long long
    // method_invoke_stret stret
    // method_invoke_stret fpret
    // method_invoke fpret long double

    state = 0;
    idval = nil;
    idval = (*idfn)([Super class], idmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    
    llval = 0;
    llval = (*llfn)([Super class], llmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 2);
    testassert(llval == LL_RESULT);
        
    stretval = zero;
    stretval = (*stretfn)([Super class], stretmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));
        
    fpval = 0;
    fpval = (*fpfn)([Super class], fpmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 4);
    testassert(fpval == FP_RESULT);
        
    lfpval = 0;
    lfpval = (*lfpfn)([Super class], lfpmethod, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 5);
    testassert(lfpval == LFP_RESULT);


    // message to nil
    // message to nil long long
    // message to nil stret
    // message to nil fpret
    // message to nil fpret long double
    state = 0;
    idval = ID_RESULT;
    idval = [(id)nil idret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(idval == nil);
    
    state = 0;
    llval = LL_RESULT;
    llval = [(id)nil llret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(llval == 0LL);
    
    state = 0;
    stretval = zero;
    stretval = [(id)nil stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    // no stret result guarantee
    
    state = 0;
    fpval = FP_RESULT;
    fpval = [(id)nil fpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(fpval == 0.0);
    
    state = 0;
    lfpval = LFP_RESULT;
    lfpval = [(id)nil lfpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    testassert(lfpval == 0.0);
    
    
    // message forwarded
    // message forwarded long long
    // message forwarded stret
    // message forwarded fpret
    // message forwarded fpret long double
    // fixme

    succeed(__FILE__);
}
