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

    #if defined(NeXT_PDO)
        #define LITERAL_STRING_OBJECTS
        #import <mach/cthreads_private.h>
        #if defined(WIN32)
	    #import <winnt-pdo.h>
	    #import <ntunix.h>
	#else
            #import <pdo.h>	// for pdo_malloc and pdo_free defines
            #import <sys/time.h>
        #endif
    #else
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
    #endif

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
#if defined(NeXT_PDO)
    typedef void headerType;
#else 
    #import <mach-o/loader.h>
    typedef struct mach_header headerType;
#endif 

#import <objc/Protocol.h>

typedef struct _ProtocolTemplate { @defs(Protocol) } ProtocolTemplate;
typedef struct _NXConstantStringTemplate {
    Class isa;
    void *characters;
    unsigned int _length;
} NXConstantStringTemplate;
   
#if defined(NeXT_PDO)
    #define OBJC_CONSTANT_STRING_PTR NXConstantStringTemplate**
    #define OBJC_CONSTANT_STRING_DEREF
    #define OBJC_PROTOCOL_PTR ProtocolTemplate**
    #define OBJC_PROTOCOL_DEREF -> 
#elif defined(__MACH__)
    #define OBJC_CONSTANT_STRING_PTR NXConstantStringTemplate*
    #define OBJC_CONSTANT_STRING_DEREF &
    #define OBJC_PROTOCOL_PTR ProtocolTemplate*
    #define OBJC_PROTOCOL_DEREF .
#endif

// both
OBJC_EXPORT headerType **	_getObjcHeaders();
OBJC_EXPORT Module		_getObjcModules(headerType *head, int *nmodules);
OBJC_EXPORT Class *		_getObjcClassRefs(headerType *head, int *nclasses);
OBJC_EXPORT void *		_getObjcHeaderData(headerType *head, unsigned *size);
OBJC_EXPORT const char *	_getObjcHeaderName(headerType *head);

#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
    OBJC_EXPORT ProtocolTemplate ** _getObjcProtocols(headerType *head, int *nprotos);
    OBJC_EXPORT NXConstantStringTemplate **_getObjcStringObjects(headerType *head, int *nstrs);
#elif defined(__MACH__)
    OBJC_EXPORT ProtocolTemplate * _getObjcProtocols(headerType *head, int *nprotos);
    OBJC_EXPORT NXConstantStringTemplate *_getObjcStringObjects(headerType *head, int *nstrs);
    OBJC_EXPORT SEL *		_getObjcMessageRefs(headerType *head, int *nmess);
