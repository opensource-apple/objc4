/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#import <stdint.h>
#import <stdbool.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <sys/types.h>
#import <sys/mman.h>
#import <libkern/OSAtomic.h>

#define OLD 1
#import "objc-private.h"
#import "auto_zone.h"
#import "objc-auto.h"
#import "objc-rtp.h"
#import "maptable.h"


static auto_zone_t *gc_zone_init(void);


__private_extern__ BOOL UseGC NOBSS = NO;
static BOOL RecordAllocations = NO;
static BOOL MultiThreadedGC = NO;
static BOOL WantsMainThreadFinalization = NO;
static BOOL NeedsMainThreadFinalization = NO;

static struct {
    auto_zone_foreach_object_t foreach;
    auto_zone_cursor_t cursor;
    size_t cursor_size;
    volatile BOOL finished;
    volatile BOOL started;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
} BatchFinalizeBlock;


__private_extern__ auto_zone_t *gc_zone = NULL;

// Pointer magic to make dyld happy. See notes in objc-private.h
__private_extern__ id (*objc_assign_ivar_internal)(id, id, ptrdiff_t) = objc_assign_ivar;


/***********************************************************************
* Utility exports
* Called by various libraries.
**********************************************************************/

OBJC_EXPORT void objc_set_collection_threshold(size_t threshold) { // Old naming
    if (UseGC) {
        auto_collection_parameters(gc_zone)->collection_threshold = threshold;
    }
}

OBJC_EXPORT void objc_setCollectionThreshold(size_t threshold) {
    if (UseGC) {
        auto_collection_parameters(gc_zone)->collection_threshold = threshold;
    }
}

void objc_setCollectionRatio(size_t ratio) {
    if (UseGC) {
        auto_collection_parameters(gc_zone)->full_vs_gen_frequency = ratio;
    }
}

void objc_set_collection_ratio(size_t ratio) {  // old naming
    if (UseGC) {
        auto_collection_parameters(gc_zone)->full_vs_gen_frequency = ratio;
    }
}

void objc_finalizeOnMainThread(Class cls) {
    if (UseGC) {
        WantsMainThreadFinalization = YES;
        _class_setFinalizeOnMainThread(cls);
    }
}


void objc_startCollectorThread(void) {
    static int didOnce = 0;
    if (!didOnce) {
        didOnce = 1;
        
        // pretend we're done to start out with.
        BatchFinalizeBlock.started = YES;
        BatchFinalizeBlock.finished = YES;
        pthread_mutex_init(&BatchFinalizeBlock.mutex, NULL);
        pthread_cond_init(&BatchFinalizeBlock.condition, NULL);
        auto_collect_multithreaded(gc_zone);
        MultiThreadedGC = YES;
    }
}

void objc_start_collector_thread(void) {
    objc_startCollectorThread();
}

static void batchFinalizeOnMainThread(void);

void objc_collect(unsigned long options) {
    if (!UseGC) return;
    BOOL onMainThread = pthread_main_np() ? YES : NO;

    if (MultiThreadedGC || onMainThread) {
        if (MultiThreadedGC && onMainThread) batchFinalizeOnMainThread();
        auto_collection_mode_t amode = AUTO_COLLECT_RATIO_COLLECTION;
        switch (options & 0x3) {
          case OBJC_RATIO_COLLECTION:        amode = AUTO_COLLECT_RATIO_COLLECTION;        break;
          case OBJC_GENERATIONAL_COLLECTION: amode = AUTO_COLLECT_GENERATIONAL_COLLECTION; break;
          case OBJC_FULL_COLLECTION:         amode = AUTO_COLLECT_FULL_COLLECTION;         break;
          case OBJC_EXHAUSTIVE_COLLECTION:   amode = AUTO_COLLECT_EXHAUSTIVE_COLLECTION;   break;
        }
        if (options & OBJC_COLLECT_IF_NEEDED) amode |= AUTO_COLLECT_IF_NEEDED;
        if (options & OBJC_WAIT_UNTIL_DONE)   amode |= AUTO_COLLECT_SYNCHRONOUS;  // uses different bits
        auto_collect(gc_zone, amode, NULL);
    }
    else {
        objc_msgSend(objc_getClass("NSGarbageCollector"), @selector(_callOnMainThread:withArgs:), objc_collect, (void *)options);
    }
}

// SPI
// 0 - exhaustively NSGarbageCollector.m
//   - from AppKit /Developer/Applications/Xcode.app/Contents/MacOS/Xcode via idleTimer
// GENERATIONAL
//   - from autoreleasepool
//   - several other places
void objc_collect_if_needed(unsigned long options) {
    if (!UseGC) return;
    BOOL onMainThread = pthread_main_np() ? YES : NO;

    if (MultiThreadedGC || onMainThread) {
        auto_collection_mode_t mode;
        if (options & OBJC_GENERATIONAL) {
            mode = AUTO_COLLECT_IF_NEEDED | AUTO_COLLECT_RATIO_COLLECTION;
        }
        else {
            mode = AUTO_COLLECT_EXHAUSTIVE_COLLECTION;
        }
        if (MultiThreadedGC && onMainThread) batchFinalizeOnMainThread();
        auto_collect(gc_zone, mode, NULL);
    }
    else {      // XXX could be optimized (e.g. ask auto for threshold check, if so, set ASKING if not already ASKING,...
        objc_msgSend(objc_getClass("NSGarbageCollector"), @selector(_callOnMainThread:withArgs:), objc_collect_if_needed, (void *)options);
    }
}

// NEVER USED.
size_t objc_numberAllocated(void) 
{
    auto_statistics_t stats;
    stats.version = 0;
    auto_zone_statistics(gc_zone, &stats);
    return stats.malloc_statistics.blocks_in_use;
}

// USED BY CF & ONE OTHER
BOOL objc_isAuto(id object) 
{
    return UseGC && auto_zone_is_valid_pointer(gc_zone, object) != 0;
}


BOOL objc_collectingEnabled(void) 
{
    return UseGC;
}
BOOL objc_collecting_enabled(void) // Old naming
{
    return UseGC;
}


/***********************************************************************
* Memory management. 
* Called by CF and Foundation.
**********************************************************************/

// Allocate an object in the GC zone, with the given number of extra bytes.
id objc_allocate_object(Class cls, int extra) 
{
    return class_createInstance(cls, extra);
}


/***********************************************************************
* Write barrier implementations, optimized for when GC is known to be on
* Called by the write barrier exports only.
* These implementations assume GC is on. The exported function must 
* either perform the check itself or be conditionally stomped at 
* startup time.
**********************************************************************/

static void objc_strongCast_write_barrier(id value, id *slot) {
    if (!auto_zone_set_write_barrier(gc_zone, (void*)slot, value)) {
        auto_zone_root_write_barrier(gc_zone, slot, value);
    }
}

__private_extern__ id objc_assign_strongCast_gc(id value, id *slot) 
{
    objc_strongCast_write_barrier(value, slot);
    return (*slot = value);
}

