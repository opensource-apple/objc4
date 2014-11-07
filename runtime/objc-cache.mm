/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-cache.m
* Method cache management
* Cache flushing
* Cache garbage collection
* Cache instrumentation
* Dedicated allocator for large caches
**********************************************************************/


/***********************************************************************
 * Method cache locking (GrP 2001-1-14)
 *
 * For speed, objc_msgSend does not acquire any locks when it reads 
 * method caches. Instead, all cache changes are performed so that any 
 * objc_msgSend running concurrently with the cache mutator will not 
 * crash or hang or get an incorrect result from the cache. 
 *
 * When cache memory becomes unused (e.g. the old cache after cache 
 * expansion), it is not immediately freed, because a concurrent 
 * objc_msgSend could still be using it. Instead, the memory is 
 * disconnected from the data structures and placed on a garbage list. 
 * The memory is now only accessible to instances of objc_msgSend that 
 * were running when the memory was disconnected; any further calls to 
 * objc_msgSend will not see the garbage memory because the other data 
 * structures don't point to it anymore. The collecting_in_critical
 * function checks the PC of all threads and returns FALSE when all threads 
 * are found to be outside objc_msgSend. This means any call to objc_msgSend 
 * that could have had access to the garbage has finished or moved past the 
 * cache lookup stage, so it is safe to free the memory.
 *
 * All functions that modify cache data or structures must acquire the 
 * cacheUpdateLock to prevent interference from concurrent modifications.
 * The function that frees cache garbage must acquire the cacheUpdateLock 
 * and use collecting_in_critical() to flush out cache readers.
 * The cacheUpdateLock is also used to protect the custom allocator used 
 * for large method cache blocks.
 *
 * Cache readers (PC-checked by collecting_in_critical())
 * objc_msgSend*
 * cache_getImp
 * cache_getMethod
 *
 * Cache writers (hold cacheUpdateLock while reading or writing; not PC-checked)
 * cache_fill         (acquires lock)
 * cache_expand       (only called from cache_fill)
 * cache_create       (only called from cache_expand)
 * bcopy               (only called from instrumented cache_expand)
 * flush_caches        (acquires lock)
 * cache_flush        (only called from cache_fill and flush_caches)
 * cache_collect_free (only called from cache_expand and cache_flush)
 *
 * UNPROTECTED cache readers (NOT thread-safe; used for debug info only)
 * cache_print
 * _class_printMethodCaches
 * _class_printDuplicateCacheEntries
 * _class_printMethodCacheStatistics
 *
 * _class_lookupMethodAndLoadCache is a special case. It may read a 
 * method triplet out of one cache and store it in another cache. This 
 * is unsafe if the method triplet is a forward:: entry, because the 
 * triplet itself could be freed unless _class_lookupMethodAndLoadCache 
 * were PC-checked or used a lock. Additionally, storing the method 
 * triplet in both caches would result in double-freeing if both caches 
 * were flushed or expanded. The solution is for cache_getMethod to 
 * ignore all entries whose implementation is _objc_msgForward_impcache, 
 * so _class_lookupMethodAndLoadCache cannot look at a forward:: entry
 * unsafely or place it in multiple caches.
 ***********************************************************************/


#if __OBJC2__

#include "objc-private.h"
#include "objc-cache.h"


/* Initial cache bucket count. INIT_CACHE_SIZE must be a power of two. */
enum {
    INIT_CACHE_SIZE_LOG2 = 2,
    INIT_CACHE_SIZE      = (1 << INIT_CACHE_SIZE_LOG2)
};

static size_t log2u(size_t x)
{
    unsigned int log;

    log = 0;
    while (x >>= 1)
        log += 1;

    return log;
}

static void cache_collect_free(struct bucket_t *data, size_t size);
static int _collecting_in_critical(void);
static void _garbage_make_room(void);


/***********************************************************************
* Cache statistics for OBJC_PRINT_CACHE_SETUP
**********************************************************************/
static unsigned int cache_counts[16];
static size_t cache_allocations;
static size_t cache_collections;


/***********************************************************************
* Pointers used by compiled class objects
* These use asm to avoid conflicts with the compiler's internal declarations
**********************************************************************/

