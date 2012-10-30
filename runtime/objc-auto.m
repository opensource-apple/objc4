/*
 * Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 2004 Apple Computer, Inc.  All Rights Reserved.
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
/*
 *  objc-auto.m
 *  Copyright 2004 Apple Computer, Inc.
 */

#import "objc-auto.h"

#import <stdint.h>
#import <stdbool.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

#import "objc-private.h"
#import "objc-rtp.h"
#import "maptable.h"



// Types and prototypes from non-open-source auto_zone.h

#include <sys/types.h>
#include <malloc/malloc.h>

typedef malloc_zone_t auto_zone_t;

typedef uint64_t auto_date_t;

typedef struct {
    unsigned    version; // reserved - 0 for now
    /* Memory usage */
    unsigned long long  num_allocs; // number of allocations performed
    volatile unsigned   blocks_in_use;// number of pointers in use
    unsigned    bytes_in_use;       // sum of the sizes of all pointers in use
    unsigned    max_bytes_in_use;   // high water mark
    unsigned    bytes_allocated;
    /* GC stats */
    /* When there is an array, 0 stands for full collection, 1 for generational */
    unsigned    num_collections[2];
    boolean_t   last_collection_was_generational;
    unsigned    bytes_in_use_after_last_collection[2];
    unsigned    bytes_allocated_after_last_collection[2];
    unsigned    bytes_freed_during_last_collection[2];
    auto_date_t duration_last_collection[2];
    auto_date_t duration_all_collections[2];
} auto_statistics_t;

typedef enum {
    AUTO_COLLECTION_NO_COLLECTION = 0,
    AUTO_COLLECTION_GENERATIONAL_COLLECTION,
    AUTO_COLLECTION_FULL_COLLECTION
} auto_collection_mode_t;

typedef enum {
    AUTO_LOG_COLLECTIONS = (1 << 1),    // log whenever a collection occurs
    AUTO_LOG_COLLECT_DECISION = (1 << 2), // logs when deciding whether to collect
    AUTO_LOG_GC_IMPL = (1 << 3),    // logs to help debug GC
    AUTO_LOG_REGIONS = (1 << 4),    // log whenever a new region is allocated
    AUTO_LOG_UNUSUAL = (1 << 5),    // log unusual circumstances
    AUTO_LOG_WEAK = (1 << 6),        // log weak reference manipulation
    AUTO_LOG_ALL = (~0u)
} auto_log_mask_t;

typedef struct auto_zone_cursor *auto_zone_cursor_t;

typedef void (*auto_zone_foreach_object_t) (auto_zone_cursor_t cursor, void (*op) (void *ptr, void *data), void* data);

typedef struct {
    unsigned        version; // reserved - 0 for now
    boolean_t       trace_stack_conservatively;
    boolean_t       (*should_collect)(auto_zone_t *, const auto_statistics_t *stats, boolean_t about_to_create_a_new_region); 
        // called back when a threshold is reached; must say whether to collect (and what type)
        // all locks are released when that call back is called
        // callee is free to call for statistics or reset the threshold
    unsigned        ask_should_collect_frequency;
	// should_collect() is called each <N> allocations or free, where <N> is this field
    unsigned        full_vs_gen_frequency;
	// ratio of generational vs. full GC for the frequency based ones
    int             (*collection_should_interrupt)(void);
        // called during scan to see if garbage collection should be aborted
    void        (*invalidate)(auto_zone_t *zone, void *ptr, void *collection_context);
    void        (*batch_invalidate) (auto_zone_t *zone, auto_zone_foreach_object_t foreach, auto_zone_cursor_t cursor);
        // called back with an object that is unreferenced
        // callee is responsible for invalidating object state
    void        (*resurrect) (auto_zone_t *zone, void *ptr);
        // convert the object into a safe-to-use, but otherwise "undead" object. no guarantees are made about the
        // contents of this object, other than its liveness.
    unsigned        word0_mask; // mask for defining class
    void        (*note_unknown_layout)(auto_zone_t *zone, unsigned class_field);
        // called once for each class encountered for which we don't know the layout
        // callee can decide to register class with auto_zone_register_layout(), or do nothing
        // Note that this function is called during GC and therefore should not do any auto-allocation
    char*       (*name_for_address) (auto_zone_t *zone, vm_address_t base, vm_address_t offset);
    auto_log_mask_t log;
	// set to auto_log_mask_t bits as desired
    boolean_t           disable_generational;
	// if true, ignores requests to do generational GC.
    boolean_t           paranoid_generational;
	// if true, always compares generational GC result to full GC garbage list
    boolean_t           malloc_stack_logging;
	// if true, uses malloc_zone_malloc() for stack logging.
} auto_collection_control_t;