static void objc_register_global(id value, id *slot)
{
    // use explicit root registration.
    if (value && auto_zone_is_valid_pointer(gc_zone, value)) {
        if (auto_zone_is_finalized(gc_zone, value)) {
            __private_extern__ void objc_assign_global_error(id value, id *slot);

            _objc_inform("GC: storing an already collected object %p into global memory at %p, break on objc_assign_global_error to debug\n", value, slot);
            objc_assign_global_error(value, slot);
        }
        auto_zone_add_root(gc_zone, slot, value);
    }
}

__private_extern__ id objc_assign_global_gc(id value, id *slot) {
    objc_register_global(value, slot);
    return (*slot = value);
}


__private_extern__ id objc_assign_ivar_gc(id value, id base, ptrdiff_t offset) 
{
    id *slot = (id*) ((char *)base + offset);

    if (value) {
        if (!auto_zone_set_write_barrier(gc_zone, (char *)base + offset, value)) {
            __private_extern__  void objc_assign_ivar_error(id base, ptrdiff_t offset);

            _objc_inform("GC: %p + %d isn't in the auto_zone, break on objc_assign_ivar_error to debug.\n", base, offset);
            objc_assign_ivar_error(base, offset);
        }
    }
    
    return (*slot = value);
}


/***********************************************************************
* Write barrier exports
* Called by pretty much all GC-supporting code.
*
* These "generic" implementations, available in PPC, are thought to be
* called by Rosetta when it translates the bla instruction.
**********************************************************************/

// Platform-independent write barriers
// These contain the UseGC check that the platform-specific 
// runtime-rewritten implementations do not.

id objc_assign_strongCast_generic(id value, id *dest)
{
    if (UseGC) {
        return objc_assign_strongCast_gc(value, dest);
    } else {
        return (*dest = value);
    }
}


id objc_assign_global_generic(id value, id *dest)
{
    if (UseGC) {
        return objc_assign_global_gc(value, dest);
    } else {
        return (*dest = value);
    }
}


id objc_assign_ivar_generic(id value, id dest, ptrdiff_t offset)
{
    if (UseGC) {
        return objc_assign_ivar_gc(value, dest, offset);
    } else {
        id *slot = (id*) ((char *)dest + offset);
        return (*slot = value);
    }
}

#if defined(__ppc__) || defined(__i386__) || defined(__x86_64__)

// PPC write barriers are in objc-auto-ppc.s
// write_barrier_init conditionally stomps those to jump to the _impl versions.

// These 3 functions are defined in objc-auto-i386.s and objc-auto-x86_64.s as
// the non-GC variants. Under GC, rtp_init stomps them with jumps to
// objc_assign_*_gc.

#else

// use generic implementation until time can be spent on optimizations
id objc_assign_strongCast(id value, id *dest) { return objc_assign_strongCast_generic(value, dest); }
id objc_assign_global(id value, id *dest) { return objc_assign_global_generic(value, dest); }
id objc_assign_ivar(id value, id dest, ptrdiff_t offset) { return objc_assign_ivar_generic(value, dest, offset); }

// not (defined(__ppc__)) && not defined(__i386__) && not defined(__x86_64__)
#endif


void *objc_memmove_collectable(void *dst, const void *src, size_t size)
{
    if (UseGC) {
        return auto_zone_write_barrier_memmove(gc_zone, dst, src, size);
    } else {
        return memmove(dst, src, size);
    }
}

BOOL objc_atomicCompareAndSwapGlobal(id predicate, id replacement, volatile id *objectLocation) {
    if (UseGC) objc_register_global(replacement, (id *)objectLocation);
    return OSAtomicCompareAndSwapPtr((void *)predicate, (void *)replacement, (void * volatile *)objectLocation);
}

BOOL objc_atomicCompareAndSwapGlobalBarrier(id predicate, id replacement, volatile id *objectLocation) {
    if (UseGC) objc_register_global(replacement, (id *)objectLocation);
    return OSAtomicCompareAndSwapPtrBarrier((void *)predicate, (void *)replacement, (void * volatile *)objectLocation);
}

BOOL objc_atomicCompareAndSwapInstanceVariable(id predicate, id replacement, volatile id *objectLocation) {
    if (UseGC) objc_strongCast_write_barrier(replacement, (id *)objectLocation);
    return OSAtomicCompareAndSwapPtr((void *)predicate, (void *)replacement, (void * volatile *)objectLocation);
}

BOOL objc_atomicCompareAndSwapInstanceVariableBarrier(id predicate, id replacement, volatile id *objectLocation) {
    if (UseGC) objc_strongCast_write_barrier(replacement, (id *)objectLocation);
    return OSAtomicCompareAndSwapPtrBarrier((void *)predicate, (void *)replacement, (void * volatile *)objectLocation);
}


/***********************************************************************
* Weak ivar support
**********************************************************************/

id objc_read_weak(id *location) {
    id result = *location;
    if (UseGC && result) {
        result = auto_read_weak_reference(gc_zone, (void **)location);
    }
    return result;
}

id objc_assign_weak(id value, id *location) {
    if (UseGC) {
        auto_assign_weak_reference(gc_zone, value, (void **)location, NULL);
    }
    else {
        *location = value;
    }
    return value;
}


/***********************************************************************
* Testing tools
* Used to isolate resurrection of garbage objects during finalization.
**********************************************************************/
BOOL objc_is_finalized(void *ptr) {
    if (ptr != NULL && UseGC) {
        return auto_zone_is_finalized(gc_zone, ptr);
    }
    return NO;
}


/***********************************************************************
* Stack management
* Used to tell clean up dirty stack frames before a thread blocks. To
* make this more efficient, we really need better support from pthreads.
* See <rdar://problem/4548631> for more details.
**********************************************************************/

static vm_address_t _stack_resident_base() {
    pthread_t self = pthread_self();
    size_t stack_size = pthread_get_stacksize_np(self);
    vm_address_t stack_base = (vm_address_t)pthread_get_stackaddr_np(self) - stack_size;
    size_t stack_page_count = stack_size / vm_page_size;
    char stack_residency[stack_page_count];
    vm_address_t stack_resident_base = 0;
    if (mincore((void*)stack_base, stack_size, stack_residency) == 0) {
        // we can now tell the degree to which the stack is resident, and use it as our ultimate high water mark.
        size_t i;
        for (i = 0; i < stack_page_count; ++i) {
            if (stack_residency[i]) {
                stack_resident_base = stack_base + i * vm_page_size;
                // malloc_printf("last touched page = %lu\n", stack_page_count - i - 1);
                break;
            }
        }
    }
    return stack_resident_base;
}

static __attribute__((noinline)) void* _get_stack_pointer() {
#if defined(__i386__) || defined(__ppc__) || defined(__ppc64__) || defined(__x86_64__)
    return __builtin_frame_address(0);
#else
    return NULL;
#endif
}