// "cache" is cache->buckets; "vtable" is cache->mask/occupied
// hack to avoid conflicts with compiler's internal declaration
asm("\n .section __TEXT,__const"
    "\n .globl __objc_empty_cache"
#if __LP64__
    "\n .align 3"
    "\n __objc_empty_cache: .quad 0"
#else
    "\n .align 2"
    "\n __objc_empty_cache: .long 0"
#endif
    "\n .globl __objc_empty_vtable"
    "\n .set __objc_empty_vtable, 0"
    );


#if __i386__  ||  __arm__
// objc_msgSend has few registers available.
// Cache scan increments and wraps at special end-marking bucket.
#define CACHE_END_MARKER 1
static inline mask_t cache_next(mask_t i, mask_t mask) {
    return (i+1) & mask;
}

#elif __x86_64__
// objc_msgSend has lots of registers and/or memory operands available.
// Cache scan decrements. No end marker needed.
#define CACHE_END_MARKER 0
static inline mask_t cache_next(mask_t i, mask_t mask) {
    return i ? i-1 : mask;
}

#else
#error unknown architecture
#endif


// cannot mix sel-side caches with ignored selector constant
// ignored selector constant also not implemented for class-side caches here
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
#error sorry
#endif


// copied from dispatch_atomic_maximally_synchronizing_barrier
// fixme verify that this barrier hack does in fact work here
#if __x86_64__
#define mega_barrier() \
    do { unsigned long _clbr; __asm__ __volatile__( \
        "cpuid" \
        : "=a" (_clbr) : "0" (0) : "rbx", "rcx", "rdx", "cc", "memory" \
                                                    ); } while(0)
#elif __i386__
#define mega_barrier() \
    do { unsigned long _clbr; __asm__ __volatile__( \
        "cpuid" \
        : "=a" (_clbr) : "0" (0) : "ebx", "ecx", "edx", "cc", "memory" \
                                                    ); } while(0)
#elif __arm__
#define mega_barrier() \
    __asm__ __volatile__( \
        "dsb    ish" \
        : : : "memory")
#else
#error unknown architecture
#endif


static inline mask_t cache_hash(cache_key_t key, mask_t mask) 
{
    return (mask_t)((key >> MASK_SHIFT) & mask);
}


// Class points to cache. Cache buckets store SEL+IMP.
cache_t *getCache(Class cls, SEL sel __unused) 
{
    assert(cls);
    return &cls->cache;
}
cache_key_t getKey(Class cls __unused, SEL sel) 
{
    assert(sel);
    return (cache_key_t)sel;
}


struct bucket_t {
    cache_key_t key;
    IMP imp;

    void set(cache_key_t newKey, IMP newImp)
    {
        // objc_msgSend uses key and imp with no locks.
        // It is safe for objc_msgSend to see new imp but NULL key
        // (It will get a cache miss but not dispatch to the wrong place.)
        // It is unsafe for objc_msgSend to see old imp and new key.
        // Therefore we write new imp, wait a lot, then write new key.

        assert(key == 0  ||  key == newKey);
        
        imp = newImp;

        if (key != newKey) {
            mega_barrier();
            key = newKey;
        }
    }
};


void cache_t::reallocate(mask_t oldCapacity, mask_t newCapacity)
{
    if (PrintCaches) {
        size_t bucket = log2u(newCapacity);
        if (bucket < sizeof(cache_counts) / sizeof(cache_counts[0])) {
            cache_counts[bucket]++;
        }
        cache_allocations++;
        
        if (oldCapacity) {
            bucket = log2u(oldCapacity);
            if (bucket < sizeof(cache_counts) / sizeof(cache_counts[0])) {
                cache_counts[bucket]--;
            }
        }
    }
    
    // objc_msgSend uses shiftmask and buckets with no locks.
    // It is safe for objc_msgSend to see new buckets but old shiftmask.
    // (It will get a cache miss but not overrun the buckets' bounds).
    // It is unsafe for objc_msgSend to see old buckets and new shiftmask.
    // Therefore we write new buckets, wait a lot, then write new shiftmask.
    // objc_msgSend reads shiftmask first, then buckets.

    bucket_t *oldBuckets = buckets;
    
#if CACHE_END_MARKER
    // Allocate one extra bucket to mark the end of the list.
    // fixme instead put the end mark inline when +1 is malloc-inefficient
    bucket_t *newBuckets = 
        (bucket_t *)_calloc_internal(newCapacity + 1, sizeof(bucket_t));
    
    // End marker's key is 1 and imp points to the first bucket.
    newBuckets[newCapacity].key = (cache_key_t)(uintptr_t)1;
# if __arm__
    // Point before the first bucket instead to save an instruction in msgSend
    newBuckets[newCapacity].imp = (IMP)(newBuckets - 1);
# else
    newBuckets[newCapacity].imp = (IMP)newBuckets;
# endif
#else
    bucket_t *newBuckets = 
        (bucket_t *)_calloc_internal(newCapacity, sizeof(bucket_t));
#endif
    
    // Cache's old contents are not propagated. 
    // This is thought to save cache memory at the cost of extra cache fills.
    // fixme re-measure this
    
    // ensure other threads see buckets contents before buckets pointer
    mega_barrier();
    
    buckets = newBuckets;
    
    // ensure other threads see new buckets before new shiftmask
    mega_barrier();
    
    setCapacity(newCapacity);
    occupied = 0;
    
    if (oldCapacity > 0) {
        cache_collect_free(oldBuckets, oldCapacity * sizeof(bucket_t));
        cache_collect(false);
    }
}