typedef enum {
    AUTO_TYPE_UNKNOWN = -1,                                 // this is an error value
    AUTO_UNSCANNED = 1,
    AUTO_OBJECT = 2,
    AUTO_MEMORY_SCANNED = 0,                                // holds conservatively scanned pointers
    AUTO_MEMORY_UNSCANNED = AUTO_UNSCANNED,                 // holds unscanned memory (bits)
    AUTO_OBJECT_SCANNED = AUTO_OBJECT,                      // first word is 'isa', may have 'exact' layout info elsewhere
    AUTO_OBJECT_UNSCANNED = AUTO_OBJECT | AUTO_UNSCANNED,   // first word is 'isa', good for bits or auto_zone_retain'ed items
} auto_memory_type_t;

typedef struct 
{
    vm_address_t referent;
    vm_address_t referrer_base;
    intptr_t     referrer_offset;
} auto_reference_t;

typedef void (*auto_reference_recorder_t)(auto_zone_t *zone, void *ctx, 
                                          auto_reference_t reference);


static void auto_collect(auto_zone_t *zone, auto_collection_mode_t mode, void *collection_context);
static auto_collection_control_t *auto_collection_parameters(auto_zone_t *zone);
static const auto_statistics_t *auto_collection_statistics(auto_zone_t *zone);
static void auto_enumerate_references(auto_zone_t *zone, void *referent, 
                                      auto_reference_recorder_t callback, 
                                      void *stack_bottom, void *ctx);
static void auto_enumerate_references_no_lock(auto_zone_t *zone, void *referent, auto_reference_recorder_t callback, void *stack_bottom, void *ctx);
static auto_zone_t *auto_zone(void);
static void auto_zone_add_root(auto_zone_t *zone, void *root, size_t size);
static void* auto_zone_allocate_object(auto_zone_t *zone, size_t size, auto_memory_type_t type, boolean_t initial_refcount_to_one, boolean_t clear);
static const void *auto_zone_base_pointer(auto_zone_t *zone, const void *ptr);
static auto_memory_type_t auto_zone_get_layout_type(auto_zone_t *zone, void *ptr);
static auto_memory_type_t auto_zone_get_layout_type_no_lock(auto_zone_t *zone, void *ptr);
static boolean_t auto_zone_is_finalized(auto_zone_t *zone, const void *ptr);
static boolean_t auto_zone_is_valid_pointer(auto_zone_t *zone, const void *ptr);
static unsigned int auto_zone_release(auto_zone_t *zone, void *ptr);
static void auto_zone_retain(auto_zone_t *zone, void *ptr);
static unsigned int auto_zone_retain_count_no_lock(auto_zone_t *zone, const void *ptr);
static void auto_zone_set_class_list(int (*get_class_list)(void **buffer, int count));
static size_t auto_zone_size_no_lock(auto_zone_t *zone, const void *ptr);
static void auto_zone_start_monitor(boolean_t force);
static void auto_zone_write_barrier(auto_zone_t *zone, void *recipient, const unsigned int offset_in_bytes, const void *new_value);
static void *auto_zone_write_barrier_memmove(auto_zone_t *zone, void *dst, const void *src, size_t size);



static void record_allocation(Class cls);
static auto_zone_t *gc_zone_init(void);


__private_extern__ BOOL UseGC NOBSS = NO;
static BOOL RecordAllocations = NO;
static int IsaStompBits = 0x0;

static auto_zone_t *gc_zone = NULL;
static BOOL gc_zone_finalizing = NO;
static intptr_t gc_collection_threshold = 128 * 1024;
static size_t gc_collection_ratio = 100, gc_collection_counter = 0;
static NXMapTable *gc_finalization_safe_classes = NULL;
static BOOL gc_roots_retained = YES;

/***********************************************************************
* Internal utilities
**********************************************************************/

#define ISAUTOOBJECT(x) (auto_zone_is_valid_pointer(gc_zone, (x)))


// A should-collect callback that never allows collection.
// Currently used to prevent on-demand collection.
static boolean_t objc_never_collect(auto_zone_t *zone, const auto_statistics_t *stats, boolean_t about_to_create_a_new_region)
{
    return false;
}


/***********************************************************************
* Utility exports
* Called by various libraries.
**********************************************************************/

void objc_collect(void) 
{
    if (UseGC) {
        auto_collect(gc_zone, AUTO_COLLECTION_FULL_COLLECTION, NULL);
    }
}