void objc_clear_stack(unsigned long options) {
    if (!UseGC) return;
    if (options & OBJC_CLEAR_RESIDENT_STACK) {
        // clear just the pages of stack that are currently resident.
        vm_address_t stack_resident_base = _stack_resident_base();
        vm_address_t stack_top =  (vm_address_t)_get_stack_pointer() - 2 * sizeof(void*);
        bzero((void*)stack_resident_base, (stack_top - stack_resident_base));
    } else {
        // clear the entire unused stack, regardless of whether it's pages are resident or not.
        pthread_t self = pthread_self();
        size_t stack_size = pthread_get_stacksize_np(self);
        vm_address_t stack_base = (vm_address_t)pthread_get_stackaddr_np(self) - stack_size;
        vm_address_t stack_top =  (vm_address_t)_get_stack_pointer() - 2 * sizeof(void*);
        bzero((void*)stack_base, stack_top - stack_base);
    }
}

/***********************************************************************
* CF-only write barrier exports
* Called by CF only.
* The gc_zone guards are not thought to be necessary
**********************************************************************/

// Exported as very private SPI to Foundation to tell CF about
void* objc_assign_ivar_address_CF(void *value, void *base, void **slot)
{
    if (value && gc_zone) {
        if (auto_zone_is_valid_pointer(gc_zone, base)) {
            ptrdiff_t offset = (((char *)slot)-(char *)base);
            auto_zone_write_barrier(gc_zone, base, offset, value);
        }
    }
    
    return (*slot = value);
}


// Same as objc_assign_strongCast_gc, should tell Foundation to use _gc version instead
// exported as very private SPI to Foundation to tell CF about
void* objc_assign_strongCast_CF(void* value, void **slot) 
{
    if (value && gc_zone) {
	void *base = (void *)auto_zone_base_pointer(gc_zone, (void*)slot);
	if (base) {
            ptrdiff_t offset = (((char *)slot)-(char *)base);
            auto_zone_write_barrier(gc_zone, base, offset, value);
	}
    }
    return (*slot = value);
}


/***********************************************************************
* Finalization support
**********************************************************************/

static IMP _NSObject_finalize = NULL;

// Finalizer crash debugging
static void *finalizing_object;
static const char *__crashreporter_info__;

static void finalizeOneObject(void *obj, void *sel) {
    id object = (id)obj;
    SEL selector = (SEL)sel;
    finalizing_object = obj;
    __crashreporter_info__ = object_getClassName(obj);

    /// call -finalize method.
    objc_msgSend(object, selector);
    // Call C++ destructors, if any.
    object_cxxDestruct(object);

    finalizing_object = NULL;
    __crashreporter_info__ = NULL;
}

static void finalizeOneMainThreadOnlyObject(void *obj, void *sel) {
    id object = (id)obj;
    Class cls = object->isa;
    if (cls == NULL) {
        _objc_fatal("object with NULL ISA passed to finalizeOneMainThreadOnlyObject:  %p\n", obj);
    }
    if (_class_shouldFinalizeOnMainThread(cls)) {
        finalizeOneObject(obj, sel);
    }
}

static void finalizeOneAnywhereObject(void *obj, void *sel) {
    id object = (id)obj;
    Class cls = object->isa;
    if (cls == NULL) {
        _objc_fatal("object with NULL ISA passed to finalizeOneAnywhereObject:  %p\n", obj);
    }
    if (!_class_shouldFinalizeOnMainThread(cls)) {
        finalizeOneObject(obj, sel);
    }
    else {
        NeedsMainThreadFinalization = YES;
    }
}



static void batchFinalize(auto_zone_t *zone,
                          auto_zone_foreach_object_t foreach,
                          auto_zone_cursor_t cursor, 
                          size_t cursor_size,
                          void (*finalize)(void *, void*))
{
    for (;;) {
        @try {
            foreach(cursor, finalize, @selector(finalize));
            // non-exceptional return means finalization is complete.
            break;
        } @catch (id exception) {
            // whoops, note exception, then restart at cursor's position
            __private_extern__ void objc_exception_during_finalize_error(void);
            _objc_inform("GC: -finalize resulted in an exception (%p) being thrown, break on objc_exception_during_finalize_error to debug\n\t%s", exception, (const char*)[[exception description] UTF8String]);
            objc_exception_during_finalize_error();
        }
    }
}


static void batchFinalizeOnMainThread(void) {
    pthread_mutex_lock(&BatchFinalizeBlock.mutex);
    if (BatchFinalizeBlock.started) {
        // main thread got here already
        pthread_mutex_unlock(&BatchFinalizeBlock.mutex);
        return;
    }
    BatchFinalizeBlock.started = YES;
    pthread_mutex_unlock(&BatchFinalizeBlock.mutex);
        
    batchFinalize(gc_zone, BatchFinalizeBlock.foreach, BatchFinalizeBlock.cursor, BatchFinalizeBlock.cursor_size, finalizeOneMainThreadOnlyObject);
    // signal the collector thread that finalization has finished.
    pthread_mutex_lock(&BatchFinalizeBlock.mutex);
    BatchFinalizeBlock.finished = YES;
    pthread_cond_signal(&BatchFinalizeBlock.condition);
    pthread_mutex_unlock(&BatchFinalizeBlock.mutex);
}

static void batchFinalizeOnTwoThreads(auto_zone_t *zone,
                                         auto_zone_foreach_object_t foreach,
                                         auto_zone_cursor_t cursor, 
                                         size_t cursor_size)
{
    // First, lets get rid of everything we can on this thread, then ask main thread to help if needed
    NeedsMainThreadFinalization = NO;
    char cursor_copy[cursor_size];
    memcpy(cursor_copy, cursor, cursor_size);
    batchFinalize(zone, foreach, cursor_copy, cursor_size, finalizeOneAnywhereObject);

    if (! NeedsMainThreadFinalization)
        return;     // no help needed
    
    // set up the control block.  Either our ping of main thread with _callOnMainThread will get to it, or
    // an objc_collect_if_needed() will get to it.  Either way, this block will be processed on the main thread.
    pthread_mutex_lock(&BatchFinalizeBlock.mutex);
    BatchFinalizeBlock.foreach = foreach;
    BatchFinalizeBlock.cursor = cursor;
    BatchFinalizeBlock.cursor_size = cursor_size;
    BatchFinalizeBlock.started = NO;
    BatchFinalizeBlock.finished = NO;
    pthread_mutex_unlock(&BatchFinalizeBlock.mutex);
    
    //printf("----->asking main thread to finalize\n");
    objc_msgSend(objc_getClass("NSGarbageCollector"), @selector(_callOnMainThread:withArgs:), batchFinalizeOnMainThread, &BatchFinalizeBlock);
    
    // wait for the main thread to finish finalizing instances of classes marked CLS_FINALIZE_ON_MAIN_THREAD.
    pthread_mutex_lock(&BatchFinalizeBlock.mutex);
    while (!BatchFinalizeBlock.finished) pthread_cond_wait(&BatchFinalizeBlock.condition, &BatchFinalizeBlock.mutex);
    pthread_mutex_unlock(&BatchFinalizeBlock.mutex);
    //printf("<------ main thread finalize done\n");

}