// called by objc_msgSend
extern "C" 
void objc_msgSend_corrupt_cache_error(id receiver, SEL sel, Class isa, 
                                      bucket_t *bucket)
{
    cache_t::bad_cache(receiver, sel, isa, bucket);
}

extern "C" 
void cache_getImp_corrupt_cache_error(id receiver, SEL sel, Class isa, 
                                      bucket_t *bucket)
{
    cache_t::bad_cache(receiver, sel, isa, bucket);
}

void cache_t::bad_cache(id receiver, SEL sel, Class isa, bucket_t *bucket)
{
    // Log in separate steps in case the logging itself causes a crash.
    _objc_inform_now_and_on_crash
        ("Method cache corrupted. This may be a message to an "
         "invalid object, or a memory error somewhere else.");
    cache_t *cache = &isa->cache;
    _objc_inform_now_and_on_crash
        ("%s %p, SEL %p, isa %p, cache %p, buckets %p, "
         "mask 0x%x, occupied 0x%x, wrap bucket %p", 
         receiver ? "receiver" : "unused", receiver, 
         sel, isa, cache, cache->buckets, 
         cache->shiftmask >> MASK_SHIFT, cache->occupied, bucket);
    _objc_inform_now_and_on_crash
        ("%s %zu bytes, buckets %zu bytes", 
         receiver ? "receiver" : "unused", malloc_size(receiver), 
         malloc_size(cache->buckets));
    _objc_inform_now_and_on_crash
        ("selector '%s'", sel_getName(sel));
    _objc_inform_now_and_on_crash
        ("isa '%s'", isa->getName());
    _objc_fatal
        ("Method cache corrupted.");
}


bucket_t * cache_t::find(cache_key_t k)
{
    mask_t m = mask();
    mask_t begin = cache_hash(k, m);
    mask_t i = begin;
    do {
        if (buckets[i].key == 0  ||  buckets[i].key == k) {
            return &buckets[i];
        }
    } while ((i = cache_next(i, m)) != begin);

    // hack
    Class cls = (Class)((uintptr_t)this - offsetof(objc_class, cache));
    cache_t::bad_cache(nil, (SEL)k, cls, nil);
}


void cache_t::expand()
{
    mutex_assert_locked(&cacheUpdateLock);
    
    mask_t oldCapacity = capacity();
    mask_t newCapacity = oldCapacity ? oldCapacity*2 : INIT_CACHE_SIZE;

    if ((((newCapacity-1) << MASK_SHIFT) >> MASK_SHIFT) != newCapacity-1) {
        // shiftmask overflow - can't grow further
        newCapacity = oldCapacity;
    }

    reallocate(oldCapacity, newCapacity);
}


static void cache_fill_nolock(Class cls, SEL sel, IMP imp)
{
    mutex_assert_locked(&cacheUpdateLock);

    // Never cache before +initialize is done
    if (!cls->isInitialized()) return;

    // Make sure the entry wasn't added to the cache by some other thread 
    // before we grabbed the cacheUpdateLock.
    if (cache_getImp(cls, sel)) return;

    cache_t *cache = getCache(cls, sel);
    cache_key_t key = getKey(cls, sel);

    // Use the cache as-is if it is less than 3/4 full
    mask_t newOccupied = cache->occupied + 1;
    if ((newOccupied * 4) <= (cache->mask() + 1) * 3) {
        // Cache is less than 3/4 full.
    } else {
        // Cache is too full. Expand it.
        cache->expand();
    }

    // Scan for the first unused slot (or used for this class) and insert there
    // There is guaranteed to be an empty slot because the 
    // minimum size is 4 and we resized at 3/4 full.
    bucket_t *bucket = cache->find(key);
    if (bucket->key == 0) cache->occupied++;
    bucket->set(key, imp);
}