void objc_collect_if_needed(unsigned long options) {
    if (UseGC) {
        const auto_statistics_t *stats = auto_collection_statistics(gc_zone);
        if (options & OBJC_GENERATIONAL) {
            // use an absolute memory allocated threshold to decide when to generationally collect.
            intptr_t bytes_allocated_since_last_gc = stats->bytes_in_use - stats->bytes_in_use_after_last_collection[stats->last_collection_was_generational];
            if (bytes_allocated_since_last_gc >= gc_collection_threshold) {
                // malloc_printf("bytes_allocated_since_last_gc = %ld\n", bytes_allocated_since_last_gc);
                // periodically run a full collection until to keep memory usage down, controlled by OBJC_COLLECTION_RATIO (100 to 1 is the default).
                auto_collection_mode_t mode = AUTO_COLLECTION_GENERATIONAL_COLLECTION;
                if (gc_collection_counter++ >= gc_collection_ratio) {
                    mode = AUTO_COLLECTION_FULL_COLLECTION;
                    gc_collection_counter = 0;
                }
                auto_collect(gc_zone, mode, NULL);
            }
        } else {
            // Run full collections until we no longer recover additional objects. We use two measurements
            // to determine whether or not the collector is being productive: the total number of blocks
            // must be shrinking, and the collector must itself be freeing bytes. Otherwise, another thread
            // could be responsible for reducing the block count. On the other hand, another thread could
            // be generating a lot of garbage, which would keep us collecting. This will need even more
            // tuning to prevent starvation, etc.
            unsigned blocks_in_use;
            do {
                blocks_in_use = stats->blocks_in_use;
                auto_collect(gc_zone, AUTO_COLLECTION_FULL_COLLECTION, NULL);
                // malloc_printf("bytes freed = %ld\n", stats->bytes_freed_during_last_collection[0]);
            } while (stats->bytes_freed_during_last_collection[0] > 0 && stats->blocks_in_use < blocks_in_use);
            gc_collection_counter = 0;
        }
    }
}

void objc_collect_generation(void) 
{
    if (UseGC) {
        auto_collect(gc_zone, AUTO_COLLECTION_GENERATIONAL_COLLECTION, NULL);
    }
}


unsigned int objc_numberAllocated(void) 
{
    const auto_statistics_t *stats = auto_collection_statistics(gc_zone);
    return stats->blocks_in_use;
}


BOOL objc_isAuto(id object) 
{
    return UseGC && ISAUTOOBJECT(object) != 0;
}


BOOL objc_collecting_enabled(void) 
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
    id result = 
        (id)auto_zone_allocate_object(gc_zone, cls->instance_size + extra, 
                                      AUTO_OBJECT_SCANNED, false, true);
    result->isa = cls;
    if (RecordAllocations) record_allocation(cls);
    return result;
}


/***********************************************************************
* Write barrier exports
* Called by pretty much all GC-supporting code.
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


id objc_assign_ivar_generic(id value, id dest, unsigned int offset)
{
    if (UseGC) {
        return objc_assign_ivar_gc(value, dest, offset);
    } else {
        id *slot = (id*) ((char *)dest + offset);
        return (*slot = value);
    }
}

#if defined(__ppc__)

// PPC write barriers are in objc-auto-ppc.s
// write_barrier_init conditionally stomps those to jump to the _impl versions.

#else

// use generic implementation until time can be spent on optimizations
id objc_assign_strongCast(id value, id *dest) { return objc_assign_strongCast_generic(value, dest); }
id objc_assign_global(id value, id *dest) { return objc_assign_global_generic(value, dest); }
id objc_assign_ivar(id value, id dest, unsigned int offset) { return objc_assign_ivar_generic(value, dest, offset); }

// not defined(__ppc__)
#endif


void *objc_memmove_collectable(void *dst, const void *src, size_t size)
{
    if (UseGC) {
        return auto_zone_write_barrier_memmove(gc_zone, dst, src, size);
    } else {
        return memmove(dst, src, size);
    }
}


/***********************************************************************
* Testing tools
* Used to isolate resurrection of garbage objects during finalization.
**********************************************************************/
BOOL objc_is_finalized(void *ptr) {
    return ptr != NULL && auto_zone_is_finalized(gc_zone, ptr);
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
            unsigned int offset = (((char *)slot)-(char *)base);
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
            unsigned int offset = (((char *)slot)-(char *)base);
            auto_zone_write_barrier(gc_zone, base, offset, value);
	}
    }
    return (*slot = value);
}


/***********************************************************************
* Write barrier implementations, optimized for when GC is known to be on
* Called by the write barrier exports only.
* These implementations assume GC is on. The exported function must 
* either perform the check itself or be conditionally stomped at 
* startup time.
**********************************************************************/

__private_extern__ id objc_assign_strongCast_gc(id value, id *slot) 
{
    id base;
    
    base = (id) auto_zone_base_pointer(gc_zone, (void*)slot);
    if (base) {
        unsigned int offset = (((char *)slot)-(char *)base);
        auto_zone_write_barrier(gc_zone, base, (char*)slot - (char*)base, value);
    }
    return (*slot = value);
}


__private_extern__ id objc_assign_global_gc(id value, id *slot) 
{
    if (gc_roots_retained) {
        if (value && ISAUTOOBJECT(value)) {
            if (auto_zone_is_finalized(gc_zone, value))
                _objc_inform("GC: storing an already collected object %p into global memory at %p\n", value, slot);
            auto_zone_retain(gc_zone, value);
        }
        if (*slot && ISAUTOOBJECT(*slot)) {
            auto_zone_release(gc_zone, *slot);
        }
    } else {
        // use explicit root registration.
        if (value && ISAUTOOBJECT(value)) {
            if (auto_zone_is_finalized(gc_zone, value))
                _objc_inform("GC: storing an already collected object %p into global memory at %p\n", value, slot);
            auto_zone_add_root(gc_zone, slot, sizeof(id*));
        }
    }
    return (*slot = value);
}


