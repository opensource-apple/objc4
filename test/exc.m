#include "test.h"
#include <objc/runtime.h>
#include <objc/objc-exception.h>

static volatile int state = 0;
#define BAD 1000000

#if defined(USE_FOUNDATION)

#include <Foundation/Foundation.h>

static NSAutoreleasePool *p;
void pool(void) { [p release]; p = [NSAutoreleasePool new]; }

@interface Super : NSException @end
@implementation Super
+new { return [[self exceptionWithName:@"Super" reason:@"reason" userInfo:nil] retain];  }
-(void)check { state++; }
+(void)check { testassert(!"caught class object, not instance"); }
@end

#else

void pool(void) {  }

@interface Super { id isa; } @end
@implementation Super
+new { return class_createInstance(self, 0); }
+(void)initialize { } 
-(void)check { state++; }
+(void)check { testassert(!"caught class object, not instance"); }
-(void)release { object_dispose(self); }
@end

#endif

@interface Sub : Super @end
@implementation Sub 
@end


#if __OBJC2__

void altHandlerFail(id unused __unused, void *context __unused)
{
    fail("altHandlerFail called");
}

#define ALT_HANDLER(n)                                          \
    void altHandler##n(id unused __unused, void *context)       \
    {                                                           \
        testassert(context == (void*)&altHandler##n);           \
        testassert(state == n);                                 \
        state++;                                                \
    }

ALT_HANDLER(2)
ALT_HANDLER(3)
ALT_HANDLER(4)
ALT_HANDLER(5)
ALT_HANDLER(6)
ALT_HANDLER(7)


static void throwWithAltHandler(void) __attribute__((noinline));
static void throwWithAltHandler(void)
{
    @try {
        state++;
        uintptr_t token = objc_addExceptionHandler(altHandler3, altHandler3);
        // state++ inside alt handler
        @throw [Super new];
        state = BAD;
        objc_removeExceptionHandler(token);
    } 
    @catch (Sub *e) {
        state = BAD;
    }
    state = BAD;
}


static void throwWithAltHandlerAndRethrow(void) __attribute__((noinline));
static void throwWithAltHandlerAndRethrow(void)
{
    @try {
        state++;
        uintptr_t token = objc_addExceptionHandler(altHandler3, altHandler3);
        // state++ inside alt handler
        @throw [Super new];
        state = BAD;
        objc_removeExceptionHandler(token);
    } 
    @catch (...) {
        testassert(state == 4);
        state++;
        @throw;
    }
    state = BAD;
}

#endif


int main()
{
    pool();

    testprintf("try-catch-finally, exception caught exactly\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Super *e) {
            state++;
            [e check];  // state++
            [e release];
        }
        @finally {
            state++;
        }
        state++;
    } 
    @catch (...) {
        state = BAD;
    }
    testassert(state == 6);


    testprintf("try-finally, no exception thrown\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
        } 
        @finally {
            state++;
        }
        state++;
    } 
    @catch (...) {
        state = BAD;
    }
    testassert(state == 4);


    testprintf("try-finally, with exception\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @finally {
            state++;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 5);


    testprintf("try-catch-finally, no exception\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
        } 
        @catch (...) {
            state = BAD;
        }
        @finally {
            state++;
        }
        state++;
    } @catch (...) {
        state = BAD;
    }
    testassert(state == 4);


    testprintf("try-catch-finally, exception not caught\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Sub *e) {
            state = BAD;
        }
        @finally {
            state++;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 5);


    testprintf("try-catch-finally, exception caught exactly, rethrown\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Super *e) {
            state++;
            [e check];  // state++
            @throw;
            state = BAD;
        }
        @finally {
            state++;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 7);


    testprintf("try-catch, no exception\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
        } 
        @catch (...) {
            state = BAD;
        }
        state++;
    } @catch (...) {
        state = BAD;
    }
    testassert(state == 3);


    testprintf("try-catch, exception not caught\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Sub *e) {
            state = BAD;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 4);


    testprintf("try-catch, exception caught exactly\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Super *e) {
            state++;
            [e check];  // state++
            [e release];
        }
        state++;
    } 
    @catch (...) {
        state = BAD;
    }
    testassert(state == 5);


    testprintf("try-catch, exception caught exactly, rethrown\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Super *e) {
            state++;
            [e check];  // state++
            @throw;
            state = BAD;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 6);


    testprintf("try-catch, exception caught exactly, thrown again explicitly\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (Super *e) {
            state++;
            [e check];  // state++
            @throw e;
            state = BAD;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 6);


    testprintf("try-catch, default catch, rethrown\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (...) {
            state++;
            @throw;
            state = BAD;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 5);


    testprintf("try-catch, default catch, rethrown and caught inside nested handler\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (...) {
            state++;
            
            @try {
                state++;
                @throw;
                state = BAD;
            } @catch (Sub *e) {
                state = BAD;
            } @catch (Super *e) {
                state++;
                [e check];  // state++
                [e release];
            } @catch (...) {
                state = BAD;
            } @finally {
                state++;
            }

            state++;
        }
        state++;
    } 
    @catch (...) {
        state = BAD;
    }
    testassert(state == 9);


    testprintf("try-catch, default catch, rethrown inside nested handler but not caught\n");

    state = 0;
    @try {
        state++;
        @try {
            state++;
            @throw [Super new];
            state = BAD;
        } 
        @catch (...) {
            state++;
            
            @try {
                state++;
                @throw;
                state = BAD;
            } @catch (Sub *e) {
                state = BAD;
            } @finally {
                state++;
            }

            state = BAD;
        }
        state = BAD;
    } 
    @catch (id e) {
        state++;
        [e check];  // state++
        [e release];
    }
    testassert(state == 7);

