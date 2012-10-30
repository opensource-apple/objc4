/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
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
*	objc-class.m
*	Copyright 1988-1997, Apple Computer, Inc.
*	Author:	s. naroff
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
 * _cache_getImp
 * _cache_getMethod
 *
 * Cache writers (hold cacheUpdateLock while reading or writing; not PC-checked)
 * _cache_fill         (acquires lock)
 * _cache_expand       (only called from cache_fill)
 * _cache_create       (only called from cache_expand)
 * bcopy               (only called from instrumented cache_expand)
 * flush_caches        (acquires lock)
 * _cache_flush        (only called from cache_fill and flush_caches)
 * _cache_collect_free (only called from cache_expand and cache_flush)
 *
 * UNPROTECTED cache readers (NOT thread-safe; used for debug info only)
 * _cache_print
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
 * were flushed or expanded. The solution is for _cache_getMethod to 
 * ignore all entries whose implementation is _objc_msgForward, so 
 * _class_lookupMethodAndLoadCache cannot look at a forward:: entry
 * unsafely or place it in multiple caches.
 ***********************************************************************/

/***********************************************************************
 * Lazy method list arrays and method list locking  (2004-10-19)
 * 
 * cls->methodLists may be in one of three forms:
 * 1. NULL: The class has no methods.
 * 2. non-NULL, with CLS_NO_METHOD_ARRAY set: cls->methodLists points 
 *    to a single method list, which is the class's only method list.
 * 3. non-NULL, with CLS_NO_METHOD_ARRAY clear: cls->methodLists points to 
 *    an array of method list pointers. The end of the array's block 
 *    is set to -1. If the actual number of method lists is smaller 
 *    than that, the rest of the array is NULL.
 * 
 * Attaching categories and adding and removing classes may change 
 * the form of the class list. In addition, individual method lists 
 * may be reallocated when fixed up.
 *
 * Classes are initially read as #1 or #2. If a category is attached 
 * or other methods added, the class is changed to #3. Once in form #3, 
 * the class is never downgraded to #1 or #2, even if methods are removed.
 * Classes added with objc_addClass are initially either #1 or #3.
 * 
 * Accessing and manipulating a class's method lists are synchronized, 
 * to prevent races when one thread restructures the list. However, 
 * if the class is not yet in use (i.e. not in class_hash), then the 
 * thread loading the class may access its method lists without locking.
 * 
 * The following functions acquire methodListLock:
 * class_getInstanceMethod
 * class_getClassMethod
 * class_nextMethodList
 * class_addMethods
 * class_removeMethods
 * class_respondsToMethod
 * _class_lookupMethodAndLoadCache
 * lookupMethodInClassAndLoadCache
 * _objc_add_category_flush_caches
 *
 * The following functions don't acquire methodListLock because they 
 * only access method lists during class load and unload:
 * _objc_register_category
 * _resolve_categories_for_class (calls _objc_add_category)
 * add_class_to_loadable_list
 * _objc_addClass
 * _objc_remove_classes_in_image
 *
 * The following functions use method lists without holding methodListLock.
 * The caller must either hold methodListLock, or be loading the class.
 * _getMethod (called by class_getInstanceMethod, class_getClassMethod, 
 *   and class_respondsToMethod)
 * _findMethodInClass (called by _class_lookupMethodAndLoadCache, 
 *   lookupMethodInClassAndLoadCache, _getMethod)
 * _findMethodInList (called by _findMethodInClass)
 * nextMethodList (called by _findMethodInClass and class_nextMethodList
 * fixupSelectorsInMethodList (called by nextMethodList)
 * _objc_add_category (called by _objc_add_category_flush_caches, 
 *   resolve_categories_for_class and _objc_register_category)
 * _objc_insertMethods (called by class_addMethods and _objc_add_category)
 * _objc_removeMethods (called by class_removeMethods)
 * _objcTweakMethodListPointerForClass (called by _objc_insertMethods)
 * get_base_method_list (called by add_class_to_loadable_list)
 * lookupNamedMethodInMethodList (called by add_class_to_loadable_list)
 ***********************************************************************/

/***********************************************************************
 * Thread-safety of class info bits  (2004-10-19)
 * 
 * Some class info bits are used to store mutable runtime state. 
 * Modifications of the info bits at particular times need to be 
 * synchronized to prevent races.
 * 
 * Three thread-safe modification functions are provided:
 * _class_setInfo()     // atomically sets some bits
 * _class_clearInfo()   // atomically clears some bits
 * _class_changeInfo()  // atomically sets some bits and clears others
 * These replace CLS_SETINFO() for the multithreaded cases.
 * 
 * Three modification windows are defined:
 * - compile time
 * - class construction or image load (before +load) in one thread
 * - multi-threaded messaging and method caches
 * 
 * Info bit modification at compile time and class construction do not 
 *   need to be locked, because only one thread is manipulating the class.
 * Info bit modification during messaging needs to be locked, because 
 *   there may be other threads simultaneously messaging or otherwise 
 *   manipulating the class.
 *   
 * Modification windows for each flag:
 * 
 * CLS_CLASS: compile-time and class load
 * CLS_META: compile-time and class load
 * CLS_INITIALIZED: +initialize
 * CLS_POSING: messaging
 * CLS_MAPPED: compile-time
 * CLS_FLUSH_CACHE: messaging
 * CLS_GROW_CACHE: messaging
 * CLS_NEED_BIND: unused
 * CLS_METHOD_ARRAY: unused
 * CLS_JAVA_HYBRID: JavaBridge only
 * CLS_JAVA_CLASS: JavaBridge only
 * CLS_INITIALIZING: messaging
 * CLS_FROM_BUNDLE: class load
 * CLS_HAS_CXX_STRUCTORS: compile-time and class load
 * CLS_NO_METHOD_ARRAY: class load and messaging
 * CLS_HAS_LOAD_METHOD: class load
 * 
 * CLS_INITIALIZED and CLS_INITIALIZING have additional thread-safety 
 * constraints to support thread-safe +initialize. See "Thread safety 
 * during class initialization" for details.
 * 
 * CLS_JAVA_HYBRID and CLS_JAVA_CLASS are set immediately after JavaBridge 
 * calls objc_addClass(). The JavaBridge does not use an atomic update, 
 * but the modification counts as "class construction" unless some other 
 * thread quickly finds the class via the class list. This race is 
 * small and unlikely in well-behaved code.
 *
 * Most info bits that may be modified during messaging are also never 
 * read without a lock. There is no general read lock for the info bits.
 * CLS_INITIALIZED: classInitLock
 * CLS_FLUSH_CACHE: cacheUpdateLock
 * CLS_GROW_CACHE: cacheUpdateLock
 * CLS_NO_METHOD_ARRAY: methodListLock
 * CLS_INITIALIZING: classInitLock
 ***********************************************************************/

/***********************************************************************
 * Thread-safety during class initialization (GrP 2001-9-24)
 *
 * Initial state: CLS_INITIALIZING and CLS_INITIALIZED both clear. 
 * During initialization: CLS_INITIALIZING is set
 * After initialization: CLS_INITIALIZING clear and CLS_INITIALIZED set.
 * CLS_INITIALIZING and CLS_INITIALIZED are never set at the same time.
 * CLS_INITIALIZED is never cleared once set.
 *
 * Only one thread is allowed to actually initialize a class and send 
 * +initialize. Enforced by allowing only one thread to set CLS_INITIALIZING.
 *
 * Additionally, threads trying to send messages to a class must wait for 
 * +initialize to finish. During initialization of a class, that class's 
 * method cache is kept empty. objc_msgSend will revert to 
 * class_lookupMethodAndLoadCache, which checks CLS_INITIALIZED before 
 * messaging. If CLS_INITIALIZED is clear but CLS_INITIALIZING is set, 
 * the thread must block, unless it is the thread that started 
 * initializing the class in the first place. 
 *
 * Each thread keeps a list of classes it's initializing. 
 * The global classInitLock is used to synchronize changes to CLS_INITIALIZED 
 * and CLS_INITIALIZING: the transition to CLS_INITIALIZING must be 
 * an atomic test-and-set with respect to itself and the transition 
 * to CLS_INITIALIZED.
 * The global classInitWaitCond is used to block threads waiting for an 
 * initialization to complete. The classInitLock synchronizes
 * condition checking and the condition variable.
 **********************************************************************/

/***********************************************************************
 *  +initialize deadlock case when a class is marked initializing while 
 *  its superclass is initialized. Solved by completely initializing 
 *  superclasses before beginning to initialize a class.
 *
 *  OmniWeb class hierarchy:
 *                 OBObject 
 *                     |    ` OBPostLoader
 *                 OFObject
 *                 /     \
 *      OWAddressEntry  OWController
 *                        | 
 *                      OWConsoleController
 *
 *  Thread 1 (evil testing thread):
 *    initialize OWAddressEntry
 *    super init OFObject
 *    super init OBObject		     
 *    [OBObject initialize] runs OBPostLoader, which inits lots of classes...
 *    initialize OWConsoleController
 *    super init OWController - wait for Thread 2 to finish OWController init
 *
 *  Thread 2 (normal OmniWeb thread):
 *    initialize OWController
 *    super init OFObject - wait for Thread 1 to finish OFObject init
 *
 *  deadlock!
 *
 *  Solution: fully initialize super classes before beginning to initialize 
 *  a subclass. Then the initializing+initialized part of the class hierarchy
 *  will be a contiguous subtree starting at the root, so other threads 
 *  can't jump into the middle between two initializing classes, and we won't 
 *  get stuck while a superclass waits for its subclass which waits for the 
 *  superclass.
 **********************************************************************/



/***********************************************************************
* Imports.
**********************************************************************/

#import <mach/mach_interface.h>
#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>

#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/uio.h>
#include <sys/fcntl.h>

#import "objc-class.h"

#import <objc/Object.h>
#import <objc/objc-runtime.h>
#import "objc-private.h"
#import "hashtable2.h"
#import "maptable.h"

#include <sys/types.h>

// Needed functions not in any header file
size_t malloc_size (const void * ptr);

// Needed kernel interface
#import <mach/mach.h>
#import <mach/thread_status.h>


/***********************************************************************
* Conditionals.
**********************************************************************/

// Define PRELOAD_SUPERCLASS_CACHES to cause method lookups to add the
// method the appropriate superclass caches, in addition to the normal
// encaching in the subclass where the method was messaged.  Doing so
// will speed up messaging the same method from instances of the
// superclasses, but also uses up valuable cache space for a speculative
// purpose
// See radar 2364264 about incorrectly propogating _objc_forward entries
// and double freeing them, first, before turning this on!
// (Radar 2364264 is now "inactive".)
// Double-freeing is also a potential problem when this is off. See 
// note about _class_lookupMethodAndLoadCache in "Method cache locking".
//#define PRELOAD_SUPERCLASS_CACHES

/***********************************************************************
* Exports.
**********************************************************************/

#ifdef OBJC_INSTRUMENTED
enum {
    CACHE_HISTOGRAM_SIZE	= 512
};

unsigned int	CacheHitHistogram [CACHE_HISTOGRAM_SIZE];
unsigned int	CacheMissHistogram [CACHE_HISTOGRAM_SIZE];
#endif

/***********************************************************************
* Constants and macros internal to this module.
**********************************************************************/

// INIT_CACHE_SIZE and INIT_META_CACHE_SIZE must be a power of two
enum {
    INIT_CACHE_SIZE_LOG2		= 2,
    INIT_META_CACHE_SIZE_LOG2	= 2,
    INIT_CACHE_SIZE			= (1 << INIT_CACHE_SIZE_LOG2),
    INIT_META_CACHE_SIZE		= (1 << INIT_META_CACHE_SIZE_LOG2)
};

// Amount of space required for count hash table buckets, knowing that
// one entry is embedded in the cache structure itself
#define TABLE_SIZE(count)	((count - 1) * sizeof(Method))

// A sentinal (magic value) to report bad thread_get_state status
#define PC_SENTINAL             0


/***********************************************************************
* Types internal to this module.
**********************************************************************/

#ifdef OBJC_INSTRUMENTED
struct CacheInstrumentation
{
    unsigned int	hitCount;		// cache lookup success tally
    unsigned int	hitProbes;		// sum entries checked to hit
    unsigned int	maxHitProbes;		// max entries checked to hit
    unsigned int	missCount;		// cache lookup no-find tally
    unsigned int	missProbes;		// sum entries checked to miss
    unsigned int	maxMissProbes;		// max entries checked to miss
    unsigned int	flushCount;		// cache flush tally
    unsigned int	flushedEntries;		// sum cache entries flushed
    unsigned int	maxFlushedEntries;	// max cache entries flushed
};
typedef struct CacheInstrumentation	CacheInstrumentation;

// Cache instrumentation data follows table, so it is most compatible
#define CACHE_INSTRUMENTATION(cache)	(CacheInstrumentation *) &cache->buckets[cache->mask + 1];
#endif

/***********************************************************************
* Function prototypes internal to this module.
**********************************************************************/

static Ivar		class_getVariable		(Class cls, const char * name);
static void		flush_caches			(Class cls, BOOL flush_meta);
static struct objc_method_list *nextMethodList(struct objc_class *cls, void **it);
static void		addClassToOriginalClass	(Class posingClass, Class originalClass);
static void		_objc_addOrigClass		(Class origClass);
static void		_freedHandler			(id self, SEL sel);
static void		_nonexistentHandler		(id self, SEL sel);
static void             class_initialize                (Class cls);
static Cache	_cache_expand			(Class cls);
static int		LogObjCMessageSend		(BOOL isClassMethod, const char * objectsClass, const char * implementingClass, SEL selector);
static BOOL		_cache_fill				(Class cls, Method smt, SEL sel);
static void _cache_addForwardEntry(Class cls, SEL sel);
static void		_cache_flush			(Class cls);
static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);
static int		SubtypeUntil			(const char * type, char end);
static const char *	SkipFirstType		(const char * type);

static unsigned long	_get_pc_for_thread	(mach_port_t thread);
static int		_collecting_in_critical	(void);
static void		_garbage_make_room		(void);
static void		_cache_collect_free		(void * data, size_t size, BOOL tryCollect);

static BOOL cache_allocator_is_block(void *block);
static void *cache_allocator_calloc(size_t size);
static void cache_allocator_free(void *block);

static void		_cache_print			(Cache cache);
static unsigned int	log2				(unsigned int x);
static void		PrintCacheHeader		(void);
#ifdef OBJC_INSTRUMENTED
static void		PrintCacheHistogram		(char * title, unsigned int * firstEntry, unsigned int entryCount);
#endif

/***********************************************************************
* Static data internal to this module.
**********************************************************************/

// When _class_uncache is non-zero, cache growth copies the existing
// entries into the new (larger) cache.  When this flag is zero, new
// (larger) caches start out empty.
static int	_class_uncache		= 1;

// When _class_slow_grow is non-zero, any given cache is actually grown
// only on the odd-numbered times it becomes full; on the even-numbered
// times, it is simply emptied and re-used.  When this flag is zero,
// caches are grown every time.
static int	_class_slow_grow	= 1;

// Lock for cache access.
// Held when modifying a cache in place.
// Held when installing a new cache on a class. 
// Held when adding to the cache garbage list.
// Held when disposing cache garbage.
// See "Method cache locking" above for notes about cache locking.
static OBJC_DECLARE_LOCK(cacheUpdateLock);

// classInitLock protects classInitWaitCond and examination and modification 
// of CLS_INITIALIZED and CLS_INITIALIZING.
OBJC_DECLARE_LOCK(classInitLock);
// classInitWaitCond is signalled when any class is done initializing. 
// Threads that are waiting for a class to finish initializing wait on this.
pthread_cond_t classInitWaitCond = PTHREAD_COND_INITIALIZER;

// Lock for method list access and modification.
// Protects methodLists fields, method arrays, and CLS_NO_METHOD_ARRAY bits.
// Classes not yet in use do not need to take this lock.
OBJC_DECLARE_LOCK(methodListLock);

// When traceDuplicates is non-zero, _cacheFill checks whether the method
// being encached is already there.  The number of times it finds a match
// is tallied in cacheFillDuplicates.  When traceDuplicatesVerbose is
// non-zero, each duplication is logged when found in this way.
static int	traceDuplicates		= 0;
static int	traceDuplicatesVerbose	= 0;
static int	cacheFillDuplicates	= 0;