__private_extern__ id objc_assign_ivar_gc(id value, id base, unsigned int offset) 
{
    id *slot = (id*) ((char *)base + offset);

    if (value) {
        if (ISAUTOOBJECT(base)) {
            auto_zone_write_barrier(gc_zone, base, offset, value);
            if (gc_zone_finalizing && (auto_zone_get_layout_type(gc_zone, value) & AUTO_OBJECT) != AUTO_OBJECT) {
                // XXX_PCB: Hack, don't allow resurrection by inhibiting assigns of garbage, non-object, pointers.
		// XXX BG: move this check into auto & institute a new policy for resurrection, to wit:
		// Resurrected Objects should go on a special list during finalization & be zombified afterwards
		// using the noisy isa-slam hack.
                if (auto_zone_is_finalized(gc_zone, value) && !auto_zone_is_finalized(gc_zone, base)) {
                    _objc_inform("GC: *** objc_assign_ivar_gc: preventing a resurrecting store of %p into %p + %d\n", value, base, offset);
                    value = nil;
                }
            }
        } else {
            _objc_inform("GC: *** objc_assign_ivar_gc: %p + %d isn't in the auto_zone.\n", base, offset);
        }
    }

    return (*slot = value);
}



/***********************************************************************
* Finalization support
* Called by auto and Foundation.
**********************************************************************/

#define USE_ISA_HACK 1
#define DO_ISA_DEBUG 0

#if USE_ISA_HACK


// NSDeallocatedObject silently ignores all messages sent to it.
@interface NSDeallocatedObject {
@public
    Class IsA;
}
+ (Class)class;
@end


static unsigned int FTCount, FTSize;
static struct FTTable {
    NSDeallocatedObject  *object;
    Class  class;
} *FTTablePtr;

/* a quick and very dirty table to map finalized pointers to their isa's */
static void addPointerFT(NSDeallocatedObject *object, Class class) {
    if (FTCount >= FTSize) {
	FTSize = 2*(FTSize + 10);
	FTTablePtr = realloc(FTTablePtr, FTSize*sizeof(struct FTTable));
    }
    FTTablePtr[FTCount].object = object;
    FTTablePtr[FTCount].class = class;
    ++FTCount;
}

static Class classForPointerFT(NSDeallocatedObject *object) {
    int i;
    for (i = 0; i < FTCount; ++i)
	if (FTTablePtr[i].object == object)
	    return FTTablePtr[i].class;
    return NULL;
}

void objc_stale(id object) {
}

@implementation NSDeallocatedObject
+ (Class)class { return self; }
- (Class)class { return classForPointerFT(self); }
- (BOOL)isKindOfClass:(Class)aClass {
    Class cls;
    for (cls = classForPointerFT(self); nil != cls; cls = cls->super_class) 
	if (cls == (Class)aClass) return YES;
    return NO;
}
+ forward:(SEL)aSelector :(marg_list)args { return nil; }
- forward:(SEL)aSelector :(marg_list)args {
    Class class = classForPointerFT(self);
    if (!class) {
	if (IsaStompBits & 0x2)
	    _objc_inform("***finalized & *recovered* object %p of being sent '%s'!!\n", self, sel_getName(aSelector));
	// if its not in the current table, then its being messaged from a STALE REFERENCE!!
	objc_stale(self);
	return nil;
    }
    if (IsaStompBits & 0x4)
	_objc_inform("finalized object %p of class %s being sent %s\n", self, class->name, sel_getName(aSelector));
    return nil;
}
@end


static Class _NSDeallocatedObject = Nil;

static IMP _NSObject_finalize = NULL;


// Handed to and then called by auto
static void sendFinalize(auto_zone_t *zone, void* ptr, void *context) 
{
    if (ptr == NULL) {
	// special signal to mark end of finalization phase
	if (IsaStompBits & 0x8)
	    _objc_inform("----finalization phase over-----");
	FTCount = 0;
	return;
    }
    
    id object = ptr;
    Class cls = object->isa;
    
    if (cls == _NSDeallocatedObject) {
        // already finalized, do nothing
        _objc_inform("sendFinalize called on NSDeallocatedObject %p", ptr);
        return;
    }
    
    IMP finalizeMethod = class_lookupMethod(cls, @selector(finalize));
    if (finalizeMethod == &_objc_msgForward) {
        _objc_inform("GC: class '%s' does not implement -finalize!", cls->name);
    }

    gc_zone_finalizing = YES;

    @try {
        // fixme later, optimize away calls to NSObject's -finalize
        (*finalizeMethod)(object, @selector(finalize));
    } @catch (id exception) {
        _objc_inform("GC: -finalize resulted in an exception being thrown %p!", exception);
        // FIXME: what about uncaught C++ exceptions? Here's an idea, define a category
        // in a .mm file, so we can catch both flavors of exceptions.
        // @interface NSObject (TryToFinalize)
        //  - (BOOL)tryToFinalize {
        //      try {
        //          @try {
        //              [self finalize];
        //          } @catch (id exception) {
        //              return NO;
        //          }
        //      } catch (...) {
        //          return NO;
        //      }
        //      return YES;
        //  }
        //  @end
    }

    gc_zone_finalizing = NO;

    if (IsaStompBits) {
	NSDeallocatedObject *dead = (NSDeallocatedObject *)object;
	// examine list of okay classes and leave alone XXX get from file
	// fixme hack: smash isa to dodge some out-of-order finalize bugs
	// the following are somewhat finalize order safe
	//if (!strcmp(dead->oldIsA->name, "NSCFArray")) return;
	//if (!strcmp(dead->oldIsA->name, "NSSortedArray")) return;
	if (IsaStompBits & 0x8)
	    printf("adding [%d] %p %s\n", FTCount, dead, dead->IsA->name);
	addPointerFT(dead, dead->IsA);
	objc_assign_ivar(_NSDeallocatedObject, dead, 0);
    }
}