#if __OBJC2__
    // alt handlers
    // run a lot to catch failed unregistration (runtime complains at 1000)
#define ALT_HANDLER_REPEAT 2000
    int i;

    testprintf("alt handler, no exception\n");
    
    for (i = 0; i < ALT_HANDLER_REPEAT; i++) {
        pool();

        state = 0;
        @try {
            state++;
            @try {
                uintptr_t token = objc_addExceptionHandler(altHandlerFail, 0);
                state++;
                objc_removeExceptionHandler(token);
            } 
            @catch (...) {
                state = BAD;
            }
            state++;
        } @catch (...) {
            state = BAD;
        }
        testassert(state == 3);
    }        

    testprintf("alt handler, exception thrown through\n");

    for (i = 0; i < ALT_HANDLER_REPEAT; i++) {
        pool();

        state = 0;
        @try {
            state++;
            @try {
                state++;
                uintptr_t token = objc_addExceptionHandler(altHandler2, altHandler2);
                // state++ inside alt handler
                @throw [Super new];
                state = BAD;
                objc_removeExceptionHandler(token);
            } 
            @catch (Sub *e) {
                state = BAD;
            }
            state = BAD;
        } 
        @catch (id e) {
            testassert(state == 3);
            state++;
            [e check];  // state++
            [e release];
        }
        testassert(state == 5);
    }


    testprintf("alt handler, nested\n");

    for (i = 0; i < ALT_HANDLER_REPEAT; i++) {
        pool();

        state = 0;
        @try {
            state++;
            @try {
                state++;
                // same-level handlers called in FIFO order (not stack-like)
                uintptr_t token = objc_addExceptionHandler(altHandler4, altHandler4);
                // state++ inside alt handler
                uintptr_t token2 = objc_addExceptionHandler(altHandler5, altHandler5);
                // state++ inside alt handler
                throwWithAltHandler();  // state += 2 inside
                state = BAD;
                objc_removeExceptionHandler(token);
                objc_removeExceptionHandler(token2);
            }
            @catch (id e) {
                testassert(state == 6);
                state++;
                [e check];  // state++;
                [e release];
            }
            state++;
        } 
        @catch (...) {
            state = BAD;
        }
        testassert(state == 9);
    }


    testprintf("alt handler, nested, rethrows in between\n");

    for (i = 0; i < ALT_HANDLER_REPEAT; i++) {
        pool();

        state = 0;
        @try {
            state++;
            @try {
                state++;
                // same-level handlers called in FIFO order (not stack-like)
                uintptr_t token = objc_addExceptionHandler(altHandler5, altHandler5);
                // state++ inside alt handler
                uintptr_t token2 = objc_addExceptionHandler(altHandler6, altHandler6);
                // state++ inside alt handler
                throwWithAltHandlerAndRethrow();  // state += 3 inside
                state = BAD;
                objc_removeExceptionHandler(token);
                objc_removeExceptionHandler(token2);
            }
            @catch (...) {
                testassert(state == 7);
                state++;
                @throw;
            }
            state = BAD;
        } 
        @catch (id e) {
            testassert(state == 8);
            state++;
            [e check];  // state++
            [e release];
        }
        testassert(state == 10);
    }


    testprintf("alt handler, exception thrown and caught inside\n");

    for (i = 0; i < ALT_HANDLER_REPEAT; i++) {
        pool();

        state = 0;
        @try {
            state++;
            uintptr_t token = objc_addExceptionHandler(altHandlerFail, 0);
            @try {
                state++;
                @throw [Super new];
                state = BAD;
            } 
            @catch (Super *e) {
                state++;
                [e check];  // state++
                [e release];
            }
            state++;
            objc_removeExceptionHandler(token);
        } 
        @catch (...) {
            state = BAD;
        }
        testassert(state == 5);
    }

#endif

#if defined(USE_FOUNDATION)
    [p release];
    succeed("nsexc.m");
#else
    succeed("exc.m");
#endif
}
