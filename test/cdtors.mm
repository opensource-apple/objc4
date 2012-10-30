// TEST_CONFIG

#include <pthread.h>
#include "test.h"
#include "objc/objc-internal.h"

static unsigned ctors1 = 0;
static unsigned dtors1 = 0;
static unsigned ctors2 = 0;
static unsigned dtors2 = 0;

class cxx1 {
    unsigned & ctors;
    unsigned& dtors;

  public:
    cxx1() : ctors(ctors1), dtors(dtors1) { ctors++; }

    ~cxx1() { dtors++; }
};
class cxx2 {
    unsigned& ctors;
    unsigned& dtors;

  public:
    cxx2() : ctors(ctors2), dtors(dtors2) { ctors++; }

    ~cxx2() { dtors++; }
};

/*
  Class hierarchy:
  Base
   CXXBase
    NoCXXSub
     CXXSub

  This has two cxx-wielding classes, and a class in between without cxx.
*/


@interface Base { id isa; } 
+class;
+new;
-(void)dealloc;
@end
@implementation Base
+(void)initialize { } 
+class { return self; }
-class { return self->isa; }
+new { return class_createInstance(self, 0); }
-(void)dealloc { object_dispose(self); } 
-(void)finalize { }
@end

@interface CXXBase : Base {
    cxx1 baseIvar;
}
@end
@implementation CXXBase @end

@interface NoCXXSub : CXXBase {
    int nocxxIvar;
}
@end
@implementation NoCXXSub @end

@interface CXXSub : NoCXXSub {
    cxx2 subIvar;
}
@end
@implementation CXXSub @end


void *test_single(void *arg __unused) 
{
    volatile id o;

    // Single allocation

    objc_registerThreadWithCollector();

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = [Base new];
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [Base class]);
    [o dealloc], o = nil;
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = [CXXBase new];
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [CXXBase class]);
    [o dealloc], o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = [NoCXXSub new];
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [NoCXXSub class]);
    [o dealloc], o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = [CXXSub new];
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 1  &&  dtors2 == 0);
    testassert([o class] == [CXXSub class]);
    [o dealloc], o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 1  &&  dtors2 == 1);

    return NULL;
}

void *test_inplace(void *arg __unused) 
{
    volatile id o;
    char o2[64];

    // In-place allocation

    objc_registerThreadWithCollector();

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance([Base class], o2);
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [Base class]);
    objc_destructInstance(o), o = nil;
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance([CXXBase class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [CXXBase class]);
    objc_destructInstance(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance([NoCXXSub class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    testassert([o class] == [NoCXXSub class]);
    objc_destructInstance(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 0  &&  dtors2 == 0);

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    o = objc_constructInstance([CXXSub class], o2);
    testassert(ctors1 == 1  &&  dtors1 == 0  &&  
               ctors2 == 1  &&  dtors2 == 0);
    testassert([o class] == [CXXSub class]);
    objc_destructInstance(o), o = nil;
    testcollect();
    testassert(ctors1 == 1  &&  dtors1 == 1  &&  
               ctors2 == 1  &&  dtors2 == 1);

    return NULL;
}


void *test_batch(void *arg __unused) 
{
    id o2[100];
    unsigned int count, i;

    // Batch allocation

    objc_registerThreadWithCollector();

    for (i = 0; i < 100; i++) {
        o2[i] = (id)malloc(class_getInstanceSize([Base class]));
    }
    for (i = 0; i < 100; i++) {
        free(o2[i]);
    }

    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([Base class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [Base class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == 0  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([Base class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([CXXBase class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [CXXBase class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([Base class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([NoCXXSub class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == 0  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [NoCXXSub class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == 0  &&  dtors2 == 0);

    for (i = 0; i < 100; i++) {
        // prime batch allocator
        free(malloc(class_getInstanceSize([Base class])));
    }
    
    ctors1 = dtors1 = ctors2 = dtors2 = 0;
    count = class_createInstances([CXXSub class], 0, o2, 10);
    testassert(count > 0);
    testassert(ctors1 == count  &&  dtors1 == 0  &&  
               ctors2 == count  &&  dtors2 == 0);
    for (i = 0; i < count; i++) testassert([o2[i] class] == [CXXSub class]);
    for (i = 0; i < count; i++) object_dispose(o2[i]), o2[i] = nil;
    testcollect();
    testassert(ctors1 == count  &&  dtors1 == count  &&  
               ctors2 == count  &&  dtors2 == count);

    return NULL;
}

int main()
{
    pthread_t th;

    testassert(0 == pthread_create(&th, NULL, test_single, NULL));
    pthread_join(th, NULL);

    testassert(0 == pthread_create(&th, NULL, test_inplace, NULL));
    pthread_join(th, NULL);

    leak_mark();

    testassert(0 == pthread_create(&th, NULL, test_batch, NULL));
    pthread_join(th, NULL);

    // fixme can't get this to zero; may or may not be a real leak
    leak_check(64);

    // fixme ctor exceptions aren't caught inside .cxx_construct ?
    // Single allocation, ctors fail
    // In-place allocation, ctors fail
    // Batch allocation, ctors fail for every object
    // Batch allocation, ctors fail for every other object

    succeed(__FILE__);
}
