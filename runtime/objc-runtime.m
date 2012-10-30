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
* objc-runtime.m
* Copyright 1988-1996, NeXT Software, Inc.
* Author:	s. naroff
*
**********************************************************************/

/***********************************************************************
 * Class loading and connecting (GrP 2004-2-11)
 *
 * When images are loaded (during program startup or otherwise), the 
 * runtime needs to load classes and categories from the images, connect 
 * classes to superclasses and categories to parent classes, and call 
 * +load methods. 
 * 
 * The Objective-C runtime can cope with classes arriving in any order. 
 * That is, a class may be discovered by the runtime before some 
 * superclass is known. To handle out-of-order class loads, the 
 * runtime uses a "pending class" system. 
 * 
 * (Historical note)
 * Panther and earlier: many classes arrived out-of-order because of 
 *   the poorly-ordered callback from dyld. However, the runtime's 
 *   pending mechanism only handled "missing superclass" and not 
 *   "present superclass but missing higher class". See Radar #3225652. 
 * Tiger: The runtime's pending mechanism was augmented to handle 
 *   arbitrary missing classes. In addition, dyld was rewritten and 
 *   now sends the callbacks in strictly bottom-up link order. 
 *   The pending mechanism may now be needed only for rare and 
 *   hard to construct programs.
 * (End historical note)
 * 
 * A class when first seen in an image is considered "unconnected". 
 * It is stored in `unconnected_class_hash`. If all of the class's 
 * superclasses exist and are already "connected", then the new class 
 * can be connected to its superclasses and moved to `class_hash` for 
 * normal use. Otherwise, the class waits in `unconnected_class_hash` 
 * until the superclasses finish connecting.
 * 
 * A "connected" class is 
 * (1) in `class_hash`, 
 * (2) connected to its superclasses, 
 * (3) has no unconnected superclasses, 
 * (4) is otherwise initialized and ready for use, and 
 * (5) is eligible for +load if +load has not already been called. 
 * 
 * An "unconnected" class is 
 * (1) in `unconnected_class_hash`, 
 * (2) not connected to its superclasses, 
 * (3) has an immediate superclass which is either missing or unconnected, 
 * (4) is not ready for use, and 
 * (5) is not yet eligible for +load.
 * 
 * Image mapping is NOT CURRENTLY THREAD-SAFE with respect to just about 
 *  *  * anything. Image mapping IS RE-ENTRANT in several places: superclass 
 * lookup may cause ZeroLink to load another image, and +load calls may 
 * cause dyld to load another image.
 * 
 * Image mapping sequence:
 * 
 * Read all classes in all new images. 
 *   Add them all to unconnected_class_hash. 
 *   Note any +load implementations before categories are attached.
 *   Fix up any pended classrefs referring to them.
 *   Attach any pending categories.
 * Read all categories in all new images. 
 *   Attach categories whose parent class exists (connected or not), 
 *     and pend the rest.
 *   Mark them all eligible for +load (if implemented), even if the 
 *     parent class is missing.
 * Try to connect all classes in all new images. 
 *   If the superclass is missing, pend the class
 *   If the superclass is unconnected, try to recursively connect it
 *   If the superclass is connected:
 *     connect the class
 *     mark the class eligible for +load, if implemented
 *     connect any pended subclasses of the class
 * Resolve selector refs and class refs in all new images.
 *   Class refs whose classes still do not exist are pended.
 * Fix up protocol objects in all new images.
 * Call +load for classes and categories.
 *   May include classes or categories that are not in these images, 
 *     but are newly eligible because of these image.
 *   Class +loads will be called superclass-first because of the 
 *     superclass-first nature of the connecting process.
 *   Category +load needs to be deferred until the parent class is 
 *     connected and has had its +load called.
 * 
 * Performance: all classes are read before any categories are read. 
 * Fewer categories need be pended for lack of a parent class.
 * 
 * Performance: all categories are attempted to be attached before 
 * any classes are connected. Fewer class caches need be flushed. 
 * (Unconnected classes and their respective subclasses are guaranteed 
 * to be un-messageable, so their caches will be empty.)
 * 
 * Performance: all classes are read before any classes are connected. 
 * Fewer classes need be pended for lack of a superclass.
 * 
 * Correctness: all selector and class refs are fixed before any 
 * protocol fixups or +load methods. libobjc itself contains selector 
 * and class refs which are used in protocol fixup and +load.
 * 
 * Correctness: +load methods are scheduled in bottom-up link order. 
 * This constraint is in addition to superclass order. Some +load 
 * implementations expect to use another class in a linked-to library, 
 * even if the two classes don't share a direct superclass relationship.
 * 
 * Correctness: all classes are scanned for +load before any categories 
 * are attached. Otherwise, if a category implements +load and its class 
 * has no class methods, the class's +load scan would find the category's 
 * +load method, which would then be called twice.
 * 
 **********************************************************************/


/***********************************************************************
* Imports.
**********************************************************************/

#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_gdb.h>
#include <mach/mach.h>
#include <mach/mach_error.h>

// project headers first, otherwise we get the installed ones
#import "objc-class.h"
#import <objc/objc-runtime.h>
#import <objc/hashtable2.h>
#import "maptable.h"
#import "objc-private.h"
#import <objc/Object.h>
#import <objc/Protocol.h>
#import "objc-rtp.h"
#import "objc-auto.h"

#include <sys/time.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

/* NXHashTable SPI */
OBJC_EXPORT unsigned _NXHashCapacity(NXHashTable *table);
OBJC_EXPORT void _NXHashRehashToCapacity(NXHashTable *table, unsigned newCapacity);


OBJC_EXPORT Class _objc_getNonexistentClass(void);


OBJC_EXPORT Class getOriginalClassForPosingClass(Class);


/***********************************************************************
* Constants and macros internal to this module.
**********************************************************************/

/* Turn on support for literal string objects. */
#define LITERAL_STRING_OBJECTS

/***********************************************************************
* Types internal to this module.
**********************************************************************/

typedef struct _objc_unresolved_category
{
    struct _objc_unresolved_category *	next;
    struct objc_category *			cat;  // may be NULL
    long					version;
} _objc_unresolved_category;

typedef struct _PendingSubclass
{
    struct objc_class *subclass;  // subclass to finish connecting; may be NULL
    struct _PendingSubclass *next;
} PendingSubclass;

typedef struct _PendingClassRef
{
    struct objc_class **ref;  // class reference to fix up; may be NULL
    struct _PendingClassRef *next;
} PendingClassRef;

struct loadable_class {
    struct objc_class *cls;  // may be NULL
    IMP method;
};

struct loadable_category {
    struct objc_category *cat;  // may be NULL
    IMP method;
};


/***********************************************************************
* Exports.
**********************************************************************/

// Function called after class has been fixed up (MACH only)
void		(*callbackFunction)(Class, const char *) = 0;

// Lock for class hashtable
OBJC_DECLARE_LOCK (classLock);

// Settings from environment variables
__private_extern__ int PrintImages = -1;     // env OBJC_PRINT_IMAGES
__private_extern__ int PrintLoading = -1;    // env OBJC_PRINT_LOAD_METHODS
__private_extern__ int PrintConnecting = -1; // env OBJC_PRINT_CONNECTION
__private_extern__ int PrintRTP = -1;        // env OBJC_PRINT_RTP
__private_extern__ int PrintGC = -1;         // env OBJC_PRINT_GC
__private_extern__ int PrintSharing = -1;    // env OBJC_PRINT_SHARING
__private_extern__ int PrintCxxCtors = -1;   // env OBJC_PRINT_CXX_CTORS

__private_extern__ int UseInternalZone = -1; // env OBJC_USE_INTERNAL_ZONE
__private_extern__ int AllowInterposing = -1;// env OBJC_ALLOW_INTERPOSING

__private_extern__ int DebugUnload = -1;     // env OBJC_DEBUG_UNLOAD
__private_extern__ int DebugFragileSuperclasses = -1; // env OBJC_DEBUG_FRAGILE_SUPERCLASSES

__private_extern__ int ForceGC = -1;         // env OBJC_FORCE_GC
__private_extern__ int ForceNoGC = -1;       // env OBJC_FORCE_NO_GC
__private_extern__ int CheckFinalizers = -1; // env OBJC_CHECK_FINALIZERS

// objc's key for pthread_getspecific
__private_extern__ pthread_key_t _objc_pthread_key = 0;

// List of classes that need +load called (pending superclass +load)
// This list always has superclasses first because of the way it is constructed
static struct loadable_class *loadable_classes NOBSS = NULL;
static int loadable_classes_used NOBSS = 0;
static int loadable_classes_allocated NOBSS = 0;

// List of categories that need +load called (pending parent class +load)
static struct loadable_category *loadable_categories NOBSS = NULL;
static int loadable_categories_used NOBSS = 0;
static int loadable_categories_allocated NOBSS = 0;

// Selectors for which @selector() doesn't work
__private_extern__ SEL cxx_construct_sel = NULL;
__private_extern__ SEL cxx_destruct_sel = NULL;
__private_extern__ const char *cxx_construct_name = ".cxx_construct";
__private_extern__ const char *cxx_destruct_name = ".cxx_destruct";


/***********************************************************************
* Function prototypes internal to this module.
**********************************************************************/

static unsigned			classHash							(void * info, struct objc_class * data);
static int				classIsEqual						(void * info, struct objc_class * name, struct objc_class * cls);
static int				_objc_defaultClassHandler			(const char * clsName);
static void				_objcTweakMethodListPointerForClass	(struct objc_class * cls);
static void				_objc_add_category_flush_caches(struct objc_class * cls, struct objc_category * category, int version);
static void				_objc_add_category(struct objc_class * cls, struct objc_category * category, int version);
static void				_objc_register_category				(struct objc_category *	cat, long version);
static void				_objc_read_categories_from_image		(header_info * hi);
static const header_info * _headerForClass					(struct objc_class * cls);
static NXMapTable *		pendingClassRefsMapTable			(void);
static NXMapTable *		pendingSubclassesMapTable			(void);
static void         	_objc_read_classes_from_image		(header_info * hi);
static void				_objc_map_class_refs_for_image		(header_info * hi);
static void				_objc_fixup_protocol_objects_for_image	(header_info * hi);
static void				_objc_fixup_selector_refs			(const header_info * hi);
static void				_objc_unmap_image(const headerType *mh);
static BOOL connect_class(struct objc_class *cls);
static void add_category_to_loadable_list(struct objc_category *cat);
static vm_range_t get_shared_range(vm_address_t start, vm_address_t end);
static void offer_shared_range(vm_address_t start, vm_address_t end);
static void install_shared_range(vm_range_t remote, vm_address_t local);
static void clear_shared_range_file_cache(void);


/***********************************************************************
* Static data internal to this module.
**********************************************************************/

// we keep a linked list of header_info's describing each image as told to us by dyld
static header_info *FirstHeader NOBSS = 0;  // NULL means empty list
static header_info *LastHeader  NOBSS = 0;  // NULL means invalid; recompute it

// Hash table of classes
static NXHashTable *		class_hash NOBSS = 0;
static NXHashTablePrototype	classHashPrototype =
{
    (unsigned (*) (const void *, const void *))			classHash,
    (int (*)(const void *, const void *, const void *))	classIsEqual,
    NXNoEffectFree, 0
};

// Hash table of unconnected classes
static NXHashTable *unconnected_class_hash NOBSS = NULL;

// Exported copy of class_hash variable (hook for debugging tools)
NXHashTable *_objc_debug_class_hash = NULL;

// Function pointer objc_getClass calls through when class is not found
static int			(*objc_classHandler) (const char *) = _objc_defaultClassHandler;

// Function pointer called by objc_getClass and objc_lookupClass when 
// class is not found. _objc_classLoader is called before objc_classHandler.
static BOOL (*_objc_classLoader)(const char *) = NULL;

// Category and class registries
// Keys are COPIES of strings, to prevent stale pointers with unloaded bundles
// Use NXMapKeyCopyingInsert and NXMapKeyFreeingRemove
static NXMapTable *		category_hash = NULL;

// Keys are COPIES of strings, to prevent stale pointers with unloaded bundles
// Use NXMapKeyCopyingInsert and NXMapKeyFreeingRemove
static NXMapTable *		pendingClassRefsMap = NULL;
static NXMapTable *		pendingSubclassesMap = NULL;

/***********************************************************************
* objc_dump_class_hash.  Log names of all known classes.
**********************************************************************/
void	objc_dump_class_hash	       (void)
{
    NXHashTable *	table;
    unsigned		count;
    struct objc_class 	*		data;
    NXHashState		state;

    table = class_hash;
    count = 0;
    state = NXInitHashState (table);
    while (NXNextHashState (table, &state, (void **) &data))
        printf ("class %d: %s\n", ++count, data->name);
}

/***********************************************************************
* classHash.
**********************************************************************/
static unsigned		classHash	       (void *		info,
                                   struct objc_class *		data)
{
    // Nil classes hash to zero
    if (!data)
        return 0;

    // Call through to real hash function
    return _objc_strhash ((unsigned char *) ((struct objc_class *) data)->name);
}

/***********************************************************************
* classIsEqual.  Returns whether the class names match.  If we ever
* check more than the name, routines like objc_lookUpClass have to
* change as well.
**********************************************************************/
static int		classIsEqual	       (void *		info,
                                 struct objc_class *		name,
                                 struct objc_class *		cls)
{
    // Standard string comparison
    // Our local inlined version is significantly shorter on PPC and avoids the
    // mflr/mtlr and dyld_stub overhead when calling strcmp.
    return _objc_strcmp(name->name, cls->name) == 0;
}