void cache_fill(Class cls, SEL sel, IMP imp)
{
#if !DEBUG_TASK_THREADS
    mutex_lock(&cacheUpdateLock);
    cache_fill_nolock(cls, sel, imp);
    mutex_unlock(&cacheUpdateLock);
#else
    _collecting_in_critical();
    return;
#endif
}


// Reset any entry for cls/sel to the uncached lookup
static void cache_eraseMethod_nolock(Class cls, SEL sel)
{
    mutex_assert_locked(&cacheUpdateLock);

    cache_t *cache = getCache(cls, sel);
    cache_key_t key = getKey(cls, sel);

    bucket_t *bucket = cache->find(key);
    if (bucket->key == key) {
        bucket->imp = _objc_msgSend_uncached_impcache;
    }
}


// Resets cache entries for all methods in mlist for cls and its subclasses.
void cache_eraseMethods(Class cls, method_list_t *mlist)
{
    rwlock_assert_writing(&runtimeLock);
    mutex_lock(&cacheUpdateLock);

    FOREACH_REALIZED_CLASS_AND_SUBCLASS(c, cls, {
        for (uint32_t m = 0; m < mlist->count; m++) {
            SEL sel = mlist->get(m).name;
            cache_eraseMethod_nolock(c, sel);
        }
    });

    mutex_unlock(&cacheUpdateLock);
}


// Reset any copies of imp in this cache to the uncached lookup
void cache_eraseImp_nolock(Class cls, SEL sel, IMP imp)
{
    mutex_assert_locked(&cacheUpdateLock);

    cache_t *cache = getCache(cls, sel);

    bucket_t *buckets = cache->buckets;
    mask_t count = cache->capacity();
    for (mask_t i = 0; i < count; i++) {
        if (buckets[i].imp == imp) {
            buckets[i].imp = _objc_msgSend_uncached_impcache;
        }
    }
}


void cache_eraseImp(Class cls, SEL sel, IMP imp) 
{
    mutex_lock(&cacheUpdateLock);
    cache_eraseImp_nolock(cls, sel, imp);
    mutex_unlock(&cacheUpdateLock);
}


// Reset this entire cache to the uncached lookup by reallocating it.
// This must not shrink the cache - that breaks the lock-free scheme.
void cache_erase_nolock(cache_t *cache)
{
    mutex_assert_locked(&cacheUpdateLock);

    mask_t capacity = cache->capacity();
    if (capacity > 0  &&  cache->occupied > 0) {
        cache->reallocate(capacity, capacity);
    }
}


/***********************************************************************
* cache collection.
**********************************************************************/

#if !TARGET_OS_WIN32

// A sentinel (magic value) to report bad thread_get_state status.
// Must not be a valid PC.
// Must not be zero - thread_get_state() on a new thread returns PC == 0.
#define PC_SENTINEL  1

