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
 * objc-runtime.m
 * Copyright 1988-1996, NeXT Software, Inc.
 * Author:	s. naroff
 *
 **********************************************************************/

/***********************************************************************
 * Imports.
 **********************************************************************/

#if defined(WIN32)
#include <winnt-pdo.h>
#endif

#if defined(NeXT_PDO)
#import <pdo.h>		// for pdo_malloc and pdo_free defines
#elif defined(__MACH__)
#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <mach/vm_statistics.h>
#endif

#import <objc/objc-runtime.h>
#import <objc/hashtable2.h>
#import "maptable.h"
#import "objc-private.h"
#import <objc/Object.h>
#import <objc/Protocol.h>

#if !defined(WIN32)
#include <sys/time.h>
#include <sys/resource.h>
#endif

OBJC_EXPORT Class		_objc_getNonexistentClass	(void);

#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
OBJC_EXPORT void		(*load_class_callback)		(Class, Category);
OBJC_EXPORT unsigned int	_objc_goff_headerCount		(void);
OBJC_EXPORT header_info *	_objc_goff_headerVector		(void);
#endif 

OBJC_EXPORT Class		getOriginalClassForPosingClass	(Class);

#if defined(WIN32) || defined(__svr4__)
// Current Module Header
extern objcModHeader *		CMH;
#endif

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
	struct objc_category *			cat;
	long					version;
} _objc_unresolved_category;

typedef struct _PendingClass
{
	struct objc_class * *			ref;
	struct objc_class *			classToSetUp;
	const char *		nameof_superclass;
	int			version;
	struct _PendingClass *	next;
} PendingClass;

/***********************************************************************
 * Exports.
 **********************************************************************/

// Mask which specifies whether we are multi-threaded or not.
// A value of (-1) means single-threaded, 0 means multi-threaded. 
int		_objc_multithread_mask = (-1);

// Function to call when message sent to nil object.
void		(*_objc_msgNil)(id, SEL) = NULL;

// Function called after class has been fixed up (MACH only)
void		(*callbackFunction)(Class, const char *) = 0;

// Prototype for function passed to 
typedef void (*NilObjectMsgCallback) (id nilObject, SEL selector);

// Lock for class hashtable
OBJC_DECLARE_LOCK (classLock);

// Condition for logging load progress
int		rocketLaunchingDebug = -1;

/***********************************************************************
 * Function prototypes internal to this module.
 **********************************************************************/

static unsigned			classHash							(void * info, struct objc_class * data);
static int				classIsEqual						(void * info, struct objc_class * name, struct objc_class * cls);
static int				_objc_defaultClassHandler			(const char * clsName);
static void				_objcTweakMethodListPointerForClass	(struct objc_class * cls);
static void				__objc_add_category					(struct objc_category * category, int version);
static void				_objc_resolve_categories_for_class	(struct objc_class * cls);
static void				_objc_register_category				(struct objc_category *	cat, long version);
static void				_objc_add_categories_from_image		(header_info * hi);
#if defined(__MACH__)
static const header_info * _headerForClass					(struct objc_class * cls);
#endif
static void				checkForPendingClassReferences		(struct objc_class * cls);
static PendingClass *	newPending							(void);
static NXMapTable *		pendingClassRefsMapTable			(void);
static NXHashTable *	_objc_get_classes_from_image		(NXHashTable * clsHash, header_info * hi);
static void				_objc_fixup_string_objects_for_image(header_info * hi);
static void				_objc_map_class_refs_for_image		(header_info * hi);
static void				map_selrefs							(SEL * sels, unsigned int cnt);
static void				map_method_descs					(struct objc_method_description_list * methods);
static void				_objc_fixup_protocol_objects_for_image	(header_info * hi);
#if defined(__MACH__)
static void				_objc_bindModuleContainingCategory(Category cat);
static void				_objc_bindModuleContainingClass(struct objc_class * cls);
#endif
static const char *	libraryNameForMachHeader				(const headerType * themh);
static void				_objc_fixup_selector_refs			(const header_info * hi);
static void				_objc_call_loads_for_image			(header_info * header);
#if defined(__MACH__)
static void				_objc_map_image_callback			(headerType * mh, unsigned long vmaddr_slide);
static void				_objc_link_module_callback			(NSModule mod);
static void				_objc_unlink_module_callback		(NSModule mod);
#endif

#if defined(__MACH__)
extern int ptrace(int, int, int, int);
// ObjC is assigned the range 0xb000 - 0xbfff for first parameter
#else
#define ptrace(a, b, c, d) do {} while (0)
#endif

/***********************************************************************
 * Static data internal to this module.
 **********************************************************************/

// System vectors created at runtime by reading the `__OBJC' segments 
// that are a part of the application.
// We do not lock these variables, since they are only set during startup. 
static header_info *	header_vector = 0;
static unsigned int		header_count = 0;
static unsigned int		header_vector_size = 0;

// Hash table of classes
static NXHashTable *		class_hash = 0;
static NXHashTablePrototype	classHashPrototype = 
{
	(unsigned (*) (const void *, const void *))			classHash, 
	(int (*)(const void *, const void *, const void *))	classIsEqual, 
	NXNoEffectFree, 0
};

// Function pointer objc_getClass calls through when class is not found
static int			(*objc_classHandler) (const char *) = _objc_defaultClassHandler;

// Category and class registries
static NXMapTable *		category_hash = NULL;


static int						map_selectors_pended		= 0;

static NXMapTable *		pendingClassRefsMap = 0;

/***********************************************************************
 * objc_dump_class_hash.  Log names of all known classes.
 **********************************************************************/
