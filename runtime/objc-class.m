/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Portions Copyright (c) 1999 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.1 (the "License").  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON- INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
/***********************************************************************
 *	objc-class.m
 *	Copyright 1988-1997, Apple Computer, Inc.
 *	Author:	s. naroff
 **********************************************************************/

/***********************************************************************
 * Imports.
 **********************************************************************/

#ifdef __MACH__
	#import <mach/mach_interface.h>
	#include <mach-o/ldsyms.h>
	#include <mach-o/dyld.h>
#endif

#ifdef WIN32
	#include <io.h>
	#include <fcntl.h>
	#include <winnt-pdo.h>
#else
	#include <sys/types.h>
	#include <unistd.h>
	#include <stdlib.h>
	#include <sys/uio.h>
	#ifdef __svr4__
		#include <fcntl.h>
	#else
		#include <sys/fcntl.h>
	#endif
#endif 

#if defined(__svr4__) || defined(__hpux__) || defined(hpux)
	#import <pdo.h>
#endif

#import <objc/Object.h>
#import <objc/objc-runtime.h>
#import "objc-private.h"
#import "hashtable2.h"
#import "maptable.h"

#include <sys/types.h>

#include <CoreFoundation/CFDictionary.h>

// Needed functions not in any header file
size_t malloc_size (const void * ptr);

// Needed kernel interface
#import <mach/mach.h>
#ifdef __MACH__
#import <mach/thread_status.h>
#endif

// This is currently disabled in this file, because it is called a LOT here; turn it on when needed.
#if 0 && defined(__MACH__)
extern int ptrace(int, int, int, int); 
// ObjC is assigned the range 0xb000 - 0xbfff for first parameter; this file 0xb300-0xb3ff
#else
#define ptrace(a, b, c, d) do {} while (0)
#endif

/***********************************************************************
 * Conditionals.
 **********************************************************************/

// Define PRELOAD_SUPERCLASS_CACHES to cause method lookups to add the
// method the appropriate superclass caches, in addition to the normal
// encaching in the subclass where the method was messaged.  Doing so
// will speed up messaging the same method from instances of the
// superclasses, but also uses up valuable cache space for a speculative
// purpose
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

// Class state
#define ISCLASS(cls)		((((struct objc_class *) cls)->info & CLS_CLASS) != 0)
#define ISMETA(cls)		((((struct objc_class *) cls)->info & CLS_META) != 0)
#define GETMETA(cls)		(ISMETA(cls) ? ((struct objc_class *) cls) : ((struct objc_class *) cls)->isa)
#define ISINITIALIZED(cls)	((GETMETA(cls)->info & CLS_INITIALIZED) != 0)
#define MARKINITIALIZED(cls)	(GETMETA(cls)->info |= CLS_INITIALIZED)

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
static void		addClassToOriginalClass	(Class posingClass, Class originalClass);
static void		_objc_addOrigClass		(Class origClass);
static void		_freedHandler			(id self, SEL sel); 
static void		_nonexistentHandler		(id self, SEL sel);
static void		class_initialize		(Class clsDesc);
static void *	objc_malloc				(int byteCount);
static Cache	_cache_expand			(Class cls);
static int		LogObjCMessageSend		(BOOL isClassMethod, const char * objectsClass, const char * implementingClass, SEL selector);
static void		_cache_fill				(Class cls, Method smt, SEL sel);
static void		_cache_flush			(Class cls);
static Method	_class_lookupMethod		(Class cls, SEL sel);
static int		SubtypeUntil			(const char * type, char end); 
static const char *	SkipFirstType		(const char * type); 

#ifdef OBJC_COLLECTING_CACHE
static unsigned long	_get_pc_for_thread	(mach_port_t thread);
static int		_collecting_in_critical	(void);
static void		_garbage_make_room		(void);
static void		_cache_collect_free		(void * data, BOOL tryCollect);
#endif

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

// Locks for cache access
#ifdef OBJC_COLLECTING_CACHE
// Held when adding an entry to the cache
static OBJC_DECLARE_LOCK(cacheUpdateLock);

// Held when freeing memory from garbage
static OBJC_DECLARE_LOCK(cacheCollectionLock);
#endif

// Held when looking in, adding to, or freeing the cache.
#ifdef OBJC_COLLECTING_CACHE
// For speed, messageLock is not held by the method dispatch code.
// Instead the cache freeing code checks thread PCs to ensure no
// one is dispatching.  messageLock is held, though, during less
// time critical operations.
#endif
OBJC_DECLARE_LOCK(messageLock);

CFMutableDictionaryRef _classIMPTables = NULL;

// When traceDuplicates is non-zero, _cacheFill checks whether the method
// being encached is already there.  The number of times it finds a match
// is tallied in cacheFillDuplicates.  When traceDuplicatesVerbose is
// non-zero, each duplication is logged when found in this way.
#ifdef OBJC_COLLECTING_CACHE
static int	traceDuplicates		= 0;
static int	traceDuplicatesVerbose	= 0;
static int	cacheFillDuplicates	= 0;
#endif 

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

static int			totalCacheFills		= 0;
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

const struct objc_cache		emptyCache =
{
	0,				// mask
	0,				// occupied
	{ NULL }			// buckets
};

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
 * _internal_class_createInstanceFromZone.  Allocate an instance of the
 * specified class with the specified number of bytes for indexed
 * variables, in the specified zone.  The isa field is set to the
 * class, all other fields are zeroed.
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

