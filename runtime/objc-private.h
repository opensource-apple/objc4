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
/*
 *	objc-private.h
 *	Copyright 1988-1996, NeXT Software, Inc.
 */

#if !defined(_OBJC_PRIVATE_H_)
#define _OBJC_PRIVATE_H_

#import <pthread.h>
#import <errno.h>
#import <limits.h>
#import <unistd.h>
#import <sys/time.h>
#import <stdlib.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <ctype.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>
#import <libkern/OSAtomic.h>
#import <dlfcn.h>

#import "objc.h"
#import "runtime.h"
#import "maptable.h"
#import "auto_zone.h"

struct old_category;
struct old_method_list;
typedef struct {
    IMP imp;
    SEL sel;
} message_ref;

#if __OBJC2__

typedef struct objc_module *Module;
typedef struct objc_cache *Cache;

#endif


#if OLD

struct old_class {
    struct old_class *isa;
    struct old_class *super_class;
    const char *name;
    long version;
    long info;
    long instance_size;
    struct old_ivar_list *ivars;
    struct old_method_list **methodLists;
    Cache cache;
    struct old_protocol_list *protocols;
    // CLS_EXT only
    const char *ivar_layout;
    struct old_class_ext *ext;
};

struct old_class_ext {
    uint32_t size;
    const char *weak_ivar_layout;
    struct objc_property_list **propertyLists;
};

struct old_category {
    char *category_name;
    char *class_name;
    struct old_method_list *instance_methods;
    struct old_method_list *class_methods;
    struct old_protocol_list *protocols;
    uint32_t size;
    struct objc_property_list *instance_properties;
};

struct old_ivar {
    char *ivar_name;
    char *ivar_type;
    int ivar_offset;
#ifdef __LP64__
    int space;
#endif
};

struct old_ivar_list {
    int ivar_count;
#ifdef __LP64__
    int space;
#endif
    /* variable length structure */
    struct old_ivar ivar_list[1];
};


struct old_method {
    SEL method_name;
    char *method_types;
    IMP method_imp;
};

// Fixed-up method lists get mlist->obsolete = _OBJC_FIXED_UP.
#define _OBJC_FIXED_UP ((void *)1771)

struct old_method_list {
    struct old_method_list *obsolete;

    int method_count;
#ifdef __LP64__
    int space;
#endif
    /* variable length structure */
    struct old_method method_list[1];
};

struct old_protocol {
    Class isa;
    const char *protocol_name;
    struct old_protocol_list *protocol_list;
    struct objc_method_description_list *instance_methods;
    struct objc_method_description_list *class_methods;
};

struct old_protocol_list {
    struct old_protocol_list *next;
    long count;
    struct old_protocol *list[1];
};

struct old_protocol_ext {
    uint32_t size;
    struct objc_method_description_list *optional_instance_methods;
    struct objc_method_description_list *optional_class_methods;
    struct objc_property_list *instance_properties;
};

#endif

typedef objc_property_t Property;

struct objc_property {
    const char *name;
    const char *attributes;
};

struct objc_property_list {
    uint32_t entsize;
    uint32_t count;
    struct objc_property first;
};


#import "objc-api.h"
#import "objc-config.h"
#import "hashtable2.h"

#import "Object.h"

#define	mutex_alloc()	(pthread_mutex_t*)calloc(1, sizeof(pthread_mutex_t))
#define	mutex_init(m)	pthread_mutex_init(m, NULL)
#define	mutex_lock(m)	pthread_mutex_lock(m)
#define	mutex_try_lock(m) (! pthread_mutex_trylock(m))
#define	mutex_unlock(m)	pthread_mutex_unlock(m)
#define	mutex_clear(m)
#define	mutex_t		pthread_mutex_t*
#define mutex		MUTEX_DEFINE_ERROR


/* Opaque cookie used in _getObjc... routines.  File format independant.
 * This is used in place of the mach_header.  In fact, when compiling
 * for NEXTSTEP, this is really a (struct mach_header *).
 *
 * had been: typedef void *objc_header;
 */
#ifndef __LP64__
typedef struct mach_header headerType;
typedef struct segment_command segmentType;
#else
typedef struct mach_header_64 headerType;
typedef struct segment_command_64 segmentType;
#endif

