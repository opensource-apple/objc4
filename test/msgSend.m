// TEST_CONFIG

#include "test.h"

#ifdef __cplusplus

int main()
{
    testwarn("c++ rdar://8366474 @selector(foo::)");
    succeed(__FILE__);
}

#else

#include <objc/objc.h>
#include <objc/objc-runtime.h>
#include <objc/objc-abi.h>

#if defined(__arm__) 
// rdar://8331406
#   define ALIGN_() 
#else
#   define ALIGN_() asm(".align 4");
#endif

@interface Super { id isa; } 
+class;
@end

@interface Sub : Super @end

static int state = 0;


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

#define CHECK_ARGS_NOARG(cls, sel) \
do { \
    testassert(self == [cls class]); \
    testassert(_cmd == sel_registerName(#sel "_noarg"));\
} while (0)

struct stret {
    int a;
    int b;
    int c;
    int d;
    int e;
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
struct stret STRET_RESULT = {1, 2, 3, 4, 5};
double FP_RESULT = __DBL_MIN__ + __DBL_EPSILON__;
long double LFP_RESULT = __LDBL_MIN__ + __LDBL_EPSILON__;


@implementation Super
+class { return self; }
+(struct stret)stret { return STRET_RESULT; }
+(void)initialize { } 

+(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    if (state == 100) CHECK_ARGS(Sub, idret);
    else CHECK_ARGS(Super, idret);
    state = 1;
    return ID_RESULT;
}

+(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    if (state == 100) CHECK_ARGS(Sub, llret);
    else CHECK_ARGS(Super, llret);
    state = 2;
    return LL_RESULT;
}

+(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    if (state == 100) CHECK_ARGS(Sub, stret);
    else CHECK_ARGS(Super, stret);
    state = 3;
    return STRET_RESULT;
}

+(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    if (state == 100) CHECK_ARGS(Sub, fpret);
    else CHECK_ARGS(Super, fpret);
    state = 4;
    return FP_RESULT;
}

+(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    if (state == 100) CHECK_ARGS(Sub, lfpret);
    else CHECK_ARGS(Super, lfpret);
    state = 5;
    return LFP_RESULT;
}


+(id)idret_noarg
{
    if (state == 100) CHECK_ARGS_NOARG(Sub, idret);
    else CHECK_ARGS_NOARG(Super, idret);
    state = 11;
    return ID_RESULT;
}

+(long long)llret_noarg
{
    if (state == 100) CHECK_ARGS_NOARG(Sub, llret);
    else CHECK_ARGS_NOARG(Super, llret);
    state = 12;
    return LL_RESULT;
}

/* no objc_msgSend_stret_noarg
+(struct stret)stret_noarg
{
    if (state == 100) CHECK_ARGS_NOARG(Sub, stret);
    else CHECK_ARGS_NOARG(Super, stret);
    state = 13;
    return STRET_RESULT;
}
*/

+(double)fpret_noarg
{
    if (state == 100) CHECK_ARGS_NOARG(Sub, fpret);
    else CHECK_ARGS_NOARG(Super, fpret);
    state = 14;
    return FP_RESULT;
}

+(long double)lfpret_noarg
{
    if (state == 100) CHECK_ARGS_NOARG(Sub, lfpret);
    else CHECK_ARGS_NOARG(Super, lfpret);
    state = 15;
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

-(id)idret_noarg
{
    fail("-idret_ called instead of +idret_noarg");
    CHECK_ARGS_NOARG(Super, idret);
}

-(long long)llret_noarg
{
    fail("-llret_noarg called instead of +llret_noarg");
    CHECK_ARGS_NOARG(Super, llret);
}

-(struct stret)stret_noarg
{
    fail("-stret_noarg called instead of +stret_noarg");
    CHECK_ARGS_NOARG(Super, stret);
}

-(double)fpret_noarg
{
    fail("-fpret_noarg called instead of +fpret_noarg");
    CHECK_ARGS_NOARG(Super, fpret);
}

-(long double)lfpret_noarg
{
    fail("-lfpret_noarg called instead of +lfpret_noarg");
    CHECK_ARGS_NOARG(Super, lfpret);
}

@end


@implementation Sub

+(id)idret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    id result;
    CHECK_ARGS(Sub, idret);
    state = 100;
    result = [super idret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 1);
    testassert(result == ID_RESULT);
    state = 101;
    return result;
}

+(long long)llret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long long result;
    CHECK_ARGS(Sub, llret);
    state = 100;
    result = [super llret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 2);
    testassert(result == LL_RESULT);
    state = 102;
    return result;
}

+(struct stret)stret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    struct stret result;
    CHECK_ARGS(Sub, stret);
    state = 100;
    result = [super stret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 3);
    testassert(stret_equal(result, STRET_RESULT));
    state = 103;
    return result;
}

+(double)fpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    double result;
    CHECK_ARGS(Sub, fpret);
    state = 100;
    result = [super fpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 4);
    testassert(result == FP_RESULT);
    state = 104;
    return result;
}