/***********************************************************************
* NXMapKeyCopyingInsert
* Like NXMapInsert, but strdups the key if necessary.
* Used to prevent stale pointers when bundles are unloaded.
**********************************************************************/
static void *NXMapKeyCopyingInsert(NXMapTable *table, const void *key, const void *value)
{
    void *realKey; 
    void *realValue = NULL;

    if ((realKey = NXMapMember(table, key, &realValue)) != NX_MAPNOTAKEY) {
        // key DOES exist in table - use table's key for insertion
    } else {
        // key DOES NOT exist in table - copy the new key before insertion
        realKey = _strdup_internal(key);
    }
    return NXMapInsert(table, realKey, value);
}


/***********************************************************************
* NXMapKeyFreeingRemove
* Like NXMapRemove, but frees the existing key if necessary.
* Used to prevent stale pointers when bundles are unloaded.
**********************************************************************/
static void *NXMapKeyFreeingRemove(NXMapTable *table, const void *key)
{
    void *realKey;
    void *realValue = NULL;

    if ((realKey = NXMapMember(table, key, &realValue)) != NX_MAPNOTAKEY) {
        // key DOES exist in table - remove pair and free key
        realValue = NXMapRemove(table, realKey);
        _free_internal(realKey); // the key from the table, not necessarily the one given
        return realValue;
    } else {
        // key DOES NOT exist in table - nothing to do
        return NULL;
    }
}


/***********************************************************************
* _objc_init_class_hash.  Return the class lookup table, create it if
* necessary.
**********************************************************************/
void	_objc_init_class_hash	       (void)
{
    // Do nothing if class hash table already exists
    if (class_hash)
        return;

    // class_hash starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    // Old numbers: A smallish Foundation+AppKit program will have
    // about 520 classes.  Larger apps (like IB or WOB) have more like
    // 800 classes.  Some customers have massive quantities of classes.
    // Foundation-only programs aren't likely to notice the ~6K loss.
    class_hash = NXCreateHashTableFromZone (classHashPrototype,
                                            16,
                                            nil,
                                            _objc_internal_zone ());
    _objc_debug_class_hash = class_hash;
}

/***********************************************************************
* objc_getClassList.  Return the known classes.
**********************************************************************/
int objc_getClassList(Class *buffer, int bufferLen) {
    NXHashState state;
    struct objc_class * class;
    int cnt, num;

    OBJC_LOCK(&classLock);
    num = NXCountHashTable(class_hash);
    if (NULL == buffer) {
        OBJC_UNLOCK(&classLock);
        return num;
    }
    cnt = 0;
    state = NXInitHashState(class_hash);
    while (cnt < bufferLen  &&  
           NXNextHashState(class_hash, &state, (void **)&class)) 
    {
        buffer[cnt++] = class;
    }
    OBJC_UNLOCK(&classLock);
    return num;
}

/***********************************************************************
* objc_getClasses.  Return class lookup table.
*
* NOTE: This function is very dangerous, since you cannot safely use
* the hashtable without locking it, and the lock is private!
**********************************************************************/
void *		objc_getClasses	       (void)
{
    // Return the class lookup hash table
    return class_hash;
}

/***********************************************************************
* _objc_defaultClassHandler.  Default objc_classHandler.  Does nothing.
**********************************************************************/
static int	_objc_defaultClassHandler      (const char *	clsName)
{
    // Return zero so objc_getClass doesn't bother re-searching
    return 0;
}

/***********************************************************************
* objc_setClassHandler.  Set objc_classHandler to the specified value.
*
* NOTE: This should probably deal with userSuppliedHandler being NULL,
* because the objc_classHandler caller does not check... it would bus
* error.  It would make sense to handle NULL by restoring the default
* handler.  Is anyone hacking with this, though?
**********************************************************************/
void	objc_setClassHandler	(int	(*userSuppliedHandler) (const char *))
{
    objc_classHandler = userSuppliedHandler;
}


/***********************************************************************
* look_up_class
* Map a class name to a class using various methods.
* This is the common implementation of objc_lookUpClass and objc_getClass, 
* and is also used internally to get additional search options.
* Sequence:
* 1. class_hash
* 2. unconnected_class_hash (optional)
* 3. classLoader callback
* 4. classHandler callback (optional)
**********************************************************************/
static id look_up_class(const char *aClassName, BOOL includeUnconnected, BOOL includeClassHandler)
{
    BOOL includeClassLoader = YES; // class loader cannot be skipped
    id result = nil;
    struct objc_class query;

    query.name = aClassName;

 retry:

    if (!result  &&  class_hash) {
        // Check ordinary classes
        OBJC_LOCK (&classLock);
        result = (id)NXHashGet(class_hash, &query);
        OBJC_UNLOCK (&classLock);
    }

    if (!result  &&  includeUnconnected  &&  unconnected_class_hash) {
        // Check not-yet-connected classes
        OBJC_LOCK(&classLock);
        result = (id)NXHashGet(unconnected_class_hash, &query);
        OBJC_UNLOCK(&classLock);
    }

    if (!result  &&  includeClassLoader  &&  _objc_classLoader) {
        // Try class loader callback
        if ((*_objc_classLoader)(aClassName)) {
            // Re-try lookup without class loader
            includeClassLoader = NO;
            goto retry;
        }
    }

    if (!result  &&  includeClassHandler  &&  objc_classHandler) {
        // Try class handler callback
        if ((*objc_classHandler)(aClassName)) {
            // Re-try lookup without class handler or class loader
            includeClassLoader = NO;
            includeClassHandler = NO;
            goto retry;
        }
    }

    return result;
}


/***********************************************************************
* objc_getClass.  Return the id of the named class.  If the class does
* not exist, call _objc_classLoader and then objc_classHandler, either of 
* which may create a new class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id		objc_getClass	       (const char *	aClassName)
{
    // NO unconnected, YES class handler
    return look_up_class(aClassName, NO, YES);
}


/***********************************************************************
* objc_getRequiredClass.  
* Same as objc_getClass, but kills the process if the class is not found. 
* This is used by ZeroLink, where failing to find a class would be a 
* compile-time link error without ZeroLink.
**********************************************************************/
id objc_getRequiredClass(const char *aClassName)
{
    id cls = objc_getClass(aClassName);
    if (!cls) _objc_fatal("link error: class '%s' not found.", aClassName);
    return cls;
}


/***********************************************************************
* objc_lookUpClass.  Return the id of the named class.
* If the class does not exist, call _objc_classLoader, which may create 
* a new class.
*
* Formerly objc_getClassWithoutWarning ()
**********************************************************************/
id		objc_lookUpClass       (const char *	aClassName)
{
    // NO unconnected, NO class handler
    return look_up_class(aClassName, NO, NO);
}

/***********************************************************************
* objc_getMetaClass.  Return the id of the meta class the named class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id		objc_getMetaClass       (const char *	aClassName)
{
    struct objc_class *	cls;

    cls = objc_getClass (aClassName);
    if (!cls)
    {
        _objc_inform ("class `%s' not linked into application", aClassName);
        return Nil;
    }

    return cls->isa;
}

/***********************************************************************
* objc_addClass.  Add the specified class to the table of known classes,
* after doing a little verification and fixup.
**********************************************************************/
void		objc_addClass		(struct objc_class *cls)
{
    // Synchronize access to hash table
    OBJC_LOCK (&classLock);

    // Make sure both the class and the metaclass have caches!
    // Clear all bits of the info fields except CLS_CLASS and CLS_META.
    // Normally these bits are already clear but if someone tries to cons
    // up their own class on the fly they might need to be cleared.
    if (cls->cache == NULL) {
        cls->cache = (Cache) &emptyCache;
        cls->info = CLS_CLASS;
    }

    if (cls->isa->cache == NULL) {
        cls->isa->cache = (Cache) &emptyCache;
        cls->isa->info = CLS_META;
    }

    // methodLists should be: 
    // 1. NULL (Tiger and later only)
    // 2. A -1 terminated method list array
    // In either case, CLS_NO_METHOD_ARRAY remains clear.
    // If the user manipulates the method list directly, 
    // they must use the magic private format.

    // Add the class to the table
    (void) NXHashInsert (class_hash, cls);

    // Desynchronize
    OBJC_UNLOCK (&classLock);
}

/***********************************************************************
* _objcTweakMethodListPointerForClass.
* Change the class's method list pointer to a method list array. 
* Does nothing if the method list pointer is already a method list array.
* If the class is currently in use, methodListLock must be held by the caller.
**********************************************************************/
static void	_objcTweakMethodListPointerForClass     (struct objc_class *	cls)
{
    struct objc_method_list *	originalList;
    const int					initialEntries = 4;
    int							mallocSize;
    struct objc_method_list **	ptr;

    // Do nothing if methodLists is already an array.
    if (cls->methodLists  &&  !(cls->info & CLS_NO_METHOD_ARRAY)) return;

    // Remember existing list
    originalList = (struct objc_method_list *) cls->methodLists;

    // Allocate and zero a method list array
    mallocSize   = sizeof(struct objc_method_list *) * initialEntries;
    ptr	     = (struct objc_method_list **) _calloc_internal(1, mallocSize);

    // Insert the existing list into the array
    ptr[initialEntries - 1] = END_OF_METHODS_LIST;
    ptr[0] = originalList;

    // Replace existing list with array
    cls->methodLists = ptr;
    _class_clearInfo(cls, CLS_NO_METHOD_ARRAY);
}


/***********************************************************************
* _objc_insertMethods.
* Adds methods to a class.
* Does not flush any method caches.
* Does not take any locks.
* If the class is already in use, use class_addMethods() instead.
**********************************************************************/
void _objc_insertMethods(struct objc_class *cls, 
                         struct objc_method_list *mlist)
{
    struct objc_method_list ***list;
    struct objc_method_list **ptr;
    int endIndex;
    int oldSize;
    int newSize;

    if (!cls->methodLists) {
        // cls has no methods - simply use this method list
        cls->methodLists = (struct objc_method_list **)mlist;
        _class_setInfo(cls, CLS_NO_METHOD_ARRAY);
        return;
    }

    // Create method list array if necessary
    _objcTweakMethodListPointerForClass(cls);
    
    list = &cls->methodLists;

    // Locate unused entry for insertion point
    ptr = *list;
    while ((*ptr != 0) && (*ptr != END_OF_METHODS_LIST))
        ptr += 1;

    // If array is full, add to it
    if (*ptr == END_OF_METHODS_LIST)
    {
        // Calculate old and new dimensions
        endIndex = ptr - *list;
        oldSize  = (endIndex + 1) * sizeof(void *);
        newSize  = oldSize + sizeof(struct objc_method_list *); // only increase by 1

        // Grow the method list array by one.
        // This block may be from user code; don't use _realloc_internal
        *list = (struct objc_method_list **)realloc(*list, newSize);

        // Zero out addition part of new array
        bzero (&((*list)[endIndex]), newSize - oldSize);

        // Place new end marker
        (*list)[(newSize/sizeof(void *)) - 1] = END_OF_METHODS_LIST;

        // Insertion point corresponds to old array end
        ptr = &((*list)[endIndex]);
    }

    // Right shift existing entries by one
    bcopy (*list, (*list) + 1, ((void *) ptr) - ((void *) *list));

    // Insert at method list at beginning of array
    **list = mlist;
}

/***********************************************************************
* _objc_removeMethods.
* Remove methods from a class.
* Does not take any locks.
* Does not flush any method caches.
* If the class is currently in use, use class_removeMethods() instead.
**********************************************************************/
void _objc_removeMethods(struct objc_class *cls, 
                         struct objc_method_list *mlist)
{
    struct objc_method_list ***list;
    struct objc_method_list **ptr;

    if (cls->methodLists == NULL) {
        // cls has no methods
        return;
    }
    if (cls->methodLists == (struct objc_method_list **)mlist) {
        // mlist is the class's only method list - erase it
        cls->methodLists = NULL;
        return;
    }
    if (cls->info & CLS_NO_METHOD_ARRAY) {
        // cls has only one method list, and this isn't it - do nothing
        return;
    }

    // cls has a method list array - search it

    list = &cls->methodLists;

    // Locate list in the array
    ptr = *list;
    while (*ptr != mlist) {
        // fix for radar # 2538790
        if ( *ptr == END_OF_METHODS_LIST ) return;
        ptr += 1;
    }

    // Remove this entry
    *ptr = 0;

    // Left shift the following entries
    while (*(++ptr) != END_OF_METHODS_LIST)
        *(ptr-1) = *ptr;
    *(ptr-1) = 0;
}

/***********************************************************************
* _objc_add_category.  Install the specified category's methods and
* protocols into the class it augments.
* The class is assumed not to be in use yet: no locks are taken and 
* no method caches are flushed.
**********************************************************************/
static inline void _objc_add_category(struct objc_class *cls, struct objc_category *category, int version)
{
    if (PrintConnecting) {
        _objc_inform("CONNECT: attaching category '%s (%s)'", cls->name, category->category_name);
    }

    // Augment instance methods
    if (category->instance_methods)
        _objc_insertMethods (cls, category->instance_methods);

    // Augment class methods
    if (category->class_methods)
        _objc_insertMethods (cls->isa, category->class_methods);

    // Augment protocols
    if ((version >= 5) && category->protocols)
    {
        if (cls->isa->version >= 5)
        {
            category->protocols->next = cls->protocols;
            cls->protocols	          = category->protocols;
            cls->isa->protocols       = category->protocols;
        }
        else
        {
            _objc_inform ("unable to add protocols from category %s...\n", category->category_name);
            _objc_inform ("class `%s' must be recompiled\n", category->class_name);
        }
    }
}

/***********************************************************************
* _objc_add_category_flush_caches.  Install the specified category's 
* methods into the class it augments, and flush the class' method cache.
**********************************************************************/
static void _objc_add_category_flush_caches(struct objc_class *cls, struct objc_category *category, int version)
{
    // Install the category's methods into its intended class
    OBJC_LOCK(&methodListLock);
    _objc_add_category (cls, category, version);
    OBJC_UNLOCK(&methodListLock);

    // Flush caches so category's methods can get called
    _objc_flush_caches (cls);
}