static void objc_will_grow(auto_zone_t *zone, auto_heap_growth_info_t info) {
    if (MultiThreadedGC) {
        //printf("objc_will_grow %d\n", info);
        
        if (auto_zone_is_collecting(gc_zone)) {
            ;
        }
        else  {
            auto_collect(gc_zone, AUTO_COLLECT_RATIO_COLLECTION, NULL);
        }
    }
}


// collector calls this with garbage ready
static void BatchInvalidate(auto_zone_t *zone,
                                         auto_zone_foreach_object_t foreach,
                                         auto_zone_cursor_t cursor, 
                                         size_t cursor_size)
{
    if (pthread_main_np() || !WantsMainThreadFinalization) {
        // Collect all objects.  We're either pre-multithreaded on main thread or we're on the collector thread
        // but no main-thread-only objects have been allocated.
        batchFinalize(zone, foreach, cursor, cursor_size, finalizeOneObject);
    }
    else {
        // We're on the dedicated thread.  Collect some on main thread, the rest here.
        batchFinalizeOnTwoThreads(zone, foreach, cursor, cursor_size);
    }
    
}

// idea:  keep a side table mapping resurrected object pointers to their original Class, so we don't
// need to smash anything. alternatively, could use associative references to track against a secondary
// object with information about the resurrection, such as a stack crawl, etc.

static Class _NSResurrectedObjectClass;
static NXMapTable *_NSResurrectedObjectMap = NULL;
static OBJC_DECLARE_LOCK(_NSResurrectedObjectLock);

static Class resurrectedObjectOriginalClass(id object) {
    Class originalClass;
    OBJC_LOCK(&_NSResurrectedObjectLock);
    originalClass = (Class) NXMapGet(_NSResurrectedObjectMap, object);
    OBJC_UNLOCK(&_NSResurrectedObjectLock);
    return originalClass;
}

static id _NSResurrectedObject_classMethod(id self, SEL selector) { return self; }

static id _NSResurrectedObject_instanceMethod(id self, SEL name) {
    _objc_inform("**resurrected** object %p of class %s being sent message '%s'\n", self, class_getName(resurrectedObjectOriginalClass(self)), sel_getName(name));
    return self;
}

static void _NSResurrectedObject_finalize(id self, SEL _cmd) {
    Class originalClass;
    OBJC_LOCK(&_NSResurrectedObjectLock);
    originalClass = (Class) NXMapRemove(_NSResurrectedObjectMap, self);
    OBJC_UNLOCK(&_NSResurrectedObjectLock);
    if (originalClass) _objc_inform("**resurrected** object %p of class %s being finalized\n", self, class_getName(originalClass));
    _NSObject_finalize(self, _cmd);
}

static BOOL _NSResurrectedObject_resolveInstanceMethod(id self, SEL _cmd, SEL name) {
    class_addMethod((Class)self, name, (IMP)_NSResurrectedObject_instanceMethod, "@@:");
    return YES;
}

static BOOL _NSResurrectedObject_resolveClassMethod(id self, SEL _cmd, SEL name) {
    class_addMethod(object_getClass(self), name, (IMP)_NSResurrectedObject_classMethod, "@@:");
    return YES;
}

static void _NSResurrectedObject_initialize() {
    _NSResurrectedObjectMap = NXCreateMapTable(NXPtrValueMapPrototype, 128);
    _NSResurrectedObjectClass = objc_allocateClassPair(objc_getClass("NSObject"), "_NSResurrectedObject", 0);
    class_addMethod(_NSResurrectedObjectClass, @selector(finalize), (IMP)_NSResurrectedObject_finalize, "v@:");
    Class metaClass = object_getClass(_NSResurrectedObjectClass);
    class_addMethod(metaClass, @selector(resolveInstanceMethod:), (IMP)_NSResurrectedObject_resolveInstanceMethod, "c@::");
    class_addMethod(metaClass, @selector(resolveClassMethod:), (IMP)_NSResurrectedObject_resolveClassMethod, "c@::");
    objc_registerClassPair(_NSResurrectedObjectClass);
}

static void resurrectZombie(auto_zone_t *zone, void *ptr) {
    id object = (id) ptr;
    Class cls = object->isa;
    if (cls != _NSResurrectedObjectClass) {
        // remember the original class for this instance.
        OBJC_LOCK(&_NSResurrectedObjectLock);
        NXMapInsert(_NSResurrectedObjectMap, ptr, cls);
        OBJC_UNLOCK(&_NSResurrectedObjectLock);
        object->isa = _NSResurrectedObjectClass;
    }
}

/***********************************************************************
* Pretty printing support
* For development purposes.
**********************************************************************/


static char *name_for_address(auto_zone_t *zone, vm_address_t base, vm_address_t offset, int withRetainCount);

static char* objc_name_for_address(auto_zone_t *zone, vm_address_t base, vm_address_t offset)
{
    return name_for_address(zone, base, offset, false);
}

/***********************************************************************
* Collection support
**********************************************************************/

static const unsigned char *objc_layout_for_address(auto_zone_t *zone, void *address) 
{
    Class cls = *(Class *)address;
    return (const unsigned char *)class_getIvarLayout(cls);
}

static const unsigned char *objc_weak_layout_for_address(auto_zone_t *zone, void *address) 
{
    Class cls = *(Class *)address;
    return (const unsigned char *)class_getWeakIvarLayout(cls);
}

/***********************************************************************
* Initialization
**********************************************************************/

// Always called by _objcInit, even if GC is off.
__private_extern__ void gc_init(BOOL on)
{
    UseGC = on;

    if (PrintGC) {
        _objc_inform("GC: is %s", on ? "ON" : "OFF");
    }

    if (UseGC) {
        // Add GC state to crash log reports
        _objc_inform_on_crash("garbage collection is ON");

        // Set up the GC zone
        gc_zone = gc_zone_init();
        
        // no NSObject until Foundation calls objc_collect_init()
        _NSObject_finalize = &_objc_msgForward;
        
    } else {
        auto_zone_start_monitor(false);
        auto_zone_set_class_list((int (*)(void **, int))objc_getClassList);
    }
}


static auto_zone_t *gc_zone_init(void)
{
    auto_zone_t *result;

    // result = auto_zone_create("objc auto collected zone");
    result = auto_zone_create("auto_zone");
    
    auto_collection_control_t *control = auto_collection_parameters(result);
    
    // set up the magic control parameters
    control->batch_invalidate = BatchInvalidate;
    control->will_grow = objc_will_grow;
    control->resurrect = resurrectZombie;
    control->layout_for_address = objc_layout_for_address;
    control->weak_layout_for_address = objc_weak_layout_for_address;
    control->name_for_address = objc_name_for_address;

    return result;
}


