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
/*
 *	objc-private.h
 *	Copyright 1988-1996, NeXT Software, Inc.
 */

#if !defined(_OBJC_PRIVATE_H_)
    #define _OBJC_PRIVATE_H_

    #import <objc/objc-api.h>	// for OBJC_EXPORT

    OBJC_EXPORT void checkUniqueness();

    #import "objc-config.h"

    #import <pthread.h>
    #import <errno.h>
    #import <limits.h>
    #import <unistd.h>
    #define	mutex_alloc()	(pthread_mutex_t*)calloc(1, sizeof(pthread_mutex_t))
    #define	mutex_init(m)	pthread_mutex_init(m, NULL)
    #define	mutex_lock(m)	pthread_mutex_lock(m)
    #define	mutex_try_lock(m) (! pthread_mutex_trylock(m))
    #define	mutex_unlock(m)	pthread_mutex_unlock(m)
    #define	mutex_clear(m)
    #define	mutex_t		pthread_mutex_t*
    #define mutex		MUTEX_DEFINE_ERROR
    #import <sys/time.h>

    #import <stdlib.h>
    #import <stdarg.h>
    #import <stdio.h>
    #import <string.h>
    #import <ctype.h>

    #import <objc/objc-runtime.h>

    #import <malloc/malloc.h>


/* Opaque cookie used in _getObjc... routines.  File format independant.
 * This is used in place of the mach_header.  In fact, when compiling
 * for NEXTSTEP, this is really a (struct mach_header *).
 *
 * had been: typedef void *objc_header;
 */
#import <mach-o/loader.h>
typedef struct mach_header headerType;

#import <objc/Protocol.h>

typedef struct _ProtocolTemplate { @defs(Protocol) } ProtocolTemplate;
typedef struct _NXConstantStringTemplate {
    Class isa;
    void *characters;
    unsigned int _length;
} NXConstantStringTemplate;
   
#define OBJC_CONSTANT_STRING_PTR NXConstantStringTemplate*
#define OBJC_CONSTANT_STRING_DEREF &
#define OBJC_PROTOCOL_PTR ProtocolTemplate*
#define OBJC_PROTOCOL_DEREF .

typedef struct {
    uint32_t version; // currently 0
    uint32_t flags;
} objc_image_info;

// masks for objc_image_info.flags
#define OBJC_IMAGE_IS_REPLACEMENT (1<<0)
#define OBJC_IMAGE_SUPPORTS_GC (1<<1)


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

#define _objcHeaderSupportsGC(h) ((h)->info  &&  ((h)->info->flags & OBJC_IMAGE_SUPPORTS_GC))

/* OBJC_IMAGE_SUPPORTS_GC:
    was compiled with -fobjc-gc flag, regardless of whether write-barriers were issued
    if executable image compiled this way, then all subsequent libraries etc. must also be this way
*/

// both
OBJC_EXPORT headerType **	_getObjcHeaders();
OBJC_EXPORT Module		_getObjcModules(const headerType *head, int *nmodules);
OBJC_EXPORT Class *		_getObjcClassRefs(headerType *head, int *nclasses);
OBJC_EXPORT const struct segment_command *getsegbynamefromheader(const headerType *head, const char *segname);
OBJC_EXPORT const char *	_getObjcHeaderName(const headerType *head);
OBJC_EXPORT objc_image_info *	_getObjcImageInfo(const headerType *head, uint32_t *size);
OBJC_EXPORT ptrdiff_t 		_getImageSlide(const headerType *header);


// internal routines for delaying binding
void _objc_resolve_categories_for_class	(struct objc_class * cls);

// someday a logging facility
// ObjC is assigned the range 0xb000 - 0xbfff for first parameter
#define trace(a, b, c, d) do {} while (0)



OBJC_EXPORT ProtocolTemplate * _getObjcProtocols(headerType *head, int *nprotos);
OBJC_EXPORT NXConstantStringTemplate *_getObjcStringObjects(headerType *head, int *nstrs);
OBJC_EXPORT SEL *		_getObjcMessageRefs(headerType *head, int *nmess);