static uintptr_t _get_pc_for_thread(thread_t thread)
#if defined(__i386__)
{
    i386_thread_state_t state;
    unsigned int count = i386_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, i386_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__eip : PC_SENTINEL;
}
#elif defined(__x86_64__)
{
    x86_thread_state64_t			state;
    unsigned int count = x86_THREAD_STATE64_COUNT;
    kern_return_t okay = thread_get_state (thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__rip : PC_SENTINEL;
}
#elif defined(__arm__)
{
    arm_thread_state_t state;
    unsigned int count = ARM_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, ARM_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.__pc : PC_SENTINEL;
}
#else
{
#error _get_pc_for_thread () not implemented for this architecture
}
#endif

#endif

/***********************************************************************
* _collecting_in_critical.
* Returns TRUE if some thread is currently executing a cache-reading 
* function. Collection of cache garbage is not allowed when a cache-
* reading function is in progress because it might still be using 
* the garbage memory.
**********************************************************************/
OBJC_EXPORT uintptr_t objc_entryPoints[];
OBJC_EXPORT uintptr_t objc_exitPoints[];

static int _collecting_in_critical(void)
{
#if TARGET_OS_WIN32
    return TRUE;
#else
    thread_act_port_array_t threads;
    unsigned number;
    unsigned count;
    kern_return_t ret;
    int result;

    mach_port_t mythread = pthread_mach_thread_np(pthread_self());

    // Get a list of all the threads in the current task
#if !DEBUG_TASK_THREADS
    ret = task_threads(mach_task_self(), &threads, &number);
#else
    ret = objc_task_threads(mach_task_self(), &threads, &number);
#endif

    if (ret != KERN_SUCCESS) {
        // See DEBUG_TASK_THREADS below to help debug this.
        _objc_fatal("task_threads failed (result 0x%x)\n", ret);
    }

    // Check whether any thread is in the cache lookup code
    result = FALSE;
    for (count = 0; count < number; count++)
    {
        int region;
        uintptr_t pc;

        // Don't bother checking ourselves
        if (threads[count] == mythread)
            continue;

        // Find out where thread is executing
        pc = _get_pc_for_thread (threads[count]);

        // Check for bad status, and if so, assume the worse (can't collect)
        if (pc == PC_SENTINEL)
        {
            result = TRUE;
            goto done;
        }
        
        // Check whether it is in the cache lookup code
        for (region = 0; objc_entryPoints[region] != 0; region++)
        {
            if ((pc >= objc_entryPoints[region]) &&
                (pc <= objc_exitPoints[region])) 
            {
                result = TRUE;
                goto done;
            }
        }
    }

 done:
    // Deallocate the port rights for the threads
    for (count = 0; count < number; count++) {
        mach_port_deallocate(mach_task_self (), threads[count]);
    }

    // Deallocate the thread list
    vm_deallocate (mach_task_self (), (vm_address_t) threads, sizeof(threads[0]) * number);

    // Return our finding
    return result;
#endif
}


/***********************************************************************
* _garbage_make_room.  Ensure that there is enough room for at least
* one more ref in the garbage.
**********************************************************************/

// amount of memory represented by all refs in the garbage
static size_t garbage_byte_size = 0;

// do not empty the garbage until garbage_byte_size gets at least this big
static size_t garbage_threshold = 32*1024;

// table of refs to free
static bucket_t **garbage_refs = 0;

// current number of refs in garbage_refs
static size_t garbage_count = 0;

// capacity of current garbage_refs
static size_t garbage_max = 0;

// capacity of initial garbage_refs
enum {
    INIT_GARBAGE_COUNT = 128
};

static void _garbage_make_room(void)
{
    static int first = 1;

    // Create the collection table the first time it is needed
    if (first)
    {
        first = 0;
        garbage_refs = (bucket_t**)
            _malloc_internal(INIT_GARBAGE_COUNT * sizeof(void *));
        garbage_max = INIT_GARBAGE_COUNT;
    }

    // Double the table if it is full
    else if (garbage_count == garbage_max)
    {
        garbage_refs = (bucket_t**)
            _realloc_internal(garbage_refs, garbage_max * 2 * sizeof(void *));
        garbage_max *= 2;
    }
}


/***********************************************************************
* cache_collect_free.  Add the specified malloc'd memory to the list
* of them to free at some later point.
* size is used for the collection threshold. It does not have to be 
* precisely the block's size.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static void cache_collect_free(bucket_t *data, size_t size)
{
    mutex_assert_locked(&cacheUpdateLock);

    _garbage_make_room ();
    garbage_byte_size += size;
    garbage_refs[garbage_count++] = data;
}


/***********************************************************************
* cache_collect.  Try to free accumulated dead caches.
* collectALot tries harder to free memory.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
void cache_collect(bool collectALot)
{
    mutex_assert_locked(&cacheUpdateLock);

    // Done if the garbage is not full
    if (garbage_byte_size < garbage_threshold  &&  !collectALot) {
        return;
    }

    // Synchronize collection with objc_msgSend and other cache readers
    if (!collectALot) {
        if (_collecting_in_critical ()) {
            // objc_msgSend (or other cache reader) is currently looking in
            // the cache and might still be using some garbage.
            if (PrintCaches) {
                _objc_inform ("CACHES: not collecting; "
                              "objc_msgSend in progress");
            }
            return;
        }
    } 
    else {
        // No excuses.
        while (_collecting_in_critical()) 
            ;
    }

    // No cache readers in progress - garbage is now deletable

    // Log our progress
    if (PrintCaches) {
        cache_collections++;
        _objc_inform ("CACHES: COLLECTING %zu bytes (%zu allocations, %zu collections)", garbage_byte_size, cache_allocations, cache_collections);
    }
    
    // Dispose all refs now in the garbage
    while (garbage_count--) {
        free(garbage_refs[garbage_count]);
    }
    
    // Clear the garbage count and total size indicator
    garbage_count = 0;
    garbage_byte_size = 0;

    if (PrintCaches) {
        size_t i;
        size_t total_count = 0;
        size_t total_size = 0;

        for (i = 0; i < sizeof(cache_counts) / sizeof(cache_counts[0]); i++) {
            int count = cache_counts[i];
            int slots = 1 << i;
            size_t size = count * slots * sizeof(bucket_t);

            if (!count) continue;

            _objc_inform("CACHES: %4d slots: %4d caches, %6zu bytes", 
                         slots, count, size);

            total_count += count;
            total_size += size;
        }

        _objc_inform("CACHES:      total: %4zu caches, %6zu bytes", 
                     total_count, total_size);
    }
}


/***********************************************************************
* objc_task_threads
* Replacement for task_threads(). Define DEBUG_TASK_THREADS to debug 
* crashes when task_threads() is failing.
*
* A failure in task_threads() usually means somebody has botched their 
* Mach or MIG traffic. For example, somebody's error handling was wrong 
* and they left a message queued on the MIG reply port for task_threads() 
* to trip over.
*
* The code below is a modified version of task_threads(). It logs 
* the msgh_id of the reply message. The msgh_id can identify the sender 
* of the message, which can help pinpoint the faulty code.
* DEBUG_TASK_THREADS also calls collecting_in_critical() during every 
* message dispatch, which can increase reproducibility of bugs.
*
* This code can be regenerated by running 
* `mig /usr/include/mach/task.defs`.
**********************************************************************/
#if DEBUG_TASK_THREADS

#include <mach/mach.h>
#include <mach/message.h>
#include <mach/mig.h>

#define __MIG_check__Reply__task_subsystem__ 1
#define mig_internal static inline
#define __DeclareSendRpc(a, b)
#define __BeforeSendRpc(a, b)
#define __AfterSendRpc(a, b)
#define msgh_request_port       msgh_remote_port
#define msgh_reply_port         msgh_local_port

#ifndef __MachMsgErrorWithTimeout
#define __MachMsgErrorWithTimeout(_R_) { \
        switch (_R_) { \
        case MACH_SEND_INVALID_DATA: \
        case MACH_SEND_INVALID_DEST: \
        case MACH_SEND_INVALID_HEADER: \
            mig_put_reply_port(InP->Head.msgh_reply_port); \
            break; \
        case MACH_SEND_TIMED_OUT: \
        case MACH_RCV_TIMED_OUT: \
        default: \
            mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
        } \
    }