// Called by Foundation to install auto's interruption callback.
malloc_zone_t *objc_collect_init(int (*callback)(void))
{
    // Find NSObject's finalize method now that Foundation is loaded.
    // fixme only look for the base implementation, not a category's
    _NSObject_finalize = class_getMethodImplementation(objc_getClass("NSObject"), @selector(finalize));
    if (_NSObject_finalize == &_objc_msgForward) {
        _objc_fatal("GC: -[NSObject finalize] unimplemented!");
    }

    // create the _NSResurrectedObject class used to track resurrections.
    _NSResurrectedObject_initialize();
    
    return (malloc_zone_t *)gc_zone;
}






/***********************************************************************
* Debugging
**********************************************************************/

/* This is non-deadlocking with respect to malloc's locks EXCEPT:
 * %ls, %a, %A formats
 * more than 8 args
 */
static void objc_debug_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
}

static malloc_zone_t *objc_debug_zone(void)
{
    static malloc_zone_t *z = NULL;
    if (!z) {
        z = malloc_create_zone(4096, 0);
        malloc_set_zone_name(z, "objc-auto debug");
    }
    return z;
}

static char *_malloc_append_unsigned(uintptr_t value, unsigned base, char *head) {
    if (!value) {
        head[0] = '0';
    } else {
        if (value >= base) head = _malloc_append_unsigned(value / base, base, head);
        value = value % base;
        head[0] = (value < 10) ? '0' + value : 'a' + value - 10;
    }
    return head+1;
}

static void strcati(char *str, uintptr_t value)
{
    str = _malloc_append_unsigned(value, 10, str + strlen(str));
    str[0] = '\0';
}

static void strcatx(char *str, uintptr_t value)
{
    str = _malloc_append_unsigned(value, 16, str + strlen(str));
    str[0] = '\0';
}


static Ivar ivar_for_offset(Class cls, vm_address_t offset)
{
    int i;
    int ivar_offset;
    Ivar super_ivar, result;
    Ivar *ivars;
    unsigned int ivar_count;

    if (!cls) return NULL;

    // scan base classes FIRST
    super_ivar = ivar_for_offset(class_getSuperclass(cls), offset);
    // result is best-effort; our ivars may be closer

    ivars = class_copyIvarList(cls, &ivar_count);
    if (ivars && ivar_count) {
        // Try our first ivar. If it's too big, use super's best ivar.
        ivar_offset = ivar_getOffset(ivars[0]);
        if (ivar_offset > offset) result = super_ivar;
        else if (ivar_offset == offset) result = ivars[0];
        else result = NULL;

        // Try our other ivars. If any is too big, use the previous.
        for (i = 1; result == NULL && i < ivar_count; i++) {
            ivar_offset = ivar_getOffset(ivars[i]);
            if (ivar_offset == offset) {
                result = ivars[i];
            } else if (ivar_offset > offset) {
                result = ivars[i - 1];
            }
        }

        // Found nothing. Return our last ivar.
        if (result == NULL)
            result = ivars[ivar_count - 1];
        
        free(ivars);
    } else {
        result = super_ivar;
    }
    
    return result;
}

static void append_ivar_at_offset(char *buf, Class cls, vm_address_t offset)
{
    Ivar ivar = NULL;

    if (offset == 0) return;  // don't bother with isa
    if (offset >= class_getInstanceSize(cls)) {
        strcat(buf, ".<extra>+");
        strcati(buf, offset);
        return;
    }

    ivar = ivar_for_offset(cls, offset);
    if (!ivar) {
        strcat(buf, ".<?>");
        return;
    }

    // fixme doesn't handle structs etc.
    
    strcat(buf, ".");
    const char *ivar_name = ivar_getName(ivar);
    if (ivar_name) strcat(buf, ivar_name);
    else strcat(buf, "<anonymous ivar>");

    offset -= ivar_getOffset(ivar);
    if (offset > 0) {
        strcat(buf, "+");
        strcati(buf, offset);
    }
}


static const char *cf_class_for_object(void *cfobj)
{
    // ick - we don't link against CF anymore

    const char *result;
    void *dlh;
    size_t (*CFGetTypeID)(void *);
    void * (*_CFRuntimeGetClassWithTypeID)(size_t);

    result = "anonymous_NSCFType";

    dlh = dlopen("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
    if (!dlh) return result;

    CFGetTypeID = (size_t(*)(void*)) dlsym(dlh, "CFGetTypeID");
    _CFRuntimeGetClassWithTypeID = (void*(*)(size_t)) dlsym(dlh, "_CFRuntimeGetClassWithTypeID");
    
    if (CFGetTypeID  &&  _CFRuntimeGetClassWithTypeID) {
        struct {
            size_t version;
            const char *className;
            // don't care about the rest
        } *cfcls;
        size_t cfid;
        cfid = (*CFGetTypeID)(cfobj);
        cfcls = (*_CFRuntimeGetClassWithTypeID)(cfid);
        result = cfcls->className;
    }

    dlclose(dlh);
    return result;
}


static char *name_for_address(auto_zone_t *zone, vm_address_t base, vm_address_t offset, int withRetainCount)
{
#define APPEND_SIZE(s) \
    strcat(buf, "["); \
    strcati(buf, s); \
    strcat(buf, "]");

    char buf[500];
    char *result;

    buf[0] = '\0';

    size_t size = 
        auto_zone_size_no_lock(zone, (void *)base);
    auto_memory_type_t type = size ? 
        auto_zone_get_layout_type_no_lock(zone, (void *)base) : AUTO_TYPE_UNKNOWN;
    unsigned int refcount = size ? 
        auto_zone_retain_count_no_lock(zone, (void *)base) : 0;

    switch (type) {
    case AUTO_OBJECT_SCANNED: 
    case AUTO_OBJECT_UNSCANNED: {
        const char *class_name = object_getClassName((id)base);
        if (0 == strcmp(class_name, "NSCFType")) {
            strcat(buf, cf_class_for_object((void *)base));
        } else {
            strcat(buf, class_name);
        }
        if (offset) {
            append_ivar_at_offset(buf, object_getClass((id)base), offset);
        }
        APPEND_SIZE(size);
        break;
    }
    case AUTO_MEMORY_SCANNED:
        strcat(buf, "{conservative-block}");
        APPEND_SIZE(size);
        break;
    case AUTO_MEMORY_UNSCANNED:
        strcat(buf, "{no-pointers-block}");
        APPEND_SIZE(size);
        break;
    default:
        strcat(buf, "{unallocated-or-stack}");
    } 
    
    if (withRetainCount  &&  refcount > 0) {
        strcat(buf, " [[refcount=");
        strcati(buf, refcount);
        strcat(buf, "]]");
    }

    result = malloc_zone_malloc(objc_debug_zone(), 1 + strlen(buf));
    strcpy(result, buf);
    return result;

#undef APPEND_SIZE
}


struct objc_class_recorder_context {
    malloc_zone_t *zone;
    void *cls;
    char *clsname;
    unsigned int count;
};

static void objc_class_recorder(task_t task, void *context, unsigned type_mask,
                                vm_range_t *ranges, unsigned range_count)
{
    struct objc_class_recorder_context *ctx = 
        (struct objc_class_recorder_context *)context;

    vm_range_t *r;
    vm_range_t *end;
    for (r = ranges, end = ranges + range_count; r < end; r++) {
        auto_memory_type_t type = 
            auto_zone_get_layout_type_no_lock(ctx->zone, (void *)r->address);
        if (type == AUTO_OBJECT_SCANNED || type == AUTO_OBJECT_UNSCANNED) {
            // Check if this is an instance of class ctx->cls or some subclass
            Class cls;
            Class isa = *(Class *)r->address;
            for (cls = isa; cls; cls = _class_getSuperclass(cls)) {
                if (cls == ctx->cls) {
                    unsigned int rc;
                    objc_debug_printf("[%p]    :   %s", r->address, _class_getName(isa));
                    if ((rc = auto_zone_retain_count_no_lock(ctx->zone, (void *)r->address))) {
                        objc_debug_printf(" [[refcount %u]]", rc);
                    }
                    objc_debug_printf("\n");
                    ctx->count++;
                    break;
                }
            }
        }
    }
}

__private_extern__ void objc_enumerate_class(char *clsname)
{
    struct objc_class_recorder_context ctx;
    ctx.zone = auto_zone();
    ctx.clsname = clsname;
    ctx.cls = objc_getClass(clsname);  // GrP fixme may deadlock if classHash lock is already owned
    ctx.count = 0;
    if (!ctx.cls) {
        objc_debug_printf("No class '%s'\n", clsname);
        return;
    }
    objc_debug_printf("\n\nINSTANCES OF CLASS '%s':\n\n", clsname);
    (*ctx.zone->introspect->enumerator)(mach_task_self(), &ctx, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)ctx.zone, NULL, objc_class_recorder);
    objc_debug_printf("\n%d instances\n\n", ctx.count);
}