typedef struct {
    uint32_t version; // currently 0
    uint32_t flags;
} objc_image_info;

// masks for objc_image_info.flags
#define OBJC_IMAGE_IS_REPLACEMENT (1<<0)
#define OBJC_IMAGE_SUPPORTS_GC (1<<1)
#define OBJC_IMAGE_REQUIRES_GC (1<<2)


#define _objcHeaderIsReplacement(h)  ((h)->info  &&  ((h)->info->flags & OBJC_IMAGE_IS_REPLACEMENT))

/* OBJC_IMAGE_IS_REPLACEMENT:
   Don't load any classes
   Don't load any categories
   Do fix up selector refs (@selector points to them)
   Do fix up class refs (@class and objc_msgSend points to them)
   Do fix up protocols (@protocol points to them)
   Do fix up super_class pointers in classes ([super ...] points to them)
   Future: do load new classes?
   Future: do load new categories?
   Future: do insert new methods on existing classes?
   Future: do insert new methods on existing categories?
*/

#define _objcInfoSupportsGC(info) (((info)->flags & OBJC_IMAGE_SUPPORTS_GC) ? 1 : 0)
#define _objcInfoRequiresGC(info) (((info)->flags & OBJC_IMAGE_REQUIRES_GC) ? 1 : 0)
#define _objcHeaderSupportsGC(h) ((h)->info && _objcInfoSupportsGC((h)->info))
#define _objcHeaderRequiresGC(h) ((h)->info && _objcInfoRequiresGC((h)->info))

/* OBJC_IMAGE_SUPPORTS_GC:
    was compiled with -fobjc-gc flag, regardless of whether write-barriers were issued
    if executable image compiled this way, then all subsequent libraries etc. must also be this way
*/


typedef struct _header_info
{
    struct _header_info *next;
    const headerType *  mhdr;
    ptrdiff_t           image_slide;
    const segmentType * objcSegmentHeader;
    const segmentType * dataSegmentHeader;
    struct objc_module *mod_ptr;
    size_t              mod_count;
    const objc_image_info *info;
    Dl_info             dl_info;
    BOOL                allClassesRealized;
} header_info;


extern objc_image_info *_getObjcImageInfo(const headerType *head, ptrdiff_t slide, size_t *size);
extern const segmentType *getsegbynamefromheader(const headerType *head, const char *segname);
extern const char *_getObjcHeaderName(const headerType *head);
extern ptrdiff_t _getImageSlide(const headerType *header);

extern Module _getObjcModules(const headerType *head, ptrdiff_t slide, size_t *count);
extern SEL *_getObjcSelectorRefs(const header_info *hi, size_t *count);
#if !__OBJC2__
extern struct old_protocol *_getObjcProtocols(const header_info *head, size_t *count);
extern struct old_class **_getObjcClassRefs(const header_info *hi, size_t *count);
extern const char *_getObjcClassNames(const header_info *hi, size_t *size);
#endif

#if __OBJC2__
extern SEL *_getObjc2SelectorRefs(const header_info *hi, size_t *count);
extern message_ref *_getObjc2MessageRefs(const header_info *hi, size_t *count);extern struct class_t **_getObjc2ClassRefs(const header_info *hi, size_t *count);
extern struct class_t **_getObjc2SuperRefs(const header_info *hi, size_t *count);
extern struct class_t **_getObjc2ClassList(const header_info *hi, size_t *count);
extern struct class_t **_getObjc2NonlazyClassList(const header_info *hi, size_t *count);
extern struct category_t **_getObjc2CategoryList(const header_info *hi, size_t *count);
extern struct category_t **_getObjc2NonlazyCategoryList(const header_info *hi, size_t *count);
extern struct protocol_t **_getObjc2ProtocolList(const header_info *head, size_t *count);
extern struct protocol_t **_getObjc2ProtocolRefs(const header_info *head, size_t *count);
#endif

#define END_OF_METHODS_LIST ((struct old_method_list*)-1)

OBJC_EXPORT header_info *_objc_headerStart ();

OBJC_EXPORT const char *_nameForHeader(const headerType*);