+(long double)lfpret: 
   (int)i1:(int)i2:(int)i3:(int)i4:(int)i5:(int)i6:(int)i7:(int)i8:(int)i9:(int)i10:(int)i11:(int)i12:(int)i13 :(double)f1:(double)f2:(double)f3:(double)f4:(double)f5:(double)f6:(double)f7:(double)f8:(double)f9:(double)f10:(double)f11:(double)f12:(double)f13:(double)f14:(double)f15
{
    long double result;
    CHECK_ARGS(Sub, lfpret);
    state = 100;
    result = [super lfpret:i1:i2:i3:i4:i5:i6:i7:i8:i9:i10:i11:i12:i13:f1:f2:f3:f4:f5:f6:f7:f8:f9:f10:f11:f12:f13:f14:f15];
    testassert(state == 5);
    testassert(result == LFP_RESULT);
    state = 105;
    return result;
}


+(id)idret_noarg
{
    id result;
    CHECK_ARGS_NOARG(Sub, idret);
    state = 100;
    result = [super idret_noarg];
    testassert(state == 11);
    testassert(result == ID_RESULT);
    state = 111;
    return result;
}

+(long long)llret_noarg
{
    long long result;
    CHECK_ARGS_NOARG(Sub, llret);
    state = 100;
    result = [super llret_noarg];
    testassert(state == 12);
    testassert(result == LL_RESULT);
    state = 112;
    return result;
}
/*
+(struct stret)stret_noarg
{
    struct stret result;
    CHECK_ARGS_NOARG(Sub, stret);
    state = 100;
    result = [super stret_noarg];
    testassert(state == 13);
    testassert(stret_equal(result, STRET_RESULT));
    state = 113;
    return result;
}
*/
+(double)fpret_noarg
{
    double result;
    CHECK_ARGS_NOARG(Sub, fpret);
    state = 100;
    result = [super fpret_noarg];
    testassert(state == 14);
    testassert(result == FP_RESULT);
    state = 114;
    return result;
}