static void _addListIMPsToTable(CFMutableDictionaryRef table, struct objc_method_list *mlist, Class cls, void **iterator) {
    int i;
    struct objc_method_list *new_mlist;
    if (!mlist) return;
    /* Work from end of list so that categories override */
    new_mlist = _class_inlinedNextMethodList(cls, iterator);
    _addListIMPsToTable(table, new_mlist, cls, iterator);
    for (i = 0; i < mlist->method_count; i++) {
	CFDictionarySetValue(table, mlist->method_list[i].method_name, mlist->method_list[i].method_imp);
    }
}

static void _addClassIMPsToTable(CFMutableDictionaryRef table, Class cls) {
    struct objc_method_list *mlist;
    void *iterator = 0;
#ifdef INCLUDE_SUPER_IMPS_IN_IMP_TABLE
    if (cls->super_class) {	/* Do superclass first so subclass overrides */
	CFMutableDictionaryRef super_table = CFDictionaryGetValue(_classIMPTables, cls->super_class);
	if (super_table) {
	    CFIndex cnt;
	    const void **keys, **values, *buffer1[128], *buffer2[128];
	    cnt = CFDictionaryGetCount(super_table);
	    keys = (cnt <= 128) ? buffer1 : CFAllocatorAllocate(NULL, cnt * sizeof(void *), 0);
	    values = (cnt <= 128) ? buffer2 : CFAllocatorAllocate(NULL, cnt * sizeof(void *), 0);
	    CFDictionaryGetKeysAndValues(super_table, keys, values);
	    while (cnt--) {
		CFDictionarySetValue(table, keys[cnt], values[cnt]);
	    }
	    if (keys != buffer1) CFAllocatorDeallocate(NULL, keys);
	    if (values != buffer2) CFAllocatorDeallocate(NULL, values);
	} else {
	    _addClassIMPsToTable(table, cls->super_class);
	}
    }
#endif
    mlist = _class_inlinedNextMethodList(cls, &iterator);
    _addListIMPsToTable(table, mlist, cls, &iterator);
}

CFMutableDictionaryRef _getClassIMPTable(Class cls) {
    CFMutableDictionaryRef table;
    if (NULL == _classIMPTables) {
	// maps Classes to mutable dictionaries
	_classIMPTables = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    }
    table = (CFMutableDictionaryRef)CFDictionaryGetValue(_classIMPTables, cls);
    // IMP table maps SELs to IMPS
    if (NULL == table) {
	table = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
	_addClassIMPsToTable(table, cls);
	CFDictionaryAddValue(_classIMPTables, cls, table);
    }
    return table;
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

/* These next three functions are the heart of ObjC method lookup. */
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

static inline Method _findMethodInClass(Class cls, SEL sel) {
    struct objc_method_list *mlist;
    void *iterator = 0;
    while ((mlist = _class_inlinedNextMethodList(cls, &iterator))) {
	Method m = _findMethodInList(mlist, sel);
	if (m) return m;
    }
    return NULL;
}

static inline Method _getMethod(Class cls, SEL sel) {
    for (; cls; cls = cls->super_class) {
        Method m = _findMethodInClass(cls, sel);
	if (m) return m;
    }
    return NULL;
}


/***********************************************************************
 * class_getInstanceMethod.  Return the instance method for the
 * specified class and selector.
 **********************************************************************/
Method		class_getInstanceMethod	       (Class		aClass,
						SEL		aSelector)
{
	// Need both a class and a selector
	if (!aClass || !aSelector)
		return NULL;

	// Go to the class
	return _getMethod (aClass, aSelector);
}

/***********************************************************************
 * class_getClassMethod.  Return the class method for the specified
 * class and selector.
 **********************************************************************/
Method		class_getClassMethod	       (Class		aClass,
						SEL		aSelector)
{
	// Need both a class and a selector
	if (!aClass || !aSelector)
		return NULL;

	// Go to the class or isa
	return _getMethod (GETMETA(aClass), aSelector);
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
static void	flush_caches	       (Class		cls,
					BOOL		flush_meta)
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
	if (cls && !((struct objc_class *) cls)->cache)
		return;

	newNumClasses = objc_getClassList((Class *)NULL, 0);
	while (numClasses < newNumClasses) {
		numClasses = newNumClasses;
		classes = realloc(classes, sizeof(Class) * numClasses);
		newNumClasses = objc_getClassList((Class *)classes, numClasses);
	}
	numClasses = newNumClasses;

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
			metaClsObject = ((struct objc_class *) clsObject)->isa;
			if (cls && metaClsObject && (((struct objc_class *) metaClsObject)->isa != ((struct objc_class *) metaClsObject)->isa))
				continue;

#ifdef OBJC_INSTRUMENTED
			subclassCount += 1;
#endif

			// Be careful of classes that do not yet have caches
			if (((struct objc_class *) clsObject)->cache)
				_cache_flush (clsObject);
			if (flush_meta && metaClsObject && ((struct objc_class *) metaClsObject)->cache)
				_cache_flush (((struct objc_class *) clsObject)->isa);
		}
#ifdef OBJC_INSTRUMENTED
		LinearFlushCachesVisitedCount += classesVisited;
		if (classesVisited > MaxLinearFlushCachesVisitedCount)
			MaxLinearFlushCachesVisitedCount = classesVisited;
		IdealFlushCachesCount += subclassCount;
		if (subclassCount > MaxIdealFlushCachesCount)
			MaxIdealFlushCachesCount = subclassCount;
#endif

		free(classes);
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

	// Relinquish access to class hash table
	free(classes);
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
 *
 * usage:
 * void *	iterator = 0;
 * while (class_nextMethodList (cls, &iterator)) {...}
 **********************************************************************/
OBJC_EXPORT struct objc_method_list * class_nextMethodList (Class	cls,
							    void **	it)
{
    return _class_inlinedNextMethodList(cls, it);
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
	// Insert atomically.
	_objc_insertMethods (meths, &((struct objc_class *) cls)->methodLists);
	
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
	// Remove atomically.
	_objc_removeMethods (meths, &((struct objc_class *) cls)->methodLists);
	
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
						  _objc_create_zone ());
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
							     _objc_create_zone ());
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
	char			imposterName[256]; 
	char *			imposterNamePtr; 
	NXHashTable *		class_hash;
	NXHashState		state;
	struct objc_class * 			copy;