static void objc_reference_printer(auto_zone_t *zone, void *ctx, 
                                   auto_reference_t ref)
{
    char *referrer_name = name_for_address(zone, ref.referrer_base, ref.referrer_offset, true);
    char *referent_name = name_for_address(zone, ref.referent, 0, true);

    objc_debug_printf("[%p%+d -> %p]  :  %s  ->  %s\n", 
                      ref.referrer_base, ref.referrer_offset, ref.referent,
                      referrer_name, referent_name);

    malloc_zone_free(objc_debug_zone(), referrer_name);
    malloc_zone_free(objc_debug_zone(), referent_name);
}


__private_extern__ void objc_print_references(void *referent, void *stack_bottom, int lock)
{
    if (lock) {
        auto_enumerate_references(auto_zone(), referent, 
                                  objc_reference_printer, stack_bottom, NULL);
    } else {
        auto_enumerate_references_no_lock(auto_zone(), referent, 
                                          objc_reference_printer, stack_bottom, NULL);
    }
}



typedef struct {
    vm_address_t address;          // of this object
    int refcount;                  // of this object - nonzero means ROOT
    int depth;                     // number of links away from referent, or -1
    auto_reference_t *referrers; // of this object
    int referrers_used;
    int referrers_allocated;
    auto_reference_t back; // reference from this object back toward the target
    uint32_t ID; // Graphic ID for grafflization
} blob;


typedef struct {
    blob **list;
    unsigned int used;
    unsigned int allocated;
} blob_queue;

static blob_queue blobs = {NULL, 0, 0};
static blob_queue untraced_blobs = {NULL, 0, 0};
static blob_queue root_blobs = {NULL, 0, 0};


static void spin(void) {    
    static time_t t = 0;
    time_t now = time(NULL);
    if (t != now) {
        objc_debug_printf(".");
        t = now;
    }
}


static void enqueue_blob(blob_queue *q, blob *b)
{
    if (q->used == q->allocated) {
        q->allocated = q->allocated * 2 + 1;
        q->list = malloc_zone_realloc(objc_debug_zone(), q->list, q->allocated * sizeof(blob *));
    }
    q->list[q->used++] = b;
}


static blob *dequeue_blob(blob_queue *q)
{
    blob *result = q->list[0];
    q->used--;
    memmove(&q->list[0], &q->list[1], q->used * sizeof(blob *));
    return result;
}


static blob *blob_for_address(vm_address_t addr)
{
    blob *b, **bp, **end;

    if (addr == 0) return NULL;

    for (bp = blobs.list, end = blobs.list+blobs.used; bp < end; bp++) {
        b = *bp;
        if (b->address == addr) return b;
    }

    b = malloc_zone_calloc(objc_debug_zone(), sizeof(blob), 1);
    b->address = addr;
    b->depth = -1;
    b->refcount = auto_zone_size_no_lock(auto_zone(), (void *)addr) ? auto_zone_retain_count_no_lock(auto_zone(), (void *)addr) : 1;
    enqueue_blob(&blobs, b);
    return b;
}

static int blob_exists(vm_address_t addr)
{
    blob *b, **bp, **end;
    for (bp = blobs.list, end = blobs.list+blobs.used; bp < end; bp++) {
        b = *bp;
        if (b->address == addr) return 1;
    }
    return 0;
}


// Destroy the blobs table and all blob data in it
static void free_blobs(void)
{
    blob *b, **bp, **end;
    for (bp = blobs.list, end = blobs.list+blobs.used; bp < end; bp++) {
        b = *bp;
        malloc_zone_free(objc_debug_zone(), b);
    }
    if (blobs.list) malloc_zone_free(objc_debug_zone(), blobs.list);
}

static void print_chain(auto_zone_t *zone, blob *root)
{
    blob *b;
    for (b = root; b != NULL; b = blob_for_address(b->back.referent)) {
        char *name;
        if (b->back.referent) {
            name = name_for_address(zone, b->address, b->back.referrer_offset, true);
            objc_debug_printf("[%p%+d]  :  %s  ->\n", b->address, b->back.referrer_offset, name);
        } else {
            name = name_for_address(zone, b->address, 0, true);
            objc_debug_printf("[%p]    :   %s\n", b->address, name);
        }
        malloc_zone_free(objc_debug_zone(), name);
    }
}


static void objc_blob_recorder(auto_zone_t *zone, void *ctx, 
                               auto_reference_t ref)
{
    blob *b = (blob *)ctx;

    spin();

    if (b->referrers_used == b->referrers_allocated) {
        b->referrers_allocated = b->referrers_allocated * 2 + 1;
        b->referrers = malloc_zone_realloc(objc_debug_zone(), b->referrers,
                                             b->referrers_allocated * 
                                             sizeof(auto_reference_t));
    }

    b->referrers[b->referrers_used++] = ref;
    if (!blob_exists(ref.referrer_base)) {
        enqueue_blob(&untraced_blobs, blob_for_address(ref.referrer_base));
    }
}