#endif  /* __MachMsgErrorWithTimeout */

#ifndef __MachMsgErrorWithoutTimeout
#define __MachMsgErrorWithoutTimeout(_R_) { \
        switch (_R_) { \
        case MACH_SEND_INVALID_DATA: \
        case MACH_SEND_INVALID_DEST: \
        case MACH_SEND_INVALID_HEADER: \
            mig_put_reply_port(InP->Head.msgh_reply_port); \
            break; \
        default: \
            mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
        } \
    }
#endif  /* __MachMsgErrorWithoutTimeout */


#if ( __MigTypeCheck )
#if __MIG_check__Reply__task_subsystem__
#if !defined(__MIG_check__Reply__task_threads_t__defined)
#define __MIG_check__Reply__task_threads_t__defined

mig_internal kern_return_t __MIG_check__Reply__task_threads_t(__Reply__task_threads_t *Out0P)
{

	typedef __Reply__task_threads_t __Reply;
	boolean_t msgh_simple;
#if	__MigTypeCheck
	unsigned int msgh_size;
#endif	/* __MigTypeCheck */
	if (Out0P->Head.msgh_id != 3502) {
	    if (Out0P->Head.msgh_id == MACH_NOTIFY_SEND_ONCE)
		{ return MIG_SERVER_DIED; }
	    else
		{ return MIG_REPLY_MISMATCH; }
	}

	msgh_simple = !(Out0P->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX);
#if	__MigTypeCheck
	msgh_size = Out0P->Head.msgh_size;

	if ((msgh_simple || Out0P->msgh_body.msgh_descriptor_count != 1 ||
	    msgh_size != (mach_msg_size_t)sizeof(__Reply)) &&
	    (!msgh_simple || msgh_size != (mach_msg_size_t)sizeof(mig_reply_error_t) ||
	    ((mig_reply_error_t *)Out0P)->RetCode == KERN_SUCCESS))
		{ return MIG_TYPE_ERROR ; }
#endif	/* __MigTypeCheck */

	if (msgh_simple) {
		return ((mig_reply_error_t *)Out0P)->RetCode;
	}

#if	__MigTypeCheck
	if (Out0P->act_list.type != MACH_MSG_OOL_PORTS_DESCRIPTOR ||
	    Out0P->act_list.disposition != 17) {
		return MIG_TYPE_ERROR;
	}
#endif	/* __MigTypeCheck */

	return MACH_MSG_SUCCESS;
}
#endif /* !defined(__MIG_check__Reply__task_threads_t__defined) */
#endif /* __MIG_check__Reply__task_subsystem__ */
#endif /* ( __MigTypeCheck ) */