static void finalizeOneObject(void *ptr, void *data) {
    id object = ptr;
    Class cls = object->isa;
    
    if (cls == _NSDeallocatedObject) {
        // already finalized, do nothing
        _objc_inform("finalizeOneObject called on NSDeallocatedObject %p", ptr);
        return;
    }
    
    IMP finalizeMethod = class_lookupMethod(cls, @selector(finalize));
    if (finalizeMethod == &_objc_msgForward) {
        _objc_inform("GC: class '%s' does not implement -finalize!", cls->name);
    }
        
    // fixme later, optimize away calls to NSObject's -finalize
    (*finalizeMethod)(object, @selector(finalize));
    
    if (IsaStompBits) {
	NSDeallocatedObject *dead = (NSDeallocatedObject *)object;
	// examine list of okay classes and leave alone XXX get from file
	// fixme hack: smash isa to dodge some out-of-order finalize bugs
	// the following are somewhat finalize order safe
	//if (!strcmp(dead->oldIsA->name, "NSCFArray")) return;
	//if (!strcmp(dead->oldIsA->name, "NSSortedArray")) return;
        if (gc_finalization_safe_classes && NXMapGet(gc_finalization_safe_classes, cls->name)) {
            // malloc_printf("&&& finalized safe instance of %s &&&\n", cls->name);
            return;
        }
	if (IsaStompBits & 0x8)
	    printf("adding [%d] %p %s\n", FTCount, dead, dead->IsA->name);
	addPointerFT(dead, dead->IsA);
	objc_assign_ivar(_NSDeallocatedObject, dead, 0);
    }
}

static void batchFinalize(auto_zone_t *zone,
                          auto_zone_foreach_object_t foreach,
                          auto_zone_cursor_t cursor)
{
    gc_zone_finalizing = YES;
    for (;;) {
        @try {
            // eventually foreach(cursor, objc_msgSend, @selector(finalize));
            // foreach(cursor, finalizeOneObject, NULL);
            foreach(cursor, objc_msgSend, @selector(finalize));
            // non-exceptional return means finalization is complete.
            break;
        } @catch (id exception) {
            _objc_inform("GC: -finalize resulted in an exception being thrown %p!", exception);
        }
    }
    gc_zone_finalizing = NO;
}

@interface NSResurrectedObject {
    @public
    Class _isa;                // [NSResurrectedObject class]
    Class _old_isa;            // original class
    unsigned _resurrections;   // how many times this object has been resurrected.
}
+ (Class)class;
@end

@implementation NSResurrectedObject
+ (Class)class { return self; }
- (Class)class { return _isa; }
+ forward:(SEL)aSelector :(marg_list)args { return nil; }
- forward:(SEL)aSelector :(marg_list)args {
    _objc_inform("**resurrected** object %p of class %s being sent message '%s'\n", self, _old_isa->name, sel_getName(aSelector));
    return nil;
}
- (void)finalize {
    _objc_inform("**resurrected** object %p of class %s being finalized\n", self, _old_isa->name);
}
@end

static Class _NSResurrectedObject;

static void resurrectZombie(auto_zone_t *zone, void *ptr) {
    NSResurrectedObject *zombie = (NSResurrectedObject*) ptr;
    if (zombie->_isa != _NSResurrectedObject) {
        Class old_isa = zombie->_isa;
        zombie->_isa = _NSResurrectedObject;
        zombie->_old_isa = old_isa;
        zombie->_resurrections = 1;
    } else {
        zombie->_resurrections++;
    }
}

/***********************************************************************
* Allocation recording
* For development purposes.
**********************************************************************/

static NXMapTable *the_histogram = NULL;
static pthread_mutex_t the_histogram_lock = PTHREAD_MUTEX_INITIALIZER;


static void record_allocation(Class cls) 
{
    pthread_mutex_lock(&the_histogram_lock);
    unsigned long count = (unsigned long) NXMapGet(the_histogram, cls);
    NXMapInsert(the_histogram, cls, (const void*) (count + 1));
    pthread_mutex_unlock(&the_histogram_lock);
}