OBJC_EXPORT SEL sel_registerNameNoLock(const char *str, BOOL copy);
OBJC_EXPORT void sel_lock(void);
OBJC_EXPORT void sel_unlock(void);

/* optional malloc zone for runtime data */
OBJC_EXPORT malloc_zone_t *_objc_internal_zone(void);
OBJC_EXPORT void *_malloc_internal(size_t size);
OBJC_EXPORT void *_calloc_internal(size_t count, size_t size);
OBJC_EXPORT void *_realloc_internal(void *ptr, size_t size);
OBJC_EXPORT char *_strdup_internal(const char *str);
OBJC_EXPORT char *_strdupcat_internal(const char *s1, const char *s2);
OBJC_EXPORT void *_memdup_internal(const void *mem, size_t size);
OBJC_EXPORT void _free_internal(void *ptr);

#if !__OBJC2__
OBJC_EXPORT Class objc_getOrigClass (const char *name);
OBJC_EXPORT IMP lookupNamedMethodInMethodList(struct old_method_list *mlist, const char *meth_name);
OBJC_EXPORT void _objc_insertMethods(struct old_class *cls, struct old_method_list *mlist, struct old_category *cat);
OBJC_EXPORT void _objc_removeMethods(struct old_class *cls, struct old_method_list *mlist);
OBJC_EXPORT void _objc_flush_caches (Class cls);
extern void _class_addProperties(struct old_class *cls, struct objc_property_list *additions);
extern void change_class_references(struct old_class *imposter, struct old_class *original, struct old_class *copy, BOOL changeSuperRefs);
extern void flush_marked_caches(void);
extern void set_superclass(struct old_class *cls, struct old_class *supercls);
#endif

OBJC_EXPORT IMP _cache_getImp(Class cls, SEL sel);
OBJC_EXPORT Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp);

/* message dispatcher */
OBJC_EXPORT IMP _class_lookupMethodAndLoadCache(Class, SEL);
OBJC_EXPORT id _objc_msgForward (id self, SEL sel, ...);
extern id _objc_ignored_method(id self, SEL _cmd);