void	objc_dump_class_hash	       (void)
{
	NXHashTable *	table;
	unsigned		count;
	struct objc_class *	*		data;
	NXHashState		state;
	
	table = class_hash;
	count = 0;
	state = NXInitHashState (table);
	while (NXNextHashState (table, &state, (void **) &data))
		printf ("class %d: %s\n", ++count, (*data)->name);
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
	return ((name->name[0] == cls->name[0]) &&
		(strcmp (name->name, cls->name) == 0));
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
	
	// Provide a generous initial capacity to cut down on rehashes
	// at launch time.  A smallish Foundation+AppKit program will have
	// about 520 classes.  Larger apps (like IB or WOB) have more like
	// 800 classes.  Some customers have massive quantities of classes.
	// Foundation-only programs aren't likely to notice the ~6K loss.
	class_hash = NXCreateHashTableFromZone (classHashPrototype,
						1024,
						nil,
						_objc_create_zone ());
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
	while (cnt < num && NXNextHashState(class_hash, &state, (void **)&class)) {
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
#if defined(NeXT_PDO)
	// Make sure a hash table exists
	if (!class_hash)
		_objc_init_class_hash ();
#endif

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
 * objc_getClass.  Return the id of the named class.  If the class does
 * not exist, call the objc_classHandler routine with the class name.
 * If the objc_classHandler returns a non-zero value, try once more to
 * find the class.  Default objc_classHandler always returns zero.
 * objc_setClassHandler is how someone can install a non-default routine.
 **********************************************************************/
id		objc_getClass	       (const char *	aClassName)
{ 
	struct objc_class	cls;
	id					ret;

	// Synchronize access to hash table
	OBJC_LOCK (&classLock);
	
	// Check the hash table
	cls.name = aClassName;
	ret = (id) NXHashGet (class_hash, &cls);
	OBJC_UNLOCK (&classLock);
	
	// If not found, go call objc_classHandler and try again
	if (!ret && (*objc_classHandler)(aClassName))
	{
		OBJC_LOCK (&classLock);
		ret = (id) NXHashGet (class_hash, &cls);
		OBJC_UNLOCK (&classLock);
	}

	return ret;
}

/***********************************************************************
 * objc_lookUpClass.  Return the id of the named class.
 *
 * Formerly objc_getClassWithoutWarning ()
 **********************************************************************/
id		objc_lookUpClass       (const char *	aClassName)
{ 
	struct objc_class	cls;
	id					ret;
	
	// Synchronize access to hash table
	OBJC_LOCK (&classLock);

	// Check the hash table
	cls.name = aClassName;
	ret = (id) NXHashGet (class_hash, &cls);
	
	// Desynchronize
	OBJC_UNLOCK (&classLock);
	return ret;
}

/***********************************************************************
 * objc_getMetaClass.  Return the id of the meta class the named class.
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
void		objc_addClass		(Class		cls) 
{
	// Synchronize access to hash table
	OBJC_LOCK (&classLock);
	
	// Make sure both the class and the metaclass have caches!
	// Clear all bits of the info fields except CLS_CLASS and CLS_META.
	// Normally these bits are already clear but if someone tries to cons
	// up their own class on the fly they might need to be cleared.
	if (((struct objc_class *)cls)->cache == NULL)
	{
		((struct objc_class *)cls)->cache = (Cache) &emptyCache;
		((struct objc_class *)cls)->info = CLS_CLASS;
	}
	
	if (((struct objc_class *)cls)->isa->cache == NULL)
	{
		((struct objc_class *)cls)->isa->cache = (Cache) &emptyCache;
		((struct objc_class *)cls)->isa->info = CLS_META;
	}
	
	// Add the class to the table
	(void) NXHashInsert (class_hash, cls);

	// Desynchronize
	OBJC_UNLOCK (&classLock);
}

/***********************************************************************
 * _objcTweakMethodListPointerForClass.
 **********************************************************************/
static void	_objcTweakMethodListPointerForClass     (struct objc_class *	cls)
{
	struct objc_method_list *	originalList;
	const int					initialEntries = 4;
	int							mallocSize;
	struct objc_method_list **	ptr;
	
	// Remember existing list
	originalList = (struct objc_method_list *) cls->methodLists;
	
	// Allocate and zero a method list array
	mallocSize   = sizeof(struct objc_method_list *) * initialEntries;
	ptr	     = (struct objc_method_list **) malloc_zone_calloc (_objc_create_zone (), 1, mallocSize);
	
	// Insert the existing list into the array
	ptr[initialEntries - 1] = END_OF_METHODS_LIST;
	ptr[0] = originalList;
	
	// Replace existing list with array
	((struct objc_class *)cls)->methodLists = ptr;
	((struct objc_class *)cls)->info |= CLS_METHOD_ARRAY;
	
	// Do the same thing to the meta-class
	if (((((struct objc_class *)cls)->info & CLS_CLASS) != 0) && cls->isa)
		_objcTweakMethodListPointerForClass (cls->isa);
}

/***********************************************************************
 * _objc_insertMethods.
 **********************************************************************/
void	_objc_insertMethods    (struct objc_method_list *	mlist,
								struct objc_method_list ***	list)
{
	struct objc_method_list **			ptr;
	volatile struct objc_method_list **	tempList;
	int									endIndex;
	int									oldSize;
	int									newSize;
	
	// Locate unused entry for insertion point
	ptr = *list;
	while ((*ptr != 0) && (*ptr != END_OF_METHODS_LIST))
		ptr += 1;
	
	// If array is full, double it
	if (*ptr == END_OF_METHODS_LIST)
	{
		// Calculate old and new dimensions
		endIndex = ptr - *list;
		oldSize  = (endIndex + 1) * sizeof(void *);
		newSize  = oldSize + sizeof(struct objc_method_list *); // only increase by 1
		
		// Replace existing array with copy twice its size
		tempList = (struct objc_method_list **) malloc_zone_realloc ((void *) _objc_create_zone (),
								      						   (void *) *list,
														       (size_t) newSize);
		*list = tempList;
		
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
 **********************************************************************/
void	_objc_removeMethods    (struct objc_method_list *	mlist,
								struct objc_method_list ***	list)
{
	struct objc_method_list **	ptr;
 
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
 * __objc_add_category.  Install the specified category's methods and
 * protocols into the class it augments.
 **********************************************************************/
static inline void	__objc_add_category    (struct objc_category *	category,
											int						version)
{
	struct objc_class *	cls;
	
	// Locate the class that the category will extend
	cls = (struct objc_class *) objc_getClass (category->class_name);
	if (!cls)
	{
		_objc_inform ("unable to add category %s...\n", category->category_name);
		_objc_inform ("class `%s' not linked into application\n", category->class_name);
		return;
	}

	// Augment instance methods
	if (category->instance_methods)
		_objc_insertMethods (category->instance_methods, &cls->methodLists);

	// Augment class methods
	if (category->class_methods)
		_objc_insertMethods (category->class_methods, &cls->isa->methodLists);

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
	
#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
	// Call back
	if (load_class_callback)
		(*load_class_callback) (cls, 0);
	
	// Call +finishLoading:: from the category's method list
	send_load_message_to_category (category, (void *) header_vector[0].mhdr);
#endif
}

/***********************************************************************
 * _objc_add_category.  Install the specified category's methods into
 * the class it augments, and flush the class' method cache.
 *
 * Private extern used by objc_loadModules ()
 **********************************************************************/
void	_objc_add_category     (struct objc_category *	category,
								int						version)
{
	// Install the category's methods into its intended class
	__objc_add_category (category, version);
	
	// Flush caches so category's methods can get called
	_objc_flush_caches (objc_lookUpClass (category->class_name));
}

/***********************************************************************
 * _objc_resolve_categories_for_class.  Install all categories intended
 * for the specified class, in reverse order from the order in which we
 * found the categories in the image.
 **********************************************************************/
static void	_objc_resolve_categories_for_class  (struct objc_class *	cls)
{
	_objc_unresolved_category *	cat;
	_objc_unresolved_category *	next;
	
	// Nothing to do if there are no categories at all
	if (!category_hash)
		return;
	
	// Locate and remove first element in category list
	// associated with this class
	cat = NXMapRemove (category_hash, cls->name);
	
	// Traverse the list of categories, if any, registered for this class
	while (cat)
	{
		// Install the category
		_objc_add_category (cat->cat, cat->version);
		
		// Delink and reclaim this registration
		next = cat->next;
		free (cat);
		cat = next;
	}
}

/***********************************************************************
 * _objc_register_category.  Add the specified category to the registry
 * of categories to be installed later (once we know for sure which
 * classes we have).  If there are multiple categories on a given class,
 * they will be processed in reverse order from the order in which they
 * were found in the image.
 **********************************************************************/
static void _objc_register_category    (struct objc_category *	cat,
										long					version)
{
	_objc_unresolved_category *	new_cat;
	_objc_unresolved_category *	old;
	
	
	// If the category's class exists, just add the category
	if (objc_lookUpClass (cat->class_name))
	{
		_objc_add_category (cat, version);
		return;
	}
	
	// Create category lookup table if needed
	if (!category_hash)
		category_hash = NXCreateMapTableFromZone (NXStrValueMapPrototype,
							  128,
							  _objc_create_zone ());
	
	// Locate an existing category, if any, for the class.  This is linked
	// after the new entry, so list is LIFO.
	old = NXMapGet (category_hash, cat->class_name);
	
	// Register the category to be fixed up later
	new_cat = malloc_zone_malloc (_objc_create_zone (),
				sizeof(_objc_unresolved_category));
	new_cat->next    = old;
	new_cat->cat     = cat;
	new_cat->version = version;
	(void) NXMapInsert (category_hash, cat->class_name , new_cat);
}

/***********************************************************************
 * _objc_add_categories_from_image.
 **********************************************************************/
static void _objc_add_categories_from_image (header_info *  hi)
{
	Module		mods;
	unsigned int	midx;
	
	// Major loop - process all modules in the header
	mods = (Module) ((unsigned long) hi->mod_ptr + hi->image_slide);

//	ptrace(0xb120, hi->mod_count, 0, 0);

	for (midx = 0; midx < hi->mod_count; midx += 1)
	{
		unsigned int	index; 
		unsigned int	total; 
		
		// Nothing to do for a module without a symbol table
		if (mods[midx].symtab == NULL)
			continue;
		
		// Total entries in symbol table (class entries followed
		// by category entries)
		total = mods[midx].symtab->cls_def_cnt +
			mods[midx].symtab->cat_def_cnt;
		
#if defined(__MACH__)
		if ((hi->mhdr->filetype == MH_DYLIB) ||
		    (hi->mhdr->filetype == MH_BUNDLE))
		{
			void **	defs;
			
			defs = mods[midx].symtab->defs;

//			ptrace(0xb121, midx, mods[midx].symtab->cls_def_cnt, mods[midx].symtab->cat_def_cnt);

			for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
				_objc_bindModuleContainingClass (defs[index]);
			
			for (index = mods[midx].symtab->cls_def_cnt; index < total; index += 1)
				_objc_bindModuleContainingCategory (defs[index]);

//			ptrace(0xb122, midx, 0, 0);
		}
#endif 
		
//		ptrace(0xb123, midx, mods[midx].symtab->cat_def_cnt, 0);

		// Minor loop - register all categories from given module
		for (index = mods[midx].symtab->cls_def_cnt; index < total; index += 1)
		{
			_objc_register_category	(mods[midx].symtab->defs[index],
						 mods[midx].version);
		}

//		ptrace(0xb124, midx, 0, 0);
	}

//	ptrace(0xb12f, 0, 0, 0);
}

#if defined(__MACH__)
/***********************************************************************
 * _headerForClass.
 **********************************************************************/
static const header_info *  _headerForClass     (struct objc_class *	cls)
{
	const struct segment_command *	objcSeg;
	unsigned int					hidx;
	unsigned int					size;
	unsigned long					vmaddrPlus;
	
	// Check all headers in the vector
	for (hidx = 0; hidx < header_count; hidx += 1)
	{
		// Locate header data, if any
		objcSeg = _getObjcHeaderData ((headerType *) header_vector[hidx].mhdr, &size);
		if (!objcSeg)
			continue;

		// Is the class in this header?
		vmaddrPlus = (unsigned long) objcSeg->vmaddr + header_vector[hidx].image_slide;
		if ((vmaddrPlus <= (unsigned long) cls) &&
		    ((unsigned long) cls < (vmaddrPlus + size)))
			return &(header_vector[hidx]);
	}
	
	// Not found
	return 0;
}
#endif // __MACH__

/***********************************************************************
 * _nameForHeader.
 **********************************************************************/
const char *	_nameForHeader	       (const headerType *	header)
{
	return _getObjcHeaderName ((headerType *) header);
}

/***********************************************************************
 * checkForPendingClassReferences.  Complete any fixups registered for
 * this class.
 **********************************************************************/
static void	checkForPendingClassReferences	       (struct objc_class *	cls)
{
	PendingClass *	pending;

	// Nothing to do if there are no pending classes
	if (!pendingClassRefsMap)
		return;
	
	// Get pending list for this class
	pending = NXMapGet (pendingClassRefsMap, cls->name);
	if (!pending)
		return;
	
	// Remove the list from the table
	(void) NXMapRemove (pendingClassRefsMap, cls->name);
	
	// Process all elements in the list
	while (pending)
	{
		PendingClass *	next;
		
		// Remember follower for loop
		next = pending->next;
		
		// Fill in a pointer to Class 
		// (satisfies caller of objc_pendClassReference)
		if (pending->ref)
			*pending->ref = objc_getClass (cls->name);

		// Fill in super, isa, cache, and version for the class
		// and its meta-class
		// (satisfies caller of objc_pendClassInstallation)
		// NOTE: There must be no more than one of these for
		// any given classToSetUp
		if (pending->classToSetUp)
		{
			struct objc_class *	fixCls;
		
			// Locate the Class to be fixed up
			fixCls = pending->classToSetUp;
			
			// Set up super class fields with names to be replaced by pointers
			fixCls->super_class      = (struct objc_class *) pending->nameof_superclass;
			fixCls->isa->super_class = (struct objc_class *) pending->nameof_superclass;
			
			// Fix up class pointers, version, and cache pointers
			_class_install_relationships (fixCls, pending->version);
		}
		
		// Reclaim the element
		free (pending);
		
		// Move on
		pending = next;
	}
}

/***********************************************************************
 * newPending.  Allocate and zero a PendingClass structure.
 **********************************************************************/
static inline PendingClass *	newPending	       (void)
{
	PendingClass *	pending;
	
	pending = (PendingClass *) malloc_zone_calloc (_objc_create_zone (), 1, sizeof(PendingClass));
	
	return pending;
}

/***********************************************************************
 * pendingClassRefsMapTable.  Return a pointer to the lookup table for
 * pending classes.
 **********************************************************************/
static inline NXMapTable *	pendingClassRefsMapTable    (void)
{
	// Allocate table if needed
	if (!pendingClassRefsMap)
		pendingClassRefsMap = NXCreateMapTableFromZone (NXStrValueMapPrototype, 10, _objc_create_zone ());
	
	// Return table pointer
	return pendingClassRefsMap;
}

/***********************************************************************
 * objc_pendClassReference.  Register the specified class pointer (ref)
 * to be filled in later with a pointer to the class having the specified
 * name.
 **********************************************************************/
void	objc_pendClassReference	       (const char *	className,
										struct objc_class * *		ref)
{
	NXMapTable *		table;
	PendingClass *		pending;
	
	// Create and/or locate pending class lookup table
	table = pendingClassRefsMapTable ();

	// Create entry containing the class reference
	pending = newPending ();
	pending->ref = ref;
	
	// Link new entry into head of list of entries for this class
	pending->next = NXMapGet (pendingClassRefsMap, className);
	
	// (Re)place entry list in the table
	(void) NXMapInsert (table, className, pending);
}

/***********************************************************************
 * objc_pendClassInstallation.  Register the specified class to have its
 * super class pointers filled in later because the superclass is not
 * yet found.
 **********************************************************************/
void	objc_pendClassInstallation     (struct objc_class *	cls,
										int		version)
{
	NXMapTable *		table;
	PendingClass *		pending;
	
	// Create and/or locate pending class lookup table
	table = pendingClassRefsMapTable ();

	// Create entry referring to this class
	pending = newPending ();
	pending->classToSetUp	   = cls;
	pending->nameof_superclass = (const char *) cls->super_class;
	pending->version	   = version;
	
	// Link new entry into head of list of entries for this class
	pending->next		   = NXMapGet (pendingClassRefsMap, cls->super_class);
	
	// (Re)place entry list in the table
	(void) NXMapInsert (table, cls->super_class, pending);
}

/***********************************************************************
 * _objc_get_classes_from_image.  Install all classes contained in the
 * specified image.
 **********************************************************************/
static NXHashTable *	_objc_get_classes_from_image   (NXHashTable *	clsHash,
														header_info *	hi)
{
	unsigned int	index;
	unsigned int	midx;
	Module			mods;
	
	// Major loop - process all modules in the image
	mods = (Module) ((unsigned long) hi->mod_ptr + hi->image_slide);
	for (midx = 0; midx < hi->mod_count; midx += 1)
	{
		// Skip module containing no classes
		if (mods[midx].symtab == NULL)
			continue;
		
		// Minor loop - process all the classes in given module
		for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
		{
		struct objc_class *	oldCls;
		struct objc_class *	newCls;
			
			// Locate the class description pointer
			newCls = mods[midx].symtab->defs[index];
			
			// Convert old style method list to the new style
			_objcTweakMethodListPointerForClass (newCls);

			oldCls = NXHashInsert (clsHash, newCls);

			// Non-Nil oldCls is a class that NXHashInsert just
			// bumped from table because it has the same name
			// as newCls
			if (oldCls)
			{
#if defined(__MACH__)
				const header_info *	oldHeader;
				const header_info *	newHeader;
				const char *		oldName;
				const char *		newName;

				// Log the duplication
				oldHeader = _headerForClass (oldCls);
				newHeader = _headerForClass (newCls);
				oldName   = _nameForHeader  (oldHeader->mhdr);
				newName   = _nameForHeader  (newHeader->mhdr);
				_objc_inform ("Both %s and %s have implementations of class %s.",
								oldName, newName, oldCls->name);				   
				_objc_inform ("Using implementation from %s.", newName);
#endif

				// Use the chosen class
				// NOTE: Isn't this a NOP?
				newCls = objc_lookUpClass (oldCls->name);
			}
			
			// Unless newCls was a duplicate, and we chose the
			// existing one instead, set the version in the meta-class
			if (newCls != oldCls)
				newCls->isa->version = mods[midx].version;

			// Install new categories intended for this class
			// NOTE: But, if we displaced an existing "isEqual"
			// class, the categories have already been installed
			// on an old class and are gone from the registry!!
			_objc_resolve_categories_for_class (newCls);
			
			// Resolve (a) pointers to the named class, and/or
			// (b) the super_class, cache, and version
			// fields of newCls and its meta-class
			// NOTE: But, if we displaced an existing "isEqual"
			// class, this has already been done... with an
			// old-now-"unused" class!!
			checkForPendingClassReferences (newCls);
			
#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
			// Invoke registered callback
			if (load_class_callback)
				(*load_class_callback) (newCls, 0);
			
			// Call +finishLoading:: from the class' method list
			send_load_message_to_class (newCls, (headerType *) hi->mhdr);
#endif
		}
	}
	
	// Return the table the caller passed
	return clsHash;
}

/***********************************************************************
 * _objc_fixup_string_objects_for_image.  Initialize the isa pointers
 * of all NSConstantString objects.
 **********************************************************************/
static void	_objc_fixup_string_objects_for_image   (header_info *	hi)
{
	unsigned int				size;
	OBJC_CONSTANT_STRING_PTR	section;
	struct objc_class *						constantStringClass;
	unsigned int				index;
	
	// Locate section holding string objects
	section = _getObjcStringObjects ((headerType *) hi->mhdr, &size);
	if (!section || !size)
		return;
	section = (OBJC_CONSTANT_STRING_PTR) ((unsigned long) section + hi->image_slide);
#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
	if (!(*section))
		return;
#endif

	// Luckily NXConstantString is the same size as NSConstantString
	constantStringClass = objc_getClass ("NSConstantString");
	
	// Process each string object in the section
	for (index = 0; index < size; index += 1)
	{
		struct objc_class * *		isaptr;
		
		isaptr = (struct objc_class * *) OBJC_CONSTANT_STRING_DEREF section[index];
		if (*isaptr == 0)
			*isaptr = constantStringClass;
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
		cls = (struct objc_class *)objc_lookUpClass (ref);
		
		// If class isn't there yet, use pending mechanism
		if (!cls)
		{
			// Register this ref to be set later
			objc_pendClassReference (ref, &cls_refs[index]);
			
			// Use place-holder class
			cls_refs[index] = _objc_getNonexistentClass ();
		}
		
		// Replace name string pointer with class pointer
		else
			cls_refs[index] = cls;
	}
}

/***********************************************************************
 * map_selrefs.  Register each selector in the specified array.  If a
 * given selector is already registered, update this array to point to
 * the registered selector string.
 **********************************************************************/
static inline void	map_selrefs    (SEL *			sels,
									unsigned int	cnt)
{ 
	unsigned int	index;
	
	// Process each selector
	for (index = 0; index < cnt; index += 1)
	{
		SEL	sel;
		
		// Lookup pointer to uniqued string
		sel = sel_registerNameNoCopy ((const char *) sels[index]);

		// Replace this selector with uniqued one (avoid
		// modifying the VM page if this would be a NOP)
		if (sels[index] != sel)
			sels[index] = sel;
	}
}


/***********************************************************************
 * map_method_descs.  For each method in the specified method list,
 * replace the name pointer with a uniqued selector.
 **********************************************************************/
static void  map_method_descs (struct objc_method_description_list * methods)
{
	unsigned int	index;
	
	// Process each method
	for (index = 0; index < methods->count; index += 1)
	{
		struct objc_method_description *	method;
		SEL					sel;
		
		// Get method entry to fix up
		method = &methods->list[index];

		// Lookup pointer to uniqued string
		sel = sel_registerNameNoCopy ((const char *) method->name);

		// Replace this selector with uniqued one (avoid
		// modifying the VM page if this would be a NOP)
		if (method->name != sel)
			method->name = sel;
	}		  
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
	unsigned int		size;
	OBJC_PROTOCOL_PTR	protos;
	unsigned int		index;
	
	// Locate protocals in the image
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
			map_method_descs (protos[index] OBJC_PROTOCOL_DEREF instance_methods);
		
		// Selectorize the class methods
		if (protos[index] OBJC_PROTOCOL_DEREF class_methods)
			map_method_descs (protos[index] OBJC_PROTOCOL_DEREF class_methods);
	}
	
	// Invoke Protocol class method to fix up the protocol
	[Protocol _fixup:(OBJC_PROTOCOL_PTR)protos numElements:size];
}

/***********************************************************************
 * _objc_headerVector.  Build the header vector, sorting it as
 * _objc_map_selectors () expects.
 **********************************************************************/
header_info *	_objc_headerVector (const headerType * const *	machhdrs)
{
	unsigned int	hidx;
	header_info *	hdrVec;
	
#if defined(__MACH__) // not GENERIC_OBJ_FILE
	// Take advatage of our previous work
	if (header_vector)
		return header_vector;
#else // GENERIC_OBJ_FILE
	// If no headers specified, vectorize generically
	if (!machhdrs)
		return _objc_goff_headerVector ();
	
	// Start from scratch
	header_count = 0;
#endif
	
	// Count headers
	for (hidx = 0; machhdrs[hidx]; hidx += 1)
		header_count += 1;

	header_vector_size = header_count * 3; // very big

	// Allocate vector large enough to have entries for all of them
	hdrVec = malloc_zone_malloc  (_objc_create_zone (),
				header_vector_size * sizeof(header_info));
	if (!hdrVec)
		_objc_fatal ("unable to allocate module vector");
	
	// Fill vector entry for each header
	for (hidx = 0; hidx < header_count; hidx += 1)
	{
		int	size;
#if defined(__MACH__)
		const struct segment_command *	objcSeg = NULL;
#endif
	
		hdrVec[hidx].mhdr	 = machhdrs[hidx];
		hdrVec[hidx].image_slide = 0;
		hdrVec[hidx].mod_ptr	 = _getObjcModules ((headerType *) machhdrs[hidx], &size);
		hdrVec[hidx].mod_count	 = size;
		hdrVec[hidx].objcSize    = 0;
	
#if defined(__MACH__) // not GENERIC_OBJ_FILE
		objcSeg = (struct segment_command *) _getObjcHeaderData ((headerType *) machhdrs[hidx], &size);
		if (objcSeg)
			hdrVec[hidx].objcSize = ((struct segment_command *) objcSeg)->filesize;
#endif
	}
	
	return hdrVec;
}

#if defined(__MACH__)
void _objc_bindModuleContainingList() {
/* We define this for backwards binary compat with things which should not
 * have been using it (cough OmniWeb), but now it does nothing for them.
 */
}

/***********************************************************************
 * _objc_bindModuleContainingCategory.  Bind the module containing the
 * category.
 **********************************************************************/
static void  _objc_bindModuleContainingCategory   (Category	cat)
{
	char *			class_name;
	char *			category_name;
	char *			name;
        char                    tmp_buf[128];
        unsigned int            name_len;

	// Bind ".objc_category_name_<classname>_<categoryname>",
	// where <classname> is the class name with the leading
	// '%'s stripped.
	class_name    = cat->class_name;
	category_name = cat->category_name;
        name_len      = strlen(class_name) + strlen(category_name) + 30;
        if ( name_len > 128 )
	    name = malloc(name_len);
        else
            name = tmp_buf;
	while (*class_name == '%')
		class_name += 1;
	strcpy (name, ".objc_category_name_");
	strcat (name, class_name);
	strcat (name, "_");
	strcat (name, category_name);
	if (NSIsSymbolNameDefined(name)) _dyld_lookup_and_bind_objc(name, 0, 0);
        if ( name != tmp_buf )
            free(name);
}

/***********************************************************************
 * _objc_bindModuleContainingClass.  Bind the module containing the
 * class.
 **********************************************************************/
static void _objc_bindModuleContainingClass (struct objc_class * cls)
{
	struct objc_method_list *	mList;
	const char *	class_name;
	char *			name;
        char                    tmp_buf[128];
        unsigned int            name_len;
	
	// Use the real class behind the poser
	if (CLS_GETINFO (cls, CLS_POSING))
		cls = getOriginalClassForPosingClass (cls);

	// Bind ".objc_class_name_<classname>", where <classname>
	// is the class name with the leading '%'s stripped.
	class_name = cls->name;
        name_len   = strlen(class_name) + 20;
        if ( name_len > 128 )
	    name = malloc(name_len);
        else
            name = tmp_buf;
	while (*class_name == '%')
		class_name += 1;
	strcpy (name, ".objc_class_name_");
	strcat (name, class_name);
	if (NSIsSymbolNameDefined(name)) _dyld_lookup_and_bind_objc(name, 0, 0);
        if ( name != tmp_buf )
            free(name);
}
#endif // __MACH__
	
/***********************************************************************
 * _objc_headerCount.  Return the currently known number of `__OBJC'
 * segments that are a part of the application
 **********************************************************************/
unsigned int	_objc_headerCount	       (void)
{
#if defined(__MACH__) // not GENERIC_OBJ_FILE
	return header_count;
#else
	return _objc_goff_headerCount ();
#endif
}

/***********************************************************************
 * _objc_addHeader.
 *
 * NOTE: Yet another wildly inefficient routine.
 **********************************************************************/
void	_objc_addHeader	       (const headerType *	header,
								unsigned long		vmaddr_slide)
{
	// Account for addition
	header_count += 1;
	
	// Create vector table if needed
	if (header_vector == 0)
	{
		header_vector_size = 100;
		header_vector = malloc_zone_malloc (_objc_create_zone (), 
					      header_vector_size * sizeof(header_info));
#if defined(WIN32) || defined(__svr4__)
		bzero (header_vector, (header_vector_size * sizeof(header_info)));
#endif
	}
	
	
	// Malloc a new vector table one bigger than before
	else if (header_count > header_vector_size)
	{
		void *	old;
	
		header_vector_size *= 2;	
		old = (void *) header_vector;
		header_vector = malloc_zone_malloc (_objc_create_zone (),
					      header_vector_size * sizeof(header_info));
	
#if defined(WIN32) || defined(__svr4__)
		bzero (header_vector, (header_vector_size * sizeof(header_info)));
#endif
		memcpy ((void *) header_vector, old, (header_count - 1) * sizeof(header_info));
		malloc_zone_free (_objc_create_zone (), old);
	}
	
	// Set up the new vector entry
	header_vector[header_count - 1].mhdr		= header;
	header_vector[header_count - 1].mod_ptr		= NULL;
	header_vector[header_count - 1].mod_count	= 0;
	header_vector[header_count - 1].image_slide	= vmaddr_slide;
	header_vector[header_count - 1].objcSize	= 0;
}

/***********************************************************************
 * libraryNameForMachHeader.
**********************************************************************/
static const char *	libraryNameForMachHeader  (const headerType * themh)
{
#if defined(NeXT_PDO)
	return "";
#else
	unsigned long	index;
	unsigned long	imageCount;
	headerType *	mh;
	
	// Search images for matching type
	imageCount = _dyld_image_count ();
	for (index = 0; index < imageCount ; index += 1)
	{
		// Return name of image with matching type
		mh = _dyld_get_image_header (index);
		if (mh == themh)
			return _dyld_get_image_name (index);
	}
	
	// Not found
	return 0;
#endif
}

/***********************************************************************
 * _objc_fixup_selector_refs.  Register all of the selectors in each
 * image, and fix them all up.
 *
 **********************************************************************/
static void _objc_fixup_selector_refs   (const header_info *	hi)
{
	unsigned int		midx;
	unsigned int		size;
	OBJC_PROTOCOL_PTR	protos;
	Module			mods;
	unsigned int		index;
#if defined(__MACH__)
	SEL *			messages_refs;
#endif // __MACH__
	
	mods = (Module) ((unsigned long) hi->mod_ptr + hi->image_slide);

	if ( rocketLaunchingDebug )
	{
		printf ("uniquing selectors for %s\n", libraryNameForMachHeader(hi->mhdr));
		printf ("   uniquing message_refs\n");
	}
	
#if defined(__MACH__)
	// Fix up message refs
	messages_refs = (SEL *) _getObjcMessageRefs ((headerType *) hi->mhdr, &size);
	if (messages_refs)
	{
		messages_refs = (SEL *) ((unsigned long) messages_refs + hi->image_slide);
		map_selrefs (messages_refs, size);
	}
#endif // __MACH__

        
#if !defined(__MACH__)
	// This is redundant with the fixup done in _objc_fixup_protocol_objects_for_image()
	// in a little while, at least on MACH.

	// Fix up protocols
	protos = (OBJC_PROTOCOL_PTR) _getObjcProtocols ((headerType *) hi->mhdr, &size);
	if (protos)
	{
		protos = (OBJC_PROTOCOL_PTR)((unsigned long)protos + hi->image_slide);
		
		for (index = 0; index < size; index += 1)
		{
			// Fix up instance method names
			if (protos[index] OBJC_PROTOCOL_DEREF instance_methods)
				map_method_descs (protos[index] OBJC_PROTOCOL_DEREF instance_methods);
			
			// Fix up class method names
			if (protos[index] OBJC_PROTOCOL_DEREF class_methods)
				map_method_descs (protos[index] OBJC_PROTOCOL_DEREF class_methods);
		}
	}
#endif
}


/***********************************************************************
 * _objc_call_loads_for_image.
 **********************************************************************/
static void _objc_call_loads_for_image (header_info * header)
{
	struct objc_class *			cls;
	struct objc_class * *		pClass;
	Category *			pCategory;
	IMP							load_method;
	unsigned int				nModules;
	unsigned int				nClasses;
	unsigned int				nCategories;
	struct objc_symtab *		symtab;
	struct objc_module *		module;
	
	// Major loop - process all modules named in header
	module = (struct objc_module *) ((unsigned long) header->mod_ptr + header->image_slide);
	for (nModules = header->mod_count; nModules; nModules -= 1, module += 1)
	{
		symtab = module->symtab;
		if (symtab == NULL)
			continue;
		
		// Minor loop - call the +load from each class in the given module
		for (nClasses = symtab->cls_def_cnt, pClass = (Class *) symtab->defs;
		     nClasses;
		     nClasses -= 1, pClass += 1)
		{
			struct objc_method_list **mlistp;
			cls = (struct objc_class *)*pClass;
			mlistp = get_base_method_list(cls->isa);
			if (cls->isa->methodLists && mlistp)
			{
				// Look up the method manually (vs messaging the class) to bypass
				// +initialize and cache fill on class that is not even loaded yet
				load_method = class_lookupNamedMethodInMethodList (*mlistp, "load");
				if (load_method)
					(*load_method) ((id) cls, @selector(load));
			}
		}
		
		// Minor loop - call the +load from augmented class of
		// each category in the given module
		for (nCategories = symtab->cat_def_cnt,
			pCategory = (Category *) &symtab->defs[symtab->cls_def_cnt];
		     nCategories;
		     nCategories -= 1, pCategory += 1)
		{
			struct objc_method_list *	methods;
			
			cls = objc_getClass ((*pCategory)->class_name);
			methods = (*pCategory)->class_methods;
			if (methods)
			{
				load_method = class_lookupNamedMethodInMethodList (methods, "load");
				if (load_method)
					(*load_method) ((id) cls, @selector(load));
			}
		}
	}
}

/***********************************************************************
 * objc_setMultithreaded.
 **********************************************************************/
void objc_setMultithreaded (BOOL flag)
{
	if (flag == YES)
		_objc_multithread_mask = 0;
	else
		_objc_multithread_mask = (-1);
}

/* Library initializer called by dyld. */
void __initialize_objc(void) {
	int hidx;

#if defined(NeXT_PDO)
	const headerType * const *	headers;

        if ( rocketLaunchingDebug == -1 ) {
	    if ( getenv("OBJC_UNIQUE_DEBUG") ) rocketLaunchingDebug = 1;
            else rocketLaunchingDebug = 0;
        }

	// Get architecture dependent module headers
	headers = (const headerType * const *) _getObjcHeaders ();
	if (headers)
	{
		// Create vector from these headers
		header_vector = _objc_headerVector (headers);
		if (header_vector) 
		{
			// Load classes from all images in the vector
			for (hidx = 0; hidx < header_count; hidx += 1)
				(void) _objc_get_classes_from_image (class_hash, &header_vector[hidx]);
		}
	}
#endif
#if defined(__MACH__)
	static int _done = 0;
	extern void __CFInitialize(void);

	/* Protect against multiple invocations, as all library
	 * initializers should. */
	if (0 != _done) return;
	_done = 1;

	ptrace(0xb000, 0, 0, 0);

	// make sure CF is initialized before we go further;
	// someday this can be removed, as it'll probably be automatic
	__CFInitialize();

	// Create the class lookup table
	_objc_init_class_hash ();
	
//	ptrace(0xb001, 0, 0, 0);

	// Get our configuration
        if ( rocketLaunchingDebug == -1 ) {
            if ( getenv("OBJC_UNIQUE_DEBUG") ) rocketLaunchingDebug = 1;
            else rocketLaunchingDebug = 0;
        }

//	ptrace(0xb003, 0, 0, 0);

	map_selectors_pended = 1;

// XXXXX BEFORE HERE *NO* PAGES ARE STOMPED ON

	// Register our image mapping routine with dyld so it
	// gets invoked when an image is added.  This also invokes
	// the callback right now on any images already present.
	_dyld_register_func_for_add_image (&_objc_map_image_callback);
	
// XXXXX BEFORE HERE *ALL* PAGES ARE STOMPED ON

	map_selectors_pended  = 0;
	
//	ptrace(0xb005, 0, 0, 0);
		
	// Register module link callback with dyld
	_dyld_register_func_for_link_module (&_objc_link_module_callback);

	// Register callback with dyld
	_dyld_register_func_for_unlink_module (&_objc_unlink_module_callback);
#endif // MACH

//	ptrace(0xb006, header_count, 0, 0);

	// Install relations on classes that were found
	for (hidx = 0; hidx < header_count; hidx += 1)
	{
		int			nModules;
		int			index;
		struct objc_module *	module;
		struct objc_class *	cls;
		
		module = (struct objc_module *) ((unsigned long) header_vector[hidx].mod_ptr + header_vector[hidx].image_slide);
		for (nModules = header_vector[hidx].mod_count; nModules; nModules -= 1)
		{
			for (index = 0; index < module->symtab->cls_def_cnt; index += 1)
			{
				cls = (struct objc_class *) module->symtab->defs[index];
				_class_install_relationships (cls, module->version);
			}

			module += 1;
		}

//		ptrace(0xb007, hidx, header_vector[hidx].mod_count, 0);
		
	}
	
//	ptrace(0xb008, header_count, 0, 0);
		
	for (hidx = 0; hidx < header_count; hidx += 1)
	{
#if !defined(__MACH__)
		(void)_objc_add_categories_from_image (&header_vector[hidx]);
		(void) _objc_fixup_selector_refs (&header_vector[hidx]);
#endif
		// Initialize the isa pointers of all NXConstantString objects
		(void)_objc_fixup_string_objects_for_image (&header_vector[hidx]);

		// Convert class refs from name pointers to ids
		(void)_objc_map_class_refs_for_image (&header_vector[hidx]);
	}

//	ptrace(0xb00a, 0, 0, 0);
		
	// For each image selectorize the method names and +_fixup each of
	// protocols in the image
	for (hidx = 0; hidx < header_count; hidx += 1)
		_objc_fixup_protocol_objects_for_image (&header_vector[hidx]);
	
#if defined(WIN32) || defined(__svr4__)
	CMH = (objcModHeader *) 0;
#endif

	ptrace(0xb00f, 0, 0, 0);	// end of ObjC init
}

void _objcInit(void) {
	static int _done = 0;
	int hidx;
        /* Protect against multiple invocations, as all library
         * initializers should. */
        if (0 != _done) return;
        _done = 1;
	ptrace(0xb010, 0, 0, 0);	// marks call to _objcInit
	__initialize_objc();
	/* We delay this until here, because dyld cannot detect and
	 * properly order calls to ObjC initializers amongst the
	 * calls to module and library initializers. */
	for (hidx = 0; hidx < header_count; hidx += 1)
		_objc_call_loads_for_image (&header_vector[hidx]);
	ptrace(0xb01f, 0, 0, 0);	// marks call to _objcInit
}

#if defined(__MACH__)
/***********************************************************************
 * _objc_map_image.
 **********************************************************************/
static void	_objc_map_image(headerType *	mh,
						unsigned long	vmaddr_slide)
{
        static int dumpClasses = -1;
	header_info *					hInfo;
	const struct segment_command *	objcSeg;
	unsigned int					size;
	
        if ( dumpClasses == -1 ) {
            if ( getenv("OBJC_DUMP_CLASSES") ) dumpClasses = 1;
            else dumpClasses = 0;
        }

	ptrace(0xb100, 0, 0, 0);

	// Add this header to the header_vector
	_objc_addHeader (mh, vmaddr_slide);
	
//	ptrace(0xb101, 0, 0, 0);

	// Touch up the vector entry we just added (yuck)
	hInfo = &(header_vector[header_count-1]);
	hInfo->mod_ptr	   = (Module) _getObjcModules ((headerType *) hInfo->mhdr, &size);
	hInfo->mod_count   = size;
	objcSeg = (struct segment_command *) _getObjcHeaderData ((headerType *) mh, &size);
	if (objcSeg)
		hInfo->objcSize = objcSeg->filesize;
	else
		hInfo->objcSize = 0;
	
//	ptrace(0xb102, 0, 0, 0);

	// Register any categories and/or classes and/or selectors this image contains
	_objc_add_categories_from_image (hInfo);

//	ptrace(0xb103, 0, 0, 0);

	class_hash = _objc_get_classes_from_image (class_hash, hInfo);

//	ptrace(0xb104, 0, 0, 0);

	_objc_fixup_selector_refs (hInfo);
	
//	ptrace(0xb105, 0, 0, 0);

	// Log all known class names, if asked
	if ( dumpClasses )
	{
		printf ("classes...\n");
		objc_dump_class_hash ();
	}
	
	if (!map_selectors_pended)
	{
		int			nModules;
		int			index;
		struct objc_module *	module;
		
		// Major loop - process each module
		module = (struct objc_module *) ((unsigned long) hInfo->mod_ptr + hInfo->image_slide);

//		ptrace(0xb106, hInfo->mod_count, 0, 0);

		for (nModules = hInfo->mod_count; nModules; nModules -= 1)
		{
			// Minor loop - process each class in a given module
			for (index = 0; index < module->symtab->cls_def_cnt; index += 1)
			{
				struct objc_class * cls;
				
				// Locate the class description
				cls = (struct objc_class *) module->symtab->defs[index];
				
				// If there is no superclass or the superclass can be found,
				// install this class, and invoke the expected callback
				if (!((struct objc_class *)cls)->super_class || objc_lookUpClass ((char *) ((struct objc_class *)cls)->super_class))
				{
					_class_install_relationships (cls, module->version);
					if (callbackFunction)
						(*callbackFunction) (cls, 0);
				}
				
				// Super class can not be found yet, arrange for this class to
				// be filled in later
				else
				{
					objc_pendClassInstallation (cls, module->version);
					((struct objc_class *)cls)->super_class      = _objc_getNonexistentClass ();
					((struct objc_class *)cls)->isa->super_class = _objc_getNonexistentClass ();
				}
			}

			// Move on
			module += 1;
		}
		
//		ptrace(0xb108, 0, 0, 0);

		// Initialize the isa pointers of all NXConstantString objects
		_objc_fixup_string_objects_for_image (hInfo);

//		ptrace(0xb109, 0, 0, 0);

		// Convert class refs from name pointers to ids
		_objc_map_class_refs_for_image (hInfo);

//		ptrace(0xb10a, 0, 0, 0);

		// Selectorize the method names and +_fixup each of
		// protocols in the image
		_objc_fixup_protocol_objects_for_image (hInfo);

//		ptrace(0xb10b, 0, 0, 0);

		// Call +load on all classes and categorized classes
		_objc_call_loads_for_image (hInfo);

//		ptrace(0xb10c, 0, 0, 0);
	}
	
	ptrace(0xb10f, 0, 0, 0);
}

static volatile int handling_in_progress = 0;
static volatile int pended_callbacks_count = 0;
static volatile struct {
	headerType *    mh;
	unsigned long   vmaddr_slide;
} pended_callbacks[250] = {{0, 0}};

static void	_objc_map_image_callback       (headerType *	mh,
						unsigned long	vmaddr_slide)
{
	pended_callbacks[pended_callbacks_count].mh = mh;
	pended_callbacks[pended_callbacks_count].vmaddr_slide = vmaddr_slide;
	pended_callbacks_count++;
	if (0 != handling_in_progress) return;
	handling_in_progress = 1;
	while (0 < pended_callbacks_count) {
		pended_callbacks_count--;
		_objc_map_image(pended_callbacks[pended_callbacks_count].mh, pended_callbacks[pended_callbacks_count].vmaddr_slide);
	}
	handling_in_progress = 0;
}

#endif // __MACH__

#if defined(__MACH__)
/***********************************************************************
 * _objc_link_module_callback.  Callback installed with
 * _dyld_register_func_for_link_module.
 *
 * NOTE: Why does this exist?  The old comment said "This will install
 * class relations for the executable and dylibs."  Hmm.
 **********************************************************************/
static void	_objc_link_module_callback     (NSModule	mod)
{
}

/***********************************************************************
 * _objc_unlink_module_callback.  Callback installed with
 * _dyld_register_func_for_unlink_module.
 **********************************************************************/
static void	_objc_unlink_module_callback   (NSModule	mod)
{
	_objc_fatal ("unlinking is not supported in this version of Objective C\n");
}
#endif // __MACH__

#if defined(WIN32)
#import <stdlib.h>
/***********************************************************************
 * NSRootDirectory.  Returns the value of the root directory that the
 * product was installed to.
 **********************************************************************/
const char *	NSRootDirectory	       (void)
{
	static char *root = (char *)0;

        if ( ! root ) {
            char *p = getenv("NEXT_ROOT");
            if ( p ) {
                root = malloc_zone_malloc(malloc_default_zone(), strlen(p)+1);
                (void)strcpy(root, p);
            }
            else root = "";
        }
	return (const char *)root;
}
#endif 

/***********************************************************************
 * objc_setNilObjectMsgHandler.
 **********************************************************************/
void  objc_setNilObjectMsgHandler   (NilObjectMsgCallback  nilObjMsgCallback)
{
	_objc_msgNil = nilObjMsgCallback;
}

/***********************************************************************
 * objc_getNilObjectMsgHandler.
 **********************************************************************/
NilObjectMsgCallback  objc_getNilObjectMsgHandler   (void)
{
	return _objc_msgNil;
}

#if defined(NeXT_PDO)
// so we have a symbol for libgcc2.c when running PDO
arith_t		_objcInit_addr = (arith_t) _objcInit;
#endif