/***********************************************************************
* reverse_cat
* Reverse the given linked list of pending categories. 
* The pending category list is built backwards, and needs to be 
* reversed before actually attaching the categories to a class.
* Returns the head of the new linked list.
**********************************************************************/
static _objc_unresolved_category *reverse_cat(_objc_unresolved_category *cat)
{
    if (!cat) return NULL;

    _objc_unresolved_category *prev = NULL;
    _objc_unresolved_category *cur = cat;
    _objc_unresolved_category *ahead = cat->next;
    
    while (cur) {
        ahead = cur->next;
        cur->next = prev;
        prev = cur;
        cur = ahead;
    }

    return prev;
}


/***********************************************************************
* resolve_categories_for_class.  
* Install all existing categories intended for the specified class.
* cls must be a true class and not a metaclass.
**********************************************************************/
static void resolve_categories_for_class(struct objc_class *cls)
{
    _objc_unresolved_category *	pending;
    _objc_unresolved_category *	next;

    // Nothing to do if there are no categories at all
    if (!category_hash) return;

    // Locate and remove first element in category list
    // associated with this class
    pending = NXMapKeyFreeingRemove (category_hash, cls->name);

    // Traverse the list of categories, if any, registered for this class

    // The pending list is built backwards. Reverse it and walk forwards.
    pending = reverse_cat(pending);

    while (pending) {
        if (pending->cat) {
            // Install the category
            // use the non-flush-cache version since we are only
            // called from the class intialization code
            _objc_add_category(cls, pending->cat, pending->version);
        }

        // Delink and reclaim this registration
        next = pending->next;
        _free_internal(pending);
        pending = next;
    }
}


/***********************************************************************
* _objc_resolve_categories_for_class.  
* Public version of resolve_categories_for_class. This was 
* exported pre-10.4 for Omni et al. to workaround a problem 
* with too-lazy category attachment.
* cls should be a class, but this function can also cope with metaclasses.
**********************************************************************/
void _objc_resolve_categories_for_class(struct objc_class *cls)
{

    // If cls is a metaclass, get the class. 
    // resolve_categories_for_class() requires a real class to work correctly.
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

    resolve_categories_for_class(cls);
}


/***********************************************************************
* _objc_register_category.
* Process a category read from an image. 
* If the category's class exists, attach the category immediately. 
* If the category's class does not exist yet, pend the category for 
* later attachment. Pending categories are attached in the order 
* they were discovered.
**********************************************************************/
static void _objc_register_category(struct objc_category *cat, long version)
{
    _objc_unresolved_category *	new_cat;
    _objc_unresolved_category *	old;
    struct objc_class *theClass;

    // If the category's class exists, attach the category.
    if ((theClass = objc_lookUpClass(cat->class_name))) {
        _objc_add_category_flush_caches(theClass, cat, version);
        return;
    }
    
    // If the category's class exists but is unconnected, 
    // then attach the category to the class but don't bother 
    // flushing any method caches (because they must be empty).
    // YES unconnected, NO class_handler
    if ((theClass = look_up_class(cat->class_name, YES, NO))) {
        _objc_add_category(theClass, cat, version);
        return;
    }


    // Category's class does not exist yet. 
    // Save the category for later attachment.

    if (PrintConnecting) {
        _objc_inform("CONNECT: pending category '%s (%s)'", cat->class_name, cat->category_name);
    }

    // Create category lookup table if needed
    if (!category_hash)
        category_hash = NXCreateMapTableFromZone (NXStrValueMapPrototype,
                                                  128,
                                                  _objc_internal_zone ());

    // Locate an existing list of categories, if any, for the class.
    old = NXMapGet (category_hash, cat->class_name);

    // Register the category to be fixed up later.
    // The category list is built backwards, and is reversed again 
    // by resolve_categories_for_class().
    new_cat = _malloc_internal(sizeof(_objc_unresolved_category));
    new_cat->next    = old;
    new_cat->cat     = cat;
    new_cat->version = version;
    (void) NXMapKeyCopyingInsert (category_hash, cat->class_name, new_cat);
}


/***********************************************************************
* _objc_read_categories_from_image.
* Read all categories from the given image. 
* Install them on their parent classes, or register them for later 
*   installation. 
* Register them for later +load, if implemented.
**********************************************************************/
static void _objc_read_categories_from_image (header_info *  hi)
{
    Module		mods;
    unsigned int	midx;

    if (_objcHeaderIsReplacement(hi)) {
        // Ignore any categories in this image
        return;
    }

    // Major loop - process all modules in the header
    mods = hi->mod_ptr;

    // NOTE: The module and category lists are traversed backwards 
    // to preserve the pre-10.4 processing order. Changing the order 
    // would have a small chance of introducing binary compatibility bugs.
    midx = hi->mod_count;
    while (midx-- > 0) {
        unsigned int	index;
        unsigned int	total;
        
        // Nothing to do for a module without a symbol table
        if (mods[midx].symtab == NULL)
            continue;
        
        // Total entries in symbol table (class entries followed
        // by category entries)
        total = mods[midx].symtab->cls_def_cnt +
            mods[midx].symtab->cat_def_cnt;
        
        // Minor loop - register all categories from given module
        index = total;
        while (index-- > mods[midx].symtab->cls_def_cnt) {
            struct objc_category *cat = mods[midx].symtab->defs[index];
            _objc_register_category(cat, mods[midx].version);
            add_category_to_loadable_list(cat);
        }
    }
}


/***********************************************************************
* _headerForAddress.
* addr can be a class or a category
**********************************************************************/
static const header_info *_headerForAddress(void *addr)
{
    unsigned long			size;
    unsigned long			seg;
    header_info *		hInfo;

    // Check all headers in the vector
    for (hInfo = FirstHeader; hInfo != NULL; hInfo = hInfo->next)
    {
        // Locate header data, if any
        if (!hInfo->objcSegmentHeader) continue;
        seg = hInfo->objcSegmentHeader->vmaddr + hInfo->image_slide;
        size = hInfo->objcSegmentHeader->filesize;

        // Is the class in this header?
        if ((seg <= (unsigned long) addr) &&
            ((unsigned long) addr < (seg + size)))
            return hInfo;
    }

    // Not found
    return 0;
}


/***********************************************************************
* _headerForClass
* Return the image header containing this class, or NULL.
* Returns NULL on runtime-constructed classes, and the NSCF classes.
**********************************************************************/
static const header_info *_headerForClass(struct objc_class *cls)
{
    return _headerForAddress(cls);
}


/***********************************************************************
* _nameForHeader.
**********************************************************************/
const char *	_nameForHeader	       (const headerType *	header)
{
    return _getObjcHeaderName ((headerType *) header);
}


/***********************************************************************
* class_is_connected.
* Returns TRUE if class cls is connected. 
* A connected class has either a connected superclass or a NULL superclass, 
* and is present in class_hash.
**********************************************************************/
static BOOL class_is_connected(struct objc_class *cls)
{
    BOOL result;
    OBJC_LOCK(&classLock);
    result = NXHashMember(class_hash, cls);
    OBJC_UNLOCK(&classLock);
    return result;
}


/***********************************************************************
* pendingClassRefsMapTable.  Return a pointer to the lookup table for
* pending class refs.
**********************************************************************/
static inline NXMapTable *pendingClassRefsMapTable(void)
{
    // Allocate table if needed
    if (!pendingClassRefsMap) {
        pendingClassRefsMap = 
            NXCreateMapTableFromZone(NXStrValueMapPrototype, 
                                     10, _objc_internal_zone ());
    }
    
    // Return table pointer
    return pendingClassRefsMap;
}


/***********************************************************************
* pendingSubclassesMapTable.  Return a pointer to the lookup table for
* pending subclasses.
**********************************************************************/
static inline NXMapTable *pendingSubclassesMapTable(void)
{
    // Allocate table if needed
    if (!pendingSubclassesMap) {
        pendingSubclassesMap = 
            NXCreateMapTableFromZone(NXStrValueMapPrototype, 
                                     10, _objc_internal_zone ());
    }
    
    // Return table pointer
    return pendingSubclassesMap;
}


/***********************************************************************
* pendClassInstallation
* Finish connecting class cls when its superclass becomes connected.
* Check for multiple pends of the same class because connect_class does not.
**********************************************************************/
static void pendClassInstallation(struct objc_class *cls, 
                                  const char *superName)
{
    NXMapTable *table;
    PendingSubclass *pending;
    PendingSubclass *oldList;
    PendingSubclass *l;
    
    // Create and/or locate pending class lookup table
    table = pendingSubclassesMapTable ();

    // Make sure this class isn't already in the pending list.
    oldList = NXMapGet (table, superName);
    for (l = oldList; l != NULL; l = l->next) {
        if (l->subclass == cls) return;  // already here, nothing to do
    }
    
    // Create entry referring to this class
    pending = _malloc_internal(sizeof(PendingSubclass));
    pending->subclass = cls;
    
    // Link new entry into head of list of entries for this class
    pending->next = oldList;
    
    // (Re)place entry list in the table
    (void) NXMapKeyCopyingInsert (table, superName, pending);
}


/***********************************************************************
* pendClassReference
* Fix up a class ref when the class with the given name becomes connected.
**********************************************************************/
static void pendClassReference(struct objc_class **ref, 
                               const char *className)
{
    NXMapTable *table;
    PendingClassRef *pending;
    
    // Create and/or locate pending class lookup table
    table = pendingClassRefsMapTable ();
    
    // Create entry containing the class reference
    pending = _malloc_internal(sizeof(PendingClassRef));
    pending->ref = ref;
    
    // Link new entry into head of list of entries for this class
    pending->next = NXMapGet (table, className);
    
    // (Re)place entry list in the table
    (void) NXMapKeyCopyingInsert (table, className, pending);

    if (PrintConnecting) {
        _objc_inform("CONNECT: pended reference to class '%s' at %p", 
                     className, (void *)ref);
    }
}


/***********************************************************************
* resolve_references_to_class
* Fix up any pending class refs to this class.
**********************************************************************/
static void resolve_references_to_class(struct objc_class *cls)
{
    PendingClassRef *pending;
    
    if (!pendingClassRefsMap) return;  // no unresolved refs for any class

    pending = NXMapGet(pendingClassRefsMap, cls->name); 
    if (!pending) return;  // no unresolved refs for this class

    NXMapKeyFreeingRemove(pendingClassRefsMap, cls->name);

    if (PrintConnecting) {
        _objc_inform("CONNECT: resolving references to class '%s'", cls->name);
    }

    while (pending) {
        PendingClassRef *next = pending->next;
        if (pending->ref) *pending->ref = cls;
        _free_internal(pending);
        pending = next;
    }

    if (NXCountMapTable(pendingClassRefsMap) == 0) {
        NXFreeMapTable(pendingClassRefsMap);
        pendingClassRefsMap = NULL;
    }
}


/***********************************************************************
* resolve_subclasses_of_class
* Fix up any pending subclasses of this class.
**********************************************************************/
static void resolve_subclasses_of_class(struct objc_class *cls)
{
    PendingSubclass *pending;
    
    if (!pendingSubclassesMap) return;  // no unresolved subclasses 

    pending = NXMapGet(pendingSubclassesMap, cls->name); 
    if (!pending) return;  // no unresolved subclasses for this class

    NXMapKeyFreeingRemove(pendingSubclassesMap, cls->name);

    // Destroy the pending table if it's now empty, to save memory.
    if (NXCountMapTable(pendingSubclassesMap) == 0) {
        NXFreeMapTable(pendingSubclassesMap);
        pendingSubclassesMap = NULL;
    }

    if (PrintConnecting) {
        _objc_inform("CONNECT: resolving subclasses of class '%s'", cls->name);
    }

    while (pending) {
        PendingSubclass *next = pending->next;
        if (pending->subclass) connect_class(pending->subclass);
        _free_internal(pending);
        pending = next;
    }
}


/***********************************************************************
* get_base_method_list
* Returns the method list containing the class's own methods, 
* ignoring any method lists added by categories or class_addMethods. 
* Called only by add_class_to_loadable_list. 
* Does not hold methodListLock because add_class_to_loadable_list 
* does not manipulate in-use classes.
**********************************************************************/
static struct objc_method_list *get_base_method_list(struct objc_class *cls) 
{
    struct objc_method_list **ptr;

    if (!cls->methodLists) return NULL;
    if (cls->info & CLS_NO_METHOD_ARRAY) return (struct objc_method_list *)cls->methodLists;
    ptr = cls->methodLists;
    if (!*ptr  ||  *ptr == END_OF_METHODS_LIST) return NULL;
    while ( *ptr != 0 && *ptr != END_OF_METHODS_LIST ) { ptr++; }
    --ptr;
    return *ptr;
}


/***********************************************************************
* add_class_to_loadable_list
* Class cls has just become connected. Schedule it for +load if
* it implements a +load method.
**********************************************************************/
static void add_class_to_loadable_list(struct objc_class *cls)
{
    IMP method = NULL;
    struct objc_method_list *mlist;
    
    if (cls->isa->info & CLS_HAS_LOAD_METHOD) {
        mlist = get_base_method_list(cls->isa);
        if (mlist) {
            method = lookupNamedMethodInMethodList (mlist, "load");
        }
    }
    // Don't bother if cls has no +load method
    if (!method) return;
    
    if (PrintLoading) {
        _objc_inform("LOAD: class '%s' scheduled for +load", cls->name);
    }
    
    if (loadable_classes_used == loadable_classes_allocated) {
        loadable_classes_allocated = loadable_classes_allocated*2 + 16;
        loadable_classes =
            _realloc_internal(loadable_classes,
                              loadable_classes_allocated *
                              sizeof(struct loadable_class));
    }
    
    loadable_classes[loadable_classes_used].cls = cls;
    loadable_classes[loadable_classes_used].method = method;
    loadable_classes_used++;
}