/* errors */
OBJC_EXPORT void _objc_fatal(const char *fmt, ...) __attribute__((noreturn, format (printf, 1, 2)));
OBJC_EXPORT void __objc_error(id, const char *, ...) __attribute__((format (printf, 2, 3)));
OBJC_EXPORT void _objc_inform(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
OBJC_EXPORT void _objc_inform_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
OBJC_EXPORT void _objc_inform_now_and_on_crash(const char *fmt, ...) __attribute__((format (printf, 1, 2)));
OBJC_EXPORT void _objc_warn_deprecated(const char *old, const char *new) __attribute__((noinline));
OBJC_EXPORT void _objc_error(id, const char *, va_list);

/* magic */
OBJC_EXPORT Class _objc_getFreedObjectClass (void);
#ifndef OBJC_INSTRUMENTED
OBJC_EXPORT const struct objc_cache _objc_empty_cache;
#else
OBJC_EXPORT struct objc_cache _objc_empty_cache;
#endif
#if __OBJC2__
extern IMP _objc_empty_vtable[128];
#endif

/* map table additions */
extern void *NXMapKeyCopyingInsert(NXMapTable *table, const void *key, const void *value);
extern void *NXMapKeyFreeingRemove(NXMapTable *table, const void *key);

/* locking */
#define OBJC_DECLARE_LOCK(MTX) pthread_mutex_t MTX = PTHREAD_MUTEX_INITIALIZER
#ifdef NDEBUG
#define OBJC_LOCK(MUTEX)            mutex_lock (MUTEX)
#define OBJC_UNLOCK(MUTEX)          mutex_unlock (MUTEX)
#define OBJC_CHECK_LOCKED(MUTEX)    do { } while (0)
#define OBJC_CHECK_UNLOCKED(MUTEX)  do { } while (0)
#else
#define OBJC_LOCK(MUTEX)            _lock_debug (MUTEX, #MUTEX)
#define OBJC_UNLOCK(MUTEX)          _unlock_debug (MUTEX, #MUTEX)
#define OBJC_CHECK_LOCKED(MUTEX)    _checklock_debug (MUTEX, #MUTEX)
#define OBJC_CHECK_UNLOCKED(MUTEX)  _checkunlock_debug (MUTEX, #MUTEX)
#endif

OBJC_EXPORT pthread_mutex_t classLock;
OBJC_EXPORT pthread_mutex_t methodListLock;

OBJC_EXPORT NXHashTable *class_hash;

/* nil handler object */
OBJC_EXPORT id _objc_nilReceiver;
OBJC_EXPORT id _objc_setNilReceiver(id newNilReceiver);
OBJC_EXPORT id _objc_getNilReceiver(void);

/* forward handler functions */
OBJC_EXPORT void *_objc_forward_handler;
OBJC_EXPORT void *_objc_forward_stret_handler;

/* C++ interoperability */
OBJC_EXPORT SEL cxx_construct_sel;
OBJC_EXPORT SEL cxx_destruct_sel;
OBJC_EXPORT const char *cxx_construct_name;
OBJC_EXPORT const char *cxx_destruct_name;

/* GC and RTP startup */
OBJC_EXPORT void gc_init(BOOL on);
OBJC_EXPORT void rtp_init(void);

/* Exceptions */
struct alt_handler_list;
OBJC_EXPORT void exception_init(void);
OBJC_EXPORT void _destroyAltHandlerList(struct alt_handler_list *list);

/* Write barrier implementations */
OBJC_EXPORT id objc_assign_strongCast_gc(id val, id *dest);
OBJC_EXPORT id objc_assign_global_gc(id val, id *dest);
OBJC_EXPORT id objc_assign_ivar_gc(id value, id dest, ptrdiff_t offset);
OBJC_EXPORT id objc_assign_strongCast_non_gc(id value, id *dest);
OBJC_EXPORT id objc_assign_global_non_gc(id value, id *dest);
OBJC_EXPORT id objc_assign_ivar_non_gc(id value, id dest, ptrdiff_t offset);

/*
    objc_assign_ivar, objc_assign_global, and objc_assign_strongCast MUST NOT be called directly
    from inside libobjc. They live in the data segment, and must be called through the
    following pointer(s) for libobjc to exist in the shared cache.

    Note: If we build with GC enabled, gcc will emit calls to the original functions, which will break this.
*/

extern id (*objc_assign_ivar_internal)(id, id, ptrdiff_t);

/* Code modification */
OBJC_EXPORT size_t objc_branch_size(void *entry, void *target);
OBJC_EXPORT size_t objc_write_branch(void *entry, void *target);
OBJC_EXPORT size_t objc_cond_branch_size(void *entry, void *target, unsigned cond);
OBJC_EXPORT size_t objc_write_cond_branch(void *entry, void *target, unsigned cond);
#if defined(__ppc__)  ||  defined(__ppc64__)
#define COND_ALWAYS 0x02800000  /* BO=10100, BI=00000 */
#define COND_NE     0x00820000  /* BO=00100, BI=00010 */
#elif defined(__i386__) || defined(__x86_64__)
#define COND_ALWAYS 0xE9  /* JMP rel32 */
#define COND_NE     0x85  /* JNE rel32  (0F 85) */
#endif


/* Thread-safe info field */
#if !__OBJC2__
OBJC_EXPORT void _class_setInfo(Class cls, long set);
OBJC_EXPORT void _class_clearInfo(Class cls, long clear);
OBJC_EXPORT void _class_changeInfo(Class cls, long set, long clear);
#endif

/* Secure /tmp usage */
OBJC_EXPORT int secure_open(const char *filename, int flags, uid_t euid);


#if !defined(SEG_OBJC)
#define SEG_OBJC        "__OBJC"        /* objective-C runtime segment */
#endif
#if !defined(SEG_OBJC2)
#define SEG_OBJC2 "__OBJC2"
#endif


// Settings from environment variables
OBJC_EXPORT int PrintImages;     // env OBJC_PRINT_IMAGES
OBJC_EXPORT int PrintLoading;    // env OBJC_PRINT_LOAD_METHODS
OBJC_EXPORT int PrintInitializing; // env OBJC_PRINT_INITIALIZE_METHODS
OBJC_EXPORT int PrintResolving;  // env OBJC_PRINT_RESOLVED_METHODS
OBJC_EXPORT int PrintConnecting; // env OBJC_PRINT_CLASS_SETUP
OBJC_EXPORT int PrintProtocols;  // env OBJC_PRINT_PROTOCOL_SETUP
OBJC_EXPORT int PrintIvars;      // env OBJC_PRINT_IVAR_SETUP
OBJC_EXPORT int PrintFuture;     // env OBJC_PRINT_FUTURE_CLASSES
OBJC_EXPORT int PrintRTP;        // env OBJC_PRINT_RTP
OBJC_EXPORT int PrintGC;         // env OBJC_PRINT_GC
OBJC_EXPORT int PrintSharing;    // env OBJC_PRINT_SHARING
OBJC_EXPORT int PrintCxxCtors;   // env OBJC_PRINT_CXX_CTORS
OBJC_EXPORT int PrintExceptions; // env OBJC_PRINT_EXCEPTIONS
OBJC_EXPORT int PrintAltHandlers; // env OBJC_PRINT_ALT_HANDLERS
OBJC_EXPORT int PrintDeprecation;// env OBJC_PRINT_DEPRECATION_WARNINGS
OBJC_EXPORT int PrintReplacedMethods; // env OBJC_PRINT_REPLACED_METHODS
OBJC_EXPORT int PrintCacheCollection; // env OBJC_PRINT_CACHE_COLLECTION
OBJC_EXPORT int UseInternalZone; // env OBJC_USE_INTERNAL_ZONE
OBJC_EXPORT int AllowInterposing;// env OBJC_ALLOW_INTERPOSING

OBJC_EXPORT int DebugUnload;     // env OBJC_DEBUG_UNLOAD
OBJC_EXPORT int DebugFragileSuperclasses; // env OBJC_DEBUG_FRAGILE_SUPERCLASSES
OBJC_EXPORT int DebugFinalizers; // env OBJC_DEBUG_FINALIZERS
OBJC_EXPORT int DebugNilSync;    // env OBJC_DEBUG_NIL_SYNC

OBJC_EXPORT int DisableGC;       // env OBJC_DISABLE_GC

/* GC state */
OBJC_EXPORT BOOL UseGC;          // equivalent to calling objc_collecting_enabled()
OBJC_EXPORT auto_zone_t *gc_zone;  // the GC zone, or NULL if no GC

static __inline__ int _objc_strcmp(const char *s1, const char *s2) {
    char c1, c2;
    for ( ; (c1 = *s1) == (c2 = *s2); s1++, s2++)
        if (c1 == '\0')
            return 0;
    return (c1 - c2);
}       

static __inline__ uintptr_t _objc_strhash(const char *s) {
    uintptr_t hash = 0;
    for (;;) {
	int a = *s++;
	if (0 == a) break;
	hash += (hash << 8) + a;
    }
    return hash;
}


// objc per-thread storage
typedef struct {
    struct _objc_initializing_classes *initializingClasses; // for +initialize
    struct _objc_lock_list *lockList;  // for lock debugging
    struct SyncCache *syncCache;  // for @synchronize
    struct alt_handler_list *handlerList;  // for exception alt handlers

    // If you add new fields here, don't forget to update 
    // _objc_pthread_destroyspecific()

} _objc_pthread_data;

OBJC_EXPORT _objc_pthread_data *_objc_fetch_pthread_data(BOOL create);


// Class state
#if !__OBJC2__
#define ISCLASS(cls)		(((cls)->info & CLS_CLASS) != 0)
#define ISMETA(cls)		(((cls)->info & CLS_META) != 0)
#define GETMETA(cls)		(ISMETA(cls) ? (cls) : (cls)->isa)
#endif


// Attribute for global variables to keep them out of bss storage
// To save one page per non-Objective-C process, variables used in 
// the "Objective-C not used" case should not be in bss storage.
// On Tiger, this reduces the number of touched pages for each 
// CoreFoundation-only process from three to two. See #3857126 and #3857136.
#define NOBSS __attribute__((section("__DATA,__data")))

// cache.h
extern void flush_caches(Class cls, BOOL flush_meta);
extern void flush_cache(Class cls);
extern BOOL _cache_fill(Class cls, Method smt, SEL sel);
extern void _cache_addForwardEntry(Class cls, SEL sel);
extern void _cache_free(Cache cache);
#if !__OBJC2__
// used by flush_caches outside objc-cache.m
extern void _cache_flush(Class cls);
extern pthread_mutex_t cacheUpdateLock;
#ifdef OBJC_INSTRUMENTED
extern unsigned int LinearFlushCachesCount;
extern unsigned int LinearFlushCachesVisitedCount;
extern unsigned int MaxLinearFlushCachesVisitedCount;
extern unsigned int NonlinearFlushCachesCount;
extern unsigned int NonlinearFlushCachesClassCount;
extern unsigned int NonlinearFlushCachesVisitedCount;
extern unsigned int MaxNonlinearFlushCachesVisitedCount;
extern unsigned int IdealFlushCachesCount;
extern unsigned int MaxIdealFlushCachesCount;
#endif
#endif

// encoding.h
extern unsigned int encoding_getNumberOfArguments(const char *typedesc);
extern unsigned int encoding_getSizeOfArguments(const char *typedesc);
extern unsigned int encoding_getArgumentInfo(const char *typedesc, int arg, const char **type, int *offset);
extern void encoding_getReturnType(const char *t, char *dst, size_t dst_len);
extern char * encoding_copyReturnType(const char *t);
extern void encoding_getArgumentType(const char *t, unsigned int index, char *dst, size_t dst_len);
extern char *encoding_copyArgumentType(const char *t, unsigned int index);

// lock.h
extern void _lock_debug(mutex_t lock, const char *name);
extern void _checklock_debug(mutex_t lock, const char *name);
extern void _checkunlock_debug(mutex_t lock, const char *name);
extern void _unlock_debug(mutex_t lock, const char *name);
extern void _destroyLockList(struct _objc_lock_list *locks);

// sync.h
extern void _destroySyncCache(struct SyncCache *cache);

// layout.h
typedef struct {
    uint8_t *bits;
    size_t bitCount;
    size_t bitsAllocated;
    BOOL weak;
} layout_bitmap;
extern layout_bitmap layout_bitmap_create(const unsigned char *layout_string, size_t layoutStringInstanceSize, size_t instanceSize, BOOL weak);
extern void layout_bitmap_free(layout_bitmap bits);
extern const unsigned char *layout_string_create(layout_bitmap bits);
extern void layout_bitmap_set_ivar(layout_bitmap bits, const char *type, size_t offset);
extern void layout_bitmap_grow(layout_bitmap *bits, size_t newCount);
extern void layout_bitmap_slide(layout_bitmap *bits, size_t oldPos, size_t newPos);
extern BOOL layout_bitmap_splat(layout_bitmap dst, layout_bitmap src, 
                                size_t oldSrcInstanceSize);
extern BOOL layout_bitmap_or(layout_bitmap dst, layout_bitmap src, const char *msg);


// fixme runtime
extern id look_up_class(const char *aClassName, BOOL includeUnconnected, BOOL includeClassHandler);
extern void _read_images(header_info **hList, uint32_t hCount);
extern void prepare_load_methods(header_info *hi);
extern void _unload_image(header_info *hi);
extern const char ** _objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount);