void objc_allocation_histogram(void)
{
    Class cls;
    unsigned long count;
    NXMapState state = NXInitMapState(the_histogram);
    printf("struct histogram {\n\tconst char* name;\n\tunsigned long instance_size;\n\tunsigned long count;\n} the_histogram[] = {\n");
    while (NXNextMapState(the_histogram, &state, (const void**) &cls, (const void**) &count)) {
        printf("\t{ \"%s\", %lu, %lu },\n", cls->name, (unsigned long) cls->instance_size, count);
    }
    printf("};\n");
}

static char *name_for_address(auto_zone_t *zone, vm_address_t base, vm_address_t offset, int withRetainCount);

static char* objc_name_for_address(auto_zone_t *zone, vm_address_t base, vm_address_t offset)
{
    return name_for_address(zone, base, offset, false);
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
        // Set up the GC zone
        gc_zone = gc_zone_init();
        
        // no NSObject until Foundation calls objc_collect_init()
        _NSObject_finalize = &_objc_msgForward;
        
        // Set up allocation recording
        RecordAllocations = (getenv("OBJC_RECORD_ALLOCATIONS") != NULL);
        if (RecordAllocations) the_histogram = NXCreateMapTable(NXPtrValueMapPrototype, 1024);
        
        if (getenv("OBJC_FINALIZATION_SAFE_CLASSES")) {
            FILE *f = fopen(getenv("OBJC_FINALIZATION_SAFE_CLASSES"), "r");
            if (f != NULL) {
                char *line;
                size_t length;
                gc_finalization_safe_classes = NXCreateMapTable(NXStrValueMapPrototype, 17);
                while ((line = fgetln(f, &length)) != NULL) {
                    char *last = &line[length - 1];
                    if (*last == '\n') *last = '\0'; // strip off trailing newline.
                    char *className = strdup(line);
                    NXMapInsert(gc_finalization_safe_classes, className, className);
                }
                fclose(f);
            }
        }
    } else {
        auto_zone_start_monitor(false);
        auto_zone_set_class_list(objc_getClassList);
    }
}


static auto_zone_t *gc_zone_init(void)
{
    auto_zone_t *result;

    // result = auto_zone_create("objc auto collected zone");
    result = auto_zone(); // honor existing entry point for now (fixme)
    
    auto_collection_control_t *control = auto_collection_parameters(result);
    
    // set up the magic control parameters
    control->invalidate = sendFinalize;
    control->batch_invalidate = batchFinalize;
    control->resurrect = resurrectZombie;
    control->name_for_address = objc_name_for_address;
    
    // don't collect "on-demand" until... all Cocoa allocations are outside locks
    control->should_collect = objc_never_collect;   
    control->ask_should_collect_frequency = UINT_MAX;
    control->trace_stack_conservatively = YES;
    
    // No interruption callback yet. Foundation will install one later.
    control->collection_should_interrupt = NULL;
    
    // debug: if set, only do full generational; sometimes useful for bringup
    control->disable_generational = getenv("AUTO_DISABLE_GENERATIONAL") != NULL;
    
    // debug: always compare generational GC result to full GC garbage list
    // this *can* catch missing write-barriers and other bugs
    control->paranoid_generational = (getenv("AUTO_PARANOID_GENERATIONAL") != NULL);
    
    // if set take a slightly slower path for object allocation
    control->malloc_stack_logging = (getenv("MallocStackLogging") != NULL  ||  getenv("MallocStackLoggingNoCompact") != NULL);
    
    // logging level: none by default
    control->log = 0;
    if (getenv("AUTO_LOG_NOISY"))       control->log |= AUTO_LOG_COLLECTIONS;
    if (getenv("AUTO_LOG_ALL"))         control->log |= AUTO_LOG_ALL;
    if (getenv("AUTO_LOG_COLLECTIONS")) control->log |= AUTO_LOG_COLLECTIONS;
    if (getenv("AUTO_LOG_COLLECT_DECISION"))  control->log |= AUTO_LOG_COLLECT_DECISION;
    if (getenv("AUTO_LOG_GC_IMPL"))     control->log |= AUTO_LOG_GC_IMPL;
    if (getenv("AUTO_LOG_REGIONS"))     control->log |= AUTO_LOG_REGIONS;
    if (getenv("AUTO_LOG_UNUSUAL"))     control->log |= AUTO_LOG_UNUSUAL;
    if (getenv("AUTO_LOG_WEAK"))        control->log |= AUTO_LOG_WEAK;
    
    if (getenv("OBJC_ISA_STOMP")) {
	// != 0, stomp isa
	// 0x1, just stomp, no messages
	// 0x2, log messaging after reclaim (break on objc_stale())
	// 0x4, log messages sent during finalize
	// 0x8, log all finalizations
	IsaStompBits = strtol(getenv("OBJC_ISA_STOMP"), NULL, 0);
    }
    
    if (getenv("OBJC_COLLECTION_THRESHOLD")) {
        gc_collection_threshold = (size_t) strtoul(getenv("OBJC_COLLECTION_THRESHOLD"), NULL, 0);
    }
    
    if (getenv("OBJC_COLLECTION_RATIO")) {
        gc_collection_ratio = (size_t) strtoul(getenv("OBJC_COLLECTION_RATIO"), NULL, 0);
    }
    
    if (getenv("OBJC_EXPLICIT_ROOTS")) gc_roots_retained = NO;
    
    return result;
}