// Custom cache allocator parameters
// CACHE_REGION_SIZE must be a multiple of CACHE_QUANTUM.
#define CACHE_QUANTUM 520
#define CACHE_REGION_SIZE 131040  // quantized just under 128KB (131072)
// #define CACHE_REGION_SIZE 262080  // quantized just under 256KB (262144)

#ifdef OBJC_INSTRUMENTED
// Instrumentation
static unsigned int	LinearFlushCachesCount			= 0;
static unsigned int	LinearFlushCachesVisitedCount		= 0;
static unsigned int	MaxLinearFlushCachesVisitedCount	= 0;
static unsigned int	NonlinearFlushCachesCount		= 0;
static unsigned int	NonlinearFlushCachesClassCount		= 0;
static unsigned int	NonlinearFlushCachesVisitedCount	= 0;
static unsigned int	MaxNonlinearFlushCachesVisitedCount	= 0;
static unsigned int	IdealFlushCachesCount			= 0;
static unsigned int	MaxIdealFlushCachesCount		= 0;
#endif

// Method call logging
typedef int	(*ObjCLogProc)(BOOL, const char *, const char *, SEL);

static int totalCacheFills NOBSS = 0;
static int			objcMsgLogFD		= (-1);
static ObjCLogProc	objcMsgLogProc		= &LogObjCMessageSend;
static int			objcMsgLogEnabled	= 0;

// Error Messages
static const char
_errNoMem[]					= "failed -- out of memory(%s, %u)",
_errAllocNil[]				= "allocating nil object",
_errFreedObject[]			= "message %s sent to freed object=0x%lx",
_errNonExistentObject[]		= "message %s sent to non-existent object=0x%lx",
_errBadSel[]				= "invalid selector %s",
_errNotSuper[]				= "[%s poseAs:%s]: target not immediate superclass",
_errNewVars[]				= "[%s poseAs:%s]: %s defines new instance variables";

/***********************************************************************
* Information about multi-thread support:
*
* Since we do not lock many operations which walk the superclass, method
* and ivar chains, these chains must remain intact once a class is published
* by inserting it into the class hashtable.  All modifications must be
* atomic so that someone walking these chains will always geta valid
* result.
***********************************************************************/
/***********************************************************************
* A static empty cache.  All classes initially point at this cache.
* When the first message is sent it misses in the cache, and when
* the cache is grown it checks for this case and uses malloc rather
* than realloc.  This avoids the need to check for NULL caches in the
* messenger.
***********************************************************************/

#ifndef OBJC_INSTRUMENTED
const struct objc_cache		emptyCache =
{
    0,				// mask
    0,				// occupied
    { NULL }			// buckets
};
#else
// OBJC_INSTRUMENTED requires writable data immediately following emptyCache.
struct objc_cache		emptyCache =
{
    0,				// mask
    0,				// occupied
    { NULL }			// buckets
};
CacheInstrumentation emptyCacheInstrumentation = {0};
#endif


// Freed objects have their isa set to point to this dummy class.
// This avoids the need to check for Nil classes in the messenger.
static const struct objc_class freedObjectClass =
{
    Nil,				// isa
    Nil,				// super_class
    "FREED(id)",			// name
    0,				// version
    0,				// info
    0,				// instance_size
    NULL,				// ivars
    NULL,				// methodLists
    (Cache) &emptyCache,		// cache
    NULL				// protocols
};

static const struct objc_class nonexistentObjectClass =
{
    Nil,				// isa
    Nil,				// super_class
    "NONEXISTENT(id)",		// name
    0,				// version
    0,				// info
    0,				// instance_size
    NULL,				// ivars
    NULL,				// methodLists
    (Cache) &emptyCache,		// cache
    NULL				// protocols
};

/***********************************************************************
* object_getClassName.
**********************************************************************/
const char *	object_getClassName		   (id		obj)
{
    // Even nil objects have a class name, sort of
    if (obj == nil)
        return "nil";

    // Retrieve name from object's class
    return ((struct objc_class *) obj->isa)->name;
}

/***********************************************************************
* object_getIndexedIvars.
**********************************************************************/
void *		object_getIndexedIvars		   (id		obj)
{
    // ivars are tacked onto the end of the object
    return ((char *) obj) + ((struct objc_class *) obj->isa)->instance_size;
}


/***********************************************************************
* object_cxxDestructFromClass.
* Call C++ destructors on obj, starting with cls's 
*   dtor method (if any) followed by superclasses' dtors (if any), 
*   stopping at cls's dtor (if any).
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
static void object_cxxDestructFromClass(id obj, Class cls)
{
    void (*dtor)(id);

    // Call cls's dtor first, then superclasses's dtors.

    for ( ; cls != NULL; cls = cls->super_class) {
        if (!(cls->info & CLS_HAS_CXX_STRUCTORS)) continue; 
        dtor = (void(*)(id))
            lookupMethodInClassAndLoadCache(cls, cxx_destruct_sel);
        if (dtor != (void(*)(id))&_objc_msgForward) {
            if (PrintCxxCtors) {
                _objc_inform("CXX: calling C++ destructors for class %s", 
                             cls->name);
            }
            (*dtor)(obj);
        }
    }
}


/***********************************************************************
* object_cxxDestruct.
* Call C++ destructors on obj, if any.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
void object_cxxDestruct(id obj)
{
    if (!obj) return;
    object_cxxDestructFromClass(obj, obj->isa);
}


/***********************************************************************
* object_cxxConstructFromClass.
* Recursively call C++ constructors on obj, starting with base class's 
*   ctor method (if any) followed by subclasses' ctors (if any), stopping 
*   at cls's ctor (if any).
* Returns YES if construction succeeded.
* Returns NO if some constructor threw an exception. The exception is 
*   caught and discarded. Any partial construction is destructed.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
*
* .cxx_construct returns id. This really means:
* return self: construction succeeded
* return nil:  construction failed because a C++ constructor threw an exception
**********************************************************************/
static BOOL object_cxxConstructFromClass(id obj, Class cls)
{
    id (*ctor)(id);

    // Call superclasses' ctors first, if any.
    if (cls->super_class) {
        BOOL ok = object_cxxConstructFromClass(obj, cls->super_class);
        if (!ok) return NO;  // some superclass's ctor failed - give up
    }

    // Find this class's ctor, if any.
    if (!(cls->info & CLS_HAS_CXX_STRUCTORS)) return YES;  // no ctor - ok
    ctor = (id(*)(id))lookupMethodInClassAndLoadCache(cls, cxx_construct_sel);
    if (ctor == (id(*)(id))&_objc_msgForward) return YES;  // no ctor - ok
    
    // Call this class's ctor.
    if (PrintCxxCtors) {
        _objc_inform("CXX: calling C++ constructors for class %s", cls->name);
    }
    if ((*ctor)(obj)) return YES;  // ctor called and succeeded - ok

    // This class's ctor was called and failed. 
    // Call superclasses's dtors to clean up.
    if (cls->super_class) object_cxxDestructFromClass(obj, cls->super_class);
    return NO;
}


/***********************************************************************
* object_cxxConstructFromClass.
* Call C++ constructors on obj, if any.
* Returns YES if construction succeeded.
* Returns NO if some constructor threw an exception. The exception is 
*   caught and discarded. Any partial construction is destructed.
* Uses methodListLock and cacheUpdateLock. The caller must hold neither.
**********************************************************************/
BOOL object_cxxConstruct(id obj)
{
    if (!obj) return YES;
    return object_cxxConstructFromClass(obj, obj->isa);
}


/***********************************************************************
* _internal_class_createInstanceFromZone.  Allocate an instance of the
* specified class with the specified number of bytes for indexed
* variables, in the specified zone.  The isa field is set to the
* class, C++ default constructors are called, and all other fields are zeroed.
**********************************************************************/
static id	_internal_class_createInstanceFromZone (Class		aClass,
                                                  unsigned	nIvarBytes,
                                                  void *	z)
{
    id			obj;
    register unsigned	byteCount;

    // Can't create something for nothing
    if (aClass == Nil)
    {
        __objc_error ((id) aClass, _errAllocNil, 0);
        return nil;
    }

    // Allocate and initialize
    byteCount = ((struct objc_class *) aClass)->instance_size + nIvarBytes;
    obj = (id) malloc_zone_calloc (z, 1, byteCount);
    if (!obj)
    {
        __objc_error ((id) aClass, _errNoMem, ((struct objc_class *) aClass)->name, nIvarBytes);
        return nil;
    }

    // Set the isa pointer
    obj->isa = aClass;

    // Call C++ constructors, if any.
    if (!object_cxxConstruct(obj)) {
        // Some C++ constructor threw an exception. 
        malloc_zone_free(z, obj);
        return nil;
    }

    return obj;
}

/***********************************************************************
* _internal_class_createInstance.  Allocate an instance of the specified
* class with the specified number of bytes for indexed variables, in
* the default zone, using _internal_class_createInstanceFromZone.
**********************************************************************/
static id	_internal_class_createInstance	       (Class		aClass,
                                                 unsigned	nIvarBytes)
{
    return _internal_class_createInstanceFromZone (aClass,
                                                   nIvarBytes,
                                                   malloc_default_zone ());
}

id (*_poseAs)() = (id (*)())class_poseAs;
id (*_alloc)(Class, unsigned) = _internal_class_createInstance;
id (*_zoneAlloc)(Class, unsigned, void *) = _internal_class_createInstanceFromZone;

/***********************************************************************
* class_createInstanceFromZone.  Allocate an instance of the specified
* class with the specified number of bytes for indexed variables, in
* the specified zone, using _zoneAlloc.
**********************************************************************/
id	class_createInstanceFromZone   (Class		aClass,
                                   unsigned	nIvarBytes,
                                   void *	z)
{
    // _zoneAlloc can be overridden, but is initially set to
    // _internal_class_createInstanceFromZone
    return (*_zoneAlloc) (aClass, nIvarBytes, z);
}

/***********************************************************************
* class_createInstance.  Allocate an instance of the specified class with
* the specified number of bytes for indexed variables, using _alloc.
**********************************************************************/
id	class_createInstance	       (Class		aClass,
                                unsigned	nIvarBytes)
{
    // _alloc can be overridden, but is initially set to
    // _internal_class_createInstance
    return (*_alloc) (aClass, nIvarBytes);
}

/***********************************************************************
* class_setVersion.  Record the specified version with the class.
**********************************************************************/
void	class_setVersion	       (Class		aClass,
                              int		version)
{
    ((struct objc_class *) aClass)->version = version;
}

/***********************************************************************
* class_getVersion.  Return the version recorded with the class.
**********************************************************************/
int	class_getVersion	       (Class		aClass)
{
    return ((struct objc_class *) aClass)->version;
}


static inline Method _findNamedMethodInList(struct objc_method_list * mlist, const char *meth_name) {
    int i;
    if (!mlist) return NULL;
    for (i = 0; i < mlist->method_count; i++) {
        Method m = &mlist->method_list[i];
        if (*((const char *)m->method_name) == *meth_name && 0 == strcmp((const char *)(m->method_name), meth_name)) {
            return m;
        }
    }
    return NULL;
}


/***********************************************************************
* fixupSelectorsInMethodList
* Uniques selectors in the given method list.
* The given method list must be non-NULL and not already fixed-up.
* If the class was loaded from a bundle:
*   fixes up the given list in place with heap-allocated selector strings
* If the class was not from a bundle:
*   allocates a copy of the method list, fixes up the copy, and returns 
*   the copy. The given list is unmodified.
*
* If cls is already in use, methodListLock must be held by the caller.
**********************************************************************/
// Fixed-up method lists get mlist->obsolete = _OBJC_FIXED_UP.
#define _OBJC_FIXED_UP ((void *)1771)

static struct objc_method_list *fixupSelectorsInMethodList(Class cls, struct objc_method_list *mlist)
{
    unsigned i, size;
    Method method;
    struct objc_method_list *old_mlist; 
    
    if ( ! mlist ) return (struct objc_method_list *)0;
    if ( mlist->obsolete != _OBJC_FIXED_UP ) {
        BOOL isBundle = CLS_GETINFO(cls, CLS_FROM_BUNDLE) ? YES : NO;
        if (!isBundle) {
            old_mlist = mlist;
            size = sizeof(struct objc_method_list) - sizeof(struct objc_method) + old_mlist->method_count * sizeof(struct objc_method);
            mlist = _malloc_internal(size);
            memmove(mlist, old_mlist, size);
        } else {
            // Mach-O bundles are fixed up in place. 
            // This prevents leaks when a bundle is unloaded.
        }
        sel_lock();
        for ( i = 0; i < mlist->method_count; i += 1 ) {
            method = &mlist->method_list[i];
            method->method_name =
                sel_registerNameNoLock((const char *)method->method_name, isBundle);  // Always copy selector data from bundles.
        }
        sel_unlock();
        mlist->obsolete = _OBJC_FIXED_UP;
    }
    return mlist;
}


/***********************************************************************
* nextMethodList
* Returns successive method lists from the given class.
* Method lists are returned in method search order (i.e. highest-priority 
* implementations first).
* All necessary method list fixups are performed, so the 
* returned method list is fully-constructed.
*
* If cls is already in use, methodListLock must be held by the caller.
* For full thread-safety, methodListLock must be continuously held by the 
* caller across all calls to nextMethodList(). If the lock is released, 
* the bad results listed in class_nextMethodList() may occur.
*
* void *iterator = NULL;
* struct objc_method_list *mlist;
* OBJC_LOCK(&methodListLock);
* while ((mlist = nextMethodList(cls, &iterator))) {
*     // do something with mlist
* }
* OBJC_UNLOCK(&methodListLock);
**********************************************************************/
static struct objc_method_list *nextMethodList(struct objc_class *cls,
                                               void **it)
{
    uintptr_t index = *(uintptr_t *)it;
    struct objc_method_list **resultp;

    if (index == 0) {
        // First call to nextMethodList.
        if (!cls->methodLists) {
            resultp = NULL;
        } else if (cls->info & CLS_NO_METHOD_ARRAY) {
            resultp = (struct objc_method_list **)&cls->methodLists;
        } else {
            resultp = &cls->methodLists[0];
            if (!*resultp  ||  *resultp == END_OF_METHODS_LIST) {
                resultp = NULL;
            }
        }
    } else {
        // Subsequent call to nextMethodList.
        if (!cls->methodLists) {
            resultp = NULL;
        } else if (cls->info & CLS_NO_METHOD_ARRAY) {
            resultp = NULL;
        } else {
            resultp = &cls->methodLists[index];
            if (!*resultp  ||  *resultp == END_OF_METHODS_LIST) {
                resultp = NULL;
            }
        }
    }

    // resultp now is NULL, meaning there are no more method lists, 
    // OR the address of the method list pointer to fix up and return.
    
    if (resultp) {
        if (*resultp  &&  (*resultp)->obsolete != _OBJC_FIXED_UP) {
            *resultp = fixupSelectorsInMethodList(cls, *resultp);
        }
        *it = (void *)(index + 1);
        return *resultp;
    } else {
        *it = 0;
        return NULL;
    }
}


/* These next three functions are the heart of ObjC method lookup. 
 * If the class is currently in use, methodListLock must be held by the caller.
 */
static inline Method _findMethodInList(struct objc_method_list * mlist, SEL sel) {
    int i;
    if (!mlist) return NULL;
    for (i = 0; i < mlist->method_count; i++) {
        Method m = &mlist->method_list[i];
        if (m->method_name == sel) {
            return m;
        }
    }
    return NULL;
}

static inline Method _findMethodInClass(Class cls, SEL sel) __attribute__((always_inline));
static inline Method _findMethodInClass(Class cls, SEL sel) {
    // Flattened version of nextMethodList(). The optimizer doesn't 
    // do a good job with hoisting the conditionals out of the loop.
    // Conceptually, this looks like:
    // while ((mlist = nextMethodList(cls, &iterator))) {
    //     Method m = _findMethodInList(mlist, sel);
    //     if (m) return m;
    // }

    if (!cls->methodLists) {
        // No method lists.
        return NULL;
    }
    else if (cls->info & CLS_NO_METHOD_ARRAY) {
        // One method list.
        struct objc_method_list **mlistp;
        mlistp = (struct objc_method_list **)&cls->methodLists;
        if ((*mlistp)->obsolete != _OBJC_FIXED_UP) {
            *mlistp = fixupSelectorsInMethodList(cls, *mlistp);
        }
        return _findMethodInList(*mlistp, sel);
    }
    else {
        // Multiple method lists.
        struct objc_method_list **mlistp;
        for (mlistp = cls->methodLists; 
             *mlistp != NULL  &&  *mlistp != END_OF_METHODS_LIST; 
             mlistp++) 
        {
            Method m;
            if ((*mlistp)->obsolete != _OBJC_FIXED_UP) {
                *mlistp = fixupSelectorsInMethodList(cls, *mlistp);
            }
            m = _findMethodInList(*mlistp, sel);
            if (m) return m;
        }
        return NULL;
    }
}