#define END_OF_METHODS_LIST ((struct objc_method_list*)-1)

    typedef struct _header_info
    {
      const headerType *	mhdr;
      Module			mod_ptr;                    // already slid
      unsigned int		mod_count;
      unsigned long		image_slide;
      const struct segment_command *	objcSegmentHeader;  // already slid
      objc_image_info *		info;                       // already slid
      struct _header_info *	next;
    } header_info;
    OBJC_EXPORT header_info *_objc_headerStart ();

    OBJC_EXPORT int _objcModuleCount();
    OBJC_EXPORT const char *_objcModuleNameAtIndex(int i);
    OBJC_EXPORT Class objc_getOrigClass (const char *name);

    OBJC_EXPORT const char *__S(_nameForHeader) (const headerType*);

    OBJC_EXPORT SEL sel_registerNameNoLock(const char *str, BOOL copy);
    OBJC_EXPORT void sel_lock(void);
    OBJC_EXPORT void sel_unlock(void);

    /* optional malloc zone for runtime data */
    OBJC_EXPORT malloc_zone_t *_objc_internal_zone(void);
    OBJC_EXPORT void *_malloc_internal(size_t size);
    OBJC_EXPORT void *_calloc_internal(size_t count, size_t size);
    OBJC_EXPORT void *_realloc_internal(void *ptr, size_t size);
    OBJC_EXPORT char *_strdup_internal(const char *str);
    OBJC_EXPORT void _free_internal(void *ptr);

    OBJC_EXPORT BOOL class_respondsToMethod(Class, SEL);
    OBJC_EXPORT IMP class_lookupMethod(Class, SEL);
    OBJC_EXPORT IMP lookupNamedMethodInMethodList(struct objc_method_list *mlist, const char *meth_name);
    OBJC_EXPORT void _objc_insertMethods(struct objc_class *cls, struct objc_method_list *mlist);
    OBJC_EXPORT void _objc_removeMethods(struct objc_class *cls, struct objc_method_list *mlist);

    OBJC_EXPORT IMP _cache_getImp(Class cls, SEL sel);
    OBJC_EXPORT Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp);

    /* message dispatcher */
    OBJC_EXPORT IMP _class_lookupMethodAndLoadCache(Class, SEL);
    OBJC_EXPORT id _objc_msgForward (id self, SEL sel, ...);

    /* errors */
    OBJC_EXPORT volatile void _objc_fatal(const char *fmt, ...);
    OBJC_EXPORT volatile void _objc_error(id, const char *, va_list);
    OBJC_EXPORT volatile void __objc_error(id, const char *, ...);
    OBJC_EXPORT void _objc_inform(const char *fmt, ...);
    OBJC_EXPORT void _objc_syslog(const char *fmt, ...);

    /* magic */
    OBJC_EXPORT Class _objc_getFreedObjectClass (void);
#ifndef OBJC_INSTRUMENTED
    OBJC_EXPORT const struct objc_cache emptyCache;
#else
    OBJC_EXPORT struct objc_cache emptyCache;
#endif
    OBJC_EXPORT void _objc_flush_caches (Class cls);
    
    /* locking */
    #define MUTEX_TYPE pthread_mutex_t*
    #define OBJC_DECLARE_LOCK(MTX) pthread_mutex_t MTX = PTHREAD_MUTEX_INITIALIZER
    OBJC_EXPORT pthread_mutex_t classLock;
    OBJC_EXPORT pthread_mutex_t methodListLock;

    /* nil handler object */
    OBJC_EXPORT id _objc_nilReceiver;
    OBJC_EXPORT id _objc_setNilReceiver(id newNilReceiver);
    OBJC_EXPORT id _objc_getNilReceiver(void);

    /* C++ interoperability */
    OBJC_EXPORT SEL cxx_construct_sel;
    OBJC_EXPORT SEL cxx_destruct_sel;
    OBJC_EXPORT const char *cxx_construct_name;
    OBJC_EXPORT const char *cxx_destruct_name;
    OBJC_EXPORT BOOL object_cxxConstruct(id obj);
    OBJC_EXPORT void object_cxxDestruct(id obj);

    /* GC and RTP startup */
    OBJC_EXPORT void gc_init(BOOL on);
    OBJC_EXPORT void rtp_init(void);

    /* Write barrier implementations */
    OBJC_EXPORT id objc_assign_strongCast_gc(id val, id *dest);
    OBJC_EXPORT id objc_assign_global_gc(id val, id *dest);
    OBJC_EXPORT id objc_assign_ivar_gc(id value, id dest, unsigned int offset);
    OBJC_EXPORT id objc_assign_strongCast_non_gc(id value, id *dest);
    OBJC_EXPORT id objc_assign_global_non_gc(id value, id *dest);
    OBJC_EXPORT id objc_assign_ivar_non_gc(id value, id dest, unsigned int offset);

    /* Code modification */
#if defined(__ppc__)
    OBJC_EXPORT size_t objc_write_branch(void *entry, void *target);