/***********************************************************************
* add_category_to_loadable_list
* Category cat's parent class exists and the category has been attached
* to its class. Schedule this category for +load after its parent class
* becomes connected and has its own +load method called.
**********************************************************************/
static void add_category_to_loadable_list(struct objc_category *cat)
{
    IMP method = NULL;
    struct objc_method_list *mlist;

    mlist = cat->class_methods;
    if (mlist) {
        method = lookupNamedMethodInMethodList (mlist, "load");
    }
    // Don't bother if cat has no +load method
    if (!method) return;

    if (PrintLoading) {
        _objc_inform("LOAD: category '%s(%s)' scheduled for +load", 
                     cat->class_name, cat->category_name);
    }
    
    if (loadable_categories_used == loadable_categories_allocated) {
        loadable_categories_allocated = loadable_categories_allocated*2 + 16;
        loadable_categories =
            _realloc_internal(loadable_categories,
                              loadable_categories_allocated *
                              sizeof(struct loadable_category));
    }

    loadable_categories[loadable_categories_used].cat = cat;
    loadable_categories[loadable_categories_used].method = method;
    loadable_categories_used++;
}


/***********************************************************************
* remove_class_from_loadable_list
* Class cls may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
static void remove_class_from_loadable_list(struct objc_class *cls)
{
    if (loadable_classes) {
        int i;
        for (i = 0; i < loadable_classes_used; i++) {
            if (loadable_classes[i].cls == cls) {
                loadable_classes[i].cls = NULL;
                if (PrintLoading) {
                    _objc_inform("LOAD: class '%s' unscheduled for +load", cls->name);
                }
                return;
            }
        }
    }
}


/***********************************************************************
* remove_category_from_loadable_list
* Category cat may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
static void remove_category_from_loadable_list(struct objc_category *cat)
{
    if (loadable_categories) {
        int i;
        for (i = 0; i < loadable_categories_used; i++) {
            if (loadable_categories[i].cat == cat) {
                loadable_categories[i].cat = NULL;
                if (PrintLoading) {
                    _objc_inform("LOAD: category '%s(%s)' unscheduled for +load",
                                 cat->class_name, cat->category_name);
                }
                return;
            }
        }
    }
}


/***********************************************************************
* call_class_loads
* Call all pending class +load methods.
* If new classes become loadable, +load is NOT called for them.
*
* Called only by call_load_methods().
**********************************************************************/
static void call_class_loads(void)
{
    int i;
    
    // Detach current loadable list.
    struct loadable_class *classes = loadable_classes;
    int used = loadable_classes_used;
    loadable_classes = NULL;
    loadable_classes_allocated = 0;
    loadable_classes_used = 0;
    
    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) {
        struct objc_class *cls = classes[i].cls;
        IMP load_method = classes[i].method;
        if (!cls) continue; 

        if (PrintLoading) {
            _objc_inform("LOAD: +[%s load]\n", cls->name);
        }
        (*load_method) ((id) cls, @selector(load));
    }
    
    // Destroy the detached list.
    if (classes) _free_internal(classes);
}


/***********************************************************************
* call_category_loads
* Call some pending category +load methods.
* The parent class of the +load-implementing categories has all of 
*   its categories attached, in case some are lazily waiting for +initalize.
* Don't call +load unless the parent class is connected.
* If new categories become loadable, +load is NOT called, and they 
*   are added to the end of the loadable list, and we return TRUE.
* Return FALSE if no new categories became loadable.
*
* Called only by call_load_methods().
**********************************************************************/
static BOOL call_category_loads(void)
{
    int i, shift;
    BOOL new_categories_added = NO;
    
    // Detach current loadable list.
    struct loadable_category *cats = loadable_categories;
    int used = loadable_categories_used;
    int allocated = loadable_categories_allocated;
    loadable_categories = NULL;
    loadable_categories_allocated = 0;
    loadable_categories_used = 0;

    // Call all +loads for the detached list.
    for (i = 0; i < used; i++) {
        struct objc_category *cat = cats[i].cat;
        IMP load_method = cats[i].method;
        struct objc_class *cls;
        if (!cat) continue;

        cls = objc_getClass(cat->class_name);
        if (cls  &&  class_is_connected(cls)) {
            if (PrintLoading) {
                _objc_inform("LOAD: +[%s(%s) load]\n", 
                             cls->name, cat->category_name);
            }
            (*load_method) ((id) cls, @selector(load));
            cats[i].cat = NULL;
        }
    }

    // Compact detached list (order-preserving)
    shift = 0;
    for (i = 0; i < used; i++) {
        if (cats[i].cat) {
            cats[i-shift] = cats[i];
        } else {
            shift++;
        }
    }
    used -= shift;

    // Copy any new +load candidates from the new list to the detached list.
    new_categories_added = (loadable_categories_used > 0);
    for (i = 0; i < loadable_categories_used; i++) {
        if (used == allocated) {
            allocated = allocated*2 + 16;
            cats = _realloc_internal(cats, allocated * 
                                     sizeof(struct loadable_category));
        }
        cats[used++] = loadable_categories[i];
    }

    // Destroy the new list.
    if (loadable_categories) _free_internal(loadable_categories);

    // Reattach the (now augmented) detached list. 
    // But if there's nothing left to load, destroy the list.
    if (used) {
        loadable_categories = cats;
        loadable_categories_used = used;
        loadable_categories_allocated = allocated;
    } else {
        if (cats) _free_internal(cats);
        loadable_categories = NULL;
        loadable_categories_used = 0;
        loadable_categories_allocated = 0;
    }

    if (PrintLoading) {
        if (loadable_categories_used != 0) {
            _objc_inform("LOAD: %d categories still waiting for +load\n",
                         loadable_categories_used);
        }
    }

    return new_categories_added;
}


/***********************************************************************
* call_load_methods
* Call all pending class and category +load methods.
* Class +load methods are called superclass-first. 
* Category +load methods are not called until after the parent class's +load.
* 
* This method must be RE-ENTRANT, because a +load could trigger 
* more image mapping. In addition, the superclass-first ordering 
* must be preserved in the face of re-entrant calls. Therefore, 
* only the OUTERMOST call of this function will do anything, and 
* that call will handle all loadable classes, even those generated 
* while it was running.
*
* The sequence below preserves +load ordering in the face of 
* image loading during a +load, and make sure that no 
* +load method is forgotten because it was added during 
* a +load call.
* Sequence:
* 1. Repeatedly call class +loads until there aren't any more
* 2. Call category +loads ONCE.
* 3. Run more +loads if:
*    (a) there are more classes to load, OR
*    (b) there are some potential category +loads that have 
*        still never been attempted.
* Category +loads are only run once to ensure "parent class first" 
* ordering, even if a category +load triggers a new loadable class 
* and a new loadable category attached to that class. 
*
* fixme this is not thread-safe, but neither is the rest of image mapping.
**********************************************************************/
static void call_load_methods(void)
{
    static pthread_t load_method_thread NOBSS = NULL;
    BOOL more_categories;

    if (load_method_thread) {
        // +loads are already being called. Do nothing, but complain 
        // if it looks like multithreaded use of this thread-unsafe code.

        if (! pthread_equal(load_method_thread, pthread_self())) {
            _objc_inform("WARNING: multi-threaded library loading detected "
                         "(implementation is not thread-safe)");
        }
        return;
    }
    
    // Nobody else is calling +loads, so we should do it ourselves.
    load_method_thread = pthread_self();

    do {
        // 1. Repeatedly call class +loads until there aren't any more
        while (loadable_classes_used > 0) {
            call_class_loads();
        }

        // 2. Call category +loads ONCE
        more_categories = call_category_loads();

        // 3. Run more +loads if there are classes OR more untried categories
    } while (loadable_classes_used > 0  ||  more_categories);

    load_method_thread = NULL;
}


/***********************************************************************
* really_connect_class
* Connect cls to superclass supercls unconditionally.
* Also adjust the class hash tables and handle +load and pended subclasses.
*
* This should be called from connect_class() ONLY.
**********************************************************************/
static void really_connect_class(struct objc_class *cls, 
                                 struct objc_class *supercls)
{
    struct objc_class *oldCls;
    struct objc_class *meta = cls->isa;

    // Wire the classes together.
    if (supercls) {
        cls->super_class = supercls;
        meta->super_class = supercls->isa;
        meta->isa = supercls->isa->isa;
    } else {        
        cls->super_class = NULL; // superclass of root class is NULL
        meta->super_class = cls; // superclass of root metaclass is root class
        meta->isa = meta;      // metaclass of root metaclass is root metaclass
    }

    OBJC_LOCK(&classLock);

    // Update hash tables. 
    NXHashRemove(unconnected_class_hash, cls);
    oldCls = NXHashInsert(class_hash, cls);

    // Delete unconnected_class_hash if it is now empty.
    if (NXCountHashTable(unconnected_class_hash) == 0) {
        NXFreeHashTable(unconnected_class_hash);
        unconnected_class_hash = NULL;
    }

    OBJC_UNLOCK(&classLock);

    // Warn if the new class has the same name as a previously-installed class.
    // The new class is kept and the old class is discarded.
    if (oldCls) {
        const header_info *oldHeader = _headerForClass(oldCls);
        const header_info *newHeader = _headerForClass(cls);
        const char *oldName = _nameForHeader(oldHeader->mhdr);
        const char *newName = _nameForHeader(newHeader->mhdr);
        
        _objc_inform ("Both %s and %s have implementations of class %s.",
                      oldName, newName, oldCls->name);
        _objc_inform ("Using implementation from %s.", newName);
    }
 
    // Prepare for +load and connect newly-connectable subclasses
    add_class_to_loadable_list(cls);
    resolve_subclasses_of_class(cls);

    // GC debugging: make sure all classes with -dealloc also have -finalize
    if (CheckFinalizers) {
        extern IMP findIMPInClass(Class cls, SEL sel);
        if (findIMPInClass(cls, sel_getUid("dealloc"))  &&  
            ! findIMPInClass(cls, sel_getUid("finalize")))
        {
            _objc_inform("GC: class '%s' implements -dealloc but not -finalize", cls->name);
        }
    }

    // Debugging: if this class has ivars, make sure this class's ivars don't 
    // overlap with its super's. This catches some broken fragile base classes.
    // Do not use super->instance_size vs. self->ivar[0] to check this. 
    // Ivars may be packed across instance_size boundaries.
    if (DebugFragileSuperclasses  &&  cls->ivars  &&  cls->ivars->ivar_count) {
        struct objc_class *ivar_cls = supercls;

        // Find closest superclass that has some ivars, if one exists.
        while (ivar_cls  &&  
               (!ivar_cls->ivars || ivar_cls->ivars->ivar_count == 0))
        {
            ivar_cls = ivar_cls->super_class;
        }

        if (ivar_cls) {
            // Compare superclass's last ivar to this class's first ivar
            struct objc_ivar *super_ivar = 
                &ivar_cls->ivars->ivar_list[ivar_cls->ivars->ivar_count - 1];
            struct objc_ivar *self_ivar = 
                &cls->ivars->ivar_list[0];

            // fixme could be smarter about super's ivar size
            if (self_ivar->ivar_offset <= super_ivar->ivar_offset) {
                _objc_inform("WARNING: ivars of superclass '%s' and "
                             "subclass '%s' overlap; superclass may have "
                             "changed since subclass was compiled", 
                             ivar_cls->name, cls->name);
            }
        }
    }
}


/***********************************************************************
* connect_class
* Connect class cls to its superclasses, if possible.
* If cls becomes connected, move it from unconnected_class_hash 
*   to connected_class_hash.
* Returns TRUE if cls is connected.
* Returns FALSE if cls could not be connected for some reason 
*   (missing superclass or still-unconnected superclass)
**********************************************************************/
static BOOL connect_class(struct objc_class *cls)
{
    if (class_is_connected(cls)) {
        // This class is already connected to its superclass.
        // Do nothing.
        return TRUE;
    }
    else if (cls->super_class == NULL) {
        // This class is a root class. 
        // Connect it to itself. 

        if (PrintConnecting) {
            _objc_inform("CONNECT: class '%s' now connected (root class)", 
                        cls->name);
        }

        really_connect_class(cls, NULL);
        return TRUE;
    }
    else {
        // This class is not a root class and is not yet connected.
        // Connect it if its superclass and root class are already connected. 
        // Otherwise, add this class to the to-be-connected list, 
        // pending the completion of its superclass and root class.

        // At this point, cls->super_class and cls->isa->isa are still STRINGS
        char *supercls_name = (char *)cls->super_class;
        struct objc_class *supercls;

        // YES unconnected, YES class handler
        if (NULL == (supercls = look_up_class(supercls_name, YES, YES))) {
            // Superclass does not exist yet.
            // pendClassInstallation will handle duplicate pends of this class
            pendClassInstallation(cls, supercls_name);

            if (PrintConnecting) {
                _objc_inform("CONNECT: class '%s' NOT connected (missing super)", cls->name);
            }
            return FALSE;
        }
        
        if (! connect_class(supercls)) {
            // Superclass exists but is not yet connected.
            // pendClassInstallation will handle duplicate pends of this class
            pendClassInstallation(cls, supercls_name);

            if (PrintConnecting) {
                _objc_inform("CONNECT: class '%s' NOT connected (unconnected super)", cls->name);
            }
            return FALSE;
        }

        // Superclass exists and is connected. 
        // Connect this class to the superclass.
        
        if (PrintConnecting) {
            _objc_inform("CONNECT: class '%s' now connected", cls->name);
        }

        really_connect_class(cls, supercls);
        return TRUE;
    } 
}