static inline Method _getMethod(Class cls, SEL sel) {
    for (; cls; cls = cls->super_class) {
        Method m;
        m = _findMethodInClass(cls, sel);
        if (m) return m;
    }
    return NULL;
}


// fixme for gc debugging temporary use
__private_extern__ IMP findIMPInClass(Class cls, SEL sel)
{
    Method m = _findMethodInClass(cls, sel);
    if (m) return m->method_imp;
    else return NULL;
}

/***********************************************************************
* class_getInstanceMethod.  Return the instance method for the
* specified class and selector.
**********************************************************************/
Method		class_getInstanceMethod	       (Class		aClass,
                                        SEL		aSelector)
{
    Method result;

    // Need both a class and a selector
    if (!aClass || !aSelector)
        return NULL;

    // Go to the class
    OBJC_LOCK(&methodListLock);
    result = _getMethod (aClass, aSelector);
    OBJC_UNLOCK(&methodListLock);
    return result;
}

/***********************************************************************
* class_getClassMethod.  Return the class method for the specified
* class and selector.
**********************************************************************/
Method		class_getClassMethod	       (Class		aClass,
                                     SEL		aSelector)
{
    Method result;

    // Need both a class and a selector
    if (!aClass || !aSelector)
        return NULL;

    // Go to the class or isa
    OBJC_LOCK(&methodListLock);
    result = _getMethod (GETMETA(aClass), aSelector);
    OBJC_UNLOCK(&methodListLock);
    return result;
}

/***********************************************************************
* class_getVariable.  Return the named instance variable.
**********************************************************************/
static Ivar	class_getVariable	       (Class		cls,
                                      const char *	name)
{
    struct objc_class *	thisCls;

    // Outer loop - search the class and its superclasses
    for (thisCls = cls; thisCls != Nil; thisCls = ((struct objc_class *) thisCls)->super_class)
    {
        int	index;
        Ivar	thisIvar;

        // Skip class having no ivars
        if (!thisCls->ivars)
            continue;

        // Inner loop - search the given class
        thisIvar = &thisCls->ivars->ivar_list[0];
        for (index = 0; index < thisCls->ivars->ivar_count; index += 1)
        {
            // Check this ivar's name.  Be careful because the
            // compiler generates ivar entries with NULL ivar_name
            // (e.g. for anonymous bit fields).
            if ((thisIvar->ivar_name) &&
                (strcmp (name, thisIvar->ivar_name) == 0))
                return thisIvar;

            // Move to next ivar
            thisIvar += 1;
        }
    }

    // Not found
    return NULL;
}

/***********************************************************************
* class_getInstanceVariable.  Return the named instance variable.
*
* Someday add class_getClassVariable ().
**********************************************************************/
Ivar	class_getInstanceVariable	       (Class		aClass,
                                       const char *	name)
{
    // Must have a class and a name
    if (!aClass || !name)
        return NULL;

    // Look it up
    return class_getVariable (aClass, name);
}

/***********************************************************************
* flush_caches.  Flush the instance and optionally class method caches
* of cls and all its subclasses.
*
* Specifying Nil for the class "all classes."
**********************************************************************/
static void flush_caches(Class cls, BOOL flush_meta)
{
    int		numClasses = 0, newNumClasses;
    struct objc_class * *		classes = NULL;
    int		i;
    struct objc_class *		clsObject;
#ifdef OBJC_INSTRUMENTED
    unsigned int	classesVisited;
    unsigned int	subclassCount;
#endif

    // Do nothing if class has no cache
    // This check is safe to do without any cache locks.
    if (cls && !((struct objc_class *) cls)->cache)
        return;

    newNumClasses = objc_getClassList((Class *)NULL, 0);
    while (numClasses < newNumClasses) {
        numClasses = newNumClasses;
        classes = _realloc_internal(classes, sizeof(Class) * numClasses);
        newNumClasses = objc_getClassList((Class *)classes, numClasses);
    }
    numClasses = newNumClasses;

    OBJC_LOCK(&cacheUpdateLock);

    // Handle nil and root instance class specially: flush all
    // instance and class method caches.  Nice that this
    // loop is linear vs the N-squared loop just below.
    if (!cls || !((struct objc_class *) cls)->super_class)
    {
#ifdef OBJC_INSTRUMENTED
        LinearFlushCachesCount += 1;
        classesVisited = 0;
        subclassCount = 0;
#endif
        // Traverse all classes in the hash table
        for (i = 0; i < numClasses; i++)
        {
            struct objc_class *		metaClsObject;
#ifdef OBJC_INSTRUMENTED
            classesVisited += 1;
#endif
            clsObject = classes[i];

            // Skip class that is known not to be a subclass of this root
            // (the isa pointer of any meta class points to the meta class
            // of the root).
            // NOTE: When is an isa pointer of a hash tabled class ever nil?
            metaClsObject = clsObject->isa;
            if (cls  &&  metaClsObject  &&  cls->isa != metaClsObject->isa)
            {
                continue;
            }

#ifdef OBJC_INSTRUMENTED
            subclassCount += 1;
#endif

            _cache_flush (clsObject);
            if (flush_meta  &&  metaClsObject != NULL) {
                _cache_flush (metaClsObject);
            }
        }
#ifdef OBJC_INSTRUMENTED
        LinearFlushCachesVisitedCount += classesVisited;
        if (classesVisited > MaxLinearFlushCachesVisitedCount)
            MaxLinearFlushCachesVisitedCount = classesVisited;
        IdealFlushCachesCount += subclassCount;
        if (subclassCount > MaxIdealFlushCachesCount)
            MaxIdealFlushCachesCount = subclassCount;
#endif

        OBJC_UNLOCK(&cacheUpdateLock);
        _free_internal(classes);
        return;
    }

    // Outer loop - flush any cache that could now get a method from
    // cls (i.e. the cache associated with cls and any of its subclasses).
#ifdef OBJC_INSTRUMENTED
    NonlinearFlushCachesCount += 1;
    classesVisited = 0;
    subclassCount = 0;
#endif
    for (i = 0; i < numClasses; i++)
    {
        struct objc_class *		clsIter;

#ifdef OBJC_INSTRUMENTED
        NonlinearFlushCachesClassCount += 1;
#endif
        clsObject = classes[i];

        // Inner loop - Process a given class
        clsIter = clsObject;
        while (clsIter)
        {

#ifdef OBJC_INSTRUMENTED
            classesVisited += 1;
#endif
            // Flush clsObject instance method cache if
            // clsObject is a subclass of cls, or is cls itself
            // Flush the class method cache if that was asked for
            if (clsIter == cls)
            {
#ifdef OBJC_INSTRUMENTED
                subclassCount += 1;
#endif
                _cache_flush (clsObject);
                if (flush_meta)
                    _cache_flush (clsObject->isa);

                break;

            }

            // Flush clsObject class method cache if cls is
            // the meta class of clsObject or of one
            // of clsObject's superclasses
            else if (clsIter->isa == cls)
            {
#ifdef OBJC_INSTRUMENTED
                subclassCount += 1;
#endif
                _cache_flush (clsObject->isa);
                break;
            }

            // Move up superclass chain
            else if (ISINITIALIZED(clsIter))
                clsIter = clsIter->super_class;

            // clsIter is not initialized, so its cache
            // must be empty.  This happens only when
            // clsIter == clsObject, because
            // superclasses are initialized before
            // subclasses, and this loop traverses
            // from sub- to super- classes.
            else
                break;
        }
    }
#ifdef OBJC_INSTRUMENTED
    NonlinearFlushCachesVisitedCount += classesVisited;
    if (classesVisited > MaxNonlinearFlushCachesVisitedCount)
        MaxNonlinearFlushCachesVisitedCount = classesVisited;
    IdealFlushCachesCount += subclassCount;
    if (subclassCount > MaxIdealFlushCachesCount)
        MaxIdealFlushCachesCount = subclassCount;
#endif

    OBJC_UNLOCK(&cacheUpdateLock);
    _free_internal(classes);
}

/***********************************************************************
* _objc_flush_caches.  Flush the caches of the specified class and any
* of its subclasses.  If cls is a meta-class, only meta-class (i.e.
* class method) caches are flushed.  If cls is an instance-class, both
* instance-class and meta-class caches are flushed.
**********************************************************************/
void		_objc_flush_caches	       (Class		cls)
{
    flush_caches (cls, YES);
}

/***********************************************************************
* do_not_remove_this_dummy_function.
**********************************************************************/
void		do_not_remove_this_dummy_function	   (void)
{
    (void) class_nextMethodList (NULL, NULL);
}


/***********************************************************************
* class_nextMethodList.
* External version of nextMethodList().
*
* This function is not fully thread-safe. A series of calls to 
* class_nextMethodList() may fail if methods are added to or removed 
* from the class between calls.
* If methods are added between calls to class_nextMethodList(), it may 
* return previously-returned method lists again, and may fail to return 
* newly-added lists. 
* If methods are removed between calls to class_nextMethodList(), it may 
* omit surviving method lists or simply crash.
**********************************************************************/
OBJC_EXPORT struct objc_method_list * class_nextMethodList (Class	cls,
                                                            void **	it)
{
    struct objc_method_list *result;
    OBJC_LOCK(&methodListLock);
    result = nextMethodList(cls, it);
    OBJC_UNLOCK(&methodListLock);
    return result;
}

/***********************************************************************
* _dummy.
**********************************************************************/
void		_dummy		   (void)
{
    (void) class_nextMethodList (Nil, NULL);
}

/***********************************************************************
* class_addMethods.
*
* Formerly class_addInstanceMethods ()
**********************************************************************/
void	class_addMethods       (Class				cls,
                             struct objc_method_list *	meths)
{
    // Add the methods.
    OBJC_LOCK(&methodListLock);
    _objc_insertMethods(cls, meths);
    OBJC_UNLOCK(&methodListLock);

    // Must flush when dynamically adding methods.  No need to flush
    // all the class method caches.  If cls is a meta class, though,
    // this will still flush it and any of its sub-meta classes.
    flush_caches (cls, NO);
}

/***********************************************************************
* class_addClassMethods.
*
* Obsolete (for binary compatibility only).
**********************************************************************/
void	class_addClassMethods  (Class				cls,
                             struct objc_method_list *	meths)
{
    class_addMethods (((struct objc_class *) cls)->isa, meths);
}

/***********************************************************************
* class_removeMethods.
**********************************************************************/
void	class_removeMethods    (Class				cls,
                             struct objc_method_list *	meths)
{
    // Remove the methods
    OBJC_LOCK(&methodListLock);
    _objc_removeMethods(cls, meths);
    OBJC_UNLOCK(&methodListLock);

    // Must flush when dynamically removing methods.  No need to flush
    // all the class method caches.  If cls is a meta class, though,
    // this will still flush it and any of its sub-meta classes.
    flush_caches (cls, NO);
}

/***********************************************************************
* addClassToOriginalClass.  Add to a hash table of classes involved in
* a posing situation.  We use this when we need to get to the "original"
* class for some particular name through the function objc_getOrigClass.
* For instance, the implementation of [super ...] will use this to be
* sure that it gets hold of the correct super class, so that no infinite
* loops will occur if the class it appears in is involved in posing.
*
* We use the classLock to guard the hash table.
*
* See tracker bug #51856.
**********************************************************************/

static NXMapTable *	posed_class_hash = NULL;
static NXMapTable *	posed_class_to_original_class_hash = NULL;

static void	addClassToOriginalClass	       (Class	posingClass,
                                            Class	originalClass)
{
    // Install hash table when it is first needed
    if (!posed_class_to_original_class_hash)
    {
        posed_class_to_original_class_hash =
        NXCreateMapTableFromZone (NXPtrValueMapPrototype,
                                  8,
                                  _objc_internal_zone ());
    }

    // Add pose to hash table
    NXMapInsert (posed_class_to_original_class_hash,
                 posingClass,
                 originalClass);
}

/***********************************************************************
* getOriginalClassForPosingClass.
**********************************************************************/
Class	getOriginalClassForPosingClass	(Class	posingClass)
{
    return NXMapGet (posed_class_to_original_class_hash, posingClass);
}

/***********************************************************************
* objc_getOrigClass.
**********************************************************************/
Class	objc_getOrigClass		   (const char *	name)
{
    struct objc_class *	ret;

    // Look for class among the posers
    ret = Nil;
    OBJC_LOCK(&classLock);
    if (posed_class_hash)
        ret = (Class) NXMapGet (posed_class_hash, name);
    OBJC_UNLOCK(&classLock);
    if (ret)
        return ret;

    // Not a poser.  Do a normal lookup.
    ret = objc_getClass (name);
    if (!ret)
        _objc_inform ("class `%s' not linked into application", name);

    return ret;
}

/***********************************************************************
* _objc_addOrigClass.  This function is only used from class_poseAs.
* Registers the original class names, before they get obscured by
* posing, so that [super ..] will work correctly from categories
* in posing classes and in categories in classes being posed for.
**********************************************************************/
static void	_objc_addOrigClass	   (Class	origClass)
{
    OBJC_LOCK(&classLock);

    // Create the poser's hash table on first use
    if (!posed_class_hash)
    {
        posed_class_hash = NXCreateMapTableFromZone (NXStrValueMapPrototype,
                                                     8,
                                                     _objc_internal_zone ());
    }

    // Add the named class iff it is not already there (or collides?)
    if (NXMapGet (posed_class_hash, ((struct objc_class *)origClass)->name) == 0)
        NXMapInsert (posed_class_hash, ((struct objc_class *)origClass)->name, origClass);

    OBJC_UNLOCK(&classLock);
}