#define INSTANCE_ROOTS 1
#define HEAP_ROOTS 2
#define ALL_REFS 3
static void objc_print_recursive_refs(vm_address_t target, int which, void *stack_bottom, int lock);
static void grafflize(blob_queue *blobs, int everything);

__private_extern__ void objc_print_instance_roots(vm_address_t target, void *stack_bottom, int lock)
{
    objc_print_recursive_refs(target, INSTANCE_ROOTS, stack_bottom, lock);
}

__private_extern__ void objc_print_heap_roots(vm_address_t target, void *stack_bottom, int lock)
{
    objc_print_recursive_refs(target, HEAP_ROOTS, stack_bottom, lock);
}

__private_extern__ void objc_print_all_refs(vm_address_t target, void *stack_bottom, int lock)
{
    objc_print_recursive_refs(target, ALL_REFS, stack_bottom, lock);
}

static void sort_blobs_by_refcount(blob_queue *blobs)
{
    int i, j;

    // simple bubble sort
    for (i = 0; i < blobs->used; i++) {
        for (j = i+1; j < blobs->used; j++) {
            if (blobs->list[i]->refcount < blobs->list[j]->refcount) {
                blob *temp = blobs->list[i];
                blobs->list[i] = blobs->list[j];
                blobs->list[j] = temp;
            }
        }
    }
}


static void sort_blobs_by_depth(blob_queue *blobs)
{
    int i, j;

    // simple bubble sort
    for (i = 0; i < blobs->used; i++) {
        for (j = i+1; j < blobs->used; j++) {
            if (blobs->list[i]->depth > blobs->list[j]->depth) {
                blob *temp = blobs->list[i];
                blobs->list[i] = blobs->list[j];
                blobs->list[j] = temp;
            }
        }
    }
}


static void objc_print_recursive_refs(vm_address_t target, int which, void *stack_bottom, int lock)
{
    objc_debug_printf("\n   ");  // make spinner draw in a pretty place

    // Construct pointed-to graph (of things eventually pointing to target)
    
    enqueue_blob(&untraced_blobs, blob_for_address(target));
    
    while (untraced_blobs.used > 0) {
        blob *b = dequeue_blob(&untraced_blobs);
        spin();
        if (lock) {
            auto_enumerate_references(auto_zone(), (void *)b->address, 
                                      objc_blob_recorder, stack_bottom, b);
        } else {
            auto_enumerate_references_no_lock(auto_zone(), (void *)b->address, 
                                              objc_blob_recorder, stack_bottom, b);
        }
    }

    // Walk pointed-to graph to find shortest paths from roots to target.
    // This is BREADTH-FIRST order.

    blob_for_address(target)->depth = 0;
    enqueue_blob(&untraced_blobs, blob_for_address(target));
    
    while (untraced_blobs.used > 0) {
        blob *b = dequeue_blob(&untraced_blobs);
        blob *other;
        auto_reference_t *r, *end;
        int stop = NO;

        spin();

        if (which == ALL_REFS) {
            // Never stop at roots.
            stop = NO;
        } else if (which == HEAP_ROOTS) {
            // Stop at any root (a block with positive retain count)
            stop = (b->refcount > 0);
        } else if (which == INSTANCE_ROOTS) {
            // Only stop at roots that are instances
	    auto_memory_type_t type = auto_zone_get_layout_type_no_lock(auto_zone(), (void *)b->address);
            stop = (b->refcount > 0  &&  (type == AUTO_OBJECT_SCANNED || type == AUTO_OBJECT_UNSCANNED)); // GREG XXX ???
        }

        // If this object is a root, save it and don't walk its referrers.
        if (stop) {
            enqueue_blob(&root_blobs, b);
            continue;
        }

        // For any "other object" that points to "this object"
        // and does not yet have a depth:
        // (1) other object is one level deeper than this object
        // (2) (one of) the shortest path(s) from other object to the 
        //     target goes through this object

        for (r = b->referrers, end = b->referrers + b->referrers_used; 
             r < end;
             r++)
        {
            other = blob_for_address(r->referrer_base);
            if (other->depth == -1) {
                other->depth = b->depth + 1;
                other->back = *r;
                enqueue_blob(&untraced_blobs, other);
            }
        }
    }

    {
        char *name = name_for_address(auto_zone(), target, 0, true);
        objc_debug_printf("\n\n%d %s %p (%s)\n\n",
                          (which==ALL_REFS) ? blobs.used : root_blobs.used, 
                          (which==ALL_REFS) ? "INDIRECT REFS TO" : "ROOTS OF", 
                          target, name);
        malloc_zone_free(objc_debug_zone(), name);
    }

    if (which == ALL_REFS) {
        // Print all reference objects, biggest refcount first
        int i;
        sort_blobs_by_refcount(&blobs);
        for (i = 0; i < blobs.used; i++) {
            char *name = name_for_address(auto_zone(), blobs.list[i]->address, 0, true);
            objc_debug_printf("[%p]    :   %s\n", blobs.list[i]->address, name);
            malloc_zone_free(objc_debug_zone(), name);
        }
    }    
    else {
        // Walk back chain from every root to the target, printing every step.
        
        while (root_blobs.used > 0) {
            blob *root = dequeue_blob(&root_blobs);
            print_chain(auto_zone(), root);
            objc_debug_printf("\n");
        }
    }

    grafflize(&blobs, which == ALL_REFS);

    objc_debug_printf("\ndone\n\n");

    // Clean up

    free_blobs();
    if (untraced_blobs.list) malloc_zone_free(objc_debug_zone(), untraced_blobs.list);
    if (root_blobs.list) malloc_zone_free(objc_debug_zone(), root_blobs.list);

    memset(&blobs, 0, sizeof(blobs));
    memset(&root_blobs, 0, sizeof(root_blobs));
    memset(&untraced_blobs, 0, sizeof(untraced_blobs));
}



struct objc_block_recorder_context {
    malloc_zone_t *zone;
    int fd;
    unsigned int count;
};


static void objc_block_recorder(task_t task, void *context, unsigned type_mask,
                                vm_range_t *ranges, unsigned range_count)
{
    char buf[20];
    struct objc_block_recorder_context *ctx = 
        (struct objc_block_recorder_context *)context;

    vm_range_t *r;
    vm_range_t *end;
    for (r = ranges, end = ranges + range_count; r < end; r++) {
        char *name = name_for_address(ctx->zone, r->address, 0, true);
        buf[0] = '\0';
        strcatx(buf, r->address);

        write(ctx->fd, "0x", 2);
        write(ctx->fd, buf, strlen(buf));
        write(ctx->fd, " ", 1);
        write(ctx->fd, name, strlen(name));
        write(ctx->fd, "\n", 1);

        malloc_zone_free(objc_debug_zone(), name);
        ctx->count++;
    }
}