extern Class _objc_allocateFutureClass(const char *name);


extern Property *copyPropertyList(struct objc_property_list *plist, unsigned int *outCount);


extern const header_info *_headerForClass(Class cls);

// fixme class
extern Property property_list_nth(const struct objc_property_list *plist, uint32_t i);
extern size_t property_list_size(const struct objc_property_list *plist);

extern Class _class_getSuperclass(Class cls);
extern BOOL _class_getInfo(Class cls, int info);
extern const char *_class_getName(Class cls);
extern size_t _class_getInstanceSize(Class cls);
extern Class _class_getMeta(Class cls);
extern BOOL _class_isMetaClass(Class cls);
extern Cache _class_getCache(Class cls);
extern void _class_setCache(Class cls, Cache cache);
extern BOOL _class_isInitializing(Class cls);
extern BOOL _class_isInitialized(Class cls);
extern void _class_setInitializing(Class cls);
extern void _class_setInitialized(Class cls);
extern Class _class_getNonMetaClass(Class cls);
extern Method _class_getMethodNoSuper(Class cls, SEL sel);
extern Method _class_getMethod(Class cls, SEL sel);
extern BOOL _class_isLoadable(Class cls);
extern IMP _class_getLoadMethod(Class cls);
extern BOOL _class_hasLoadMethod(Class cls);
extern BOOL _class_hasCxxStructorsNoSuper(Class cls);
extern BOOL _class_shouldFinalizeOnMainThread(Class cls);
extern void _class_setFinalizeOnMainThread(Class cls);
extern BOOL _class_shouldGrowCache(Class cls);
extern void _class_setGrowCache(Class cls, BOOL grow);
extern Ivar _class_getVariable(Class cls, const char *name);
extern Class _class_getFreedObjectClass(void);
extern Class _class_getNonexistentObjectClass(void);
extern id _internal_class_createInstanceFromZone(Class cls, size_t extraBytes,
                                                 void *zone);