/***********************************************************************
* class_poseAs.
*
* !!! class_poseAs () does not currently flush any caches.
**********************************************************************/
Class		class_poseAs	       (Class		imposter,
                            Class		original)
{
    struct objc_class * clsObject;
    char *			imposterNamePtr;
    NXHashTable *		class_hash;
    NXHashState		state;
    struct objc_class * 			copy;
#ifdef OBJC_CLASS_REFS
    header_info *		hInfo;
#endif

    // Trivial case is easy
    if (imposter == original)
        return imposter;

    // Imposter must be an immediate subclass of the original
    if (((struct objc_class *)imposter)->super_class != original) {
        __objc_error(imposter, _errNotSuper, ((struct objc_class *)imposter)->name, ((struct objc_class *)original)->name);
    }

    // Can't pose when you have instance variables (how could it work?)
    if (((struct objc_class *)imposter)->ivars) {
        __objc_error(imposter, _errNewVars, ((struct objc_class *)imposter)->name, ((struct objc_class *)original)->name, ((struct objc_class *)imposter)->name);
    }

    // Build a string to use to replace the name of the original class.
    #define imposterNamePrefix "_%"
    imposterNamePtr = _malloc_internal(strlen(((struct objc_class *)original)->name) + strlen(imposterNamePrefix) + 1);
    strcpy(imposterNamePtr, imposterNamePrefix);
    strcat(imposterNamePtr, ((struct objc_class *)original)->name);
    #undef imposterNamePrefix

    // We lock the class hashtable, so we are thread safe with respect to
    // calls to objc_getClass ().  However, the class names are not
    // changed atomically, nor are all of the subclasses updated
    // atomically.  I have ordered the operations so that you will
    // never crash, but you may get inconsistent results....

    // Register the original class so that [super ..] knows
    // exactly which classes are the "original" classes.
    _objc_addOrigClass (original);
    _objc_addOrigClass (imposter);

    // Copy the imposter, so that the imposter can continue
    // its normal life in addition to changing the behavior of
    // the original.  As a hack we don't bother to copy the metaclass.
    // For some reason we modify the original rather than the copy.
    copy = (*_zoneAlloc)(imposter->isa, sizeof(struct objc_class), _objc_internal_zone());
    memmove(copy, imposter, sizeof(struct objc_class));

    OBJC_LOCK(&classLock);

    class_hash = objc_getClasses ();

    // Remove both the imposter and the original class.
    NXHashRemove (class_hash, imposter);
    NXHashRemove (class_hash, original);

    NXHashInsert (class_hash, copy);
    addClassToOriginalClass (imposter, copy);

    // Mark the imposter as such
    _class_setInfo(imposter, CLS_POSING);
    _class_setInfo(imposter->isa, CLS_POSING);

    // Change the name of the imposter to that of the original class.
    ((struct objc_class *)imposter)->name		= ((struct objc_class *)original)->name;
    ((struct objc_class *)imposter)->isa->name = ((struct objc_class *)original)->isa->name;

    // Also copy the version field to avoid archiving problems.
    ((struct objc_class *)imposter)->version = ((struct objc_class *)original)->version;

    // Change all subclasses of the original to point to the imposter.
    state = NXInitHashState (class_hash);
    while (NXNextHashState (class_hash, &state, (void **) &clsObject))
    {
        while  ((clsObject) && (clsObject != imposter) &&
                (clsObject != copy))
        {
            if (clsObject->super_class == original)
            {
                clsObject->super_class = imposter;
                clsObject->isa->super_class = ((struct objc_class *)imposter)->isa;
                // We must flush caches here!
                break;
            }

            clsObject = clsObject->super_class;
        }
    }

#ifdef OBJC_CLASS_REFS
    // Replace the original with the imposter in all class refs
    // Major loop - process all headers
    for (hInfo = _objc_headerStart(); hInfo != NULL; hInfo = hInfo->next)
    {
        Class *		cls_refs;
        unsigned int	refCount;
        unsigned int	index;

        // Get refs associated with this header
        cls_refs = (Class *) _getObjcClassRefs ((headerType *) hInfo->mhdr, &refCount);
        if (!cls_refs || !refCount)
            continue;

        // Minor loop - process this header's refs
        cls_refs = (Class *) ((unsigned long) cls_refs + hInfo->image_slide);
        for (index = 0; index < refCount; index += 1)
        {
            if (cls_refs[index] == original)
                cls_refs[index] = imposter;
        }
    }
#endif // OBJC_CLASS_REFS

    // Change the name of the original class.
    ((struct objc_class *)original)->name	    = imposterNamePtr + 1;
    ((struct objc_class *)original)->isa->name = imposterNamePtr;

    // Restore the imposter and the original class with their new names.
    NXHashInsert (class_hash, imposter);
    NXHashInsert (class_hash, original);

    OBJC_UNLOCK(&classLock);

    return imposter;
}

/***********************************************************************
* _freedHandler.
**********************************************************************/
static void	_freedHandler	       (id		self,
                                  SEL		sel)
{
    __objc_error (self, _errFreedObject, SELNAME(sel), self);
}

/***********************************************************************
* _nonexistentHandler.
**********************************************************************/
static void	_nonexistentHandler    (id		self,
                                    SEL		sel)
{
    __objc_error (self, _errNonExistentObject, SELNAME(sel), self);
}

/***********************************************************************
* class_respondsToMethod.
*
* Called from -[Object respondsTo:] and +[Object instancesRespondTo:]
**********************************************************************/
BOOL	class_respondsToMethod	       (Class		cls,
                                    SEL		sel)
{
    Method				meth;
    IMP imp;

    // No one responds to zero!
    if (!sel)
        return NO;

    imp = _cache_getImp(cls, sel);
    if (imp) {
        // Found method in cache. 
        // If the cache entry is forward::, the class does not respond to sel.
        return (imp != &_objc_msgForward);
    }

    // Handle cache miss
    OBJC_LOCK(&methodListLock);
    meth = _getMethod(cls, sel);
    OBJC_UNLOCK(&methodListLock);
    if (meth) {
        _cache_fill(cls, meth, sel);
        return YES;
    }

    // Not implemented.  Use _objc_msgForward.
    _cache_addForwardEntry(cls, sel);

    return NO;
}


/***********************************************************************
* class_lookupMethod.
*
* Called from -[Object methodFor:] and +[Object instanceMethodFor:]
**********************************************************************/
IMP		class_lookupMethod	       (Class		cls,
                                SEL		sel)
{
    IMP imp;

    // No one responds to zero!
    if (!sel) {
        __objc_error(cls, _errBadSel, sel);
    }

    imp = _cache_getImp(cls, sel);
    if (imp) return imp;

    // Handle cache miss
    return _class_lookupMethodAndLoadCache (cls, sel);
}

/***********************************************************************
* lookupNamedMethodInMethodList
* Only called to find +load/-.cxx_construct/-.cxx_destruct methods, 
* without fixing up the entire method list.
* The class is not yet in use, so methodListLock is not taken.
**********************************************************************/
__private_extern__ IMP lookupNamedMethodInMethodList(struct objc_method_list *mlist, const char *meth_name)
{
    Method m = meth_name ? _findNamedMethodInList(mlist, meth_name) : NULL;
    return (m ? m->method_imp : NULL);
}


/***********************************************************************
* _cache_malloc.
*
* Called from _cache_create() and cache_expand()
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static Cache _cache_malloc(int slotCount)
{
    Cache new_cache;
    size_t size;

    // Allocate table (why not check for failure?)
    size = sizeof(struct objc_cache) + TABLE_SIZE(slotCount);
#ifdef OBJC_INSTRUMENTED
    // Custom cache allocator can't handle instrumentation.
    size += sizeof(CacheInstrumentation);
    new_cache = _calloc_internal(size, 1);
    new_cache->mask = slotCount - 1;
#else
    if (size < CACHE_QUANTUM  ||  UseInternalZone) {
        new_cache = _calloc_internal(size, 1);
        new_cache->mask = slotCount - 1;
        // occupied and buckets and instrumentation are all zero
    } else {
        new_cache = cache_allocator_calloc(size);
        // mask is already set
        // occupied and buckets and instrumentation are all zero
    }
#endif

    return new_cache;
}


/***********************************************************************
* _cache_create.
*
* Called from _cache_expand().
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
Cache		_cache_create		(Class		cls)
{
    Cache		new_cache;
    int			slotCount;

    // Select appropriate size
    slotCount = (ISMETA(cls)) ? INIT_META_CACHE_SIZE : INIT_CACHE_SIZE;

    new_cache = _cache_malloc(slotCount);

    // Install the cache
    ((struct objc_class *)cls)->cache = new_cache;

    // Clear the cache flush flag so that we will not flush this cache
    // before expanding it for the first time.
    _class_clearInfo(cls, CLS_FLUSH_CACHE);

    // Clear the grow flag so that we will re-use the current storage,
    // rather than actually grow the cache, when expanding the cache
    // for the first time
    if (_class_slow_grow)
        _class_clearInfo(cls, CLS_GROW_CACHE);

    // Return our creation
    return new_cache;
}

/***********************************************************************
* _cache_expand.
*
* Called from _cache_fill ()
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static	Cache		_cache_expand	       (Class		cls)
{
    Cache		old_cache;
    Cache		new_cache;
    unsigned int	slotCount;
    unsigned int	index;

    // First growth goes from emptyCache to a real one
    old_cache = ((struct objc_class *)cls)->cache;
    if (old_cache == &emptyCache)
        return _cache_create (cls);

    // iff _class_slow_grow, trade off actual cache growth with re-using
    // the current one, so that growth only happens every odd time
    if (_class_slow_grow)
    {
        // CLS_GROW_CACHE controls every-other-time behavior.  If it
        // is non-zero, let the cache grow this time, but clear the
        // flag so the cache is reused next time
        if ((((struct objc_class * )cls)->info & CLS_GROW_CACHE) != 0)
            _class_clearInfo(cls, CLS_GROW_CACHE);

        // Reuse the current cache storage this time
        else
        {
            // Clear the valid-entry counter
            old_cache->occupied = 0;

            // Invalidate all the cache entries
            for (index = 0; index < old_cache->mask + 1; index += 1)
            {
                // Remember what this entry was, so we can possibly
                // deallocate it after the bucket has been invalidated
                Method		oldEntry = old_cache->buckets[index];
                // Skip invalid entry
                if (!CACHE_BUCKET_VALID(old_cache->buckets[index]))
                    continue;

                // Invalidate this entry
                CACHE_BUCKET_VALID(old_cache->buckets[index]) = NULL;

                // Deallocate "forward::" entry
                if (CACHE_BUCKET_IMP(oldEntry) == &_objc_msgForward)
                {
                    _cache_collect_free (oldEntry, sizeof(struct objc_method), NO);
                }
            }

            // Set the slow growth flag so the cache is next grown
            _class_setInfo(cls, CLS_GROW_CACHE);

            // Return the same old cache, freshly emptied
            return old_cache;
        }

    }

    // Double the cache size
    slotCount = (old_cache->mask + 1) << 1;

    new_cache = _cache_malloc(slotCount);

#ifdef OBJC_INSTRUMENTED
    // Propagate the instrumentation data
    {
        CacheInstrumentation *	oldCacheData;
        CacheInstrumentation *	newCacheData;

        oldCacheData = CACHE_INSTRUMENTATION(old_cache);
        newCacheData = CACHE_INSTRUMENTATION(new_cache);
        bcopy ((const char *)oldCacheData, (char *)newCacheData, sizeof(CacheInstrumentation));
    }
#endif

    // iff _class_uncache, copy old cache entries into the new cache
    if (_class_uncache == 0)
    {
        int	newMask;

        newMask = new_cache->mask;

        // Look at all entries in the old cache
        for (index = 0; index < old_cache->mask + 1; index += 1)
        {
            int	index2;

            // Skip invalid entry
            if (!CACHE_BUCKET_VALID(old_cache->buckets[index]))
                continue;

            // Hash the old entry into the new table
            index2 = CACHE_HASH(CACHE_BUCKET_NAME(old_cache->buckets[index]), 
                                newMask);

            // Find an available spot, at or following the hashed spot;
            // Guaranteed to not infinite loop, because table has grown
            for (;;)
            {
                if (!CACHE_BUCKET_VALID(new_cache->buckets[index2]))
                {
                    new_cache->buckets[index2] = old_cache->buckets[index];
                    break;
                }

                index2 += 1;
                index2 &= newMask;
            }

            // Account for the addition
            new_cache->occupied += 1;
        }

        // Set the cache flush flag so that we will flush this cache
        // before expanding it again.
        _class_setInfo(cls, CLS_FLUSH_CACHE);
    }

    // Deallocate "forward::" entries from the old cache
    else
    {
        for (index = 0; index < old_cache->mask + 1; index += 1)
        {
            if (CACHE_BUCKET_VALID(old_cache->buckets[index]) &&
                CACHE_BUCKET_IMP(old_cache->buckets[index]) == &_objc_msgForward)
            {
                _cache_collect_free (old_cache->buckets[index], sizeof(struct objc_method), NO);
            }
        }
    }

    // Install new cache
    ((struct objc_class *)cls)->cache = new_cache;

    // Deallocate old cache, try freeing all the garbage
    _cache_collect_free (old_cache, old_cache->mask * sizeof(Method), YES);
    return new_cache;
}

/***********************************************************************
* instrumentObjcMessageSends/logObjcMessageSends.
**********************************************************************/
static int	LogObjCMessageSend (BOOL			isClassMethod,
                               const char *	objectsClass,
                               const char *	implementingClass,
                               SEL				selector)
{
    char	buf[ 1024 ];

    // Create/open the log file
    if (objcMsgLogFD == (-1))
    {
        snprintf (buf, sizeof(buf), "/tmp/msgSends-%d", (int) getpid ());
        objcMsgLogFD = secure_open (buf, O_WRONLY | O_CREAT, geteuid());
        if (objcMsgLogFD < 0) {
            // no log file - disable logging
            objcMsgLogEnabled = 0;
            objcMsgLogFD = -1;
            return 1;
        }
    }

    // Make the log entry
    snprintf(buf, sizeof(buf), "%c %s %s %s\n",
            isClassMethod ? '+' : '-',
            objectsClass,
            implementingClass,
            (char *) selector);

    write (objcMsgLogFD, buf, strlen(buf));

    // Tell caller to not cache the method
    return 0;
}

void	instrumentObjcMessageSends       (BOOL		flag)
{
    int		enabledValue = (flag) ? 1 : 0;

    // Shortcut NOP
    if (objcMsgLogEnabled == enabledValue)
        return;

    // If enabling, flush all method caches so we get some traces
    if (flag)
        flush_caches (Nil, YES);

    // Sync our log file
    if (objcMsgLogFD != (-1))
        fsync (objcMsgLogFD);

    objcMsgLogEnabled = enabledValue;
}

void	logObjcMessageSends      (ObjCLogProc	logProc)
{
    if (logProc)
    {
        objcMsgLogProc = logProc;
        objcMsgLogEnabled = 1;
    }
    else
    {
        objcMsgLogProc = logProc;
        objcMsgLogEnabled = 0;
    }

    if (objcMsgLogFD != (-1))
        fsync (objcMsgLogFD);
}


/***********************************************************************
* _cache_fill.  Add the specified method to the specified class' cache.
* Returns NO if the cache entry wasn't added: cache was busy, 
*  class is still being initialized, new entry is a duplicate.
*
* Called only from _class_lookupMethodAndLoadCache and
* class_respondsToMethod and _cache_addForwardEntry.
*
* Cache locks: cacheUpdateLock must not be held.
**********************************************************************/
static	BOOL	_cache_fill(Class cls, Method smt, SEL sel)
{
    unsigned int		newOccupied;
    arith_t index;
    Method *buckets;
    Cache cache;

    // Never cache before +initialize is done
    if (!ISINITIALIZED(cls)) {
        return NO;
    }

    // Keep tally of cache additions
    totalCacheFills += 1;

    OBJC_LOCK(&cacheUpdateLock);

    cache = ((struct objc_class *)cls)->cache;

    // Check for duplicate entries, if we're in the mode
    if (traceDuplicates)
    {
        int	index2;
        arith_t mask = cache->mask;
        buckets	= cache->buckets;        

        // Scan the cache
        for (index2 = 0; index2 < mask + 1; index2 += 1)
        {
            // Skip invalid or non-duplicate entry
            if ((!CACHE_BUCKET_VALID(buckets[index2])) ||
                (strcmp ((char *) CACHE_BUCKET_NAME(buckets[index2]), (char *) smt->method_name) != 0))
                continue;

            // Tally duplication, but report iff wanted
            cacheFillDuplicates += 1;
            if (traceDuplicatesVerbose)
            {
                _objc_inform  ("Cache fill duplicate #%d: found %x adding %x: %s\n",
                               cacheFillDuplicates,
                               (unsigned int) CACHE_BUCKET_NAME(buckets[index2]),
                               (unsigned int) smt->method_name,
                               (char *) smt->method_name);
            }
        }
    }

    // Make sure the entry wasn't added to the cache by some other thread 
    // before we grabbed the cacheUpdateLock.
    // Don't use _cache_getMethod() because _cache_getMethod() doesn't 
    // return forward:: entries.
    if (_cache_getImp(cls, sel)) {
        OBJC_UNLOCK(&cacheUpdateLock);
        return NO; // entry is already cached, didn't add new one
    }

    // Use the cache as-is if it is less than 3/4 full
    newOccupied = cache->occupied + 1;
    if ((newOccupied * 4) <= (cache->mask + 1) * 3) {
        // Cache is less than 3/4 full.
        cache->occupied = newOccupied;
    } else {
        // Cache is too full. Flush it or expand it.
        if ((((struct objc_class * )cls)->info & CLS_FLUSH_CACHE) != 0) {
            _cache_flush (cls);
        } else {
            cache = _cache_expand (cls);
        }

        // Account for the addition
        cache->occupied += 1;
    }

    // Insert the new entry.  This can be done by either:
    // 	(a) Scanning for the first unused spot.  Easy!
    //	(b) Opening up an unused spot by sliding existing
    //	    entries down by one.  The benefit of this
    //	    extra work is that it puts the most recently
    //	    loaded entries closest to where the selector
    //	    hash starts the search.
    //
    // The loop is a little more complicated because there
    // are two kinds of entries, so there have to be two ways
    // to slide them.
    buckets	= cache->buckets;
    index	= CACHE_HASH(sel, cache->mask); 
    for (;;)
    {
        // Slide existing entries down by one
        Method		saveMethod;

        // Copy current entry to a local
        saveMethod = buckets[index];

        // Copy previous entry (or new entry) to current slot
        buckets[index] = smt;

        // Done if current slot had been invalid
        if (saveMethod == NULL)
            break;

        // Prepare to copy saved value into next slot
        smt = saveMethod;

        // Move on to next slot
        index += 1;
        index &= cache->mask;
    }

    OBJC_UNLOCK(&cacheUpdateLock);

    return YES; // successfully added new cache entry
}