// Called by Foundation to install auto's interruption callback.
malloc_zone_t *objc_collect_init(int (*callback)(void))
{
    // Find NSObject's finalize method now that Foundation is loaded.
    // fixme only look for the base implementation, not a category's
    _NSDeallocatedObject = objc_getClass("NSDeallocatedObject");
    _NSResurrectedObject = objc_getClass("NSResurrectedObject");
    _NSObject_finalize = 
        class_lookupMethod(objc_getClass("NSObject"), @selector(finalize));
    if (_NSObject_finalize == &_objc_msgForward) {
        _objc_fatal("GC: -[NSObject finalize] unimplemented!");
    }

    // Don't install the callback if OBJC_DISABLE_COLLECTION_INTERRUPT is set
    if (gc_zone  &&  getenv("OBJC_DISABLE_COLLECTION_INTERRUPT") == NULL) {
        auto_collection_control_t *ctrl = auto_collection_parameters(gc_zone);
        ctrl->collection_should_interrupt = callback;
    }

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

static char *_malloc_append_unsigned(unsigned value, unsigned base, char *head) {
    if (!value) {
        head[0] = '0';
    } else {
        if (value >= base) head = _malloc_append_unsigned(value / base, base, head);
        value = value % base;
        head[0] = (value < 10) ? '0' + value : 'a' + value - 10;
    }
    return head+1;
}

static void strcati(char *str, unsigned value)
{
    str = _malloc_append_unsigned(value, 10, str + strlen(str));
    str[0] = '\0';
}

static void strcatx(char *str, unsigned value)
{
    str = _malloc_append_unsigned(value, 16, str + strlen(str));
    str[0] = '\0';
}


static Ivar ivar_for_offset(struct objc_class *cls, vm_address_t offset)
{
    int i;
    int ivar_offset;
    Ivar super_ivar;
    struct objc_ivar_list *ivars;

    if (!cls) return NULL;

    // scan base classes FIRST
    super_ivar = ivar_for_offset(cls->super_class, offset);
    // result is best-effort; our ivars may be closer

    ivars = cls->ivars;
    // If we have no ivars, return super's ivar
    if (!ivars  ||  ivars->ivar_count == 0) return super_ivar;

    // Try our first ivar. If it's too big, use super's best ivar.
    ivar_offset = ivars->ivar_list[0].ivar_offset;
    if (ivar_offset > offset) return super_ivar;
    else if (ivar_offset == offset) return &ivars->ivar_list[0];

    // Try our other ivars. If any is too big, use the previous.
    for (i = 1; i < ivars->ivar_count; i++) {
        int ivar_offset = ivars->ivar_list[i].ivar_offset;
        if (ivar_offset == offset) {
            return &ivars->ivar_list[i];
        } else if (ivar_offset > offset) {
            return &ivars->ivar_list[i-1];
        }
    }

    // Found nothing. Return our last ivar.
    return &ivars->ivar_list[ivars->ivar_count - 1];
}

static void append_ivar_at_offset(char *buf, struct objc_class *cls, vm_address_t offset)
{
    Ivar ivar = NULL;

    if (offset == 0) return;  // don't bother with isa
    if (offset >= cls->instance_size) {
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
    if (ivar->ivar_name) strcat(buf, ivar->ivar_name);
    else strcat(buf, "<anonymous ivar>");

    offset -= ivar->ivar_offset;
    if (offset > 0) {
        strcat(buf, "+");
        strcati(buf, offset);
    }
}


static const char *cf_class_for_object(void *cfobj)
{
    // ick - we don't link against CF anymore

    struct {
        uint32_t version;
        const char *className;
        // don't care about the rest
    } *cfcls;
    uint32_t cfid;
    NSSymbol sym;
    uint32_t (*CFGetTypeID)(void *);
    void * (*_CFRuntimeGetClassWithTypeID)(uint32_t);

    sym = NSLookupAndBindSymbolWithHint("_CFGetTypeID", "CoreFoundation");
    if (!sym) return "anonymous_NSCFType";
    CFGetTypeID = NSAddressOfSymbol(sym);
    if (!CFGetTypeID) return "NSCFType";

    sym = NSLookupAndBindSymbolWithHint("__CFRuntimeGetClassWithTypeID", "CoreFoundation");
    if (!sym) return "anonymous_NSCFType";
    _CFRuntimeGetClassWithTypeID = NSAddressOfSymbol(sym);
    if (!_CFRuntimeGetClassWithTypeID) return "anonymous_NSCFType";

    cfid = (*CFGetTypeID)(cfobj);
    cfcls = (*_CFRuntimeGetClassWithTypeID)(cfid);
    return cfcls->className;
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

    unsigned int size = 
        auto_zone_size_no_lock(zone, (void *)base);
    auto_memory_type_t type = size ? 
        auto_zone_get_layout_type_no_lock(zone, (void *)base) : AUTO_TYPE_UNKNOWN;
    unsigned int refcount = size ? 
        auto_zone_retain_count_no_lock(zone, (void *)base) : 0;

    switch (type) {
    case AUTO_OBJECT_SCANNED: 
    case AUTO_OBJECT_UNSCANNED: {
        Class cls = *(struct objc_class **)base;
        if (0 == strcmp(cls->name, "NSCFType")) {
            strcat(buf, cf_class_for_object((void *)base));
        } else {
            strcat(buf, cls->name);
        }
        if (offset) {
            append_ivar_at_offset(buf, cls, offset);
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
            for (cls = isa; cls; cls = cls->super_class) {
                if (cls == ctx->cls) {
                    unsigned int rc;
                    objc_debug_printf("[%p]    :   %s", r->address, isa->name);
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

void objc_enumerate_class(char *clsname)
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


void objc_print_references(void *referent, void *stack_bottom, int lock)
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

blob_queue blobs = {NULL, 0, 0};
blob_queue untraced_blobs = {NULL, 0, 0};
blob_queue root_blobs = {NULL, 0, 0};



static void spin(void) {    
    static char* spinner[] = {"\010\010| ", "\010\010/ ", "\010\010- ", "\010\010\\ "};
    static int spindex = 0;
 
    objc_debug_printf(spinner[spindex++]);
    if (spindex == 4) spindex = 0;
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

void objc_print_instance_roots(vm_address_t target, void *stack_bottom, int lock)
{
    objc_print_recursive_refs(target, INSTANCE_ROOTS, stack_bottom, lock);
}

void objc_print_heap_roots(vm_address_t target, void *stack_bottom, int lock)
{
    objc_print_recursive_refs(target, HEAP_ROOTS, stack_bottom, lock);
}

void objc_print_all_refs(vm_address_t target, void *stack_bottom, int lock)
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


void objc_dump_block_list(const char* path)
{
    struct objc_block_recorder_context ctx;
    char filename[] = "/tmp/blocks-XXXXX.txt";

    ctx.zone = auto_zone();
    ctx.count = 0;
    ctx.fd = (path ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666) : mkstemps(filename, strlen(strrchr(filename, '.'))));

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
    int width = 30 + strlen(name)*6;
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
    gfile = mkstemps(filename, strlen(strrchr(filename, '.')));
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

#endif



// Stubs for non-open-source libauto functions

static void auto_collect(auto_zone_t *zone, auto_collection_mode_t mode, void *collection_context)
{
}

static auto_collection_control_t *auto_collection_parameters(auto_zone_t *zone)
{
    return NULL;
}

static const auto_statistics_t *auto_collection_statistics(auto_zone_t *zone)
{
    return NULL;
}

static void auto_enumerate_references(auto_zone_t *zone, void *referent, 
                                      auto_reference_recorder_t callback, 
                                      void *stack_bottom, void *ctx)
{
}

static void auto_enumerate_references_no_lock(auto_zone_t *zone, void *referent, auto_reference_recorder_t callback, void *stack_bottom, void *ctx)
{
}

static auto_zone_t *auto_zone(void)
{
    return NULL;
}

static void auto_zone_add_root(auto_zone_t *zone, void *root, size_t size)
{
}

static void* auto_zone_allocate_object(auto_zone_t *zone, size_t size, auto_memory_type_t type, boolean_t initial_refcount_to_one, boolean_t clear)
{
    return NULL;
}

static const void *auto_zone_base_pointer(auto_zone_t *zone, const void *ptr)
{
    return NULL;
}

static auto_memory_type_t auto_zone_get_layout_type(auto_zone_t *zone, void *ptr)
{
    return 0;
}

static auto_memory_type_t auto_zone_get_layout_type_no_lock(auto_zone_t *zone, void *ptr)
{
    return 0;
}

static boolean_t auto_zone_is_finalized(auto_zone_t *zone, const void *ptr)
{
    return NO;
}

static boolean_t auto_zone_is_valid_pointer(auto_zone_t *zone, const void *ptr)
{
    return NO;
}

static unsigned int auto_zone_release(auto_zone_t *zone, void *ptr)
{
    return 0;
}

static void auto_zone_retain(auto_zone_t *zone, void *ptr)
{
}

static unsigned int auto_zone_retain_count_no_lock(auto_zone_t *zone, const void *ptr)
{
    return 0;
}

static void auto_zone_set_class_list(int (*get_class_list)(void **buffer, int count))
{
}

static size_t auto_zone_size_no_lock(auto_zone_t *zone, const void *ptr)
{
    return 0;
}

static void auto_zone_start_monitor(boolean_t force)
{
}

static void auto_zone_write_barrier(auto_zone_t *zone, void *recipient, const unsigned int offset_in_bytes, const void *new_value)
{
    *(uintptr_t *)(offset_in_bytes + (uint8_t *)recipient) = (uintptr_t)new_value;
}

static void *auto_zone_write_barrier_memmove(auto_zone_t *zone, void *dst, const void *src, size_t size)
{
    return memmove(dst, src, size);
}