/***********************************************************************
* _objc_read_classes_from_image.
* Read classes from the given image, perform assorted minor fixups, 
*   scan for +load implementation.
* Does not connect classes to superclasses. 
* Does attach pended categories to the classes.
* Adds all classes to unconnected_class_hash. class_hash is unchanged.
**********************************************************************/
static void	_objc_read_classes_from_image(header_info *hi)
{
    unsigned int	index;
    unsigned int	midx;
    Module		mods;
    int 		isBundle = (hi->mhdr->filetype == MH_BUNDLE);

    if (_objcHeaderIsReplacement(hi)) {
        // Ignore any classes in this image
        return;
    }

    // class_hash starts small, enough only for libobjc itself. 
    // If other Objective-C libraries are found, immediately resize 
    // class_hash, assuming that Foundation and AppKit are about 
    // to add lots of classes.
    OBJC_LOCK(&classLock);
    if (hi->mhdr != &_mh_dylib_header && _NXHashCapacity(class_hash) < 1024) {
        _NXHashRehashToCapacity(class_hash, 1024);
    }
    OBJC_UNLOCK(&classLock);

    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;

        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct objc_class *	newCls;
            struct objc_method_list *mlist;

            // Locate the class description pointer
            newCls = mods[midx].symtab->defs[index];

            // Classes loaded from Mach-O bundles can be unloaded later.
            // Nothing uses this class yet, so _class_setInfo is not needed.
            if (isBundle) newCls->info |= CLS_FROM_BUNDLE;
            if (isBundle) newCls->isa->info |= CLS_FROM_BUNDLE;

            // Use common static empty cache instead of NULL
            if (newCls->cache == NULL)
                newCls->cache = (Cache) &emptyCache;
            if (newCls->isa->cache == NULL)
                newCls->isa->cache = (Cache) &emptyCache;

            // Set metaclass version
            newCls->isa->version = mods[midx].version;

            // methodLists is NULL or a single list, not an array
            newCls->info |= CLS_NO_METHOD_ARRAY;
            newCls->isa->info |= CLS_NO_METHOD_ARRAY;

            // Check for +load implementation before categories are attached
            if ((mlist = get_base_method_list(newCls->isa))) {
                if (lookupNamedMethodInMethodList (mlist, "load")) {
                    newCls->isa->info |= CLS_HAS_LOAD_METHOD;
                }
            }
            
            // Install into unconnected_class_hash
            OBJC_LOCK(&classLock);
            if (!unconnected_class_hash) {
                unconnected_class_hash = 
                    NXCreateHashTableFromZone(classHashPrototype, 128, NULL, 
                                              _objc_internal_zone());
            }
            NXHashInsert(unconnected_class_hash, newCls);
            OBJC_UNLOCK(&classLock);

            // Fix up pended class refs to this class, if any
            resolve_references_to_class(newCls);

            // Attach pended categories for this class, if any
            resolve_categories_for_class(newCls);
        }
    }
}


/***********************************************************************
* _objc_connect_classes_from_image.
* Connect the classes in the given image to their superclasses,
* or register them for later connection if any superclasses are missing.
**********************************************************************/
static void _objc_connect_classes_from_image(header_info *hi)
{
    unsigned int index;
    unsigned int midx;
    Module mods;
    BOOL replacement = _objcHeaderIsReplacement(hi);

    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;

        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct objc_class *cls = mods[midx].symtab->defs[index];
            if (! replacement) {
                BOOL connected = connect_class(cls);
                if (connected  &&  callbackFunction) {
                    (*callbackFunction)(cls, 0);
                }
            } else {
                // Replacement image - fix up super_class only (#3704817)
                const char *super_name = (const char *) cls->super_class;
                if (super_name) cls->super_class = objc_getClass(super_name);
            }
        }
    }
}


/***********************************************************************
* _objc_map_class_refs_for_image.  Convert the class ref entries from
* a class name string pointer to a class pointer.  If the class does
* not yet exist, the reference is added to a list of pending references
* to be fixed up at a later date.
**********************************************************************/
static void _objc_map_class_refs_for_image (header_info * hi)
{
    struct objc_class * *			cls_refs;
    unsigned int	size;
    unsigned int	index;

    // Locate class refs in image
    cls_refs = _getObjcClassRefs ((headerType *) hi->mhdr, &size);
    if (!cls_refs)
        return;
    cls_refs = (struct objc_class * *) ((unsigned long) cls_refs + hi->image_slide);

    // Process each class ref
    for (index = 0; index < size; index += 1)
    {
        const char *	ref;
        struct objc_class *		cls;

        // Get ref to convert from name string to class pointer
        ref = (const char *) cls_refs[index];

        // Get pointer to class of this name
        // YES unconnected, YES class loader
        cls = look_up_class(ref, YES, YES);
        if (cls) {
            // Referenced class exists. Fix up the reference.
            cls_refs[index] = cls;
        } else {
            // Referenced class does not exist yet. Insert a placeholder 
            // class and fix up the reference later.
            pendClassReference (&cls_refs[index], ref);
            cls_refs[index] = _objc_getNonexistentClass ();
        }
    }
}


/***********************************************************************
* _objc_remove_pending_class_refs_in_image
* Delete any pending class ref fixups for class refs in the given image, 
* because the image is about to be unloaded.
**********************************************************************/
static void _objc_remove_pending_class_refs_in_image(header_info *hi)
{
    struct objc_class **cls_refs, **cls_refs_end;
    unsigned int size;

    if (!pendingClassRefsMap) return;

    // Locate class refs in this image
    cls_refs = _getObjcClassRefs ((headerType *) hi->mhdr, &size);
    if (!cls_refs)
        return;
    cls_refs = (struct objc_class **) ((uintptr_t)cls_refs + hi->image_slide);
    cls_refs_end = (struct objc_class **)(size + (uintptr_t)cls_refs);

    // Search the pending class ref table for class refs in this range.
    // The class refs may have already been stomped with nonexistentClass, 
    // so there's no way to recover the original class name.
    
    const char *key;
    PendingClassRef *pending;
    NXMapState  state = NXInitMapState(pendingClassRefsMap);
    while(NXNextMapState(pendingClassRefsMap, &state, 
                         (const void **)&key, (const void **)&pending)) 
    {
        for ( ; pending != NULL; pending = pending->next) {
            if (pending->ref >= cls_refs  &&  pending->ref < cls_refs_end) {
                pending->ref = NULL;
            }
        }
    } 
}


/***********************************************************************
* map_selrefs.  Register each selector in the specified array.  If a
* given selector is already registered, update this array to point to
* the registered selector string.
* If copy is TRUE, all selector data is always copied. This is used 
* for registering selectors from unloadable bundles, so the selector 
* can still be used after the bundle's data segment is unmapped.
* Returns YES if dst was written to, NO if it was unchanged.
**********************************************************************/
static inline BOOL map_selrefs(SEL *src, SEL *dst, size_t size, BOOL copy)
{
    BOOL result = NO;
    unsigned int cnt = size / sizeof(SEL);
    unsigned int index;

    sel_lock();

    // Process each selector
    for (index = 0; index < cnt; index += 1)
    {
        SEL sel;

        // Lookup pointer to uniqued string
        sel = sel_registerNameNoLock((const char *) src[index], copy);

        // Replace this selector with uniqued one (avoid
        // modifying the VM page if this would be a NOP)
        if (dst[index] != sel) {
            dst[index] = sel;
            result = YES;
        }
    }
    
    sel_unlock();

    return result;
}


/***********************************************************************
* map_method_descs.  For each method in the specified method list,
* replace the name pointer with a uniqued selector.
* If copy is TRUE, all selector data is always copied. This is used 
* for registering selectors from unloadable bundles, so the selector 
* can still be used after the bundle's data segment is unmapped.
**********************************************************************/
static void  map_method_descs (struct objc_method_description_list * methods, BOOL copy)
{
    unsigned int	index;

    sel_lock();

    // Process each method
    for (index = 0; index < methods->count; index += 1)
    {
        struct objc_method_description *	method;
        SEL					sel;

        // Get method entry to fix up
        method = &methods->list[index];

        // Lookup pointer to uniqued string
        sel = sel_registerNameNoLock((const char *) method->name, copy);

        // Replace this selector with uniqued one (avoid
        // modifying the VM page if this would be a NOP)
        if (method->name != sel)
            method->name = sel;
    }

    sel_unlock();
}

/***********************************************************************
* _fixup.
**********************************************************************/
@interface Protocol(RuntimePrivate)
+ _fixup: (OBJC_PROTOCOL_PTR)protos numElements: (int) nentries;
@end

/***********************************************************************
* _objc_fixup_protocol_objects_for_image.  For each protocol in the
* specified image, selectorize the method names and call +_fixup.
**********************************************************************/
static void _objc_fixup_protocol_objects_for_image (header_info * hi)
{
    unsigned int	size;
    OBJC_PROTOCOL_PTR	protos;
    unsigned int	index;
    int isBundle = hi->mhdr->filetype == MH_BUNDLE;

    // Locate protocols in the image
    protos = (OBJC_PROTOCOL_PTR) _getObjcProtocols ((headerType *) hi->mhdr, &size);
    if (!protos)
        return;

    // Apply the slide bias
    protos = (OBJC_PROTOCOL_PTR) ((unsigned long) protos + hi->image_slide);

    // Process each protocol
    for (index = 0; index < size; index += 1)
    {
        // Selectorize the instance methods
        if (protos[index] OBJC_PROTOCOL_DEREF instance_methods)
            map_method_descs (protos[index] OBJC_PROTOCOL_DEREF instance_methods, isBundle);

        // Selectorize the class methods
        if (protos[index] OBJC_PROTOCOL_DEREF class_methods)
            map_method_descs (protos[index] OBJC_PROTOCOL_DEREF class_methods, isBundle);
    }

    // Invoke Protocol class method to fix up the protocol
    [Protocol _fixup:(OBJC_PROTOCOL_PTR)protos numElements:size];
}

/***********************************************************************
* _objc_headerStart.  Return what headers we know about.
**********************************************************************/
header_info *	_objc_headerStart ()
{

    // Take advatage of our previous work
    return FirstHeader;
}

void _objc_bindModuleContainingList() {
    /* We define this for backwards binary compat with things which should not
    * have been using it (cough OmniWeb), but now it does nothing for them.
    */
}


/***********************************************************************
* _objc_addHeader.
**********************************************************************/

// tested with 2; typical case is 4, but OmniWeb & Mail push it towards 20
#define HINFO_SIZE 16

static int HeaderInfoCounter NOBSS = 0;
static header_info HeaderInfoTable[HINFO_SIZE] NOBSS = { {0} };

static header_info * _objc_addHeader(const struct mach_header *header)
{
    int mod_count = 0;
    uintptr_t mod_unslid;
    uint32_t info_size = 0;
    uintptr_t image_info_unslid;
    const struct segment_command *objc_segment;
    ptrdiff_t slide;
    header_info *result;

    // Locate the __OBJC segment
    objc_segment = getsegbynamefromheader(header, SEG_OBJC);
    if (!objc_segment) return NULL;

    // Locate some sections in the __OBJC segment
    mod_unslid = (uintptr_t)_getObjcModules(header, &mod_count);
    if (!mod_unslid) return NULL;
    image_info_unslid = (uintptr_t)_getObjcImageInfo(header, &info_size);

    // Calculate vm slide.
    slide = _getImageSlide(header);


    // Find or allocate a header_info entry.
    if (HeaderInfoCounter < HINFO_SIZE) {
        result = &HeaderInfoTable[HeaderInfoCounter++];
    } else {
        result = _malloc_internal(sizeof(header_info));
    }

    // Set up the new header_info entry.
    result->mhdr = header;
    result->mod_ptr = (Module)(mod_unslid + slide);
    result->mod_count  = mod_count;
    result->image_slide	= slide;
    result->objcSegmentHeader = objc_segment;
    if (image_info_unslid) {
        result->info = (objc_image_info *)(image_info_unslid + slide);
    } else {
        result->info = NULL;
    }

    // Make sure every copy of objc_image_info in this image is the same.
    // This means same version and same bitwise contents.
    if (result->info) {
        objc_image_info *start = result->info;
        objc_image_info *end = 
            (objc_image_info *)(info_size + (uint8_t *)start);
        objc_image_info *info = start;
        while (info < end) {
            // version is byte size, except for version 0
            size_t struct_size = info->version;
            if (struct_size == 0) struct_size = 2 * sizeof(uint32_t);
            if (info->version != start->version  ||  
                0 != memcmp(info, start, struct_size))
            {
                _objc_fatal("'%s' has inconsistently-compiled Objective-C "
                            "code. Please recompile all code in it.", 
                            _nameForHeader(header));
            }
            info = (objc_image_info *)(struct_size + (uint8_t *)info);
        }
    }

    // Add the header to the header list. 
    // The header is appended to the list, to preserve the bottom-up order.
    result->next = NULL;
    if (!FirstHeader) {
        // list is empty
        FirstHeader = LastHeader = result;
    } else {
        if (!LastHeader) {
            // list is not empty, but LastHeader is invalid - recompute it
            LastHeader = FirstHeader;
            while (LastHeader->next) LastHeader = LastHeader->next;
        }
        // LastHeader is now valid
        LastHeader->next = result;
        LastHeader = result;
    }
    
    return result;
}


/***********************************************************************
* _objc_RemoveHeader
* Remove the given header from the header list.
* FirstHeader is updated. 
* LastHeader is set to NULL. Any code that uses LastHeader must 
* detect this NULL and recompute LastHeader by traversing the list.
**********************************************************************/
static void _objc_removeHeader(header_info *hi)
{
    header_info **hiP;

    for (hiP = &FirstHeader; *hiP != NULL; hiP = &(**hiP).next) {
        if (*hiP == hi) {
            header_info *deadHead = *hiP;

            // Remove from the linked list (updating FirstHeader if necessary).
            *hiP = (**hiP).next;
            
            // Update LastHeader if necessary.
            if (LastHeader == deadHead) {
                LastHeader = NULL;  // will be recomputed next time it's used
            }

            // Free the memory, unless it was in the static HeaderInfoTable.
            if (deadHead < HeaderInfoTable  ||
                deadHead >= HeaderInfoTable + HINFO_SIZE)
            {
                _free_internal(deadHead);
            }

            break;
        }
    }
}