#endif 

    #define END_OF_METHODS_LIST ((struct objc_method_list*)-1)

    struct header_info
    {
      const headerType *	mhdr;
      Module				mod_ptr;
      unsigned int			mod_count;
      unsigned long			image_slide;
      unsigned int			objcSize;
    };
    typedef struct header_info	header_info;
    OBJC_EXPORT header_info *_objc_headerVector (const headerType * const *machhdrs);
    OBJC_EXPORT unsigned int _objc_headerCount (void);
    OBJC_EXPORT void _objc_addHeader (const headerType *header, unsigned long vmaddr_slide);

    OBJC_EXPORT int _objcModuleCount();
    OBJC_EXPORT const char *_objcModuleNameAtIndex(int i);
    OBJC_EXPORT Class objc_getOrigClass (const char *name);

    extern struct objc_method_list **get_base_method_list(Class cls);


    OBJC_EXPORT const char *__S(_nameForHeader) (const headerType*);

    /* initialize */
    OBJC_EXPORT void _sel_resolve_conflicts(headerType * header, unsigned long slide);
    OBJC_EXPORT void _class_install_relationships(Class, long);
    OBJC_EXPORT void _objc_add_category(Category, int);
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

    /* message dispatcher */
    OBJC_EXPORT Cache _cache_create(Class);
    OBJC_EXPORT IMP _class_lookupMethodAndLoadCache(Class, SEL);
    OBJC_EXPORT id _objc_msgForward (id self, SEL sel, ...);

    /* errors */
    OBJC_EXPORT volatile void __S(_objc_fatal)(const char *message);
    OBJC_EXPORT volatile void _objc_error(id, const char *, va_list);
    OBJC_EXPORT volatile void __objc_error(id, const char *, ...);
    OBJC_EXPORT void _objc_inform(const char *fmt, ...);
    OBJC_EXPORT void _NXLogError(const char *format, ...);

    /* magic */
    OBJC_EXPORT Class _objc_getFreedObjectClass (void);
    OBJC_EXPORT const struct objc_cache emptyCache;
    OBJC_EXPORT void _objc_flush_caches (Class cls);
    
    /* locking */
    #if defined(NeXT_PDO)
        #if defined(WIN32)
            #define MUTEX_TYPE long
            #define OBJC_DECLARE_LOCK(MUTEX) MUTEX_TYPE MUTEX = 0L;
        #elif defined(sparc)
            #define MUTEX_TYPE long
            #define OBJC_DECLARE_LOCK(MUTEX) MUTEX_TYPE MUTEX = 0L;
        #elif defined(__alpha__)
            #define MUTEX_TYPE long
            #define OBJC_DECLARE_LOCK(MUTEX) MUTEX_TYPE MUTEX = 0L;
        #elif defined(__hpux__) || defined(hpux)
            typedef struct { int a; int b; int c; int d; } __mutex_struct;
            #define MUTEX_TYPE __mutex_struct
            #define OBJC_DECLARE_LOCK(MUTEX) MUTEX_TYPE MUTEX = { 1, 1, 1, 1 };
        #else // unknown pdo platform
            #define MUTEX_TYPE long
            #define OBJC_DECLARE_LOCK(MUTEX) struct mutex MUTEX = { 0 };
        #endif // WIN32
        OBJC_EXPORT MUTEX_TYPE classLock;
        OBJC_EXPORT MUTEX_TYPE messageLock;
    #else
        #define MUTEX_TYPE pthread_mutex_t*
        #define OBJC_DECLARE_LOCK(MTX) pthread_mutex_t MTX = PTHREAD_MUTEX_INITIALIZER
        OBJC_EXPORT pthread_mutex_t classLock;
        OBJC_EXPORT pthread_mutex_t messageLock;
    #endif // NeXT_PDO

    OBJC_EXPORT int _objc_multithread_mask;

    // _objc_msgNil is actually (unsigned dummy, id, SEL) for i386;
    // currently not implemented for any sparc or hppa platforms
    OBJC_EXPORT void (*_objc_msgNil)(id, SEL);

    typedef struct {
       long addressOffset;
       long selectorOffset;
    } FixupEntry;

    static inline int selEqual( SEL s1, SEL s2 ) {
       OBJC_EXPORT int rocketLaunchingDebug;
       if ( rocketLaunchingDebug )
          checkUniqueness(s1, s2);
       return (s1 == s2);
    }

        #if defined(OBJC_COLLECTING_CACHE)
            #define OBJC_LOCK(MUTEX) 	mutex_lock (MUTEX)
            #define OBJC_UNLOCK(MUTEX)	mutex_unlock (MUTEX)
            #define OBJC_TRYLOCK(MUTEX)	mutex_try_lock (MUTEX)
        #elif defined(NeXT_PDO)
            #if !defined(WIN32)
                /* Where are these defined?  NT should probably be using them! */
                OBJC_EXPORT void _objc_private_lock(MUTEX_TYPE*);
                OBJC_EXPORT void _objc_private_unlock(MUTEX_TYPE*);

                /* I don't think this should be commented out for NT, should it? */
                #define OBJC_LOCK(MUTEX)		\
                    do {if (!_objc_multithread_mask)	\
                    _objc_private_lock(MUTEX);} while(0)
                #define OBJC_UNLOCK(MUTEX)		\
                    do {if (!_objc_multithread_mask)	\
                    _objc_private_unlock(MUTEX);} while(0)
            #else
                #define OBJC_LOCK(MUTEX)		\
                    do {if (!_objc_multithread_mask)	\
                    if( *MUTEX == 0 ) *MUTEX = 1;} while(0)
                #define OBJC_UNLOCK(MUTEX)		\
                    do {if (!_objc_multithread_mask)	\
                    *MUTEX = 0;} while(0)
            #endif // WIN32

        #else // not NeXT_PDO
            #define OBJC_LOCK(MUTEX)			\
              do					\
                {					\
                  if (!_objc_multithread_mask)		\
            	mutex_lock (MUTEX);			\
                }					\
              while (0)

            #define OBJC_UNLOCK(MUTEX)			\
              do					\
                {					\
                  if (!_objc_multithread_mask)		\
            	mutex_unlock (MUTEX);			\
                }					\
              while (0)
        #endif /* OBJC_COLLECTING_CACHE */

#if !defined(SEG_OBJC)
#define SEG_OBJC        "__OBJC"        /* objective-C runtime segment */
#endif

#if defined(NeXT_PDO)
    // GENERIC_OBJ_FILE
    void send_load_message_to_category(Category cat, void *header_addr); 
    void send_load_message_to_class(Class cls, void *header_addr);
#endif

#if !defined(__MACH__)
typedef struct _objcSectionStruct {
    void     **data;                   /* Pointer to array  */
    int      count;                    /* # of elements     */
    int      size;                     /* sizeof an element */
} objcSectionStruct;

typedef struct _objcModHeader {
    char *            name;
    objcSectionStruct Modules;
    objcSectionStruct Classes;
    objcSectionStruct Methods;
    objcSectionStruct Protocols;
    objcSectionStruct StringObjects;
} objcModHeader;
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

#endif /* _OBJC_PRIVATE_H_ */