extern id _internal_object_dispose(id anObject);


extern const char *_category_getName(Category cat);
extern const char *_category_getClassName(Category cat);
extern Class _category_getClass(Category cat);
extern IMP _category_getLoadMethod(Category cat);

#if !__OBJC2__
#define oldcls(cls) ((struct old_class *)cls)
#define oldprotocol(proto) ((struct old_protocol *)proto)
#define oldmethod(meth) ((struct old_method *)meth)
#define oldcategory(cat) ((struct old_category *)cat)
#define oldivar(ivar) ((struct old_ivar *)ivar)

static inline struct old_method *_method_asOld(Method m) { return (struct old_method *)m; }
static inline struct old_class *_class_asOld(Class cls) { return (struct old_class *)cls; }
static inline struct old_category *_category_asOld(Category cat) { return (struct old_category *)cat; }

extern void unload_class(struct old_class *cls);
#endif

extern BOOL object_cxxConstruct(id obj);
extern void object_cxxDestruct(id obj);

#if !__OBJC2__
#define CLS_CLASS		0x1
#define CLS_META		0x2
#define CLS_INITIALIZED		0x4
#define CLS_POSING		0x8
#define CLS_MAPPED		0x10
#define CLS_FLUSH_CACHE		0x20
#define CLS_GROW_CACHE		0x40
#define CLS_NEED_BIND		0x80
#define CLS_METHOD_ARRAY        0x100
// the JavaBridge constructs classes with these markers
#define CLS_JAVA_HYBRID		0x200
#define CLS_JAVA_CLASS		0x400
// thread-safe +initialize
#define CLS_INITIALIZING	0x800
// bundle unloading
#define CLS_FROM_BUNDLE		0x1000
// C++ ivar support
#define CLS_HAS_CXX_STRUCTORS	0x2000
// Lazy method list arrays
#define CLS_NO_METHOD_ARRAY	0x4000
// +load implementation
#define CLS_HAS_LOAD_METHOD     0x8000
// objc_allocateClassPair API
#define CLS_CONSTRUCTING        0x10000
// visibility=hidden
#define CLS_HIDDEN              0x20000
// GC:  class has unsafe finalize method
#define CLS_FINALIZE_ON_MAIN_THREAD 0x40000
// Lazy property list arrays
#define CLS_NO_PROPERTY_ARRAY	0x80000
// +load implementation
#define CLS_CONNECTED           0x100000
#define CLS_LOADED              0x200000
// objc_allocateClassPair API
#define CLS_CONSTRUCTED         0x400000
// class is leaf for cache flushing
#define CLS_LEAF                0x800000
#endif

#define OBJC_WARN_DEPRECATED \
    do { \
        static int warned = 0; \
        if (!warned) { \
            warned = 1; \
            _objc_warn_deprecated(__FUNCTION__, NULL); \
        } \
    } while (0) \

/* Method prototypes */
@interface DoesNotExist
+ class;
+ initialize;
- (id)description;
- (const char *)UTF8String;
- (unsigned long)hash;
- (BOOL)isEqual:(id)object;
- free;
@end

#endif /* _OBJC_PRIVATE_H_ */