/***********************************************************************
* check_gc
* Check whether the executable supports or requires GC, and make sure 
* all already-loaded libraries support the executable's GC mode.
* Returns TRUE if the executable wants GC on.
**********************************************************************/
static BOOL check_wants_gc(void)
{
    // GC is off in Tiger.
    return NO;
    /*
    const header_info *hi;
    BOOL appWantsGC;

    // Environment variables can override the following.
    if (ForceGC) {
        _objc_inform("GC: forcing GC ON because OBJC_FORCE_GC is set");
        appWantsGC = YES;
    } 
    else if (ForceNoGC) {
        _objc_inform("GC: forcing GC OFF because OBJC_FORCE_NO_GC is set");
        appWantsGC = NO;
    }
    else {
        // Find the executable and check its GC bits. 
        // If the executable cannot be found, default to NO.
        // (The executable will not be found if the executable contains 
        // no Objective-C code.)
        appWantsGC = NO;
        for (hi = FirstHeader; hi != NULL; hi = hi->next) {
            if (hi->mhdr->filetype == MH_EXECUTE) {
                appWantsGC = _objcHeaderSupportsGC(hi) ? YES : NO;
                if (PrintGC) {
                    _objc_inform("GC: executable '%s' %s GC",
                                 _nameForHeader(hi->mhdr), 
                                 appWantsGC ? "supports" : "does not support");
                }
            }
        }
    }
    return appWantsGC;
    */
}

/***********************************************************************
* verify_gc_readiness
* if we want gc, verify that every header describes files compiled
* and presumably ready for gc.
************************************************************************/

static void verify_gc_readiness(BOOL wantsGC, header_info *hi) 
{
    BOOL busted = NO;

    // Find the libraries and check their GC bits against the app's request
    for (; hi != NULL; hi = hi->next) {
        if (hi->mhdr->filetype == MH_EXECUTE) {
            continue;
        }
        else if (hi->mhdr == &_mh_dylib_header) {
            // libobjc itself works with anything even though it is not 
            // compiled with -fobjc-gc (fixme should it be?)
        } 
        else if (wantsGC  &&  ! _objcHeaderSupportsGC(hi)) {
            // App wants GC but library does not support it - bad
            _objc_inform("'%s' was not compiled with -fobjc-gc, but "
                         "the application requires GC",
                         _nameForHeader(hi->mhdr));
            busted = YES;
        } 

        if (PrintGC) {
            _objc_inform("GC: library '%s' %s GC", _nameForHeader(hi->mhdr), 
                         _objcHeaderSupportsGC(hi) ? "supports" : "does not support");
        }
    }
    
    if (busted) {
        // GC state is not consistent. 
        // Kill the process unless one of the forcing flags is set.
        if (!ForceGC  &&  !ForceNoGC) {
            _objc_fatal("*** GC capability of application and some libraries did not match");
        }
    }
}


/***********************************************************************
* _objc_fixup_selector_refs.  Register all of the selectors in each
* image, and fix them all up.
* 
* If the image is a dylib (not a bundle or an executable), and contains 
* at least one full aligned page of selector refs, this function uses 
* the shared range functions to try to recycle already-written memory 
* from other processes. 
**********************************************************************/
static void _objc_fixup_selector_refs   (const header_info *	hi)
{
    unsigned int count;
    Module mods;
    vm_address_t local_sels;
    vm_size_t local_size;

    mods = hi->mod_ptr;

    // Fix up message refs
    local_sels = (vm_address_t) _getObjcMessageRefs ((headerType *) hi->mhdr, &count);
    local_size = count * sizeof(SEL);
    
    if (local_sels) {
        vm_address_t aligned_start, aligned_end;

        local_sels = local_sels + hi->image_slide;
        aligned_start = round_page(local_sels);
        aligned_end = trunc_page(local_sels + local_size);
        
        if (aligned_start >= aligned_end  ||  
            hi->mhdr->filetype == MH_BUNDLE  ||  
            hi->mhdr->filetype == MH_EXECUTE) 
        {
            // Less than a page of sels, OR bundle or executable - fix in place

            map_selrefs((SEL *)local_sels, (SEL *)local_sels, local_size, 
                        hi->mhdr->filetype == MH_BUNDLE);

            if (PrintSharing) {
                _objc_inform("SHARING: NONE  [%p..%p) (%d pages) for %s", 
                             local_sels, local_sels+local_size, 
                             (aligned_end > aligned_start ? 
                              (aligned_end-aligned_start) / vm_page_size : 0), 
                             _nameForHeader(hi->mhdr));
            }
        } 
        else {
            // At least one page of sels - try to use sharing
            vm_range_t remote_range;
            
            if (PrintSharing) {
                _objc_inform("SHARING: looking for range [%p..%p) ...", 
                             aligned_start, aligned_end);
            }

            remote_range = get_shared_range(aligned_start, aligned_end);

            if (remote_range.address != 0) {
                // Sharing succeeded - fix using remote_range
                BOOL stomped;

                // local_sels..aligned_start (unshared)
                map_selrefs((SEL *)local_sels, (SEL *)local_sels, 
                            aligned_start - local_sels, NO);
                // aligned_start..aligned_end (shared)
                stomped =
                map_selrefs((SEL *)aligned_start, (SEL *)remote_range.address, 
                            aligned_end - aligned_start, NO);
                // aligned_end..local_sels+local_size (unshared)
                map_selrefs((SEL *)aligned_end, (SEL *)aligned_end, 
                            local_sels+local_size - aligned_end, NO);

                install_shared_range(remote_range, aligned_start);

                if (PrintSharing) {
                    _objc_inform("SHARING: %s [%p..%p) (%d pages) for %s", 
                                 stomped ? "TRIED" : "USING", 
                                 local_sels, local_sels+local_size, 
                                 (aligned_end-aligned_start) / vm_page_size,
                                 _nameForHeader(hi->mhdr));
                }
            } 
            else {
                // Sharing failed, including first process - 
                // fix in place and then offer to share

                map_selrefs((SEL *)local_sels, (SEL *)local_sels, local_size, NO);

                offer_shared_range(aligned_start, aligned_end);

                if (PrintSharing) {
                    _objc_inform("SHARING: OFFER [%p..%p) (%d pages) for %s", 
                                 local_sels, local_sels+local_size, 
                                 (aligned_end-aligned_start) / vm_page_size, 
                                 _nameForHeader(hi->mhdr));
                }
            }
        }
    }
}


