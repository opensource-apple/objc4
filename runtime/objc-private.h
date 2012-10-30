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

    // This needs <...> -- malloc.h is not ours, really...
    #import <objc/malloc.h>


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

// both
OBJC_EXPORT headerType **	_getObjcHeaders();
OBJC_EXPORT Module		_getObjcModules(headerType *head, int *nmodules);
OBJC_EXPORT Class *		_getObjcClassRefs(headerType *head, int *nclasses);
OBJC_EXPORT void *		_getObjcHeaderData(headerType *head, unsigned *size);
OBJC_EXPORT const char *	_getObjcHeaderName(headerType *head);

// internal routines for delaying binding
void _objc_resolve_categories_for_class	(struct objc_class * cls);
void _objc_bindClassIfNeeded(struct objc_class *cls);
void _objc_bindModuleContainingClass(struct objc_class * cls);

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
      Module			mod_ptr;
      unsigned int		mod_count;
      unsigned long		image_slide;
      struct _header_info *	next;
    } header_info;
    OBJC_EXPORT header_info *_objc_headerStart ();

    OBJC_EXPORT int _objcModuleCount();
    OBJC_EXPORT const char *_objcModuleNameAtIndex(int i);
    OBJC_EXPORT Class objc_getOrigClass (const char *name);

    extern struct objc_method_list **get_base_method_list(Class cls);


    OBJC_EXPORT const char *__S(_nameForHeader) (const headerType*);

    /* initialize */
    OBJC_EXPORT void _sel_resolve_conflicts(headerType * header, unsigned long slide);
    OBJC_EXPORT void _class_install_relationships(Class, long);
    OBJC_EXPORT void *_objc_create_zone(void);

    OBJC_EXPORT SEL sel_registerNameNoCopy(const char *str);

    /* selector fixup in method lists */

    #define _OBJC_FIXED_UP ((void *)1771)

    static inline struct objc_method_list *_objc_inlined_fixup_selectors_in_method_list(struct objc_method_list *mlist)
    {
        unsigned i, size;
        Method method;
        struct objc_method_list *old_mlist; 
        
        if ( ! mlist ) return (struct objc_method_list *)0;
        if ( mlist->obsolete != _OBJC_FIXED_UP ) {
            old_mlist = mlist;
            size = sizeof(struct objc_method_list) - sizeof(struct objc_method) + old_mlist->method_count * sizeof(struct objc_method);
            mlist = malloc_zone_malloc(_objc_create_zone(), size);
            memmove(mlist, old_mlist, size);
            for ( i = 0; i < mlist->method_count; i += 1 ) {
                method = &mlist->method_list[i];
                method->method_name =
                    sel_registerNameNoCopy((const char *)method->method_name);
            }
            mlist->obsolete = _OBJC_FIXED_UP;
        }
        return mlist;
    }

    /* method lookup */
    /* --  inline version of class_nextMethodList(Class, void **)  -- */

    static inline struct objc_method_list *_class_inlinedNextMethodList(Class cls, void **it)
    {
        struct objc_method_list ***iterator;

        iterator = (struct objc_method_list***)it;
        if (*iterator == NULL) {
            *iterator = &((((struct objc_class *) cls)->methodLists)[0]);
        }
        else (*iterator) += 1;
        // Check for list end
        if ((**iterator == NULL) || (**iterator == END_OF_METHODS_LIST)) {
            *it = nil;
            return NULL;
        }
        
        **iterator = _objc_inlined_fixup_selectors_in_method_list(**iterator);
        
        // Return method list pointer
        return **iterator;
    }

    OBJC_EXPORT BOOL class_respondsToMethod(Class, SEL);
    OBJC_EXPORT IMP class_lookupMethod(Class, SEL);
    OBJC_EXPORT IMP class_lookupMethodInMethodList(struct objc_method_list *mlist, SEL sel);
    OBJC_EXPORT IMP class_lookupNamedMethodInMethodList(struct objc_method_list *mlist, const char *meth_name);
    OBJC_EXPORT void _objc_insertMethods( struct objc_method_list *mlist, struct objc_method_list ***list );
    OBJC_EXPORT void _objc_removeMethods( struct objc_method_list *mlist, struct objc_method_list ***list );

    OBJC_EXPORT IMP _cache_getImp(Class cls, SEL sel);
    OBJC_EXPORT Method _cache_getMethod(Class cls, SEL sel);

    /* message dispatcher */
    OBJC_EXPORT IMP _class_lookupMethodAndLoadCache(Class, SEL);
    OBJC_EXPORT id _objc_msgForward (id self, SEL sel, ...);

    /* errors */
    OBJC_EXPORT volatile void __S(_objc_fatal)(const char *message);
    OBJC_EXPORT volatile void _objc_error(id, const char *, va_list);
    OBJC_EXPORT volatile void __objc_error(id, const char *, ...);
    OBJC_EXPORT void _objc_inform(const char *fmt, ...);
    OBJC_EXPORT void _objc_syslog(const char *fmt, ...);

    /* magic */
    OBJC_EXPORT Class _objc_getFreedObjectClass (void);
    OBJC_EXPORT const struct objc_cache emptyCache;
    OBJC_EXPORT void _objc_flush_caches (Class cls);
    
    /* locking */
    #define MUTEX_TYPE pthread_mutex_t*
    #define OBJC_DECLARE_LOCK(MTX) pthread_mutex_t MTX = PTHREAD_MUTEX_INITIALIZER
    OBJC_EXPORT pthread_mutex_t classLock;

    // _objc_msgNil is actually (unsigned dummy, id, SEL) for i386;
    // currently not implemented for any sparc or hppa platforms
    OBJC_EXPORT void (*_objc_msgNil)(id, SEL);

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




static __inline__ int _objc_strcmp(const unsigned char *s1, const unsigned char *s2) {
    int a, b, idx = 0;
    for (;;) {
	a = s1[idx];
	b = s2[idx];
        if (a != b || 0 == a) break;
        idx++;
    }
    return a - b;
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


#endif /* _OBJC_PRIVATE_H_ */