+(long double)lfpret_noarg
{
    long double result;
    CHECK_ARGS_NOARG(Sub, lfpret);
    state = 100;
    result = [super lfpret_noarg];
    testassert(state == 15);
    testassert(result == LFP_RESULT);
    state = 115;
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

    id (*idmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    long long (*llmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    struct stret (*stretmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    double (*fpmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));
    long double (*lfpmsg)(id, SEL, int, int, int, int, int, int, int, int, int, int, int, int, int, double, double, double, double, double, double, double, double, double, double, double, double, double, double, double) __attribute__((unused));

    id (*idmsg0)(id, SEL) __attribute__((unused));
    long long (*llmsg0)(id, SEL) __attribute__((unused));
    // struct stret (*stretmsg0)(id, SEL) __attribute__((unused));
    double (*fpmsg0)(id, SEL) __attribute__((unused));
    long double (*lfpmsg0)(id, SEL) __attribute__((unused));

    struct stret zero = {0, 0, 0, 0, 0};

    // get +initialize out of the way
    [Sub class];

    // message uncached 
    // message uncached long long
    // message uncached stret
    // message uncached fpret
    // message uncached fpret long double
    // message uncached noarg (as above)
    // message cached 
    // message cached long long
    // message cached stret
    // message cached fpret
    // message cached fpret long double
    // message cached noarg (as above)
    // fixme verify that uncached lookup didn't happen the 2nd time?
    // Do this first before anything below caches stuff.
    for (i = 0; i < 5; i++) {
        state = 0;
        idval = nil;
        idval = [Sub idret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 101);
        testassert(idval == ID_RESULT);
        
        llval = 0;
        llval = [Sub llret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 102);
        testassert(llval == LL_RESULT);
        
        stretval = zero;
        stretval = [Sub stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 103);
        testassert(stret_equal(stretval, STRET_RESULT));
        
        fpval = 0;
        fpval = [Sub fpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 104);
        testassert(fpval == FP_RESULT);
        
        lfpval = 0;
        lfpval = [Sub lfpret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 105);
        testassert(lfpval == LFP_RESULT);

#if __OBJC2__
        // explicitly call noarg messenger, even if compiler doesn't emit it
        state = 0;
        idval = nil;
        idval = ((typeof(idmsg0))objc_msgSend_noarg)([Sub class], @selector(idret_noarg));
        testassert(state == 111);
        testassert(idval == ID_RESULT);
        
        llval = 0;
        llval = ((typeof(llmsg0))objc_msgSend_noarg)([Sub class], @selector(llret_noarg));
        testassert(state == 112);
        testassert(llval == LL_RESULT);
        /*
        stretval = zero;
        stretval = ((typeof(stretmsg0))objc_msgSend_stret_noarg)([Sub class], @selector(stret_noarg));
        stretval = [Sub stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
        testassert(state == 113);
        testassert(stret_equal(stretval, STRET_RESULT));
        */
# if !__i386__
        fpval = 0;
        fpval = ((typeof(fpmsg0))objc_msgSend_noarg)([Sub class], @selector(fpret_noarg));
        testassert(state == 114);
        testassert(fpval == FP_RESULT);
# endif
# if !__i386__ && !__x86_64__
        lfpval = 0;
        lfpval = ((typeof(lfpmsg0))objc_msgSend_noarg)([Sub class], @selector(lfpret_noarg));
        testassert(state == 115);
        testassert(lfpval == LFP_RESULT);
# endif
#endif
    }

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

    // cached message performance
    // catches failure to cache or (abi=2) failure to fixup (#5584187)
    // fixme unless they all fail
    // `.align 4` matches loop alignment to make -O0 work
    // fill cache first
    [Sub idret_perf];
    [Sub llret_perf];
    [Sub stret_perf];
    [Sub fpret_perf];
    [Sub lfpret_perf];
    [Sub idret_perf];
    [Sub llret_perf];
    [Sub stret_perf];
    [Sub fpret_perf];
    [Sub lfpret_perf];
    [Sub idret_perf];
    [Sub llret_perf];
    [Sub stret_perf];
    [Sub fpret_perf];
    [Sub lfpret_perf];

    // Some of these times have high variance on some compilers. 
    // The errors we're trying to catch should be catastrophically slow, 
    // so the margins here are generous to avoid false failures.

#define COUNT 1000000
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [Sub idret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    testprintf("time: idret  %llu\n", totalTime);
    targetTime = totalTime;

    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [Sub llret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("llret ", totalTime, targetTime * 0.8, targetTime * 2.0);

    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [Sub stret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("stret ", totalTime, targetTime * 0.8, targetTime * 5.0);
        
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {        
        [Sub fpret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("fpret ", totalTime, targetTime * 0.8, targetTime * 4.0);
        
    startTime = mach_absolute_time();
    ALIGN_();
    for (i = 0; i < COUNT; i++) {
        [Sub lfpret_perf];
    }
    totalTime = mach_absolute_time() - startTime;
    timecheck("lfpret", totalTime, targetTime * 0.8, targetTime * 4.0);
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

#if __OBCJ2__
    // message to nil noarg
    // explicitly call noarg messenger, even if compiler doesn't emit it
    state = 0;
    idval = ID_RESULT;
    idval = ((typeof(idmsg0))objc_msgSend_noarg)(nil, @selector(idret_noarg));
    testassert(state == 0);
    testassert(idval == nil);
    
    state = 0;
    llval = LL_RESULT;
    llval = ((typeof(llmsg0))objc_msgSend_noarg)(nil, @selector(llret_noarg));
    testassert(state == 0);
    testassert(llval == 0LL);
    /*
    state = 0;
    stretval = zero;
    stretval = [(id)nil stret :1:2:3:4:5:6:7:8:9:10:11:12:13:1.0:2.0:3.0:4.0:5.0:6.0:7.0:8.0:9.0:10.0:11.0:12.0:13.0:14.0:15.0];
    testassert(state == 0);
    // no stret result guarantee
    */
# if !__i386__
    state = 0;
    fpval = FP_RESULT;
    fpval = ((typeof(fpmsg0))objc_msgSend_noarg)(nil, @selector(fpret_noarg));
    testassert(state == 0);
    testassert(fpval == 0.0);
# endif
# if !__i386__ && !__x86_64__
    state = 0;
    lfpval = LFP_RESULT;
    lfpval = ((typeof(lfpmsg0))objc_msgSend_noarg)(nil, @selector(lfpret_noarg));
    testassert(state == 0);
    testassert(lfpval == 0.0);
# endif
#endif
    
    // message forwarded
    // message forwarded long long
    // message forwarded stret
    // message forwarded fpret
    // message forwarded fpret long double
    // fixme

#if __OBJC2__
    // rdar://8271364 objc_msgSendSuper2 must not change objc_super
    struct objc_super sup = {
        [Sub class], 
        object_getClass([Sub class]), 
    };

    state = 100;
    idval = nil;
    idval = ((id(*)(struct objc_super *, SEL, int,int,int,int,int,int,int,int,int,int,int,int,int, double,double,double,double,double,double,double,double,double,double,double,double,double,double,double))objc_msgSendSuper2) (&sup, @selector(idret::::::::::::::::::::::::::::), 1,2,3,4,5,6,7,8,9,10,11,12,13, 1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0,11.0,12.0,13.0,14.0,15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    testassert(sup.receiver == [Sub class]);
    testassert(sup.super_class == object_getClass([Sub class]));

    state = 100;
    stretval = zero;
    stretval = ((struct stret(*)(struct objc_super *, SEL, int,int,int,int,int,int,int,int,int,int,int,int,int, double,double,double,double,double,double,double,double,double,double,double,double,double,double,double))objc_msgSendSuper2_stret) (&sup, @selector(stret::::::::::::::::::::::::::::), 1,2,3,4,5,6,7,8,9,10,11,12,13, 1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0,11.0,12.0,13.0,14.0,15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));
    testassert(sup.receiver == [Sub class]);
    testassert(sup.super_class == object_getClass([Sub class]));
#endif

#if __OBJC2__
    // Debug messengers.
    state = 0;
    idmsg = (typeof(idmsg))objc_msgSend_debug;
    idval = nil;
    idval = (*idmsg)([Sub class], @selector(idret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 101);
    testassert(idval == ID_RESULT);
    
    state = 0;
    llmsg = (typeof(llmsg))objc_msgSend_debug;
    llval = 0;
    llval = (*llmsg)([Sub class], @selector(llret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 102);
    testassert(llval == LL_RESULT);
    
    state = 0;
    stretmsg = (typeof(stretmsg))objc_msgSend_stret_debug;
    stretval = zero;
    stretval = (*stretmsg)([Sub class], @selector(stret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 103);
    testassert(stret_equal(stretval, STRET_RESULT));
    
    state = 100;
    sup.receiver = [Sub class];
    sup.super_class = object_getClass([Sub class]);
    idmsg = (typeof(idmsg))objc_msgSendSuper2_debug;
    idval = nil;
    idval = (*idmsg)((id)&sup, @selector(idret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 1);
    testassert(idval == ID_RESULT);
    
    state = 100;
    sup.receiver = [Sub class];
    sup.super_class = object_getClass([Sub class]);
    stretmsg = (typeof(stretmsg))objc_msgSendSuper2_stret_debug;
    stretval = zero;
    stretval = (*stretmsg)((id)&sup, @selector(stret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 3);
    testassert(stret_equal(stretval, STRET_RESULT));

#if __i386__
    state = 0;
    fpmsg = (typeof(fpmsg))objc_msgSend_fpret_debug;
    fpval = 0;
    fpval = (*fpmsg)([Sub class], @selector(fpret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 104);
    testassert(fpval == FP_RESULT);
#endif
#if __x86_64__
    state = 0;
    lfpmsg = (typeof(lfpmsg))objc_msgSend_fpret_debug;
    lfpval = 0;
    lfpval = (*lfpmsg)([Sub class], @selector(lfpret::::::::::::::::::::::::::::), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    testassert(state == 105);
    testassert(lfpval == LFP_RESULT);

    // fixme fp2ret
#endif

// debug messengers
#endif

    succeed(__FILE__);
}

#endif