/***********************************************************************
* objc_setConfiguration
* Read environment variables that affect the runtime.
* Also print environment variable help, if requested.
**********************************************************************/
static void objc_setConfiguration() {
    int PrintHelp = (getenv("OBJC_HELP") != NULL);
    int PrintOptions = (getenv("OBJC_PRINT_OPTIONS") != NULL);
    
    if (PrintHelp) {
        _objc_inform("OBJC_HELP: describe Objective-C runtime environment variables");
        if (PrintOptions) {
            _objc_inform("OBJC_HELP is set");
        }
        _objc_inform("OBJC_PRINT_OPTIONS: list which options are set");
    }
    if (PrintOptions) {
        _objc_inform("OBJC_PRINT_OPTIONS is set");
    }
    
#define OPTION(var, env, help) \
    if ( var == -1 ) { \
        var = getenv(#env) != NULL; \
        if (PrintHelp) _objc_inform(#env ": " help); \
        if (PrintOptions && var) _objc_inform(#env " is set"); \
    }
    
    OPTION(PrintImages, OBJC_PRINT_IMAGES,
           "log image and library names as the runtime loads them");
    OPTION(PrintConnecting, OBJC_PRINT_CONNECTION,
           "log progress of class and category connections");
    OPTION(PrintLoading, OBJC_PRINT_LOAD_METHODS,
           "log class and category +load methods as they are called");
    OPTION(PrintRTP, OBJC_PRINT_RTP,
           "log initialization of the Objective-C runtime pages");
    OPTION(PrintGC, OBJC_PRINT_GC,
           "log some GC operations");
    OPTION(PrintSharing, OBJC_PRINT_SHARING,
           "log cross-process memory sharing");
    OPTION(PrintCxxCtors, OBJC_PRINT_CXX_CTORS, 
           "log calls to C++ ctors and dtors for instance variables");

    OPTION(DebugUnload, OBJC_DEBUG_UNLOAD,
           "warn about poorly-behaving bundles when unloaded");
    OPTION(DebugFragileSuperclasses, OBJC_DEBUG_FRAGILE_SUPERCLASSES, 
           "warn about subclasses that may have been broken by subsequent changes to superclasses");

    OPTION(UseInternalZone, OBJC_USE_INTERNAL_ZONE,
           "allocate runtime data in a dedicated malloc zone");
    OPTION(AllowInterposing, OBJC_ALLOW_INTERPOSING,
           "allow function interposing of objc_msgSend()");

    OPTION(ForceGC, OBJC_FORCE_GC,
           "force GC ON, even if the executable wants it off");
    OPTION(ForceNoGC, OBJC_FORCE_NO_GC,
           "force GC OFF, even if the executable wants it on");
    OPTION(CheckFinalizers, OBJC_CHECK_FINALIZERS, 
           "warn about classes that implement -dealloc but not -finalize");
#undef OPTION
}


/***********************************************************************
* objc_setMultithreaded.
**********************************************************************/
void objc_setMultithreaded (BOOL flag)
{
    // Nothing here. Thread synchronization in the runtime is always active.
}



/***********************************************************************
* _objc_pthread_destroyspecific
* Destructor for objc's per-thread data.
* arg shouldn't be NULL, but we check anyway.
**********************************************************************/
extern void _destroyInitializingClassList(struct _objc_initializing_classes *list);
void _objc_pthread_destroyspecific(void *arg)
{
    _objc_pthread_data *data = (_objc_pthread_data *)arg;
    if (data != NULL) {
        _destroyInitializingClassList(data->initializingClasses);

        // add further cleanup here...

        _free_internal(data);
    }
}


/***********************************************************************
* _objcInit
* Former library initializer. This function is now merely a placeholder 
* for external callers. All runtime initialization has now been moved 
* to map_images().
**********************************************************************/
void _objcInit(void)
{
    // do nothing
}


/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* All class registration and fixups are performed (or deferred pending
* discovery of missing superclasses etc), and +load methods are called.
*
* info[] is in bottom-up order i.e. libobjc will be earlier in the 
* array than any library that links to libobjc.
**********************************************************************/
static void map_images(const struct dyld_image_info infoList[], 
                       uint32_t infoCount)
{
    static BOOL firstTime = YES;
    static BOOL wantsGC NOBSS = NO;
    uint32_t i;
    header_info *firstNewHeader = NULL;
    header_info *hInfo;

    // Perform first-time initialization if necessary.
    // This function is called before ordinary library initializers. 
    if (firstTime) {
        pthread_key_create(&_objc_pthread_key, _objc_pthread_destroyspecific);
        objc_setConfiguration();   // read environment variables
        _objc_init_class_hash ();  // create class_hash
        // grab selectors for which @selector() doesn't work
        cxx_construct_sel = sel_registerName(cxx_construct_name);
        cxx_destruct_sel  = sel_registerName(cxx_destruct_name);
    }

    if (PrintImages) {
        _objc_inform("IMAGES: processing %u newly-mapped images...\n", infoCount);
    }


    // Find all images with an __OBJC segment.
    // firstNewHeader is set the the first one, and the header_info 
    // linked list following firstNewHeader is the rest.
    for (i = 0; i < infoCount; i++) {
        const struct mach_header *mhdr = infoList[i].imageLoadAddress;

        hInfo = _objc_addHeader(mhdr);
        if (!hInfo) {
            // no objc data in this entry
            if (PrintImages) {
                _objc_inform("IMAGES: image '%s' contains no __OBJC segment\n",
                             infoList[i].imageFilePath);
            }
            continue;
        }

        if (!firstNewHeader) firstNewHeader = hInfo;
        
        if (PrintImages) {
            _objc_inform("IMAGES: loading image for %s%s%s%s\n", 
                         _nameForHeader(mhdr), 
                         mhdr->filetype == MH_BUNDLE ? " (bundle)" : "", 
                         _objcHeaderIsReplacement(hInfo) ? " (replacement)":"",
                         _objcHeaderSupportsGC(hInfo) ? " (supports GC)":"");
        }
    }

    // Perform one-time runtime initialization that must be deferred until 
    // the executable itself is found. This needs to be done before 
    // further initialization.
    // (The executable may not be present in this infoList if the 
    // executable does not contain Objective-C code but Objective-C 
    // is dynamically loaded later. In that case, check_wants_gc() 
    // will do the right thing.)
    if (firstTime) {
        wantsGC = check_wants_gc();
        verify_gc_readiness(wantsGC, FirstHeader);
        // TIGER DEVELOPMENT ONLY
        // REQUIRE A SPECIAL NON-SHIPPING FILE TO ENABLE GC
        if (wantsGC) {
            // make sure that the special file is there before proceeding with GC
            struct stat ignored;
            wantsGC = stat("/autozone", &ignored) != -1;
            if (!wantsGC && PrintGC)
                _objc_inform("GC: disabled, lacking /autozone file");
        }
											   
        gc_init(wantsGC);           // needs executable for GC decision
        rtp_init();                 // needs GC decision first
    } else {
        verify_gc_readiness(wantsGC, firstNewHeader);
    }


    // Initialize everything. Parts of this order are important for 
    // correctness or performance.

    // Read classes from all images.
    for (hInfo = firstNewHeader; hInfo != NULL; hInfo = hInfo->next) {
        _objc_read_classes_from_image(hInfo);
    }

    // Read categories from all images. 
    for (hInfo = firstNewHeader; hInfo != NULL; hInfo = hInfo->next) {
        _objc_read_categories_from_image(hInfo);
    }

    // Connect classes from all images.
    for (hInfo = firstNewHeader; hInfo != NULL; hInfo = hInfo->next) {
        _objc_connect_classes_from_image(hInfo);
    }

    // Fix up class refs, selector refs, and protocol objects from all images.
    for (hInfo = firstNewHeader; hInfo != NULL; hInfo = hInfo->next) {
        _objc_map_class_refs_for_image(hInfo);
        _objc_fixup_selector_refs(hInfo);
        _objc_fixup_protocol_objects_for_image(hInfo);
    }

    // Close any shared range file left open during selector uniquing
    clear_shared_range_file_cache();

    firstTime = NO;

    // Call pending +load methods.
    // Note that this may in turn cause map_images() to be called again.
    call_load_methods();
}


/***********************************************************************
* unmap_images
* Process the given images which are about to be unmapped by dyld.
* Currently we assume only MH_BUNDLE images are unmappable, and 
* print warnings about anything else.
**********************************************************************/
static void unmap_images(const struct dyld_image_info infoList[], 
                         uint32_t infoCount)
{
    uint32_t i;

    if (PrintImages) {
        _objc_inform("IMAGES: processing %u newly-unmapped images...\n", infoCount);
    }

    for (i = 0; i < infoCount; i++) {
        const struct mach_header *mhdr = infoList[i].imageLoadAddress;

        if (mhdr->filetype == MH_BUNDLE) {
            _objc_unmap_image(mhdr);
        } else {
            // currently only MH_BUNDLEs can be unmapped safely
            if (PrintImages) {
                _objc_inform("IMAGES: unmapped image '%s' was not a Mach-O bundle; ignoring\n", infoList[i].imageFilePath);
            }
        }
    }
}


/***********************************************************************
* _objc_notify_images
* Callback from dyld informing objc of images to be added or removed.
* This function is never called directly. Instead, a section 
* __OBJC,__image_notify contains a function pointer to this, and dyld 
* discovers it from there.
**********************************************************************/
__private_extern__ 
void _objc_notify_images(enum dyld_image_mode mode, uint32_t infoCount, 
                         const struct dyld_image_info infoList[])
{
    if (mode == dyld_image_adding) {
        map_images(infoList, infoCount);
    } else if (mode == dyld_image_removing) {
        unmap_images(infoList, infoCount);
    }
}


/***********************************************************************
* _objc_remove_classes_in_image
* Remove all classes in the given image from the runtime, because 
* the image is about to be unloaded.
* Things to clean up:
*   class_hash
*   unconnected_class_hash
*   pending subclasses list (only if class is still unconnected)
*   loadable class list
*   class's method caches
*   class refs in all other images
**********************************************************************/
static void    _objc_remove_classes_in_image(header_info *hi)
{
    unsigned int       index;
    unsigned int       midx;
    Module             mods;

    OBJC_LOCK(&classLock);
    
    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;
        
        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct objc_class *        cls;
            
            // Locate the class description pointer
            cls = mods[midx].symtab->defs[index];

            // Remove from loadable class list, if present
            remove_class_from_loadable_list(cls);

            // Remove from unconnected_class_hash and pending subclasses
            if (unconnected_class_hash  &&  NXHashMember(unconnected_class_hash, cls)) {
                NXHashRemove(unconnected_class_hash, cls);
                if (pendingSubclassesMap) {
                    // Find this class in its superclass's pending list
                    char *supercls_name = (char *)cls->super_class;
                    PendingSubclass *pending = 
                        NXMapGet(pendingSubclassesMap, supercls_name);
                    for ( ; pending != NULL; pending = pending->next) {
                        if (pending->subclass == cls) {
                            pending->subclass = Nil;
                            break;
                        }
                    }
                }
            }
            
            // Remove from class_hash
            NXHashRemove(class_hash, cls);

            // Free method list array (from objcTweakMethodListPointerForClass)
            // These blocks might be from user code; don't use free_internal
            if (cls->methodLists && !(cls->info & CLS_NO_METHOD_ARRAY)) {
                free(cls->methodLists);
            }
            if (cls->isa->methodLists && !(cls->isa->info & CLS_NO_METHOD_ARRAY)) {
                free(cls->isa->methodLists);
            }
            
            // Free method caches, if any
            if (cls->cache  &&  cls->cache != &emptyCache) {
                _free_internal(cls->cache);
            }
            if (cls->isa->cache  &&  cls->isa->cache != &emptyCache) {
                _free_internal(cls->isa->cache);
            }
        }
    }


    // Search all other images for class refs that point back to this range.
    // Un-fix and re-pend any such class refs.

    // Get the location of the dying image's __OBJC segment
    uintptr_t seg = hi->objcSegmentHeader->vmaddr + hi->image_slide;
    size_t seg_size = hi->objcSegmentHeader->filesize;

    header_info *other_hi;
    for (other_hi = FirstHeader; other_hi != NULL; other_hi = other_hi->next) {
        struct objc_class **other_refs;
        unsigned int size;
        if (other_hi == hi) continue;  // skip the image being unloaded

        // Locate class refs in the other image
        other_refs = _getObjcClassRefs((headerType *)other_hi->mhdr, &size);
        if (!other_refs) continue;
        other_refs = (struct objc_class **)((uintptr_t)other_refs + other_hi->image_slide);

        // Process each class ref
        for (index = 0; index < size; index++) {
            if ((uintptr_t)(other_refs[index]) >= seg  &&  
                (uintptr_t)(other_refs[index]) < seg+seg_size) 
            {
                pendClassReference(&other_refs[index],other_refs[index]->name);
                other_refs[index] = _objc_getNonexistentClass ();
            }
        }
    }

    OBJC_UNLOCK(&classLock);
}


/***********************************************************************
* _objc_remove_categories_in_image
* Remove all categories in the given image from the runtime, because 
* the image is about to be unloaded.
* Things to clean up:
*    unresolved category list
*    loadable category list
**********************************************************************/
static void    _objc_remove_categories_in_image(header_info *hi)
{
    Module mods;
    unsigned int midx;
    
    // Major loop - process all modules in the header
    mods = hi->mod_ptr;
    
    for (midx = 0; midx < hi->mod_count; midx++) {
        unsigned int index;
        unsigned int total;
        Symtab symtab = mods[midx].symtab;
        
        // Nothing to do for a module without a symbol table
        if (symtab == NULL) continue;
        
        // Total entries in symbol table (class entries followed
        // by category entries)
        total = symtab->cls_def_cnt + symtab->cat_def_cnt;
        
        // Minor loop - check all categories from given module
        for (index = symtab->cls_def_cnt; index < total; index++) {
            struct objc_category *cat = symtab->defs[index];

            // Clean up loadable category list
            remove_category_from_loadable_list(cat);

            // Clean up category_hash
            if (category_hash) {
                _objc_unresolved_category *cat_entry = 
                    NXMapGet(category_hash, cat->class_name);
                for ( ; cat_entry != NULL; cat_entry = cat_entry->next) {
                    if (cat_entry->cat == cat) {
                        cat_entry->cat = NULL;
                        break;
                    }
                }
            }
        }
    }
}


/***********************************************************************
* unload_paranoia
* Various paranoid debugging checks that look for poorly-behaving 
* unloadable bundles. 
* Called by _objc_unmap_image when OBJC_UNLOAD_DEBUG is set.
**********************************************************************/
static void unload_paranoia(header_info *hi) 
{
    // Get the location of the dying image's __OBJC segment
    uintptr_t seg = hi->objcSegmentHeader->vmaddr + hi->image_slide;
    size_t seg_size = hi->objcSegmentHeader->filesize;

    _objc_inform("UNLOAD DEBUG: unloading image '%s' [%p..%p]", 
                 _nameForHeader(hi->mhdr), seg, seg+seg_size);

    OBJC_LOCK(&classLock);

    // Make sure the image contains no categories on surviving classes.
    {
        Module mods;
        unsigned int midx;

        // Major loop - process all modules in the header
        mods = hi->mod_ptr;
        
        for (midx = 0; midx < hi->mod_count; midx++) {
            unsigned int index;
            unsigned int total;
            Symtab symtab = mods[midx].symtab;

            // Nothing to do for a module without a symbol table
            if (symtab == NULL) continue;
            
            // Total entries in symbol table (class entries followed
            // by category entries)
            total = symtab->cls_def_cnt + symtab->cat_def_cnt;
            
            // Minor loop - check all categories from given module
            for (index = symtab->cls_def_cnt; index < total; index++) {
                struct objc_category *cat = symtab->defs[index];
                struct objc_class query;

                query.name = cat->class_name;
                if (NXHashMember(class_hash, &query)) {
                    _objc_inform("UNLOAD DEBUG: dying image contains category '%s(%s)' on surviving class '%s'!", cat->class_name, cat->category_name, cat->class_name);
                }
            }
        }
    }

    // Make sure no surviving class is in the dying image.
    // Make sure no surviving class has a superclass in the dying image.
    // fixme check method implementations too
    {
        struct objc_class *cls;
        NXHashState state;

        state = NXInitHashState(class_hash);
        while (NXNextHashState(class_hash, &state, (void **)&cls)) {
            if ((vm_address_t)cls >= seg  && 
                (vm_address_t)cls < seg+seg_size) 
            {
                _objc_inform("UNLOAD DEBUG: dying image contains surviving class '%s'!", cls->name);
            }
            
            if ((vm_address_t)cls->super_class >= seg  &&  
                (vm_address_t)cls->super_class < seg+seg_size)
            {
                _objc_inform("UNLOAD DEBUG: dying image contains superclass '%s' of surviving class '%s'!", cls->super_class->name, cls->name);
            }
        }
    }

    OBJC_UNLOCK(&classLock);
}


/***********************************************************************
* _objc_unmap_image.
* Destroy any Objective-C data for the given image, which is about to 
* be unloaded by dyld.
* Note: not thread-safe, but image loading isn't either.
**********************************************************************/
static void	_objc_unmap_image(const headerType *mh) 
{
    header_info *hi;
    
    // Find the runtime's header_info struct for the image
    for (hi = FirstHeader; hi != NULL; hi = hi->next) {
        if (hi->mhdr == mh) break;
    }
    if (hi == NULL) return;  // no objc data for this image

    if (PrintImages) { 
        _objc_inform("IMAGES: unloading image for %s%s%s%s\n", 
                     _nameForHeader(mh), 
                     mh->filetype == MH_BUNDLE ? " (bundle)" : "", 
                     _objcHeaderIsReplacement(hi) ? " (replacement)" : "", 
                     _objcHeaderSupportsGC(hi) ? " (supports GC)" : "");
    }

    // Cleanup:
    // Remove image's classes from the class list and free auxiliary data.
    // Remove image's unresolved or loadable categories and free auxiliary data
    // Remove image's unresolved class refs.
    _objc_remove_classes_in_image(hi);
    _objc_remove_categories_in_image(hi);
    _objc_remove_pending_class_refs_in_image(hi);
    
    // Perform various debugging checks if requested.
    if (DebugUnload) unload_paranoia(hi);

    // Remove header_info from header list
    _objc_removeHeader(hi);
}


/***********************************************************************
* _objc_setNilReceiver
**********************************************************************/
id _objc_setNilReceiver(id newNilReceiver)
{
    id oldNilReceiver;

    oldNilReceiver = _objc_nilReceiver;
    _objc_nilReceiver = newNilReceiver;

    return oldNilReceiver;
}

/***********************************************************************
* _objc_getNilReceiver
**********************************************************************/
id _objc_getNilReceiver(void)
{
    return _objc_nilReceiver;
}


/***********************************************************************
* _objc_setClassLoader
* Similar to objc_setClassHandler, but objc_classLoader is used for 
* both objc_getClass() and objc_lookupClass(), and objc_classLoader 
* pre-empts objc_classHandler. 
**********************************************************************/
void _objc_setClassLoader(BOOL (*newClassLoader)(const char *))
{
    _objc_classLoader = newClassLoader;
}


#if defined(__ppc__)

/**********************************************************************
* objc_write_branch
* Writes at entry a PPC branch instruction sequence that branches to target.
* The sequence written will be 1 or 4 instructions long. 
* Returns the number of instructions written.
**********************************************************************/
__private_extern__ size_t objc_write_branch(void *entry, void *target) 
{
    unsigned *address = (unsigned *)entry;                              // location to store the 32 bit PPC instructions
    intptr_t destination = (intptr_t)target;                            // destination as an absolute address
    intptr_t displacement = (intptr_t)destination - (intptr_t)address;  // destination as a branch relative offset

    // Test to see if either the displacement or destination is within the +/- 2^25 range needed 
    // for a simple PPC branch instruction.  Shifting the high bit of the displacement (or destination)
    // left 6 bits and then 6 bits arithmetically to the right does a sign extend of the 26th bit.  If
    // that result is equivalent to the original value, then the displacement (or destination) will fit
    // into a simple branch.  Otherwise a four instruction branch sequence is required. 
    if (((displacement << 6) >> 6) == displacement) {
        // use a relative branch with the displacement
        address[0] = 0x48000000 | (displacement & 0x03fffffc); // b *+displacement
        // issued 1 instruction
        return 1;
    } else if (((destination << 6) >> 6) == destination) {
        // use an absolute branch with the destination
        address[0] = 0x48000000 | (destination & 0x03fffffc) | 2; // ba destination (2 is the absolute flag)
        // issued 1 instruction
        return 1;
    } else {
        // The four instruction branch sequence requires that the destination be loaded
        // into a register, moved to the CTR register then branch using the contents
        // of the CTR register.
        unsigned lo = destination & 0xffff;
        unsigned hi = (destination >> 16) & 0xffff;

        address[0] = 0x3d800000 | hi;               // lis r12,hi           ; load the hi half of destination
        address[1] = 0x618c0000 | lo;               // ori r12,r12,lo       ; merge in the lo half of destination
        address[2] = 0x7d8903a6;                    // mtctr                ; move destination to the CTR register
        address[3] = 0x4e800420;                    // bctr                 ; branch to destination
        // issued 4 instructions
        return 4;
    }
}

// defined(__ppc__)
#endif


/**********************************************************************
* secure_open
* Securely open a file from a world-writable directory (like /tmp)
* If the file does not exist, it will be atomically created with mode 0600
* If the file exists, it must be, and remain after opening: 
*   1. a regular file (in particular, not a symlink)
*   2. owned by euid
*   3. permissions 0600
*   4. link count == 1
* Returns a file descriptor or -1. Errno may or may not be set on error.
**********************************************************************/
__private_extern__ int secure_open(const char *filename, int flags, uid_t euid)
{
    struct stat fs, ls;
    int fd = -1;
    BOOL truncate = NO;
    BOOL create = NO;

    if (flags & O_TRUNC) {
        // Don't truncate the file until after it is open and verified.
        truncate = YES;
        flags &= ~O_TRUNC;
    }
    if (flags & O_CREAT) {
        // Don't create except when we're ready for it
        create = YES;
        flags &= ~O_CREAT;
        flags &= ~O_EXCL;
    }

    if (lstat(filename, &ls) < 0) {
        if (errno == ENOENT  &&  create) {
            // No such file - create it
            fd = open(filename, flags | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                // File was created successfully.
                // New file does not need to be truncated.
                return fd;
            } else {
                // File creation failed.
                return -1;
            }
        } else {
            // lstat failed, or user doesn't want to create the file
            return -1;
        }
    } else {
        // lstat succeeded - verify attributes and open
        if (S_ISREG(ls.st_mode)  &&  // regular file?
            ls.st_nlink == 1  &&     // link count == 1?
            ls.st_uid == euid  &&    // owned by euid?
            (ls.st_mode & ALLPERMS) == (S_IRUSR | S_IWUSR))  // mode 0600?
        {
            // Attributes look ok - open it and check attributes again
            fd = open(filename, flags, 0000);
            if (fd >= 0) {
                // File is open - double-check attributes
                if (0 == fstat(fd, &fs)  &&  
                    fs.st_nlink == ls.st_nlink  &&  // link count == 1?
                    fs.st_uid == ls.st_uid  &&      // owned by euid?
                    fs.st_mode == ls.st_mode  &&    // regular file, 0600?
                    fs.st_ino == ls.st_ino  &&      // same inode as before?
                    fs.st_dev == ls.st_dev)         // same device as before?
                {
                    // File is open and OK
                    if (truncate) ftruncate(fd, 0);
                    return fd;
                } else {
                    // Opened file looks funny - close it
                    close(fd);
                    return -1;
                }
            } else {
                // File didn't open
                return -1;
            }
        } else {
            // Unopened file looks funny - don't open it
            return -1;
        }
    }
}


/**********************************************************************
 * Shared range support:
 *
 * Some libraries contain many pages worth of selector references. 
 * In most processes, these libraries get loaded at the same addresses, 
 * so the selectors are uniqued to the same values. To save memory, 
 * the runtime tries to share these memory pages across processes. 
 *
 * A file /tmp/objc_sharing_<arch>_<euid> records memory ranges and process 
 * IDs. When a set of selector refs is to be uniqued, this file is checked 
 * for a matching memory range being shared by another process. If 
 * such a range is found:
 * 1. map the sharing process's memory somewhere into this address space
 * 2. read from the real selector refs and write into the mapped memory. 
 * 3. vm_copy from the mapped memory to the real selector refs location
 * 4. deallocate the mapped memory
 * 
 * The mapped memory is merely used as a guess. Correct execution is 
 * guaranteed no matter what values the mapped memory actually contains.
 * If the mapped memory really matches the values needed in this process, 
 * the mapped memory will be unchanged. If the mapped memory doesn't match, 
 * or contains random values, it will be fixed up to the correct values.
 * The memory is shared whenever the guess happens to be correct.
 *
 * The file of shared ranges is imprecise. Processes may die leaving 
 * their entries in the file. A PID may be recycled to some process that 
 * does not use Objective-C. The sharing mechanism is robust in the face 
 * of these failures. Bad shared memory is simply fixed up. No shared 
 * memory means the selectors are fixed in place. If an entry in the 
 * file is found to be unusable, the process that finds it will instead 
 * offer to share its own memory, replacing the bad entry in the file.
 * 
 * Individual entries in the file are written atomically, but the file is 
 * otherwise unsynchronized. At worst, a sharing opportunity may be missed 
 * because two new entries are written simultaneously in the same place.
 **********************************************************************/


struct remote_range_t {
    vm_range_t range;
    pid_t pid;
};


// Cache for the last shared range file used, and its EUID.
static pthread_mutex_t sharedRangeLock = PTHREAD_MUTEX_INITIALIZER;
static uid_t sharedRangeEUID = 0;
static FILE * sharedRangeFile = NULL;
static BOOL sharedRangeFileInUse = NO;


/**********************************************************************
* open_shared_range_file
* Open the shared range file "/tmp/objc_sharing_<arch>_<euid>" in 
* the given mode.
* The returned file should be closed with close_shared_range_file().
**********************************************************************/
static FILE *open_shared_range_file(BOOL create)
{
    const char arch[] = 
#if defined(__ppc__)  ||  defined(ppc)
        "ppc";
#elif defined(__ppc64__)  ||  defined(ppc64)
        "ppc64";
#elif defined(__i386__)  ||  defined(i386)
        "i386";
#else
#       error "unknown architecture"
#endif
    char filename[18 + sizeof(arch) + 1 + 3*sizeof(uid_t) + 1];
    uid_t euid;
    FILE *file = NULL;
    int fd;

    // Never share when superuser
    euid = geteuid();
    if (euid == 0) {
        if (PrintSharing) { 
            _objc_inform("SHARING: superuser never shares");
        }
        return NULL;
    }

    // Return cached file if it matches and it's not still being used
    pthread_mutex_lock(&sharedRangeLock);
    if (!sharedRangeFileInUse  &&  euid == sharedRangeEUID) {
        file = sharedRangeFile;
        sharedRangeFileInUse = YES;
        pthread_mutex_unlock(&sharedRangeLock);
        rewind(file);
        return file;
    }
    pthread_mutex_unlock(&sharedRangeLock);

    // Open /tmp/objc_sharing_<euid>
    snprintf(filename,sizeof(filename), "/tmp/objc_sharing_%s_%u", arch, euid);
    fd = secure_open(filename, O_RDWR | (create ? O_CREAT : 0), euid);
    if (fd >= 0) {
        file = fdopen(fd, "r+");
    }

    if (file) {
        // Cache this file if there's no already-open file cached
        pthread_mutex_lock(&sharedRangeLock);
        if (!sharedRangeFileInUse) {
            sharedRangeFile = file;
            sharedRangeEUID = euid;
            sharedRangeFileInUse = YES;
        }
        pthread_mutex_unlock(&sharedRangeLock);
    } 
    else {
        // open() or fdopen() failed
        if (PrintSharing) {
            _objc_inform("SHARING: bad or missing sharing file '%s': %s", 
                         filename, errno ? strerror(errno) : 
                         "potential security violation");
        }
    }    

    return file;
}


/**********************************************************************
* close_shared_range_file
* Close a file opened with open_shared_range_file.
* The file may actually be kept open and cached for a future 
* open_shared_range_file call. If so, clear_shared_range_file_cache() 
* can be used to really close the file.
**********************************************************************/
static void close_shared_range_file(FILE *file)
{
    // Flush any writes in case the file is kept open.
    fflush(file);

    pthread_mutex_lock(&sharedRangeLock);
    if (file == sharedRangeFile  &&  sharedRangeFileInUse) {
        // This file is the cached shared file. 
        // Leave the file open and cached, but no longer in use.
        sharedRangeFileInUse = NO;
    } else {
        // This is not the cached file.
        fclose(file);
    }
    pthread_mutex_unlock(&sharedRangeLock);
}


/**********************************************************************
* clear_shared_range_file_cache
* Really close any file left open by close_shared_range_file.
* This is called by map_images() after loading multiple images, each 
* of which may have used the shared range file.
**********************************************************************/
static void clear_shared_range_file_cache(void)
{
    pthread_mutex_lock(&sharedRangeLock);
    if (sharedRangeFile  &&  !sharedRangeFileInUse) {
        fclose(sharedRangeFile);
        sharedRangeFile = NULL;
        sharedRangeEUID = 0;
        sharedRangeFileInUse = 0;
    }
    pthread_mutex_unlock(&sharedRangeLock);
}


/**********************************************************************
* get_shared_range
* Try to find a shared range matching addresses [aligned_start..aligned_end). 
* If a range is found, it is mapped into this process and returned. 
* If no range is found, or the found range could not be mapped for 
*   some reason, the range {0, 0} is returned.
* aligned_start and aligned_end must be page-aligned.
**********************************************************************/
static vm_range_t get_shared_range(vm_address_t aligned_start, 
                                   vm_address_t aligned_end)
{
    struct remote_range_t remote;
    vm_range_t result;
    FILE *file;

    result.address = 0;
    result.size = 0;

    // Open shared range file, but don't create it
    file = open_shared_range_file(NO);
    if (!file) return result;

    // Search for the desired memory range
    while (1 == fread(&remote, sizeof(remote), 1, file)) {
        if (remote.pid != 0  &&  
            remote.range.address == aligned_start  &&  
            remote.range.size == aligned_end - aligned_start) 
        {
            // Found a match in the file - try to grab the memory
            mach_port_name_t remote_task;
            vm_prot_t cur_prot, max_prot;
            vm_address_t local_addr;
            kern_return_t kr;

            // Find the task offering the memory
            kr = task_for_pid(mach_task_self(), remote.pid, &remote_task);
            if (kr != KERN_SUCCESS) {
                // task is dead
                if (PrintSharing) {
                    _objc_inform("SHARING: no task for pid %d: %s", 
                                 remote.pid, mach_error_string(kr));
                }
                break;
            }

            // Map the memory into our process
            local_addr = 0;
            kr = vm_remap(mach_task_self(), &local_addr, remote.range.size,
                          0 /*alignment*/, 1 /*anywhere*/, 
                          remote_task, remote.range.address, 
                          1 /*copy*/, &cur_prot, &max_prot, VM_INHERIT_NONE);
            mach_port_deallocate(mach_task_self(), remote_task);

            if (kr != KERN_SUCCESS) {
                // couldn't map memory
                if (PrintSharing) {
                    _objc_inform("SHARING: vm_remap from pid %d failed: %s", 
                                 remote.pid, mach_error_string(kr));
                }
                break;
            }

            if (!(cur_prot & VM_PROT_READ)  ||  !(cur_prot & VM_PROT_WRITE)) {
                // Received memory is not mapped read/write - don't use it
                // fixme try to change permissions? check max_prot?
                if (PrintSharing) {
                    _objc_inform("SHARING: memory from pid %d not read/write", 
                                 remote.pid);
                }
                vm_deallocate(mach_task_self(), local_addr, remote.range.size);
                break;
            }

            // Success
            result.address = local_addr;
            result.size = remote.range.size;
        }
    }

    close_shared_range_file(file);
    return result;
}


/**********************************************************************
* offer_shared_range
* Offer memory range [aligned_start..aligned_end) in this process 
*  to other Objective-C-using processes.
* If some other entry in the shared range list matches this range, 
*   is is overwritten with this process's PID. (Thus any stale PIDs are 
*   replaced.)
* If the shared range file could not be updated for any reason, this 
*   function fails silently.
* aligned_start and aligned_end must be page-aligned.
**********************************************************************/
static void offer_shared_range(vm_address_t aligned_start, 
                               vm_address_t aligned_end)
{
    struct remote_range_t remote;
    struct remote_range_t local;
    BOOL found = NO;
    FILE *file;
    int err = 0;

    local.range.address = aligned_start;
    local.range.size = aligned_end - aligned_start;
    local.pid = getpid();

    // Open shared range file, creating if necessary
    file = open_shared_range_file(YES);
    if (!file) return;

    // Find an existing entry for this range, if any
    while (1 == fread(&remote, sizeof(remote), 1, file)) {
        if (remote.pid != 0  &&  
            remote.range.address == aligned_start  &&  
            remote.range.size == aligned_end - aligned_start) 
        {
            // Found a match - overwrite it
            err = fseek(file, -sizeof(remote), SEEK_CUR);
            found = YES;
            break;
        }
    }

    if (!found) {
        // No existing entry - write at the end of the file
        err = fseek(file, 0, SEEK_END);
    }

    if (err == 0) {
        fwrite(&local, sizeof(local), 1, file);
    }
    
    close_shared_range_file(file);
}


/**********************************************************************
* install_shared_range
* Install a shared range received from get_shared_range() into 
*   its final resting place. 
* If possible, the memory is copied using virtual memory magic rather 
*   than actual data writes. dst always gets updated values, even if 
*   virtual memory magic is not possible.
* The shared range is always deallocated. 
* src and dst must be page-aligned.
**********************************************************************/
static void install_shared_range(vm_range_t src, vm_address_t dst)
{
    kern_return_t kr;

    // Copy from src to dst
    kr = vm_copy(mach_task_self(), src.address, src.size, dst);
    if (kr != KERN_SUCCESS) {
        // VM copy failed. Use non-VM copy.
        if (PrintSharing) {
            _objc_inform("SHARING: vm_copy failed: %s", mach_error_string(kr));
        }
        memmove((void *)dst, (void *)src.address, src.size);
    }

    // Unmap the shared range at src
    vm_deallocate(mach_task_self(), src.address, src.size);
}