#ifdef OBJC_CLASS_REFS
	unsigned int		hidx;
	unsigned int		hdrCount;
	header_info *		hdrVector;

	// Get these now before locking, to minimize impact
	hdrCount  = _objc_headerCount ();
	hdrVector = _objc_headerVector (NULL);
#endif

	// Trivial case is easy
	if (imposter == original) 
		return imposter;

	// Imposter must be an immediate subclass of the original
	if (((struct objc_class *)imposter)->super_class != original)
		return (Class) [(id) imposter error:_errNotSuper, 
				((struct objc_class *)imposter)->name, ((struct objc_class *)original)->name];
	
	// Can't pose when you have instance variables (how could it work?)
	if (((struct objc_class *)imposter)->ivars)
		return (Class) [(id) imposter error:_errNewVars, ((struct objc_class *)imposter)->name, 
				((struct objc_class *)original)->name, ((struct objc_class *)imposter)->name];

	// Build a string to use to replace the name of the original class.
	strcpy (imposterName, "_%"); 
	strcat (imposterName, ((struct objc_class *)original)->name);
	imposterNamePtr = objc_malloc (strlen (imposterName)+1);
	strcpy (imposterNamePtr, imposterName);

	// We lock the class hashtable, so we are thread safe with respect to
	// calls to objc_getClass ().  However, the class names are not
	// changed atomically, nor are all of the subclasses updated
	// atomically.  I have ordered the operations so that you will
	// never crash, but you may get inconsistent results....

	// Register the original class so that [super ..] knows
	// exactly which classes are the "original" classes.
	_objc_addOrigClass (original);
	_objc_addOrigClass (imposter);

	OBJC_LOCK(&classLock);

	class_hash = objc_getClasses ();

	// Remove both the imposter and the original class.
	NXHashRemove (class_hash, imposter);
	NXHashRemove (class_hash, original);

	// Copy the imposter, so that the imposter can continue
	// its normal life in addition to changing the behavior of
	// the original.  As a hack we don't bother to copy the metaclass.
	// For some reason we modify the original rather than the copy.
	copy = (*_zoneAlloc)(imposter->isa, sizeof(struct objc_class), _objc_create_zone());
	memmove(copy, imposter, sizeof(struct objc_class));

	NXHashInsert (class_hash, copy);
	addClassToOriginalClass (imposter, copy);

	// Mark the imposter as such
	CLS_SETINFO(((struct objc_class *)imposter), CLS_POSING);
	CLS_SETINFO(((struct objc_class *)imposter)->isa, CLS_POSING);

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
	for (hidx = 0; hidx < hdrCount; hidx += 1)
	{
		Class *		cls_refs;
		unsigned int	refCount;
		unsigned int	index;
		
		// Get refs associated with this header
		cls_refs = (Class *) _getObjcClassRefs ((headerType *) hdrVector[hidx].mhdr, &refCount);
		if (!cls_refs || !refCount)
			continue;

		// Minor loop - process this header's refs
		cls_refs = (Class *) ((unsigned long) cls_refs + hdrVector[hidx].image_slide);
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
 * class_initialize.  Send the 'initialize' message on demand to any
 * uninitialized class. Force initialization of superclasses first.
 *
 * Called only from _class_lookupMethodAndLoadCache (or itself).
 *
 * #ifdef OBJC_COLLECTING_CACHE
 *    The messageLock can be in either state.
 * #else
 *    The messageLock is already assumed to be taken out.
 *    It is temporarily released while the initialize method is sent. 
 * #endif
 **********************************************************************/
static void	class_initialize	       (Class		clsDesc)
{
	struct objc_class *	super;

	// Skip if someone else beat us to it
	if (ISINITIALIZED(((struct objc_class *)clsDesc)))
		return;

	// Force initialization of superclasses first
	super = ((struct objc_class *)clsDesc)->super_class;
	if ((super != Nil) && (!ISINITIALIZED(super)))
		class_initialize (super);

	// Initializing the super class might have initialized us,
	// or another thread might have initialized us during this time.
	if (ISINITIALIZED(((struct objc_class *)clsDesc)))
		return;

	// Mark the class initialized so it can receive the "initialize"
	// message.  This solution to the catch-22 is the source of a
	// bug: the class is able to receive messages *from anyone* now
	// that it is marked, even though initialization is not complete.
	MARKINITIALIZED(((struct objc_class *)clsDesc));

#ifndef OBJC_COLLECTING_CACHE
	// Release the message lock so that messages can be sent.
	OBJC_UNLOCK(&messageLock);
#endif

	// Send the initialize method.
	[(id)clsDesc initialize];

#ifndef OBJC_COLLECTING_CACHE
	// Re-acquire the lock
	OBJC_LOCK(&messageLock);
#endif

	return;
}

/***********************************************************************
 * _class_install_relationships.  Fill in the class pointers of a class
 * that was loaded before some or all of the classes it needs to point to.
 * The deal here is that the class pointer fields have been usurped to
 * hold the string name of the pertinent class.  Our job is to look up
 * the real thing based on those stored names.
 **********************************************************************/
void	_class_install_relationships	       (Class	cls,
						long	version)
{
	struct objc_class *		meta;
	struct objc_class *		clstmp;

	// Get easy access to meta class structure
	meta = ((struct objc_class *)cls)->isa;
	
	// Set version in meta class strucure
	meta->version = version;

	// Install superclass based on stored name.  No name iff
	// cls is a root class.
	if (((struct objc_class *)cls)->super_class)
	{
		clstmp = objc_getClass ((const char *) ((struct objc_class *)cls)->super_class);
		if (!clstmp)
		{
			_objc_inform("failed objc_getClass(%s) for %s->super_class", (const char *)((struct objc_class *)cls)->super_class, ((struct objc_class *)cls)->name);
			goto Error;
		}
		
		((struct objc_class *)cls)->super_class = clstmp;
	}

	// Install meta's isa based on stored name.  Meta class isa
	// pointers always point to the meta class of the root class
	// (root meta class, too, it points to itself!).
	clstmp = objc_getClass ((const char *) meta->isa);
	if (!clstmp)
	{
		_objc_inform("failed objc_getClass(%s) for %s->isa->isa", (const char *) meta->isa, ((struct objc_class *)cls)->name);
		goto Error;
	}
	
	meta->isa = clstmp->isa;

	// Install meta's superclass based on stored name.  No name iff
	// cls is a root class.
	if (meta->super_class)
	{
		// Locate instance class of super class
		clstmp = objc_getClass ((const char *) meta->super_class);
		if (!clstmp)
		{
			_objc_inform("failed objc_getClass(%s) for %s->isa->super_class", (const char *)meta->super_class, ((struct objc_class *)cls)->name);
			goto Error;
		}
		
		// Store meta class of super class
		meta->super_class = clstmp->isa;
	}

	// cls is root, so `tie' the (root) meta class down to its
	// instance class.  This way, class methods can come from
	// the root instance class.
	else
		((struct objc_class *)meta)->super_class = cls;

	// Use common static empty cache instead of NULL
	if (((struct objc_class *)cls)->cache == NULL)
		((struct objc_class *)cls)->cache = (Cache) &emptyCache;
	if (((struct objc_class *)meta)->cache == NULL)
		((struct objc_class *)meta)->cache = (Cache) &emptyCache;

	return;

Error:
	_objc_fatal ("please link appropriate classes in your program");
}

/***********************************************************************
 * objc_malloc.
 **********************************************************************/
static void *		objc_malloc		   (int		byteCount)
{
	void *		space;

	space = malloc_zone_malloc (_objc_create_zone (), byteCount);
	if (!space && byteCount)
		_objc_fatal ("unable to allocate space");

#ifdef WIN32
	bzero (space, byteCount);
#endif

	return space;
}


/***********************************************************************
 * class_respondsToMethod.
 *
 * Called from -[Object respondsTo:] and +[Object instancesRespondTo:]
 **********************************************************************/
BOOL	class_respondsToMethod	       (Class		cls,
					SEL		sel)
{
	struct objc_class *				thisCls;
	arith_t				index;
	arith_t				mask;
	Method *			buckets;
	Method				meth;
	
	// No one responds to zero!
	if (!sel) 
		return NO;

	// Synchronize access to caches
	OBJC_LOCK(&messageLock);

	// Look in the cache of the specified class
	mask	= ((struct objc_class *)cls)->cache->mask;
	buckets	= ((struct objc_class *)cls)->cache->buckets;
	index	= ((uarith_t) sel & mask);
	while (CACHE_BUCKET_VALID(buckets[index])) {
		if (CACHE_BUCKET_NAME(buckets[index]) == sel) {
			if (CACHE_BUCKET_IMP(buckets[index]) == &_objc_msgForward) {
				OBJC_UNLOCK(&messageLock);
				return NO;
			} else {
				OBJC_UNLOCK(&messageLock);
				return YES;
			}
		}
		
		index += 1;
		index &= mask;
	}

	// Handle cache miss
	meth = _getMethod(cls, sel);
	if (meth) {
		OBJC_UNLOCK(&messageLock);
		_cache_fill (cls, meth, sel);
		return YES;
	}
	
	// Not implememted.  Use _objc_msgForward.
	{
	Method	smt;

	smt = malloc_zone_malloc (_objc_create_zone(), sizeof(struct objc_method));
	smt->method_name	= sel;
	smt->method_types	= "";
	smt->method_imp		= &_objc_msgForward;
	_cache_fill (cls, smt, sel);
	}

	OBJC_UNLOCK(&messageLock);
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
	Method *	buckets;
	arith_t		index;
	arith_t		mask;
	IMP		result;
	
	// No one responds to zero!
	if (!sel) 
		[(id) cls error:_errBadSel, sel];

	// Synchronize access to caches
	OBJC_LOCK(&messageLock);

	// Scan the cache
	mask	= ((struct objc_class *)cls)->cache->mask;
	buckets	= ((struct objc_class *)cls)->cache->buckets;
	index	= ((unsigned int) sel & mask);
	while (CACHE_BUCKET_VALID(buckets[index]))
	{
		if (CACHE_BUCKET_NAME(buckets[index]) == sel)
		{
			result = CACHE_BUCKET_IMP(buckets[index]);
			OBJC_UNLOCK(&messageLock);
			return result;
		}
		
		index += 1;
		index &= mask;
	}

	// Handle cache miss
	result = _class_lookupMethodAndLoadCache (cls, sel);
	OBJC_UNLOCK(&messageLock);
	return result;
}

/***********************************************************************
 * class_lookupMethodInMethodList.
 *
 * Called from objc-load.m and _objc_callLoads ()
 **********************************************************************/
IMP	class_lookupMethodInMethodList (struct objc_method_list *	mlist,
					SEL				sel)
{
    Method m = _findMethodInList(mlist, sel);
    return (m ? m->method_imp : NULL);
}

IMP	class_lookupNamedMethodInMethodList(struct objc_method_list *mlist,
					const char *meth_name)
{
    Method m = meth_name ? _findNamedMethodInList(mlist, meth_name) : NULL;
    return (m ? m->method_imp : NULL);
}

/***********************************************************************
 * _cache_create.
 *
 * Called from _cache_expand () and objc_addClass ()
 **********************************************************************/
Cache		_cache_create		(Class		cls)
{
	Cache		new_cache;
	int			slotCount;
	int			index;

	// Select appropriate size
	slotCount = (ISMETA(cls)) ? INIT_META_CACHE_SIZE : INIT_CACHE_SIZE;

	// Allocate table (why not check for failure?)
#ifdef OBJC_INSTRUMENTED
	new_cache = malloc_zone_malloc (_objc_create_zone(),
			sizeof(struct objc_cache) + TABLE_SIZE(slotCount)
			 + sizeof(CacheInstrumentation));
#else
	new_cache = malloc_zone_malloc (_objc_create_zone(),
			sizeof(struct objc_cache) + TABLE_SIZE(slotCount));
#endif

	// Invalidate all the buckets
	for (index = 0; index < slotCount; index += 1)
		CACHE_BUCKET_VALID(new_cache->buckets[index]) = NULL;
	
	// Zero the valid-entry counter
	new_cache->occupied = 0;
	
	// Set the mask so indexing wraps at the end-of-table
	new_cache->mask = slotCount - 1;

#ifdef OBJC_INSTRUMENTED
	{
	CacheInstrumentation *	cacheData;

	// Zero out the cache dynamic instrumention data
	cacheData = CACHE_INSTRUMENTATION(new_cache);
	bzero ((char *) cacheData, sizeof(CacheInstrumentation));
	}
#endif

	// Install the cache
	((struct objc_class *)cls)->cache = new_cache;

	// Clear the cache flush flag so that we will not flush this cache
	// before expanding it for the first time.
	((struct objc_class * )cls)->info &= ~(CLS_FLUSH_CACHE);

	// Clear the grow flag so that we will re-use the current storage,
	// rather than actually grow the cache, when expanding the cache
	// for the first time
	if (_class_slow_grow)
		((struct objc_class * )cls)->info &= ~(CLS_GROW_CACHE);

	// Return our creation
	return new_cache;
}

/***********************************************************************
 * _cache_expand.
 *
 * #ifdef OBJC_COLLECTING_CACHE
 *	The cacheUpdateLock is assumed to be taken at this point. 
 * #endif
 *
 * Called from _cache_fill ()
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
			((struct objc_class * )cls)->info &= ~CLS_GROW_CACHE;

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
#ifdef OBJC_COLLECTING_CACHE
					_cache_collect_free (oldEntry, NO);
#else
					malloc_zone_free (_objc_create_zone(), oldEntry);
#endif
				}
			}
			
			// Set the slow growth flag so the cache is next grown
			((struct objc_class * )cls)->info |= CLS_GROW_CACHE;
			
			// Return the same old cache, freshly emptied
			return old_cache;
		}
		
	}

	// Double the cache size
	slotCount = (old_cache->mask + 1) << 1;
	
	// Allocate a new cache table
#ifdef OBJC_INSTRUMENTED
	new_cache = malloc_zone_malloc (_objc_create_zone(),
			sizeof(struct objc_cache) + TABLE_SIZE(slotCount)
			 + sizeof(CacheInstrumentation));
#else
	new_cache = malloc_zone_malloc (_objc_create_zone(),
			sizeof(struct objc_cache) + TABLE_SIZE(slotCount));
#endif

	// Zero out the new cache
	new_cache->mask = slotCount - 1;
	new_cache->occupied = 0;
	for (index = 0; index < slotCount; index += 1)
		CACHE_BUCKET_VALID(new_cache->buckets[index]) = NULL;

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
			index2 = ((unsigned int) CACHE_BUCKET_NAME(old_cache->buckets[index]) & newMask);
			
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
		((struct objc_class * )cls)->info |= CLS_FLUSH_CACHE;
	}

	// Deallocate "forward::" entries from the old cache
	else
	{
		for (index = 0; index < old_cache->mask + 1; index += 1)
		{
			if (CACHE_BUCKET_VALID(old_cache->buckets[index]) &&
				CACHE_BUCKET_IMP(old_cache->buckets[index]) == &_objc_msgForward)
			{
#ifdef OBJC_COLLECTING_CACHE
				_cache_collect_free (old_cache->buckets[index], NO);
#else
				malloc_zone_free (_objc_create_zone(), old_cache->buckets[index]);
#endif
			}
		}
	}

	// Install new cache
	((struct objc_class *)cls)->cache = new_cache;

	// Deallocate old cache, try freeing all the garbage
#ifdef OBJC_COLLECTING_CACHE
	_cache_collect_free (old_cache, YES);
#else
	malloc_zone_free (_objc_create_zone(), old_cache);
#endif
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
		sprintf (buf, "/tmp/msgSends-%d", (int) getpid ());
		objcMsgLogFD = open (buf, O_WRONLY | O_CREAT, 0666);
	}

	// Make the log entry
	sprintf(buf, "%c %s %s %s\n",
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
 *
 * Called only from _class_lookupMethodAndLoadCache and
 * class_respondsToMethod.
 *
 * #ifdef OBJC_COLLECTING_CACHE
 *	It doesn't matter if someone has the messageLock when we enter this
 *	function.  This function will fail to do the update if someone else
 *	is already updating the cache, i.e. they have the cacheUpdateLock.
 * #else
 *	The messageLock is already assumed to be taken out.
 * #endif
 **********************************************************************/

static	void	_cache_fill    (Class		cls,
								Method		smt,
								SEL			sel)
{
	Cache				cache;
	Method *			buckets;

	arith_t				index;
	arith_t				mask;
	unsigned int		newOccupied;

	// Keep tally of cache additions
	totalCacheFills += 1;

#ifdef OBJC_COLLECTING_CACHE
	// Make sure only one thread is updating the cache at a time, but don't
	// wait for concurrent updater to finish, because it might be a while, or
	// a deadlock!  Instead, just leave the method out of the cache until
	// next time.  This is nasty given that cacheUpdateLock is per task!
	if (!OBJC_TRYLOCK(&cacheUpdateLock))
		return;

	// Set up invariants for cache traversals
	cache	= ((struct objc_class *)cls)->cache;
	mask	= cache->mask;
	buckets	= cache->buckets;

	// Check for duplicate entries, if we're in the mode
	if (traceDuplicates)
	{
		int	index2;
		
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

	// Do nothing if entry is already placed.  This re-check is needed
	// only in the OBJC_COLLECTING_CACHE code, because the probe is
	// done un-sync'd.
	index	= ((unsigned int) sel & mask);
	while (CACHE_BUCKET_VALID(buckets[index]))
	{
		if (CACHE_BUCKET_NAME(buckets[index]) == sel)
		{
			OBJC_UNLOCK(&cacheUpdateLock);
			return;
		}
		
		index += 1;
		index &= mask;
	}

#else // not OBJC_COLLECTING_CACHE
	cache	= ((struct objc_class *)cls)->cache;
	mask	= cache->mask;
#endif

	// Use the cache as-is if it is less than 3/4 full
	newOccupied = cache->occupied + 1;
	if ((newOccupied * 4) <= (mask + 1) * 3)
		cache->occupied = newOccupied;
	
	// Cache is getting full
	else
	{
		// Flush the cache
		if ((((struct objc_class * )cls)->info & CLS_FLUSH_CACHE) != 0)
			_cache_flush (cls);
		
		// Expand the cache
		else
		{
			cache = _cache_expand (cls);
			mask  = cache->mask;
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
	index	= ((unsigned int) sel & mask);
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
		index &= mask;
	}

#ifdef OBJC_COLLECTING_CACHE
	OBJC_UNLOCK(&cacheUpdateLock);
#endif
}

/***********************************************************************
 * _cache_flush.  Invalidate all valid entries in the given class' cache,
 * and clear the CLS_FLUSH_CACHE in the cls->info.
 *
 * Called from flush_caches ().
 **********************************************************************/
static void	_cache_flush		(Class		cls)
{
	Cache			cache;
	unsigned int	index;
	
	// Locate cache.  Ignore unused cache.
	cache = ((struct objc_class *)cls)->cache;
	if (cache == &emptyCache)
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
#ifdef OBJC_COLLECTING_CACHE
			_cache_collect_free (oldEntry, NO);
#else
			malloc_zone_free (_objc_create_zone(), oldEntry);
#endif
	}
	
	// Clear the valid-entry counter
	cache->occupied = 0;

	// Clear the cache flush flag so that we will not flush this cache
	// before expanding it again.
	((struct objc_class * )cls)->info &= ~CLS_FLUSH_CACHE;
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
 * _class_lookupMethodAndLoadCache.
 *
 * Called only from objc_msgSend, objc_msgSendSuper and class_lookupMethod.
 **********************************************************************/
IMP	_class_lookupMethodAndLoadCache	   (Class	cls,
										SEL		sel)
{
	struct objc_class *	curClass;
	Method	smt;
	BOOL	calledSingleThreaded;
	IMP		methodPC;

	ptrace(0xb300, 0, 0, 0);
	
	// Check for freed class
	if (cls == &freedObjectClass)
		return (IMP) _freedHandler;
	
	// Check for nonexistent class
	if (cls == &nonexistentObjectClass)
		return (IMP) _nonexistentHandler;
	
#ifndef OBJC_COLLECTING_CACHE
	// Control can get here via the single-threaded message dispatcher,
	// but class_initialize can cause application to go multithreaded.  Notice 
	// whether this is the case, so we can leave the messageLock unlocked
	// on the way out, just as the single-threaded message dispatcher
	// expects.  Note that the messageLock locking in classinitialize is
	// appropriate in this case, because there are more than one thread now.
	calledSingleThreaded = (_objc_multithread_mask != 0);
#endif

	ptrace(0xb301, 0, 0, 0);
	
	// Lazy initialization.  This unlocks and relocks messageLock,
	// so cache information we might already have becomes invalid.
	if (!ISINITIALIZED(cls))
		class_initialize (objc_getClass (((struct objc_class *)cls)->name));
	
	ptrace(0xb302, 0, 0, 0);

	// Outer loop - search the caches and method lists of the
	// class and its super-classes
	methodPC = NULL;
	for (curClass = cls; curClass; curClass = ((struct objc_class * )curClass)->super_class)
	{
		Method *					buckets;
		arith_t						idx;
		arith_t						mask;
		arith_t						methodCount;
		struct objc_method_list *mlist;
		void *iterator = 0;
#ifdef PRELOAD_SUPERCLASS_CACHES
		struct objc_class *						curClass2;
#endif

		ptrace(0xb303, 0, 0, 0);
	
		mask    = curClass->cache->mask;
		buckets	= curClass->cache->buckets;

		// Minor loop #1 - check cache of given class
		for (idx = ((uarith_t) sel & mask);
			 CACHE_BUCKET_VALID(buckets[idx]);
			 idx = (++idx & mask))
		{
			// Skip entries until selector matches
			if (CACHE_BUCKET_NAME(buckets[idx]) != sel)
				continue;

			// Found the method.  Add it to the cache(s)
			// unless it was found in the cache of the
			// class originally being messaged.
			//
			// NOTE: The method is usually not found
			// the original class' cache, because
			// objc_msgSend () has already looked.
			// BUT, if sending this method resulted in
			// a +initialize on the class, and +initialize
			// sends the same method, the method will
			// indeed now be in the cache.  Calling
			// _cache_fill with a buckets[idx] from the
			// cache being filled results in a crash
			// if the cache has to grow, because the
			// buckets[idx] address is no longer valid. 
			if (curClass != cls)
			{
#ifdef PRELOAD_SUPERCLASS_CACHES
				for (curClass2 = cls; curClass2 != curClass; curClass2 = curClass2->super_class)
					_cache_fill (curClass2, buckets[idx], sel);
				_cache_fill (curClass, buckets[idx], sel);
#else
				_cache_fill (cls, buckets[idx], sel);
#endif
			}

			// Return the implementation address
			methodPC = CACHE_BUCKET_IMP(buckets[idx]);
			break;
		}

		ptrace(0xb304, (int)methodPC, 0, 0);
	
		// Done if that found it
		if (methodPC)
			break;

		smt = _findMethodInClass(curClass, sel);

		if (smt) {
			// If logging is enabled, log the message send and let
			// the logger decide whether to encache the method.
			if ((objcMsgLogEnabled == 0) ||
			(objcMsgLogProc (CLS_GETINFO(((struct objc_class * )curClass),CLS_META) ? YES : NO,
						((struct objc_class *)cls)->name,
						curClass->name, sel)))
			{
				// Cache the method implementation
#ifdef PRELOAD_SUPERCLASS_CACHES
				for (curClass2 = cls; curClass2 != curClass; curClass2 = curClass2->super_class)
					_cache_fill (curClass2, smt, sel);
				_cache_fill (curClass, smt, sel);
#else
				_cache_fill (cls, smt, sel);
#endif
			}
			// Return the implementation
			methodPC = smt->method_imp;
		}

		ptrace(0xb305, (int)methodPC, 0, 0);
	
		// Done if that found it
		if (methodPC)
			break;
	}

	ptrace(0xb306, (int)methodPC, 0, 0);
	
	if (methodPC == NULL)
	{
		// Class and superclasses do not respond -- use forwarding
		smt = malloc_zone_malloc (_objc_create_zone(), sizeof(struct objc_method));
		smt->method_name	= sel;
		smt->method_types	= "";
		smt->method_imp		= &_objc_msgForward;
		_cache_fill (cls, smt, sel);
		methodPC = &_objc_msgForward;
	}
	
#ifndef OBJC_COLLECTING_CACHE
	// Unlock the lock
	if (calledSingleThreaded)
		OBJC_UNLOCK(&messageLock);
#endif

	ptrace(0xb30f, (int)methodPC, 0, 0);
	
	return methodPC;
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
	static void *_objc_z = (void *)0xffffffff;
	if ( _objc_z == (void *)0xffffffff ) {
            char *s = getenv("OBJC_USE_OBJC_ZONE");
            if ( s ) {
                if ( (*s == '1') || (*s == 'y') || (*s == 'Y') ) {
                    _objc_z = malloc_create_zone(vm_page_size, 0);
                    malloc_set_zone_name(_objc_z, "ObjC");
                }
            }
            if ( _objc_z == (void *)0xffffffff ) {
                _objc_z = malloc_default_zone();
            }
	}
	return _objc_z;
}

/***********************************************************************
 * cache collection.
 **********************************************************************/
#ifdef OBJC_COLLECTING_CACHE

static unsigned long	_get_pc_for_thread     (mach_port_t	thread)
#ifdef hppa
{
		struct hp_pa_frame_thread_state		state;
		unsigned int count = HPPA_FRAME_THREAD_STATE_COUNT;
		thread_get_state (thread, HPPA_FRAME_THREAD_STATE, (thread_state_t)&state, &count);
		return state.ts_pcoq_front;
}
#elif defined(sparc)
{
		struct sparc_thread_state_regs		state;
		unsigned int count = SPARC_THREAD_STATE_REGS_COUNT;
		thread_get_state (thread, SPARC_THREAD_STATE_REGS, (thread_state_t)&state, &count);
		return state.regs.r_pc;
}
#elif defined(__i386__) || defined(i386)
{
		i386_thread_state_t			state;
		unsigned int count = i386_THREAD_STATE_COUNT;
		thread_get_state (thread, i386_THREAD_STATE, (thread_state_t)&state, &count);
		return state.eip;
}
#elif defined(m68k)
{
		struct m68k_thread_state_regs		state;
		unsigned int count = M68K_THREAD_STATE_REGS_COUNT;
		thread_get_state (thread, M68K_THREAD_STATE_REGS, (thread_state_t)&state, &count);
		return state.pc;
}
#elif defined(__ppc__) || defined(ppc)
{
		struct ppc_thread_state			state;
		unsigned int count = PPC_THREAD_STATE_COUNT;
		thread_get_state (thread, PPC_THREAD_STATE, (thread_state_t)&state, &count);
		return state.srr0;
}	
#else
{
	#error _get_pc_for_thread () not implemented for this architecture
}
#endif

/***********************************************************************
 * _collecting_in_critical.
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
		_objc_inform ("objc: task_thread failed\n");
		exit (1);
	}
	
	// Check whether any thread is in the cache lookup code
	result = 0;
	for (count = 0; !result && (count < number); count += 1)
	{
		int				region;
		unsigned long	pc;
	
		// Don't bother checking ourselves
		if (threads[count] == mythread)
			continue;
		
		// Find out where thread is executing
		pc = _get_pc_for_thread (threads[count]);
	
		// Check whether it is in the cache lookup code
		for (region = 0; !result && (objc_entryPoints[region] != 0); region += 1)
		{
			if ((pc >= objc_entryPoints[region]) &&
				(pc <= objc_exitPoints[region]))
				result = 1;
		}
	}
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
		garbage_refs	= malloc_zone_malloc (_objc_create_zone(),
						INIT_GARBAGE_COUNT * sizeof(void *));
		garbage_max	= INIT_GARBAGE_COUNT;
	}
	
	// Double the table if it is full
	else if (garbage_count == garbage_max)
	{
		tempGarbage	= malloc_zone_realloc ((void *) _objc_create_zone(),
						(void *) garbage_refs,
						(size_t) garbage_max * 2 * sizeof(void *));
		garbage_refs	= (void **) tempGarbage;
		garbage_max	*= 2;
	}
}

/***********************************************************************
 * _cache_collect_free.  Add the specified malloc'd memory to the list
 * of them to free at some later point.
 **********************************************************************/
static void	_cache_collect_free    (void *		data,
									BOOL		tryCollect)
{
	static char *report_garbage = (char *)0xffffffff;

	if ((char *)0xffffffff == report_garbage) {	
		// Check whether to log our activity
		report_garbage = getenv ("OBJC_REPORT_GARBAGE");
	}

	// Synchronize
	OBJC_LOCK(&cacheCollectionLock);
	
	// Insert new element in garbage list
	// Note that we do this even if we end up free'ing everything
	_garbage_make_room ();	
	garbage_byte_size += malloc_size (data);
	garbage_refs[garbage_count++] = data;
	
	// Log our progress
	if (tryCollect && report_garbage)
		_objc_inform ("total of %d bytes of garbage ...", garbage_byte_size);
	
	// Done if caller says not to empty or the garbage is not full
	if (!tryCollect || (garbage_byte_size < garbage_threshold))
	{
		OBJC_UNLOCK(&cacheCollectionLock);
		if (tryCollect && report_garbage)
			_objc_inform ("below threshold\n");
		
		return;
	}
	
	// Synchronize garbage collection with messageLock holders
	if (OBJC_TRYLOCK(&messageLock))
	{
		// Synchronize garbage collection with cache lookers
		if (!_collecting_in_critical ())
		{
			// Log our progress
			if (tryCollect && report_garbage)
				_objc_inform ("collecting!\n");
			
			// Dispose all refs now in the garbage
			while (garbage_count)
				free (garbage_refs[--garbage_count]);
			
			// Clear the total size indicator
			garbage_byte_size = 0;
		}
		
		// Someone is actively looking in the cache
		else if (tryCollect && report_garbage)
			_objc_inform ("in critical region\n");
		
		OBJC_UNLOCK(&messageLock);
	}
	
	// Someone already holds messageLock
	else if (tryCollect && report_garbage)
		_objc_inform ("messageLock taken\n");
	
	OBJC_UNLOCK(&cacheCollectionLock);
}
#endif // OBJC_COLLECTING_CACHE


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
				hash	    = (uarith_t) CACHE_BUCKET_NAME(method);
				methodChain = ((index - hash) & mask);
				
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
		_NXLogError ("%p != %p but !strcmp (%s, %s)\n", s1, s2, (char *) s1, (char *) s2);
}