/***********************************************************************
* _cache_addForwardEntry
* Add a forward:: entry  for the given selector to cls's method cache.
* Does nothing if the cache addition fails for any reason.
* Called from class_respondsToMethod and _class_lookupMethodAndLoadCache.
* Cache locks: cacheUpdateLock must not be held.
**********************************************************************/
static void _cache_addForwardEntry(Class cls, SEL sel)
{
    Method smt;
  
    smt = _malloc_internal(sizeof(struct objc_method));
    smt->method_name = sel;
    smt->method_types = "";
    smt->method_imp = &_objc_msgForward;
    if (! _cache_fill(cls, smt, sel)) {
        // Entry not added to cache. Don't leak the method struct.
        _free_internal(smt);
    }
}


/***********************************************************************
* _cache_flush.  Invalidate all valid entries in the given class' cache,
* and clear the CLS_FLUSH_CACHE in the cls->info.
*
* Called from flush_caches() and _cache_fill()
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static void	_cache_flush		(Class		cls)
{
    Cache			cache;
    unsigned int	index;

    // Locate cache.  Ignore unused cache.
    cache = ((struct objc_class *)cls)->cache;
    if (cache == NULL  ||  cache == &emptyCache)
        return;

#ifdef OBJC_INSTRUMENTED
    {
        CacheInstrumentation *	cacheData;

        // Tally this flush
        cacheData = CACHE_INSTRUMENTATION(cache);
        cacheData->flushCount += 1;
        cacheData->flushedEntries += cache->occupied;
        if (cache->occupied > cacheData->maxFlushedEntries)
            cacheData->maxFlushedEntries = cache->occupied;
    }
#endif

    // Traverse the cache
    for (index = 0; index <= cache->mask; index += 1)
    {
        // Remember what this entry was, so we can possibly
        // deallocate it after the bucket has been invalidated
        Method		oldEntry = cache->buckets[index];

        // Invalidate this entry
        CACHE_BUCKET_VALID(cache->buckets[index]) = NULL;

        // Deallocate "forward::" entry
        if (oldEntry && oldEntry->method_imp == &_objc_msgForward)
            _cache_collect_free (oldEntry, sizeof(struct objc_method), NO);
    }

    // Clear the valid-entry counter
    cache->occupied = 0;

    // Clear the cache flush flag so that we will not flush this cache
    // before expanding it again.
    _class_clearInfo(cls, CLS_FLUSH_CACHE);
}

/***********************************************************************
* _objc_getFreedObjectClass.  Return a pointer to the dummy freed
* object class.  Freed objects get their isa pointers replaced with
* a pointer to the freedObjectClass, so that we can catch usages of
* the freed object.
**********************************************************************/
Class		_objc_getFreedObjectClass	   (void)
{
    return (Class) &freedObjectClass;
}

/***********************************************************************
* _objc_getNonexistentClass.  Return a pointer to the dummy nonexistent
* object class.  This is used when, for example, mapping the class
* refs for an image, and the class can not be found, so that we can
* catch later uses of the non-existent class.
**********************************************************************/
Class		_objc_getNonexistentClass	   (void)
{
    return (Class) &nonexistentObjectClass;
}


/***********************************************************************
* struct _objc_initializing_classes
* Per-thread list of classes currently being initialized by that thread. 
* During initialization, that thread is allowed to send messages to that 
* class, but other threads have to wait.
* The list is a simple array of metaclasses (the metaclass stores 
* the initialization state). 
**********************************************************************/
typedef struct _objc_initializing_classes {
    int classesAllocated;
    struct objc_class** metaclasses;
} _objc_initializing_classes;


/***********************************************************************
* _fetchInitializingClassList
* Return the list of classes being initialized by this thread.
* If create == YES, create the list when no classes are being initialized by this thread.
* If create == NO, return NULL when no classes are being initialized by this thread.
**********************************************************************/
static _objc_initializing_classes *_fetchInitializingClassList(BOOL create)
{
    _objc_pthread_data *data;
    _objc_initializing_classes *list;
    struct objc_class **classes;

    data = pthread_getspecific(_objc_pthread_key);
    if (data == NULL) {
        if (!create) {
            return NULL;
        } else {
            data = _calloc_internal(1, sizeof(_objc_pthread_data));
            pthread_setspecific(_objc_pthread_key, data);
        }
    }

    list = data->initializingClasses;
    if (list == NULL) {
        if (!create) {
            return NULL;
        } else {
            list = _calloc_internal(1, sizeof(_objc_initializing_classes));
            data->initializingClasses = list;
        }
    }

    classes = list->metaclasses;
    if (classes == NULL) {
        // If _objc_initializing_classes exists, allocate metaclass array, 
        // even if create == NO.
        // Allow 4 simultaneous class inits on this thread before realloc.
        list->classesAllocated = 4;
        classes = _calloc_internal(list->classesAllocated, sizeof(struct objc_class *));
        list->metaclasses = classes;
    }
    return list;
}


/***********************************************************************
* _destroyInitializingClassList
* Deallocate memory used by the given initialization list. 
* Any part of the list may be NULL.
* Called from _objc_pthread_destroyspecific().
**********************************************************************/
void _destroyInitializingClassList(_objc_initializing_classes *list)
{
    if (list != NULL) {
        if (list->metaclasses != NULL) {
            _free_internal(list->metaclasses);
        }
        _free_internal(list);
    }
}


/***********************************************************************
* _thisThreadIsInitializingClass
* Return TRUE if this thread is currently initializing the given class.
**********************************************************************/
static BOOL _thisThreadIsInitializingClass(struct objc_class *cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = GETMETA(cls);
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) return YES;
        }
    }

    // no list or not found in list
    return NO;
}


/***********************************************************************
* _setThisThreadIsInitializingClass
* Record that this thread is currently initializing the given class. 
* This thread will be allowed to send messages to the class, but 
*   other threads will have to wait.
**********************************************************************/
static void _setThisThreadIsInitializingClass(struct objc_class *cls)
{
    int i;
    _objc_initializing_classes *list = _fetchInitializingClassList(YES);
    cls = GETMETA(cls);
  
    // paranoia: explicitly disallow duplicates
    for (i = 0; i < list->classesAllocated; i++) {
        if (cls == list->metaclasses[i]) {
            _objc_fatal("thread is already initializing this class!");
            return; // already the initializer
        }
    }
  
    for (i = 0; i < list->classesAllocated; i++) {
        if (0   == list->metaclasses[i]) {
            list->metaclasses[i] = cls;
            return;
        }
    }

    // class list is full - reallocate
    list->classesAllocated = list->classesAllocated * 2 + 1;
    list->metaclasses = _realloc_internal(list->metaclasses, list->classesAllocated * sizeof(struct objc_class *));
    // zero out the new entries
    list->metaclasses[i++] = cls;
    for ( ; i < list->classesAllocated; i++) {
        list->metaclasses[i] = NULL;
    }
}


/***********************************************************************
* _setThisThreadIsNotInitializingClass
* Record that this thread is no longer initializing the given class. 
**********************************************************************/
static void _setThisThreadIsNotInitializingClass(struct objc_class *cls)
{
    int i;

    _objc_initializing_classes *list = _fetchInitializingClassList(NO);
    if (list) {
        cls = GETMETA(cls);    
        for (i = 0; i < list->classesAllocated; i++) {
            if (cls == list->metaclasses[i]) {
                list->metaclasses[i] = NULL;
                return;
            }
        }
    }

    // no list or not found in list
    _objc_fatal("thread is not initializing this class!");  
}


/***********************************************************************
* class_initialize.  Send the '+initialize' message on demand to any
* uninitialized class. Force initialization of superclasses first.
*
* Called only from _class_lookupMethodAndLoadCache (or itself).
**********************************************************************/
static void class_initialize(struct objc_class *cls)
{
    struct objc_class *infoCls = GETMETA(cls);
    BOOL reallyInitialize = NO;

    // Get the real class from the metaclass. The superclass chain 
    // hangs off the real class only.
    // fixme ick
    if (ISMETA(cls)) {
        if (strncmp(cls->name, "_%", 2) == 0) {
            // Posee's meta's name is smashed and isn't in the class_hash, 
            // so objc_getClass doesn't work.
            char *baseName = strchr(cls->name, '%'); // get posee's real name
            cls = objc_getClass(baseName);
        } else {
            cls = objc_getClass(cls->name);
        }
    }

    // Make sure super is done initializing BEFORE beginning to initialize cls.
    // See note about deadlock above.
    if (cls->super_class  &&  !ISINITIALIZED(cls->super_class)) {
        class_initialize(cls->super_class);
    }
    
    // Try to atomically set CLS_INITIALIZING.
    pthread_mutex_lock(&classInitLock);
    if (!ISINITIALIZED(cls) && !ISINITIALIZING(cls)) {
        _class_setInfo(infoCls, CLS_INITIALIZING);
        reallyInitialize = YES;
    }
    pthread_mutex_unlock(&classInitLock);
    
    if (reallyInitialize) {
        // We successfully set the CLS_INITIALIZING bit. Initialize the class.
        
        // Record that we're initializing this class so we can message it.
        _setThisThreadIsInitializingClass(cls);
        
        // Send the +initialize message.
        // Note that +initialize is sent to the superclass (again) if 
        // this class doesn't implement +initialize. 2157218
        [(id)cls initialize];
        
        // Done initializing. Update the info bits and notify waiting threads.
        pthread_mutex_lock(&classInitLock);
        _class_changeInfo(infoCls, CLS_INITIALIZED, CLS_INITIALIZING);
        pthread_cond_broadcast(&classInitWaitCond);
        pthread_mutex_unlock(&classInitLock);
        _setThisThreadIsNotInitializingClass(cls);
        return;
    }
    
    else if (ISINITIALIZING(cls)) {
        // We couldn't set INITIALIZING because INITIALIZING was already set.
        // If this thread set it earlier, continue normally.
        // If some other thread set it, block until initialize is done.
        // It's ok if INITIALIZING changes to INITIALIZED while we're here, 
        //   because we safely check for INITIALIZED inside the lock 
        //   before blocking.
        if (_thisThreadIsInitializingClass(cls)) {
            return;
        } else {
            pthread_mutex_lock(&classInitLock);
            while (!ISINITIALIZED(cls)) {
                pthread_cond_wait(&classInitWaitCond, &classInitLock);
            }
            pthread_mutex_unlock(&classInitLock);
            return;
        }
    }
    
    else if (ISINITIALIZED(cls)) {
        // Set CLS_INITIALIZING failed because someone else already 
        //   initialized the class. Continue normally.
        // NOTE this check must come AFTER the ISINITIALIZING case.
        // Otherwise: Another thread is initializing this class. ISINITIALIZED 
        //   is false. Skip this clause. Then the other thread finishes 
        //   initialization and sets INITIALIZING=no and INITIALIZED=yes. 
        //   Skip the ISINITIALIZING clause. Die horribly.
        return;
    }
    
    else {
        // We shouldn't be here. 
        _objc_fatal("thread-safe class init in objc runtime is buggy!");
    }
}


/***********************************************************************
* _class_lookupMethodAndLoadCache.
*
* Called only from objc_msgSend, objc_msgSendSuper and class_lookupMethod.
**********************************************************************/
IMP	_class_lookupMethodAndLoadCache	   (Class	cls,
                                        SEL		sel)
{
    struct objc_class *	curClass;
    Method meth;
    IMP methodPC = NULL;

    trace(0xb300, 0, 0, 0);

    // Check for freed class
    if (cls == &freedObjectClass)
        return (IMP) _freedHandler;

    // Check for nonexistent class
    if (cls == &nonexistentObjectClass)
        return (IMP) _nonexistentHandler;

    trace(0xb301, 0, 0, 0);

    if (!ISINITIALIZED(cls)) {
        class_initialize ((struct objc_class *)cls);
        // If sel == initialize, class_initialize will send +initialize and 
        // then the messenger will send +initialize again after this 
        // procedure finishes. Of course, if this is not being called 
        // from the messenger then it won't happen. 2778172
    }

    trace(0xb302, 0, 0, 0);

    // Outer loop - search the caches and method lists of the
    // class and its super-classes
    for (curClass = cls; curClass; curClass = ((struct objc_class * )curClass)->super_class)
    {
#ifdef PRELOAD_SUPERCLASS_CACHES
        struct objc_class *curClass2;
#endif

        trace(0xb303, 0, 0, 0);

        // Beware of thread-unsafety and double-freeing of forward:: 
        // entries here! See note in "Method cache locking" above.
        // The upshot is that _cache_getMethod() will return NULL 
        // instead of returning a forward:: entry.
        meth = _cache_getMethod(curClass, sel, &_objc_msgForward);
        if (meth) {
            // Found the method in this class or a superclass.
            // Cache the method in this class, unless we just found it in 
            // this class's cache.
            if (curClass != cls) {
#ifdef PRELOAD_SUPERCLASS_CACHES
                for (curClass2 = cls; curClass2 != curClass; curClass2 = curClass2->super_class)
                    _cache_fill (curClass2, meth, sel);
                _cache_fill (curClass, meth, sel);
#else
                _cache_fill (cls, meth, sel);
#endif
            }

            methodPC = meth->method_imp;
            break;
        }

        trace(0xb304, (int)methodPC, 0, 0);

        // Cache scan failed. Search method list.

        OBJC_LOCK(&methodListLock);
        meth = _findMethodInClass(curClass, sel);
        OBJC_UNLOCK(&methodListLock);
        if (meth) {
            // If logging is enabled, log the message send and let
            // the logger decide whether to encache the method.
            if ((objcMsgLogEnabled == 0) ||
                (objcMsgLogProc (CLS_GETINFO(((struct objc_class * )curClass),
                                             CLS_META) ? YES : NO,
                                 ((struct objc_class *)cls)->name,
                                 curClass->name, sel)))
            {
                // Cache the method implementation
#ifdef PRELOAD_SUPERCLASS_CACHES
                for (curClass2 = cls; curClass2 != curClass; curClass2 = curClass2->super_class)
                    _cache_fill (curClass2, meth, sel);
                _cache_fill (curClass, meth, sel);
#else
                _cache_fill (cls, meth, sel);
#endif
            }

            methodPC = meth->method_imp;
            break;
        }

        trace(0xb305, (int)methodPC, 0, 0);
    }

    trace(0xb306, (int)methodPC, 0, 0);

    if (methodPC == NULL)
    {
        // Class and superclasses do not respond -- use forwarding
        _cache_addForwardEntry(cls, sel);
        methodPC = &_objc_msgForward;
    }

    trace(0xb30f, (int)methodPC, 0, 0);

    return methodPC;
}


/***********************************************************************
* lookupMethodInClassAndLoadCache.
* Like _class_lookupMethodAndLoadCache, but does not search superclasses.
* Caches and returns objc_msgForward if the method is not found in the class.
**********************************************************************/
static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel)
{
    Method meth;
    IMP imp;

    // Search cache first.
    imp = _cache_getImp(cls, sel);
    if (imp) return imp;

    // Cache miss. Search method list.

    OBJC_LOCK(&methodListLock);
    meth = _findMethodInClass(cls, sel);
    OBJC_UNLOCK(&methodListLock);

    if (meth) {
        // Hit in method list. Cache it.
        _cache_fill(cls, meth, sel);
        return meth->method_imp;
    } else {
        // Miss in method list. Cache objc_msgForward.
        _cache_addForwardEntry(cls, sel);
        return &_objc_msgForward;
    }
}



/***********************************************************************
* _class_changeInfo
* Atomically sets and clears some bits in cls's info field.
* set and clear must not overlap.
**********************************************************************/
static pthread_mutex_t infoLock = PTHREAD_MUTEX_INITIALIZER;
__private_extern__ void _class_changeInfo(struct objc_class *cls, 
                                          long set, long clear)
{
    pthread_mutex_lock(&infoLock);
    cls->info = (cls->info | set) & ~clear;
    pthread_mutex_unlock(&infoLock);
}


/***********************************************************************
* _class_setInfo
* Atomically sets some bits in cls's info field.
**********************************************************************/
__private_extern__ void _class_setInfo(struct objc_class *cls, long set)
{
    _class_changeInfo(cls, set, 0);
}