/* Routine task_threads */
static kern_return_t objc_task_threads
(
	task_t target_task,
	thread_act_array_t *act_list,
	mach_msg_type_number_t *act_listCnt
)
{

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
	} Request;
#ifdef  __MigPackStructs
#pragma pack()
#endif

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		/* start of the kernel processed data */
		mach_msg_body_t msgh_body;
		mach_msg_ool_ports_descriptor_t act_list;
		/* end of the kernel processed data */
		NDR_record_t NDR;
		mach_msg_type_number_t act_listCnt;
		mach_msg_trailer_t trailer;
	} Reply;
#ifdef  __MigPackStructs
#pragma pack()
#endif

#ifdef  __MigPackStructs
#pragma pack(4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		/* start of the kernel processed data */
		mach_msg_body_t msgh_body;
		mach_msg_ool_ports_descriptor_t act_list;
		/* end of the kernel processed data */
		NDR_record_t NDR;
		mach_msg_type_number_t act_listCnt;
	} __Reply;
#ifdef  __MigPackStructs
#pragma pack()
#endif
	/*
	 * typedef struct {
	 * 	mach_msg_header_t Head;
	 * 	NDR_record_t NDR;
	 * 	kern_return_t RetCode;
	 * } mig_reply_error_t;
	 */

	union {
		Request In;
		Reply Out;
	} Mess;

	Request *InP = &Mess.In;
	Reply *Out0P = &Mess.Out;

	mach_msg_return_t msg_result;

#ifdef	__MIG_check__Reply__task_threads_t__defined
	kern_return_t check_result;
#endif	/* __MIG_check__Reply__task_threads_t__defined */

	__DeclareSendRpc(3402, "task_threads")

	InP->Head.msgh_bits =
		MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	/* msgh_size passed as argument */
	InP->Head.msgh_request_port = target_task;
	InP->Head.msgh_reply_port = mig_get_reply_port();
	InP->Head.msgh_id = 3402;

	__BeforeSendRpc(3402, "task_threads")
	msg_result = mach_msg(&InP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, (mach_msg_size_t)sizeof(Request), (mach_msg_size_t)sizeof(Reply), InP->Head.msgh_reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	__AfterSendRpc(3402, "task_threads")
	if (msg_result != MACH_MSG_SUCCESS) {
		_objc_inform("task_threads received unexpected reply msgh_id 0x%zx", 
                             (size_t)Out0P->Head.msgh_id);
		__MachMsgErrorWithoutTimeout(msg_result);
		{ return msg_result; }
	}


#if	defined(__MIG_check__Reply__task_threads_t__defined)
	check_result = __MIG_check__Reply__task_threads_t((__Reply__task_threads_t *)Out0P);
	if (check_result != MACH_MSG_SUCCESS)
		{ return check_result; }
#endif	/* defined(__MIG_check__Reply__task_threads_t__defined) */

	*act_list = (thread_act_array_t)(Out0P->act_list.address);
	*act_listCnt = Out0P->act_listCnt;

	return KERN_SUCCESS;
}

// DEBUG_TASK_THREADS
#endif


// __OBJC2__
#endif