#endif

    /* Thread-safe info field */
    OBJC_EXPORT void _class_setInfo(struct objc_class *cls, long set);
    OBJC_EXPORT void _class_clearInfo(struct objc_class *cls, long clear);
    OBJC_EXPORT void _class_changeInfo(struct objc_class *cls, long set, long clear);

    /* Secure /tmp usage */
    OBJC_EXPORT int secure_open(const char *filename, int flags, uid_t euid);

    typedef struct {
       long addressOffset;
       long selectorOffset;
    } FixupEntry;

    static inline int selEqual( SEL s1, SEL s2 ) {
       return (s1 == s2);
    }

    #define OBJC_LOCK(MUTEX) 	mutex_lock (MUTEX)
    #define OBJC_UNLOCK(MUTEX)	mutex_unlock (MUTEX)
    #define OBJC_TRYLOCK(MUTEX)	mutex_try_lock (MUTEX)

#if !defined(SEG_OBJC)
#define SEG_OBJC        "__OBJC"        /* objective-C runtime segment */
#endif


// Settings from environment variables
OBJC_EXPORT int PrintImages;     // env OBJC_PRINT_IMAGES
OBJC_EXPORT int PrintLoading;    // env OBJC_PRINT_LOAD_METHODS
OBJC_EXPORT int PrintConnecting; // env OBJC_PRINT_CLASS_CONNECTION
OBJC_EXPORT int PrintRTP;        // env OBJC_PRINT_RTP
OBJC_EXPORT int PrintGC;         // env OBJC_PRINT_GC
OBJC_EXPORT int PrintSharing;    // env OBJC_PRINT_SHARING
OBJC_EXPORT int PrintCxxCtors;   // env OBJC_PRINT_CXX_CTORS

OBJC_EXPORT int UseInternalZone; // env OBJC_USE_INTERNAL_ZONE
OBJC_EXPORT int AllowInterposing;// env OBJC_ALLOW_INTERPOSING

OBJC_EXPORT int DebugUnload;     // env OBJC_DEBUG_UNLOAD
OBJC_EXPORT int DebugFragileSuperclasses; // env OBJC_DEBUG_FRAGILE_SUPERCLASSES

OBJC_EXPORT int ForceGC;         // env OBJC_FORCE_GC
OBJC_EXPORT int ForceNoGC;       // env OBJC_FORCE_NO_GC
OBJC_EXPORT int CheckFinalizers; // env OBJC_CHECK_FINALIZERS

OBJC_EXPORT BOOL UseGC;          // equivalent to calling objc_collecting_enabled()

static __inline__ int _objc_strcmp(const unsigned char *s1, const unsigned char *s2) {
    unsigned char c1, c2;
    for ( ; (c1 = *s1) == (c2 = *s2); s1++, s2++)
        if (c1 == '\0')
            return 0;
    return (c1 - c2);
}       

static __inline__ unsigned int _objc_strhash(const unsigned char *s) {
    unsigned int hash = 0;
    for (;;) {
	int a = *s++;
	if (0 == a) break;
	hash += (hash << 8) + a;
    }
    return hash;
}


// objc per-thread storage
OBJC_EXPORT pthread_key_t _objc_pthread_key;
typedef struct {
    struct _objc_initializing_classes *initializingClasses; // for +initialize

    // If you add new fields here, don't forget to update 
    // _objc_pthread_destroyspecific()

} _objc_pthread_data;


// Class state
#define ISCLASS(cls)		((((struct objc_class *) cls)->info & CLS_CLASS) != 0)
#define ISMETA(cls)		((((struct objc_class *) cls)->info & CLS_META) != 0)
#define GETMETA(cls)		(ISMETA(cls) ? ((struct objc_class *) cls) : ((struct objc_class *) cls)->isa)
#define ISINITIALIZED(cls)	((((volatile long)GETMETA(cls)->info) & CLS_INITIALIZED) != 0)
#define ISINITIALIZING(cls)	((((volatile long)GETMETA(cls)->info) & CLS_INITIALIZING) != 0)


// Attribute for global variables to keep them out of bss storage
// To save one page per non-Objective-C process, variables used in 
// the "Objective-C not used" case should not be in bss storage.
// On Tiger, this reduces the number of touched pages for each 
// CoreFoundation-only process from three to two. See #3857126 and #3857136.
#define NOBSS __attribute__((section("__DATA,__data")))

// +load implementation
#define CLS_HAS_LOAD_METHOD	0x8000L

#endif /* _OBJC_PRIVATE_H_ */