/***********************************************************************
* _class_clearInfo
* Atomically clears some bits in cls's info field.
**********************************************************************/
__private_extern__ void _class_clearInfo(struct objc_class *cls, long clear)
{
    _class_changeInfo(cls, 0, clear);
}


/***********************************************************************
* SubtypeUntil.
*
* Delegation.
**********************************************************************/
static int	SubtypeUntil	       (const char *	type,
                                char		end)
{
    int		level = 0;
    const char *	head = type;

    //
    while (*type)
    {
        if (!*type || (!level && (*type == end)))
            return (int)(type - head);

        switch (*type)
        {
            case ']': case '}': case ')': level--; break;
            case '[': case '{': case '(': level += 1; break;
        }

        type += 1;
    }

    _objc_fatal ("Object: SubtypeUntil: end of type encountered prematurely\n");
    return 0;
}

/***********************************************************************
* SkipFirstType.
**********************************************************************/
static const char *	SkipFirstType	   (const char *	type)
{
    while (1)
    {
        switch (*type++)
        {
            case 'O':	/* bycopy */
            case 'n':	/* in */
            case 'o':	/* out */
            case 'N':	/* inout */
            case 'r':	/* const */
            case 'V':	/* oneway */
            case '^':	/* pointers */
                break;

                /* arrays */
            case '[':
                while ((*type >= '0') && (*type <= '9'))
                    type += 1;
                return type + SubtypeUntil (type, ']') + 1;

                /* structures */
            case '{':
                return type + SubtypeUntil (type, '}') + 1;

                /* unions */
            case '(':
                return type + SubtypeUntil (type, ')') + 1;

                /* basic types */
            default:
                return type;
        }
    }
}

/***********************************************************************
* method_getNumberOfArguments.
**********************************************************************/
unsigned	method_getNumberOfArguments	   (Method	method)
{
    const char *		typedesc;
    unsigned		nargs;

    // First, skip the return type
    typedesc = method->method_types;
    typedesc = SkipFirstType (typedesc);

    // Next, skip stack size
    while ((*typedesc >= '0') && (*typedesc <= '9'))
        typedesc += 1;

    // Now, we have the arguments - count how many
    nargs = 0;
    while (*typedesc)
    {
        // Traverse argument type
        typedesc = SkipFirstType (typedesc);

        // Skip GNU runtime's register parameter hint
        if (*typedesc == '+') typedesc++;

        // Traverse (possibly negative) argument offset
        if (*typedesc == '-')
            typedesc += 1;
        while ((*typedesc >= '0') && (*typedesc <= '9'))
            typedesc += 1;

        // Made it past an argument
        nargs += 1;
    }

    return nargs;
}

/***********************************************************************
* method_getSizeOfArguments.
**********************************************************************/
#ifndef __alpha__
unsigned	method_getSizeOfArguments	(Method		method)
{
    const char *		typedesc;
    unsigned		stack_size;
#if defined(__ppc__) || defined(ppc)
    unsigned		trueBaseOffset;
    unsigned		foundBaseOffset;
#endif

    // Get our starting points
    stack_size = 0;
    typedesc = method->method_types;

    // Skip the return type
#if defined (__ppc__) || defined(ppc)
    // Struct returns cause the parameters to be bumped
    // by a register, so the offset to the receiver is
    // 4 instead of the normal 0.
    trueBaseOffset = (*typedesc == '{') ? 4 : 0;
#endif
    typedesc = SkipFirstType (typedesc);

    // Convert ASCII number string to integer
    while ((*typedesc >= '0') && (*typedesc <= '9'))
        stack_size = (stack_size * 10) + (*typedesc++ - '0');
#if defined (__ppc__) || defined(ppc)
    // NOTE: This is a temporary measure pending a compiler fix.
    // Work around PowerPC compiler bug wherein the method argument
    // string contains an incorrect value for the "stack size."
    // Generally, the size is reported 4 bytes too small, so we apply
    // that fudge factor.  Unfortunately, there is at least one case
    // where the error is something other than -4: when the last
    // parameter is a double, the reported stack is much too high
    // (about 32 bytes).  We do not attempt to detect that case.
    // The result of returning a too-high value is that objc_msgSendv
    // can bus error if the destination of the marg_list copying
    // butts up against excluded memory.
    // This fix disables itself when it sees a correctly built
    // type string (i.e. the offset for the Id is correct).  This
    // keeps us out of lockstep with the compiler.

    // skip the '@' marking the Id field
    typedesc = SkipFirstType (typedesc);

    // Skip GNU runtime's register parameter hint
    if (*typedesc == '+') typedesc++;

    // pick up the offset for the Id field
    foundBaseOffset = 0;
    while ((*typedesc >= '0') && (*typedesc <= '9'))
        foundBaseOffset = (foundBaseOffset * 10) + (*typedesc++ - '0');

    // add fudge factor iff the Id field offset was wrong
    if (foundBaseOffset != trueBaseOffset)
        stack_size += 4;
#endif

    return stack_size;
}

#else // __alpha__
      // XXX Getting the size of a type is done all over the place
      // (Here, Foundation, remote project)! - Should unify

unsigned int	getSizeOfType	(const char * type, unsigned int * alignPtr);

unsigned	method_getSizeOfArguments	   (Method	method)
{
    const char *	type;
    int		size;
    int		index;
    int		align;
    int		offset;
    unsigned	stack_size;
    int		nargs;

    nargs		= method_getNumberOfArguments (method);
    stack_size	= (*method->method_types == '{') ? sizeof(void *) : 0;

    for (index = 0; index < nargs; index += 1)
    {
        (void) method_getArgumentInfo (method, index, &type, &offset);
        size = getSizeOfType (type, &align);
        stack_size += ((size + 7) & ~7);
    }

    return stack_size;
}
#endif // __alpha__

/***********************************************************************
* method_getArgumentInfo.
**********************************************************************/
unsigned	method_getArgumentInfo	       (Method		method,
                                        int		arg,
                                        const char **	type,
                                        int *		offset)
{
    const char *	typedesc	   = method->method_types;
    unsigned	nargs		   = 0;
    unsigned	self_offset	   = 0;
    BOOL		offset_is_negative = NO;

    // First, skip the return type
    typedesc = SkipFirstType (typedesc);

    // Next, skip stack size
    while ((*typedesc >= '0') && (*typedesc <= '9'))
        typedesc += 1;

    // Now, we have the arguments - position typedesc to the appropriate argument
    while (*typedesc && nargs != arg)
    {

        // Skip argument type
        typedesc = SkipFirstType (typedesc);

        if (nargs == 0)
        {
            // Skip GNU runtime's register parameter hint
            if (*typedesc == '+') typedesc++;

            // Skip negative sign in offset
            if (*typedesc == '-')
            {
                offset_is_negative = YES;
                typedesc += 1;
            }
            else
                offset_is_negative = NO;

            while ((*typedesc >= '0') && (*typedesc <= '9'))
                self_offset = self_offset * 10 + (*typedesc++ - '0');
            if (offset_is_negative)
                self_offset = -(self_offset);

        }

        else
        {
            // Skip GNU runtime's register parameter hint
            if (*typedesc == '+') typedesc++;

            // Skip (possibly negative) argument offset
            if (*typedesc == '-')
                typedesc += 1;
            while ((*typedesc >= '0') && (*typedesc <= '9'))
                typedesc += 1;
        }

        nargs += 1;
    }

    if (*typedesc)
    {
        unsigned arg_offset = 0;

        *type	 = typedesc;
        typedesc = SkipFirstType (typedesc);

        if (arg == 0)
        {
#ifdef hppa
            *offset = -sizeof(id);
#else
            *offset = 0;
#endif // hppa
        }

        else
        {
            // Skip GNU register parameter hint
            if (*typedesc == '+') typedesc++;

            // Pick up (possibly negative) argument offset
            if (*typedesc == '-')
            {
                offset_is_negative = YES;
                typedesc += 1;
            }
            else
                offset_is_negative = NO;

            while ((*typedesc >= '0') && (*typedesc <= '9'))
                arg_offset = arg_offset * 10 + (*typedesc++ - '0');
            if (offset_is_negative)
                arg_offset = - arg_offset;

#ifdef hppa
            // For stacks which grow up, since margs points
            // to the top of the stack or the END of the args,
            // the first offset is at -sizeof(id) rather than 0.
            self_offset += sizeof(id);
#endif
            *offset = arg_offset - self_offset;
        }

    }

    else
    {
        *type	= 0;
        *offset	= 0;
    }

    return nargs;
}

/***********************************************************************
* _objc_create_zone.
**********************************************************************/

void *		_objc_create_zone		   (void)
{
    return malloc_default_zone();
}


/***********************************************************************
* _objc_internal_zone.
* Malloc zone for internal runtime data.
* By default this is the default malloc zone, but a dedicated zone is 
* used if environment variable OBJC_USE_INTERNAL_ZONE is set.
**********************************************************************/
__private_extern__ malloc_zone_t *_objc_internal_zone(void)
{
    static malloc_zone_t *z = (malloc_zone_t *)-1;
    if (z == (malloc_zone_t *)-1) {
        if (UseInternalZone) {
            z = malloc_create_zone(vm_page_size, 0);
            malloc_set_zone_name(z, "ObjC");
        } else {
            z = malloc_default_zone();
        }
    }
    return z;
}


/***********************************************************************
* _malloc_internal
* _calloc_internal
* _realloc_internal
* _strdup_internal
* _free_internal
* Convenience functions for the internal malloc zone.
**********************************************************************/
__private_extern__ void *_malloc_internal(size_t size) 
{
    return malloc_zone_malloc(_objc_internal_zone(), size);
}

__private_extern__ void *_calloc_internal(size_t count, size_t size) 
{
    return malloc_zone_calloc(_objc_internal_zone(), count, size);
}

__private_extern__ void *_realloc_internal(void *ptr, size_t size)
{
    return malloc_zone_realloc(_objc_internal_zone(), ptr, size);
}

__private_extern__ char *_strdup_internal(const char *str)
{
    size_t len = strlen(str);
    char *dup = malloc_zone_malloc(_objc_internal_zone(), len + 1);
    memcpy(dup, str, len + 1);
    return dup;
}

__private_extern__ void _free_internal(void *ptr)
{
    malloc_zone_free(_objc_internal_zone(), ptr);
}



/***********************************************************************
* cache collection.
**********************************************************************/