__private_extern__ void objc_dump_block_list(const char* path)
{
    struct objc_block_recorder_context ctx;
    char filename[] = "/tmp/blocks-XXXXX.txt";

    ctx.zone = auto_zone();
    ctx.count = 0;
    ctx.fd = (path ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666) : mkstemps(filename, (int)strlen(strrchr(filename, '.'))));

    objc_debug_printf("\n\nALL AUTO-ALLOCATED BLOCKS\n\n");
    (*ctx.zone->introspect->enumerator)(mach_task_self(), &ctx, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)ctx.zone, NULL, objc_block_recorder);
    objc_debug_printf("%d blocks written to file\n", ctx.count);
    objc_debug_printf("open %s\n", (path ? path : filename));

    close(ctx.fd);
}




static void grafflize_id(int gfile, int ID)
{
    char buf[20] = "";
    char *c;

    strcati(buf, ID);
    c = "<key>ID</key><integer>";
    write(gfile, c, strlen(c));
    write(gfile, buf, strlen(buf));
    c = "</integer>";
    write(gfile, c, strlen(c));
}


// head = REFERENT end = arrow
// tail = REFERRER end = no arrow
static void grafflize_reference(int gfile, auto_reference_t reference,  
                                int ID, int important)
{
    blob *referrer = blob_for_address(reference.referrer_base);
    blob *referent = blob_for_address(reference.referent);
    char *c;

    // line
    c = "<dict><key>Class</key><string>LineGraphic</string>";
    write(gfile, c, strlen(c));

    // id
    grafflize_id(gfile, ID);

    // head = REFERENT
    c = "<key>Head</key><dict>";
    write(gfile, c, strlen(c));
    grafflize_id(gfile, referent->ID);
    c = "</dict>";
    write(gfile, c, strlen(c));

    // tail = REFERRER
    c = "<key>Tail</key><dict>";
    write(gfile, c, strlen(c));
    grafflize_id(gfile, referrer->ID);
    c = "</dict>";
    write(gfile, c, strlen(c));

    // style - head arrow, thick line if important
    c = "<key>Style</key><dict><key>stroke</key><dict>"
        "<key>HeadArrow</key><string>FilledArrow</string>"
        "<key>LineType</key><integer>1</integer>";
    write(gfile, c, strlen(c));
    if (important) {
        c = "<key>Width</key><real>3</real>";
        write(gfile, c, strlen(c));
    }
    c = "</dict></dict>";
    write(gfile, c, strlen(c));
    
    // end line
    c = "</dict>";
    write(gfile, c, strlen(c));
}


static void grafflize_blob(int gfile, blob *b) 
{
    // fixme include ivar names too
    char *name = name_for_address(auto_zone(), b->address, 0, false);
    int width = 30 + (int)strlen(name)*6;
    int height = 40;
    char buf[40] = "";
    char *c;
    
    // rectangle
    c = "<dict>"
        "<key>Class</key><string>ShapedGraphic</string>"
        "<key>Shape</key><string>Rectangle</string>";
    write(gfile, c, strlen(c));
    
    // id
    grafflize_id(gfile, b->ID);
    
    // bounds
    // order vertically by depth
    c = "<key>Bounds</key><string>{{0,";
    write(gfile, c, strlen(c));
    buf[0] = '\0';
    strcati(buf, b->depth*60);
    write(gfile, buf, strlen(buf));
    c = "},{";
    write(gfile, c, strlen(c));
    buf[0] = '\0';
    strcati(buf, width);
    strcat(buf, ",");
    strcati(buf, height);
    write(gfile, buf, strlen(buf));
    c = "}}</string>";
    write(gfile, c, strlen(c));
    
    // label
    c = "<key>Text</key><dict><key>Text</key>"
        "<string>{\\rtf1\\mac\\ansicpg10000\\cocoartf102\n"
        "{\\fonttbl\\f0\\fswiss\\fcharset77 Helvetica;\\fonttbl\\f1\\fswiss\\fcharset77 Helvetica-Bold;}\n"
        "{\\colortbl;\\red255\\green255\\blue255;}\n"
        "\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\qc\n"
        "\\f0\\fs20 \\cf0 ";
    write(gfile, c, strlen(c));
    write(gfile, name, strlen(name));
    strcpy(buf, "\\\n0x");
    strcatx(buf, b->address);
    write(gfile, buf, strlen(buf));
    c = "}</string></dict>";
    write(gfile, c, strlen(c));

    // styles
    c = "<key>Style</key><dict>";
    write(gfile, c, strlen(c));

    // no shadow
    c = "<key>shadow</key><dict><key>Draws</key><string>NO</string></dict>";
    write(gfile, c, strlen(c));

    // fat border if refcount > 0
    if (b->refcount > 0) {
        c = "<key>stroke</key><dict><key>Width</key><real>4</real></dict>";
        write(gfile, c, strlen(c));
    }

    // end styles
    c = "</dict>";
    write(gfile, c, strlen(c));

    // done
    c = "</dict>\n";
    write(gfile, c, strlen(c));
    
    malloc_zone_free(objc_debug_zone(), name);
}


#define gheader "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>GraphDocumentVersion</key><integer>3</integer><key>ReadOnly</key><string>NO</string><key>GraphicsList</key><array>\n"

#define gfooter "</array></dict></plist>\n"


static void grafflize(blob_queue *blobs, int everything)
{
    // Don't require linking to Foundation!
    int i;
    int gfile;
    int nextid = 1;
    char filename[] = "/tmp/gc-XXXXX.graffle";

    // Open file
    gfile = mkstemps(filename, (int)strlen(strrchr(filename, '.')));
    if (gfile < 0) {
        objc_debug_printf("couldn't create a graffle file in /tmp/ (errno %d)\n", errno);
        return;
    }

    // Write header
    write(gfile, gheader, strlen(gheader));

    // Write a rectangle for each blob
    sort_blobs_by_depth(blobs);
    for (i = 0; i < blobs->used; i++) {
        blob *b = blobs->list[i];
        b->ID = nextid++;
        if (everything  ||  b->depth >= 0) {
            grafflize_blob(gfile, b);
        }
    }

    for (i = 0; i < blobs->used; i++) {
        int j;
        blob *b = blobs->list[i];

        if (everything) {
            // Write an arrow for each reference
            // Use big arrows for backreferences
            for (j = 0; j < b->referrers_used; j++) {
                int is_back_ref = (b->referrers[i].referent == b->back.referent  &&  b->referrers[i].referrer_offset == b->back.referrer_offset  &&  b->referrers[i].referrer_base == b->back.referrer_base);
                     
                grafflize_reference(gfile, b->referrers[j], nextid++, 
                                    is_back_ref);
            }
        }
        else {
            // Write an arrow for each backreference
            if (b->depth > 0) {
                grafflize_reference(gfile, b->back, nextid++, false);
            }
        }
    }

    // Write footer and close
    write(gfile, gfooter, strlen(gfooter));
    close(gfile);
    objc_debug_printf("wrote object graph (%d objects)\nopen %s\n", 
                      blobs->used, filename);
}