static unsigned long	_get_pc_for_thread     (mach_port_t	thread)
#ifdef hppa
{
    struct hp_pa_frame_thread_state		state;
    unsigned int count = HPPA_FRAME_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, HPPA_FRAME_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.ts_pcoq_front : PC_SENTINAL;
}
#elif defined(sparc)
{
    struct sparc_thread_state_regs		state;
    unsigned int count = SPARC_THREAD_STATE_REGS_COUNT;
    kern_return_t okay = thread_get_state (thread, SPARC_THREAD_STATE_REGS, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.regs.r_pc : PC_SENTINAL;
}
#elif defined(__i386__) || defined(i386)
{
    i386_thread_state_t			state;
    unsigned int count = i386_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, i386_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.eip : PC_SENTINAL;
}
#elif defined(m68k)
{
    struct m68k_thread_state_regs		state;
    unsigned int count = M68K_THREAD_STATE_REGS_COUNT;
    kern_return_t okay = thread_get_state (thread, M68K_THREAD_STATE_REGS, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.pc : PC_SENTINAL;
}
#elif defined(__ppc__) || defined(ppc)
{
    struct ppc_thread_state			state;
    unsigned int count = PPC_THREAD_STATE_COUNT;
    kern_return_t okay = thread_get_state (thread, PPC_THREAD_STATE, (thread_state_t)&state, &count);
    return (okay == KERN_SUCCESS) ? state.srr0 : PC_SENTINAL;
}
#else
{
#error _get_pc_for_thread () not implemented for this architecture
}
#endif

/***********************************************************************
* _collecting_in_critical.
* Returns TRUE if some thread is currently executing a cache-reading 
* function. Collection of cache garbage is not allowed when a cache-
* reading function is in progress because it might still be using 
* the garbage memory.
**********************************************************************/
OBJC_EXPORT unsigned long	objc_entryPoints[];
OBJC_EXPORT unsigned long	objc_exitPoints[];

static int	_collecting_in_critical		(void)
{
    thread_act_port_array_t		threads;
    unsigned			number;
    unsigned			count;
    kern_return_t		ret;
    int					result;

    mach_port_t mythread = pthread_mach_thread_np(pthread_self());

    // Get a list of all the threads in the current task
    ret = task_threads (mach_task_self (), &threads, &number);
    if (ret != KERN_SUCCESS)
    {
        _objc_fatal("task_thread failed (result %d)\n", ret);
    }

    // Check whether any thread is in the cache lookup code
    result = FALSE;
    for (count = 0; count < number; count++)
    {
        int region;
        unsigned long pc;

        // Don't bother checking ourselves
        if (threads[count] == mythread)
            continue;

        // Find out where thread is executing
        pc = _get_pc_for_thread (threads[count]);

        // Check for bad status, and if so, assume the worse (can't collect)
        if (pc == PC_SENTINAL)
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
    vm_deallocate (mach_task_self (), (vm_address_t) threads, sizeof(threads) * number);

    // Return our finding
    return result;
}

/***********************************************************************
* _garbage_make_room.  Ensure that there is enough room for at least
* one more ref in the garbage.
**********************************************************************/

// amount of memory represented by all refs in the garbage
static int garbage_byte_size	= 0;

// do not empty the garbage until garbage_byte_size gets at least this big
static int garbage_threshold	= 1024;

// table of refs to free
static void **garbage_refs	= 0;

// current number of refs in garbage_refs
static int garbage_count	= 0;

// capacity of current garbage_refs
static int garbage_max		= 0;

// capacity of initial garbage_refs
enum {
    INIT_GARBAGE_COUNT	= 128
};

static void	_garbage_make_room		(void)
{
    static int	first = 1;
    volatile void *	tempGarbage;

    // Create the collection table the first time it is needed
    if (first)
    {
        first		= 0;
        garbage_refs	= _malloc_internal(INIT_GARBAGE_COUNT * sizeof(void *));
        garbage_max	= INIT_GARBAGE_COUNT;
    }

    // Double the table if it is full
    else if (garbage_count == garbage_max)
    {
        tempGarbage	= _realloc_internal(garbage_refs, garbage_max * 2 * sizeof(void *));
        garbage_refs	= (void **) tempGarbage;
        garbage_max	*= 2;
    }
}

/***********************************************************************
* _cache_collect_free.  Add the specified malloc'd memory to the list
* of them to free at some later point.
* size is used for the collection threshold. It does not have to be 
* precisely the block's size.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static void _cache_collect_free(void *data, size_t size, BOOL tryCollect)
{
    static char *report_garbage = (char *)0xffffffff;

    if ((char *)0xffffffff == report_garbage) {
        // Check whether to log our activity
        report_garbage = getenv ("OBJC_REPORT_GARBAGE");
    }

    // Insert new element in garbage list
    // Note that we do this even if we end up free'ing everything
    _garbage_make_room ();
    garbage_byte_size += size;
    garbage_refs[garbage_count++] = data;

    // Log our progress
    if (tryCollect && report_garbage)
        _objc_inform ("total of %d bytes of garbage ...", garbage_byte_size);

    // Done if caller says not to empty or the garbage is not full
    if (!tryCollect || (garbage_byte_size < garbage_threshold))
    {
        if (tryCollect && report_garbage)
            _objc_inform ("couldn't collect cache garbage: below threshold\n");

        return;
    }

    // tryCollect is guaranteed to be true after this point

    // Synchronize garbage collection with objc_msgSend and other cache readers
    if (!_collecting_in_critical ()) {
        // No cache readers in progress - garbage is now deletable

        // Log our progress
        if (report_garbage)
            _objc_inform ("collecting!\n");
        
        // Dispose all refs now in the garbage
        while (garbage_count--) {
            if (cache_allocator_is_block(garbage_refs[garbage_count])) {
                cache_allocator_free(garbage_refs[garbage_count]);
            } else {
                free(garbage_refs[garbage_count]);
            }
        }

        // Clear the garbage count and total size indicator
        garbage_count = 0;
        garbage_byte_size = 0;
    }
    else {     
        // objc_msgSend (or other cache reader) is currently looking in the 
        // cache and might still be using some garbage.
        if (report_garbage) {
            _objc_inform ("couldn't collect cache garbage: objc_msgSend in progress\n");
        }
    }
}



/***********************************************************************
* Custom method cache allocator.
* Method cache block sizes are 2^slots+2 words, which is a pessimal 
* case for the system allocator. It wastes 504 bytes per cache block 
* with 128 or more slots, which adds up to tens of KB for an AppKit process.
* To save memory, the custom cache allocator below is used.
* 
* The cache allocator uses 128 KB allocation regions. Few processes will 
* require a second region. Within a region, allocation is address-ordered 
* first fit.
* 
* The cache allocator uses a quantum of 520.
* Cache block ideal sizes: 520, 1032, 2056, 4104
* Cache allocator sizes:   520, 1040, 2080, 4160
*
* Because all blocks are known to be genuine method caches, the ordinary 
* cache->mask and cache->occupied fields are used as block headers. 
* No out-of-band headers are maintained. The number of blocks will 
* almost always be fewer than 200, so for simplicity there is no free 
* list or other optimization.
* 
* Block in use: mask != 0, occupied != -1 (mask indicates block size)
* Block free:   mask != 0, occupied == -1 (mask is precisely block size)
* 
* No cache allocator functions take any locks. Instead, the caller 
* must hold the cacheUpdateLock.
**********************************************************************/

typedef struct cache_allocator_block {
    unsigned int size;
    unsigned int state;
    struct cache_allocator_block *nextFree;
} cache_allocator_block;

typedef struct cache_allocator_region {
    cache_allocator_block *start;
    cache_allocator_block *end;    // first non-block address
    cache_allocator_block *freeList;
    struct cache_allocator_region *next;
} cache_allocator_region;

static cache_allocator_region *cacheRegion = NULL;


static unsigned int cache_allocator_mask_for_size(size_t size)
{
    return (size - sizeof(struct objc_cache)) / sizeof(Method);
}

static size_t cache_allocator_size_for_mask(unsigned int mask)
{
    size_t requested = sizeof(struct objc_cache) + TABLE_SIZE(mask+1);
    size_t actual = CACHE_QUANTUM;
    while (actual < requested) actual += CACHE_QUANTUM;
    return actual;
}

/***********************************************************************
* cache_allocator_add_region
* Allocates and returns a new region that can hold at least size 
*   bytes of large method caches. 
* The actual size will be rounded up to a CACHE_QUANTUM boundary, 
*   with a minimum of CACHE_REGION_SIZE. 
* The new region is lowest-priority for new allocations. Callers that 
*   know the other regions are already full should allocate directly 
*   into the returned region.
**********************************************************************/
static cache_allocator_region *cache_allocator_add_region(size_t size)
{
    vm_address_t addr;
    cache_allocator_block *b;
    cache_allocator_region **rgnP;
    cache_allocator_region *newRegion = 
        _calloc_internal(1, sizeof(cache_allocator_region));

    // Round size up to quantum boundary, and apply the minimum size.
    size += CACHE_QUANTUM - (size % CACHE_QUANTUM);
    if (size < CACHE_REGION_SIZE) size = CACHE_REGION_SIZE;

    // Allocate the region
    addr = 0;
    vm_allocate(mach_task_self(), &addr, size, 1);
    newRegion->start = (cache_allocator_block *)addr;
    newRegion->end = (cache_allocator_block *)(addr + size);

    // Mark the first block: free and covers the entire region
    b = newRegion->start;
    b->size = size;
    b->state = (unsigned int)-1;
    b->nextFree = NULL;
    newRegion->freeList = b;

    // Add to end of the linked list of regions.
    // Other regions should be re-used before this one is touched.
    newRegion->next = NULL;
    rgnP = &cacheRegion;
    while (*rgnP) {
        rgnP = &(**rgnP).next;
    }
    *rgnP = newRegion;

    return newRegion;
}


/***********************************************************************
* cache_allocator_coalesce
* Attempts to coalesce a free block with the single free block following 
* it in the free list, if any.
**********************************************************************/
static void cache_allocator_coalesce(cache_allocator_block *block)
{
    if (block->size + (uintptr_t)block == (uintptr_t)block->nextFree) {
        block->size += block->nextFree->size;
        block->nextFree = block->nextFree->nextFree;
    }
}


/***********************************************************************
* cache_region_calloc
* Attempt to allocate a size-byte block in the given region. 
* Allocation is first-fit. The free list is already fully coalesced.
* Returns NULL if there is not enough room in the region for the block.
**********************************************************************/
static void *cache_region_calloc(cache_allocator_region *rgn, size_t size)
{
    cache_allocator_block **blockP;
    unsigned int mask;

    // Save mask for allocated block, then round size 
    // up to CACHE_QUANTUM boundary
    mask = cache_allocator_mask_for_size(size);
    size = cache_allocator_size_for_mask(mask);

    // Search the free list for a sufficiently large free block.

    for (blockP = &rgn->freeList; 
         *blockP != NULL; 
         blockP = &(**blockP).nextFree) 
    {
        cache_allocator_block *block = *blockP;
        if (block->size < size) continue;  // not big enough

        // block is now big enough. Allocate from it.

        // Slice off unneeded fragment of block, if any, 
        // and reconnect the free list around block.
        if (block->size - size >= CACHE_QUANTUM) {
            cache_allocator_block *leftover = 
                (cache_allocator_block *)(size + (uintptr_t)block);
            leftover->size = block->size - size;
            leftover->state = (unsigned int)-1;
            leftover->nextFree = block->nextFree;
            *blockP = leftover;
        } else {
            *blockP = block->nextFree;
        }
            
        // block is now exactly the right size.

        bzero(block, size);
        block->size = mask;  // Cache->mask
        block->state = 0;    // Cache->occupied

        return block;
    }

    // No room in this region.
    return NULL;
}


/***********************************************************************
* cache_allocator_calloc
* Custom allocator for large method caches (128+ slots)
* The returned cache block already has cache->mask set. 
* cache->occupied and the cache contents are zero.
* Cache locks: cacheUpdateLock must be held by the caller
**********************************************************************/
static void *cache_allocator_calloc(size_t size)
{
    cache_allocator_region *rgn;

    for (rgn = cacheRegion; rgn != NULL; rgn = rgn->next) {
        void *p = cache_region_calloc(rgn, size);
        if (p) {
            return p;
        }
    }

    // No regions or all regions full - make a region and try one more time
    // In the unlikely case of a cache over 256KB, it will get its own region.
    return cache_region_calloc(cache_allocator_add_region(size), size);
}


/***********************************************************************
* cache_allocator_region_for_block
* Returns the cache allocator region that ptr points into, or NULL.
**********************************************************************/
static cache_allocator_region *cache_allocator_region_for_block(cache_allocator_block *block) 
{
    cache_allocator_region *rgn;
    for (rgn = cacheRegion; rgn != NULL; rgn = rgn->next) {
        if (block >= rgn->start  &&  block < rgn->end) return rgn;
    }
    return NULL;
}


/***********************************************************************
* cache_allocator_is_block
* If ptr is a live block from the cache allocator, return YES
* If ptr is a block from some other allocator, return NO.
* If ptr is a dead block from the cache allocator, result is undefined.
* Cache locks: cacheUpdateLock must be held by the caller
**********************************************************************/
static BOOL cache_allocator_is_block(void *ptr)
{
    return (cache_allocator_region_for_block((cache_allocator_block *)ptr) != NULL);
}

/***********************************************************************
* cache_allocator_free
* Frees a block allocated by the cache allocator.
* Cache locks: cacheUpdateLock must be held by the caller.
**********************************************************************/
static void cache_allocator_free(void *ptr)
{
    cache_allocator_block *dead = (cache_allocator_block *)ptr;
    cache_allocator_block *cur;
    cache_allocator_region *rgn;

    if (! (rgn = cache_allocator_region_for_block(ptr))) {
        // free of non-pointer
        _objc_inform("cache_allocator_free of non-pointer %p", ptr);
        return;
    }    

    dead->size = cache_allocator_size_for_mask(dead->size);
    dead->state = (unsigned int)-1;

    if (!rgn->freeList  ||  rgn->freeList > dead) {
        // dead block belongs at front of free list
        dead->nextFree = rgn->freeList;
        rgn->freeList = dead;
        cache_allocator_coalesce(dead);
        return;
    }

    // dead block belongs in the middle or end of free list
    for (cur = rgn->freeList; cur != NULL; cur = cur->nextFree) {
        cache_allocator_block *ahead = cur->nextFree;
        
        if (!ahead  ||  ahead > dead) {
            // cur and ahead straddle dead, OR dead belongs at end of free list
            cur->nextFree = dead;
            dead->nextFree = ahead;
            
            // coalesce into dead first in case both succeed
            cache_allocator_coalesce(dead);
            cache_allocator_coalesce(cur);
            return;
        }
    }

    // uh-oh
    _objc_inform("cache_allocator_free of non-pointer %p", ptr);
}


/***********************************************************************
* _cache_print.
**********************************************************************/
static void	_cache_print	       (Cache		cache)
{
    unsigned int	index;
    unsigned int	count;

    count = cache->mask + 1;
    for (index = 0; index < count; index += 1)
        if (CACHE_BUCKET_VALID(cache->buckets[index]))
        {
            if (CACHE_BUCKET_IMP(cache->buckets[index]) == &_objc_msgForward)
                printf ("does not recognize: \n");
            printf ("%s\n", (const char *) CACHE_BUCKET_NAME(cache->buckets[index]));
        }
}

/***********************************************************************
* _class_printMethodCaches.
**********************************************************************/
void	_class_printMethodCaches       (Class		cls)
{
    if (((struct objc_class *)cls)->cache == &emptyCache)
        printf ("no instance-method cache for class %s\n", ((struct objc_class *)cls)->name);

    else
    {
        printf ("instance-method cache for class %s:\n", ((struct objc_class *)cls)->name);
        _cache_print (((struct objc_class *)cls)->cache);
    }

    if (((struct objc_class * )((struct objc_class * )cls)->isa)->cache == &emptyCache)
        printf ("no class-method cache for class %s\n", ((struct objc_class *)cls)->name);

    else
    {
        printf ("class-method cache for class %s:\n", ((struct objc_class *)cls)->name);
        _cache_print (((struct objc_class * )((struct objc_class * )cls)->isa)->cache);
    }
}

/***********************************************************************
* log2.
**********************************************************************/
static unsigned int	log2	       (unsigned int	x)
{
    unsigned int	log;

    log = 0;
    while (x >>= 1)
        log += 1;

    return log;
}

/***********************************************************************
* _class_printDuplicateCacheEntries.
**********************************************************************/
void	_class_printDuplicateCacheEntries	   (BOOL	detail)
{
    NXHashTable *	class_hash;
    NXHashState	state;
    struct objc_class *		cls;
    unsigned int	duplicates;
    unsigned int	index1;
    unsigned int	index2;
    unsigned int	mask;
    unsigned int	count;
    unsigned int	isMeta;
    Cache		cache;


    printf ("Checking for duplicate cache entries \n");

    // Outermost loop - iterate over all classes
    class_hash = objc_getClasses ();
    state	   = NXInitHashState (class_hash);
    duplicates = 0;
    while (NXNextHashState (class_hash, &state, (void **) &cls))
    {
        // Control loop - do given class' cache, then its isa's cache
        for (isMeta = 0; isMeta <= 1; isMeta += 1)
        {
            // Select cache of interest and make sure it exists
            cache = isMeta ? cls->isa->cache : ((struct objc_class *)cls)->cache;
            if (cache == &emptyCache)
                continue;

            // Middle loop - check each entry in the given cache
            mask  = cache->mask;
            count = mask + 1;
            for (index1 = 0; index1 < count; index1 += 1)
            {
                // Skip invalid entry
                if (!CACHE_BUCKET_VALID(cache->buckets[index1]))
                    continue;

                // Inner loop - check that given entry matches no later entry
                for (index2 = index1 + 1; index2 < count; index2 += 1)
                {
                    // Skip invalid entry
                    if (!CACHE_BUCKET_VALID(cache->buckets[index2]))
                        continue;

                    // Check for duplication by method name comparison
                    if (strcmp ((char *) CACHE_BUCKET_NAME(cache->buckets[index1]),
                                (char *) CACHE_BUCKET_NAME(cache->buckets[index2])) == 0)
                    {
                        if (detail)
                            printf ("%s %s\n", ((struct objc_class *)cls)->name, (char *) CACHE_BUCKET_NAME(cache->buckets[index1]));
                        duplicates += 1;
                        break;
                    }
                }
            }
        }
    }

    // Log the findings
    printf ("duplicates = %d\n", duplicates);
    printf ("total cache fills = %d\n", totalCacheFills);
}

/***********************************************************************
* PrintCacheHeader.
**********************************************************************/
static void	PrintCacheHeader        (void)
{
#ifdef OBJC_INSTRUMENTED
    printf ("Cache  Cache  Slots  Avg    Max   AvgS  MaxS  AvgS  MaxS  TotalD   AvgD  MaxD  TotalD   AvgD  MaxD  TotD  AvgD  MaxD\n");
    printf ("Size   Count  Used   Used   Used  Hit   Hit   Miss  Miss  Hits     Prbs  Prbs  Misses   Prbs  Prbs  Flsh  Flsh  Flsh\n");
    printf ("-----  -----  -----  -----  ----  ----  ----  ----  ----  -------  ----  ----  -------  ----  ----  ----  ----  ----\n");
#else
    printf ("Cache  Cache  Slots  Avg    Max   AvgS  MaxS  AvgS  MaxS\n");
    printf ("Size   Count  Used   Used   Used  Hit   Hit   Miss  Miss\n");
    printf ("-----  -----  -----  -----  ----  ----  ----  ----  ----\n");
#endif
}

/***********************************************************************
* PrintCacheInfo.
**********************************************************************/
static	void		PrintCacheInfo (unsigned int	cacheSize,
                             unsigned int	cacheCount,
                             unsigned int	slotsUsed,
                             float		avgUsed,
                             unsigned int	maxUsed,
                             float		avgSHit,
                             unsigned int	maxSHit,
                             float		avgSMiss,
                             unsigned int	maxSMiss
#ifdef OBJC_INSTRUMENTED
                             , unsigned int	totDHits,
                             float		avgDHit,
                             unsigned int	maxDHit,
                             unsigned int	totDMisses,
                             float		avgDMiss,
                             unsigned int	maxDMiss,
                             unsigned int	totDFlsh,
                             float		avgDFlsh,
                             unsigned int	maxDFlsh
#endif
                             )
{
#ifdef OBJC_INSTRUMENTED
    printf ("%5u  %5u  %5u  %5.1f  %4u  %4.1f  %4u  %4.1f  %4u  %7u  %4.1f  %4u  %7u  %4.1f  %4u  %4u  %4.1f  %4u\n",
#else
            printf ("%5u  %5u  %5u  %5.1f  %4u  %4.1f  %4u  %4.1f  %4u\n",
#endif
                    cacheSize, cacheCount, slotsUsed, avgUsed, maxUsed, avgSHit, maxSHit, avgSMiss, maxSMiss
#ifdef OBJC_INSTRUMENTED
                    , totDHits, avgDHit, maxDHit, totDMisses, avgDMiss, maxDMiss, totDFlsh, avgDFlsh, maxDFlsh
#endif
                    );
            
}

#ifdef OBJC_INSTRUMENTED
/***********************************************************************
* PrintCacheHistogram.  Show the non-zero entries from the specified
* cache histogram.
**********************************************************************/
static void	PrintCacheHistogram    (char *		title,
                                    unsigned int *	firstEntry,
                                    unsigned int	entryCount)
{
    unsigned int	index;
    unsigned int *	thisEntry;

    printf ("%s\n", title);
    printf ("    Probes    Tally\n");
    printf ("    ------    -----\n");
    for (index = 0, thisEntry = firstEntry;
         index < entryCount;
         index += 1, thisEntry += 1)
    {
        if (*thisEntry == 0)
            continue;

        printf ("    %6d    %5d\n", index, *thisEntry);
    }
}
#endif

/***********************************************************************
* _class_printMethodCacheStatistics.
**********************************************************************/

#define MAX_LOG2_SIZE		32
#define MAX_CHAIN_SIZE		100

void		_class_printMethodCacheStatistics		(void)
{
    unsigned int	isMeta;
    unsigned int	index;
    NXHashTable *	class_hash;
    NXHashState	state;
    struct objc_class *		cls;
    unsigned int	totalChain;
    unsigned int	totalMissChain;
    unsigned int	maxChain;
    unsigned int	maxMissChain;
    unsigned int	classCount;
    unsigned int	negativeEntryCount;
    unsigned int	cacheExpandCount;
    unsigned int	cacheCountBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	totalEntriesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	maxEntriesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	totalChainBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	totalMissChainBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	totalMaxChainBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	totalMaxMissChainBySize[2][MAX_LOG2_SIZE] = {{0}};
    unsigned int	maxChainBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	maxMissChainBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	chainCount[MAX_CHAIN_SIZE]		  = {0};
    unsigned int	missChainCount[MAX_CHAIN_SIZE]		  = {0};
#ifdef OBJC_INSTRUMENTED
    unsigned int	hitCountBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	hitProbesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	maxHitProbesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	missCountBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	missProbesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	maxMissProbesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	flushCountBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	flushedEntriesBySize[2][MAX_LOG2_SIZE]	  = {{0}};
    unsigned int	maxFlushedEntriesBySize[2][MAX_LOG2_SIZE] = {{0}};
#endif

    printf ("Printing cache statistics\n");

    // Outermost loop - iterate over all classes
    class_hash		= objc_getClasses ();
    state			= NXInitHashState (class_hash);
    classCount		= 0;
    negativeEntryCount	= 0;
    cacheExpandCount	= 0;
    while (NXNextHashState (class_hash, &state, (void **) &cls))
    {
        // Tally classes
        classCount += 1;

        // Control loop - do given class' cache, then its isa's cache
        for (isMeta = 0; isMeta <= 1; isMeta += 1)
        {
            Cache		cache;
            unsigned int	mask;
            unsigned int	log2Size;
            unsigned int	entryCount;

            // Select cache of interest
            cache = isMeta ? cls->isa->cache : ((struct objc_class *)cls)->cache;

            // Ignore empty cache... should we?
            if (cache == &emptyCache)
                continue;

            // Middle loop - do each entry in the given cache
            mask		= cache->mask;
            entryCount	= 0;
            totalChain	= 0;
            totalMissChain	= 0;
            maxChain	= 0;
            maxMissChain	= 0;
            for (index = 0; index < mask + 1; index += 1)
            {
                Method *			buckets;
                Method				method;
                uarith_t			hash;
                uarith_t			methodChain;
                uarith_t			methodMissChain;
                uarith_t			index2;

                // If entry is invalid, the only item of
                // interest is that future insert hashes
                // to this entry can use it directly.
                buckets = cache->buckets;
                if (!CACHE_BUCKET_VALID(buckets[index]))
                {
                    missChainCount[0] += 1;
                    continue;
                }

                method	= buckets[index];

                // Tally valid entries
                entryCount += 1;

                // Tally "forward::" entries
                if (CACHE_BUCKET_IMP(method) == &_objc_msgForward)
                    negativeEntryCount += 1;

                // Calculate search distance (chain length) for this method
                // The chain may wrap around to the beginning of the table.
                hash = CACHE_HASH(CACHE_BUCKET_NAME(method), mask);
                if (index >= hash) methodChain = index - hash;
                else methodChain = (mask+1) + index - hash;

                // Tally chains of this length
                if (methodChain < MAX_CHAIN_SIZE)
                    chainCount[methodChain] += 1;

                // Keep sum of all chain lengths
                totalChain += methodChain;

                // Record greatest chain length
                if (methodChain > maxChain)
                    maxChain = methodChain;

                // Calculate search distance for miss that hashes here
                index2	= index;
                while (CACHE_BUCKET_VALID(buckets[index2]))
                {
                    index2 += 1;
                    index2 &= mask;
                }
                methodMissChain = ((index2 - index) & mask);

                // Tally miss chains of this length
                if (methodMissChain < MAX_CHAIN_SIZE)
                    missChainCount[methodMissChain] += 1;

                // Keep sum of all miss chain lengths in this class
                totalMissChain += methodMissChain;

                // Record greatest miss chain length
                if (methodMissChain > maxMissChain)
                    maxMissChain = methodMissChain;
            }

            // Factor this cache into statistics about caches of the same
            // type and size (all caches are a power of two in size)
            log2Size						 = log2 (mask + 1);
            cacheCountBySize[isMeta][log2Size]			+= 1;
            totalEntriesBySize[isMeta][log2Size]			+= entryCount;
            if (entryCount > maxEntriesBySize[isMeta][log2Size])
                maxEntriesBySize[isMeta][log2Size]		 = entryCount;
            totalChainBySize[isMeta][log2Size]			+= totalChain;
            totalMissChainBySize[isMeta][log2Size]			+= totalMissChain;
            totalMaxChainBySize[isMeta][log2Size]			+= maxChain;
            totalMaxMissChainBySize[isMeta][log2Size]		+= maxMissChain;
            if (maxChain > maxChainBySize[isMeta][log2Size])
                maxChainBySize[isMeta][log2Size]		 = maxChain;
            if (maxMissChain > maxMissChainBySize[isMeta][log2Size])
                maxMissChainBySize[isMeta][log2Size]		 = maxMissChain;
#ifdef OBJC_INSTRUMENTED
            {
                CacheInstrumentation *	cacheData;

                cacheData = CACHE_INSTRUMENTATION(cache);
                hitCountBySize[isMeta][log2Size]			+= cacheData->hitCount;
                hitProbesBySize[isMeta][log2Size]			+= cacheData->hitProbes;
                if (cacheData->maxHitProbes > maxHitProbesBySize[isMeta][log2Size])
                    maxHitProbesBySize[isMeta][log2Size]		 = cacheData->maxHitProbes;
                missCountBySize[isMeta][log2Size]			+= cacheData->missCount;
                missProbesBySize[isMeta][log2Size]			+= cacheData->missProbes;
                if (cacheData->maxMissProbes > maxMissProbesBySize[isMeta][log2Size])
                    maxMissProbesBySize[isMeta][log2Size]		 = cacheData->maxMissProbes;
                flushCountBySize[isMeta][log2Size]			+= cacheData->flushCount;
                flushedEntriesBySize[isMeta][log2Size]			+= cacheData->flushedEntries;
                if (cacheData->maxFlushedEntries > maxFlushedEntriesBySize[isMeta][log2Size])
                    maxFlushedEntriesBySize[isMeta][log2Size]	 = cacheData->maxFlushedEntries;
            }
#endif
            // Caches start with a power of two number of entries, and grow by doubling, so
            // we can calculate the number of times this cache has expanded
            if (isMeta)
                cacheExpandCount += log2Size - INIT_META_CACHE_SIZE_LOG2;
            else
                cacheExpandCount += log2Size - INIT_CACHE_SIZE_LOG2;

        }
    }

    {
        unsigned int	cacheCountByType[2] = {0};
        unsigned int	totalCacheCount	    = 0;
        unsigned int	totalEntries	    = 0;
        unsigned int	maxEntries	    = 0;
        unsigned int	totalSlots	    = 0;
#ifdef OBJC_INSTRUMENTED
        unsigned int	totalHitCount	    = 0;
        unsigned int	totalHitProbes	    = 0;
        unsigned int	maxHitProbes	    = 0;
        unsigned int	totalMissCount	    = 0;
        unsigned int	totalMissProbes	    = 0;
        unsigned int	maxMissProbes	    = 0;
        unsigned int	totalFlushCount	    = 0;
        unsigned int	totalFlushedEntries = 0;
        unsigned int	maxFlushedEntries   = 0;
#endif

        totalChain	= 0;
        maxChain	= 0;
        totalMissChain	= 0;
        maxMissChain	= 0;

        // Sum information over all caches
        for (isMeta = 0; isMeta <= 1; isMeta += 1)
        {
            for (index = 0; index < MAX_LOG2_SIZE; index += 1)
            {
                cacheCountByType[isMeta] += cacheCountBySize[isMeta][index];
                totalEntries	   += totalEntriesBySize[isMeta][index];
                totalSlots	   += cacheCountBySize[isMeta][index] * (1 << index);
                totalChain	   += totalChainBySize[isMeta][index];
                if (maxEntriesBySize[isMeta][index] > maxEntries)
                    maxEntries  = maxEntriesBySize[isMeta][index];
                if (maxChainBySize[isMeta][index] > maxChain)
                    maxChain    = maxChainBySize[isMeta][index];
                totalMissChain	   += totalMissChainBySize[isMeta][index];
                if (maxMissChainBySize[isMeta][index] > maxMissChain)
                    maxMissChain = maxMissChainBySize[isMeta][index];
#ifdef OBJC_INSTRUMENTED
                totalHitCount	   += hitCountBySize[isMeta][index];
                totalHitProbes	   += hitProbesBySize[isMeta][index];
                if (maxHitProbesBySize[isMeta][index] > maxHitProbes)
                    maxHitProbes = maxHitProbesBySize[isMeta][index];
                totalMissCount	   += missCountBySize[isMeta][index];
                totalMissProbes	   += missProbesBySize[isMeta][index];
                if (maxMissProbesBySize[isMeta][index] > maxMissProbes)
                    maxMissProbes = maxMissProbesBySize[isMeta][index];
                totalFlushCount	   += flushCountBySize[isMeta][index];
                totalFlushedEntries += flushedEntriesBySize[isMeta][index];
                if (maxFlushedEntriesBySize[isMeta][index] > maxFlushedEntries)
                    maxFlushedEntries = maxFlushedEntriesBySize[isMeta][index];
#endif
            }

            totalCacheCount += cacheCountByType[isMeta];
        }

        // Log our findings
        printf ("There are %u classes\n", classCount);

        for (isMeta = 0; isMeta <= 1; isMeta += 1)
        {
            // Number of this type of class
            printf    ("\nThere are %u %s-method caches, broken down by size (slot count):\n",
                       cacheCountByType[isMeta],
                       isMeta ? "class" : "instance");

            // Print header
            PrintCacheHeader ();

            // Keep format consistent even if there are caches of this kind
            if (cacheCountByType[isMeta] == 0)
            {
                printf ("(none)\n");
                continue;
            }

            // Usage information by cache size
            for (index = 0; index < MAX_LOG2_SIZE; index += 1)
            {
                unsigned int	cacheCount;
                unsigned int	cacheSlotCount;
                unsigned int	cacheEntryCount;

                // Get number of caches of this type and size
                cacheCount = cacheCountBySize[isMeta][index];
                if (cacheCount == 0)
                    continue;

                // Get the cache slot count and the total number of valid entries
                cacheSlotCount  = (1 << index);
                cacheEntryCount = totalEntriesBySize[isMeta][index];

                // Give the analysis
                PrintCacheInfo (cacheSlotCount,
                                cacheCount,
                                cacheEntryCount,
                                (float) cacheEntryCount / (float) cacheCount,
                                maxEntriesBySize[isMeta][index],
                                (float) totalChainBySize[isMeta][index] / (float) cacheEntryCount,
                                maxChainBySize[isMeta][index],
                                (float) totalMissChainBySize[isMeta][index] / (float) (cacheCount * cacheSlotCount),
                                maxMissChainBySize[isMeta][index]
#ifdef OBJC_INSTRUMENTED
                                , hitCountBySize[isMeta][index],
                                hitCountBySize[isMeta][index] ?
                                (float) hitProbesBySize[isMeta][index] / (float) hitCountBySize[isMeta][index] : 0.0,
                                maxHitProbesBySize[isMeta][index],
                                missCountBySize[isMeta][index],
                                missCountBySize[isMeta][index] ?
                                (float) missProbesBySize[isMeta][index] / (float) missCountBySize[isMeta][index] : 0.0,
                                maxMissProbesBySize[isMeta][index],
                                flushCountBySize[isMeta][index],
                                flushCountBySize[isMeta][index] ?
                                (float) flushedEntriesBySize[isMeta][index] / (float) flushCountBySize[isMeta][index] : 0.0,
                                maxFlushedEntriesBySize[isMeta][index]
#endif
                                );
            }
        }

        // Give overall numbers
        printf ("\nCumulative:\n");
        PrintCacheHeader ();
        PrintCacheInfo (totalSlots,
                        totalCacheCount,
                        totalEntries,
                        (float) totalEntries / (float) totalCacheCount,
                        maxEntries,
                        (float) totalChain / (float) totalEntries,
                        maxChain,
                        (float) totalMissChain / (float) totalSlots,
                        maxMissChain
#ifdef OBJC_INSTRUMENTED
                        , totalHitCount,
                        totalHitCount ?
                        (float) totalHitProbes / (float) totalHitCount : 0.0,
                        maxHitProbes,
                        totalMissCount,
                        totalMissCount ?
                        (float) totalMissProbes / (float) totalMissCount : 0.0,
                        maxMissProbes,
                        totalFlushCount,
                        totalFlushCount ?
                        (float) totalFlushedEntries / (float) totalFlushCount : 0.0,
                        maxFlushedEntries
#endif
                        );

        printf ("\nNumber of \"forward::\" entries: %d\n", negativeEntryCount);
        printf ("Number of cache expansions: %d\n", cacheExpandCount);
#ifdef OBJC_INSTRUMENTED
        printf ("flush_caches:   total calls  total visits  average visits  max visits  total classes  visits/class\n");
        printf ("                -----------  ------------  --------------  ----------  -------------  -------------\n");
        printf ("  linear        %11u  %12u  %14.1f  %10u  %13u  %12.2f\n",
                LinearFlushCachesCount,
                LinearFlushCachesVisitedCount,
                LinearFlushCachesCount ?
                (float) LinearFlushCachesVisitedCount / (float) LinearFlushCachesCount : 0.0,
                MaxLinearFlushCachesVisitedCount,
                LinearFlushCachesVisitedCount,
                1.0);
        printf ("  nonlinear     %11u  %12u  %14.1f  %10u  %13u  %12.2f\n",
                NonlinearFlushCachesCount,
                NonlinearFlushCachesVisitedCount,
                NonlinearFlushCachesCount ?
                (float) NonlinearFlushCachesVisitedCount / (float) NonlinearFlushCachesCount : 0.0,
                MaxNonlinearFlushCachesVisitedCount,
                NonlinearFlushCachesClassCount,
                NonlinearFlushCachesClassCount ?
                (float) NonlinearFlushCachesVisitedCount / (float) NonlinearFlushCachesClassCount : 0.0);
        printf ("  ideal         %11u  %12u  %14.1f  %10u  %13u  %12.2f\n",
                LinearFlushCachesCount + NonlinearFlushCachesCount,
                IdealFlushCachesCount,
                LinearFlushCachesCount + NonlinearFlushCachesCount ?
                (float) IdealFlushCachesCount / (float) (LinearFlushCachesCount + NonlinearFlushCachesCount) : 0.0,
                MaxIdealFlushCachesCount,
                LinearFlushCachesVisitedCount + NonlinearFlushCachesClassCount,
                LinearFlushCachesVisitedCount + NonlinearFlushCachesClassCount ?
                (float) IdealFlushCachesCount / (float) (LinearFlushCachesVisitedCount + NonlinearFlushCachesClassCount) : 0.0);

        PrintCacheHistogram ("\nCache hit histogram:",  &CacheHitHistogram[0],  CACHE_HISTOGRAM_SIZE);
        PrintCacheHistogram ("\nCache miss histogram:", &CacheMissHistogram[0], CACHE_HISTOGRAM_SIZE);
#endif

#if 0
        printf ("\nLookup chains:");
        for (index = 0; index < MAX_CHAIN_SIZE; index += 1)
        {
            if (chainCount[index] != 0)
                printf ("  %u:%u", index, chainCount[index]);
        }

        printf ("\nMiss chains:");
        for (index = 0; index < MAX_CHAIN_SIZE; index += 1)
        {
            if (missChainCount[index] != 0)
                printf ("  %u:%u", index, missChainCount[index]);
        }

        printf ("\nTotal memory usage for cache data structures: %lu bytes\n",
                totalCacheCount * (sizeof(struct objc_cache) - sizeof(Method)) +
                totalSlots * sizeof(Method) +
                negativeEntryCount * sizeof(struct objc_method));
#endif
    }
}

/***********************************************************************
* checkUniqueness.
**********************************************************************/
void		checkUniqueness	       (SEL		s1,
                              SEL		s2)
{
    if (s1 == s2)
        return;

    if (s1 && s2 && (strcmp ((const char *) s1, (const char *) s2) == 0))
        _objc_inform ("%p != %p but !strcmp (%s, %s)\n", s1, s2, (char *) s1, (char *) s2);
}

