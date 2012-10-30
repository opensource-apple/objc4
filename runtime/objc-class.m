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
*	objc-class.m
*	Copyright 1988-1997, Apple Computer, Inc.
*	Author:	s. naroff
**********************************************************************/


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
 * CLS_FLUSH_CACHE: class load and messaging
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
* Imports.
**********************************************************************/

#include <mach/mach.h>
#include <mach/thread_status.h>
#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/uio.h>
#include <sys/fcntl.h>
#include <sys/mman.h>

#import "objc.h"
#import "Object.h"
#import "objc-private.h"
#import "hashtable2.h"
#import "maptable.h"
#import "objc-initialize.h"
#import "objc-auto.h"


/* overriding the default object allocation and error handling routines */

OBJC_EXPORT id	(*_alloc)(Class, size_t);
OBJC_EXPORT id	(*_copy)(id, size_t);
OBJC_EXPORT id	(*_realloc)(id, size_t);
OBJC_EXPORT id	(*_dealloc)(id);
OBJC_EXPORT id	(*_zoneAlloc)(Class, size_t, void *);
OBJC_EXPORT id	(*_zoneRealloc)(id, size_t, void *);
OBJC_EXPORT id	(*_zoneCopy)(id, size_t, void *);


/***********************************************************************
* Function prototypes internal to this module.
**********************************************************************/

static void		_freedHandler			(id self, SEL sel);
static void		_nonexistentHandler		(id self, SEL sel);
static int		LogObjCMessageSend		(BOOL isClassMethod, const char * objectsClass, const char * implementingClass, SEL selector);
static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);
static Method look_up_method(Class cls, SEL sel, BOOL withCache, BOOL withResolver);


/***********************************************************************
* Static data internal to this module.
**********************************************************************/

// Method call logging
typedef int	(*ObjCLogProc)(BOOL, const char *, const char *, SEL);

static int			objcMsgLogFD		= (-1);
static ObjCLogProc	objcMsgLogProc		= &LogObjCMessageSend;
static int			objcMsgLogEnabled	= 0;

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
* object_getClass.
**********************************************************************/
Class object_getClass(id obj)
{
    if (obj) return obj->isa;
    else return Nil;
}


/***********************************************************************
* object_setClass.
**********************************************************************/
Class object_setClass(id obj, Class cls)
{
    // fixme could check obj's block size vs. cls's instance size
    if (obj) {
        Class old = obj->isa;
        obj->isa = cls;
        return old;
    }
    else return Nil;
}


/***********************************************************************
* object_getClassName.
**********************************************************************/
const char *object_getClassName(id obj)
{
    if (obj) return _class_getName(obj->isa);
    else return "nil";
}

/***********************************************************************
* object_getIndexedIvars.
**********************************************************************/
void *object_getIndexedIvars(id obj)
{
    // ivars are tacked onto the end of the object
    if (obj) return ((char *) obj) + _class_getInstanceSize(obj->isa);
    else return NULL;
}


Ivar object_setInstanceVariable(id obj, const char *name, void *value)
{
    Ivar ivar = NULL;

    if (obj && name) {
        if ((ivar = class_getInstanceVariable(obj->isa, name))) {
            objc_assign_ivar_internal(
                             (id)value, 
                             obj, 
                             ivar_getOffset(ivar));
        }
    }
    return ivar;
}

Ivar object_getInstanceVariable(id obj, const char *name, void **value)
{
    if (obj && name) {
        Ivar ivar;
        void **ivaridx;
        if ((ivar = class_getInstanceVariable(obj->isa, name))) {
            ivaridx = (void **)((char *)obj + ivar_getOffset(ivar));
            if (value) *value = *ivaridx;
            return ivar;
        }
    }
    if (value) *value = NULL;
    return NULL;
}


void object_setIvar(id obj, Ivar ivar, id value)
{
    if (obj  &&  ivar) {
        objc_assign_ivar_internal(value, obj, ivar_getOffset(ivar));
    }
}


id object_getIvar(id obj, Ivar ivar)
{
    if (obj  &&  ivar) {
        id *idx = (id *)((char *)obj + ivar_getOffset(ivar));
        return *idx;
    }
    return NULL;
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

    for ( ; cls != NULL; cls = _class_getSuperclass(cls)) {
        if (!_class_hasCxxStructorsNoSuper(cls)) continue; 
        dtor = (void(*)(id))
            lookupMethodInClassAndLoadCache(cls, cxx_destruct_sel);
        if (dtor != (void(*)(id))&_objc_msgForward) {
            if (PrintCxxCtors) {
                _objc_inform("CXX: calling C++ destructors for class %s", 
                             _class_getName(cls));
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
__private_extern__ void object_cxxDestruct(id obj)
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
    Class supercls = _class_getSuperclass(cls);

    // Call superclasses' ctors first, if any.
    if (supercls) {
        BOOL ok = object_cxxConstructFromClass(obj, supercls);
        if (!ok) return NO;  // some superclass's ctor failed - give up
    }

    // Find this class's ctor, if any.
    if (!_class_hasCxxStructorsNoSuper(cls)) return YES;  // no ctor - ok
    ctor = (id(*)(id))lookupMethodInClassAndLoadCache(cls, cxx_construct_sel);
    if (ctor == (id(*)(id))&_objc_msgForward) return YES;  // no ctor - ok
    
    // Call this class's ctor.
    if (PrintCxxCtors) {
        _objc_inform("CXX: calling C++ constructors for class %s", _class_getName(cls));
    }
    if ((*ctor)(obj)) return YES;  // ctor called and succeeded - ok

    // This class's ctor was called and failed. 
    // Call superclasses's dtors to clean up.
    if (supercls) object_cxxDestructFromClass(obj, supercls);
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
__private_extern__ BOOL object_cxxConstruct(id obj)
{
    if (!obj) return YES;
    return object_cxxConstructFromClass(obj, obj->isa);
}


@interface objc_resolver
+(BOOL)resolveClassMethod:(SEL)sel;
+(BOOL)resolveInstanceMethod:(SEL)sel;
@end

/***********************************************************************
* _class_resolveClassMethod
* Call +resolveClassMethod and return the method added or NULL.
* cls should be a metaclass.
* Assumes the method doesn't exist already.
**********************************************************************/
static Method _class_resolveClassMethod(Class cls, SEL sel)
{
    BOOL resolved;
    Method meth = NULL;
    Class clsInstance;

    if (!look_up_method(cls, @selector(resolveClassMethod:), 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    // GrP fixme same hack as +initialize
    if (strncmp(_class_getName(cls), "_%", 2) == 0) {
        // Posee's meta's name is smashed and isn't in the class_hash, 
        // so objc_getClass doesn't work.
        char *baseName = strchr(_class_getName(cls), '%'); // get posee's real name
        clsInstance = objc_getClass(baseName);
    } else {
        clsInstance = objc_getClass(_class_getName(cls));
    }
    
    resolved = [clsInstance resolveClassMethod:sel];

    if (resolved) {
        // +resolveClassMethod adds to self->isa
        meth = look_up_method(cls, sel, YES/*cache*/, NO/*resolver*/);

        if (!meth) {
            // Method resolver didn't add anything?
            _objc_inform("+[%s resolveClassMethod:%s] returned YES, but "
                         "no new implementation of +[%s %s] was found", 
                         class_getName(cls),
                         sel_getName(sel), 
                         class_getName(cls), 
                         sel_getName(sel));
            return NULL;
        }
    }

    return meth;
}


/***********************************************************************
* _class_resolveInstanceMethod
* Call +resolveInstanceMethod and return the method added or NULL.
* cls should be a non-meta class.
* Assumes the method doesn't exist already.
**********************************************************************/
static Method _class_resolveInstanceMethod(Class cls, SEL sel)
{
    BOOL resolved;
    Method meth = NULL;

    if (!look_up_method(((id)cls)->isa, @selector(resolveInstanceMethod:), 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    resolved = [cls resolveInstanceMethod:sel];

    if (resolved) {
        // +resolveClassMethod adds to self
        meth = look_up_method(cls, sel, YES/*cache*/, NO/*resolver*/);

        if (!meth) {
            // Method resolver didn't add anything?
            _objc_inform("+[%s resolveInstanceMethod:%s] returned YES, but "
                         "no new implementation of %c[%s %s] was found", 
                         class_getName(cls),
                         sel_getName(sel), 
                         class_isMetaClass(cls) ? '+' : '-', 
                         class_getName(cls), 
                         sel_getName(sel));
            return NULL;
        }
    }

    return meth;
}


/***********************************************************************
* _class_resolveMethod
* Call +resolveClassMethod or +resolveInstanceMethod and return 
* the method added or NULL. 
* Assumes the method doesn't exist already.
**********************************************************************/
static Method _class_resolveMethod(Class cls, SEL sel)
{
    Method meth = NULL;

    if (_class_isMetaClass(cls)) {
        meth = _class_resolveClassMethod(cls, sel);
    }
    if (!meth) {
        meth = _class_resolveInstanceMethod(cls, sel);
    }

    if (PrintResolving  &&  meth) {
        _objc_inform("RESOLVE: method %c[%s %s] dynamically resolved to %p", 
                     class_isMetaClass(cls) ? '+' : '-', 
                     class_getName(cls), sel_getName(sel), 
                     method_getImplementation(meth));
    }
    
    return meth;
}


/***********************************************************************
* look_up_method
* Look up a method in the given class and its superclasses. 
* If withCache==YES, look in the class's method cache too.
* If withResolver==YES, call +resolveClass/InstanceMethod too.
* Returns NULL if the method is not found. 
* +forward:: entries are not returned.
**********************************************************************/
static Method look_up_method(Class cls, SEL sel, 
                             BOOL withCache, BOOL withResolver)
{
    Method meth = NULL;

    if (withCache) {
        meth = _cache_getMethod(cls, sel, &_objc_msgForward);
        if (!meth  &&  (IMP)_objc_msgForward == _cache_getImp(cls, sel)) {
            // Cache contains forward:: . Stop searching.
            return NULL;
        }
    }

    if (!meth) meth = _class_getMethod(cls, sel);

    if (!meth  &&  withResolver) meth = _class_resolveMethod(cls, sel);

    return meth;
}


/***********************************************************************
* class_getInstanceMethod.  Return the instance method for the
* specified class and selector.
**********************************************************************/
Method class_getInstanceMethod(Class cls, SEL sel)
{
    if (!cls  ||  !sel) return NULL;

    /* Cache is not used because historically it wasn't. */
    return look_up_method(cls, sel, NO/*cache*/, YES/*resolver*/);
}

/***********************************************************************
* class_getClassMethod.  Return the class method for the specified
* class and selector.
**********************************************************************/
Method class_getClassMethod(Class cls, SEL sel)
{
    if (!cls  ||  !sel) return NULL;

    return class_getInstanceMethod(_class_getMeta(cls), sel);
}


/***********************************************************************
* class_getInstanceVariable.  Return the named instance variable.
**********************************************************************/
Ivar class_getInstanceVariable(Class cls, const char *name)
{
    if (!cls  ||  !name) return NULL;

    return _class_getVariable(cls, name);
}


/***********************************************************************
* class_getClassVariable.  Return the named class variable.
**********************************************************************/
Ivar class_getClassVariable(Class cls, const char *name)
{
    if (!cls) return NULL;

    return class_getInstanceVariable(((id)cls)->isa, name);
}


__private_extern__ Property 
property_list_nth(const struct objc_property_list *plist, uint32_t i)
{
    return (Property)(i*plist->entsize + (char *)&plist->first);
}

__private_extern__ size_t 
property_list_size(const struct objc_property_list *plist)
{
    return sizeof(struct objc_property_list) + (plist->count-1)*plist->entsize;
}

__private_extern__ Property *
copyPropertyList(struct objc_property_list *plist, unsigned int *outCount)
{
    Property *result = NULL;
    unsigned int count = 0;

    if (plist) {
        count = plist->count;
    }

    if (count > 0) {
        unsigned int i;
        result = malloc((count+1) * sizeof(Property));
        
        for (i = 0; i < count; i++) {
            result[i] = property_list_nth(plist, i);
        }
        result[i] = NULL;
    }

    if (outCount) *outCount = count;
    return result;
}

const char *property_getName(Property prop)
{
    return prop->name;
}


const char *property_getAttributes(Property prop)
{
    return prop->attributes;
}


/***********************************************************************
* _objc_flush_caches.  Flush the caches of the specified class and any
* of its subclasses.  If cls is a meta-class, only meta-class (i.e.
* class method) caches are flushed.  If cls is an instance-class, both
* instance-class and meta-class caches are flushed.
**********************************************************************/
void _objc_flush_caches(Class cls)
{
    flush_caches (cls, YES);
}


/***********************************************************************
* _freedHandler.
**********************************************************************/
static void _freedHandler(id obj, SEL sel)
{
    __objc_error (obj, "message %s sent to freed object=%p", 
                  sel_getName(sel), obj);
}

/***********************************************************************
* _nonexistentHandler.
**********************************************************************/
static void _nonexistentHandler(id obj, SEL sel)
{
    __objc_error (obj, "message %s sent to non-existent object=%p", 
                  sel_getName(sel), obj);
}


/***********************************************************************
* class_respondsToSelector.
**********************************************************************/
BOOL class_respondsToMethod(Class cls, SEL sel)
{
    OBJC_WARN_DEPRECATED;

    return class_respondsToSelector(cls, sel);
}


BOOL class_respondsToSelector(Class cls, SEL sel)
{
    Method meth;

    if (!sel  ||  !cls) return NO;

    meth = look_up_method(cls, sel, YES/*cache*/, YES/*resolver*/);
    if (meth) {
        _cache_fill(cls, meth, sel);
        return YES;
    } else {
        // Cache negative result
        _cache_addForwardEntry(cls, sel);
        return NO;
    }
}


/***********************************************************************
* class_getMethodImplementation.
* Returns the IMP that would be invoked if [obj sel] were sent, 
* where obj is an instance of class cls.
**********************************************************************/
IMP class_lookupMethod(Class cls, SEL sel)
{
    OBJC_WARN_DEPRECATED;

    // No one responds to zero!
    if (!sel) {
        __objc_error(cls, "invalid selector (null)");
    }

    return class_getMethodImplementation(cls, sel);
}

IMP class_getMethodImplementation(Class cls, SEL sel)
{
    IMP imp;

    if (!cls  ||  !sel) return NULL;

    // fixme _objc_msgForward does not conform to ABI and cannot be 
    // called externally

    imp = _cache_getImp(cls, sel);
    if (!imp) {
        // Handle cache miss
        imp = _class_lookupMethodAndLoadCache (cls, sel);
    }
    return imp;
}


IMP class_getMethodImplementation_stret(Class cls, SEL sel)
{
    IMP imp = class_getMethodImplementation(cls, sel);
    // fixme check for forwarding and use stret forwarder instead
    return imp;
}


// Ignored selectors get method->imp = &_objc_ignored_method
__private_extern__ id _objc_ignored_method(id self, SEL _cmd) { return self; }


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

__private_extern__ void	logObjcMessageSends      (ObjCLogProc	logProc)
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
* log_and_fill_cache
* Log this method call. If the logger permits it, fill the method cache.
* cls is the method whose cache should be filled. 
* implementer is the class that owns the implementation in question.
**********************************************************************/
static void
log_and_fill_cache(Class cls, Class implementer, Method meth, SEL sel)
{
    BOOL cacheIt = YES;

    if (objcMsgLogEnabled) {
        cacheIt = objcMsgLogProc (_class_isMetaClass(implementer) ? YES : NO,
                                  _class_getName(cls),
                                  _class_getName(implementer), 
                                  sel);
    }
    if (cacheIt) {
        _cache_fill (cls, meth, sel);
    }    
}


/***********************************************************************
* _class_lookupMethodAndLoadCache.
*
* Called only from objc_msgSend, objc_msgSendSuper and class_lookupMethod.
**********************************************************************/
__private_extern__ IMP _class_lookupMethodAndLoadCache(Class cls, SEL sel)
{
    Class curClass;
    IMP methodPC = NULL;

    // Check for freed class
    if (cls == _class_getFreedObjectClass())
        return (IMP) _freedHandler;

    // Check for nonexistent class
    if (cls == _class_getNonexistentObjectClass())
        return (IMP) _nonexistentHandler;

#if __OBJC2__
    // fixme hack
    _class_realize(cls);
#endif

    if (!_class_isInitialized(cls)) {
        _class_initialize (cls);
        // If sel == initialize, _class_initialize will send +initialize and 
        // then the messenger will send +initialize again after this 
        // procedure finishes. Of course, if this is not being called 
        // from the messenger then it won't happen. 2778172
    }

    // Outer loop - search the caches and method lists of the
    // class and its super-classes
    for (curClass = cls; curClass; curClass = _class_getSuperclass(curClass))
    {
        // Beware of thread-unsafety and double-freeing of forward:: 
        // entries here! See note in "Method cache locking" above.
        // The upshot is that _cache_getMethod() will return NULL 
        // instead of returning a forward:: entry.
        Method meth = _cache_getMethod(curClass, sel, &_objc_msgForward);
        if (meth) {
            // Found the method in this class or a superclass.
            // Cache the method in this class, unless we just found it in 
            // this class's cache.
            if (curClass != cls) {
                _cache_fill (cls, meth, sel);
            }

            methodPC = method_getImplementation(meth);
            break;
        }

        // Cache scan failed. Search method list.

        meth = _class_getMethodNoSuper(curClass, sel);
        if (meth) {
            log_and_fill_cache(cls, curClass, meth, sel);
            methodPC = method_getImplementation(meth);
            break;
        }
    }

    if (methodPC == NULL) {
        // Class and superclasses do not respond -- try resolve handler
        Method meth = _class_resolveMethod(cls, sel);
        if (meth) {
            // GrP fixme this isn't quite right
            log_and_fill_cache(cls, cls, meth, sel);
            methodPC = method_getImplementation(meth);
        }        
    }

    if (methodPC == NULL) {
        // Class and superclasses do not respond and
        // resolve handler didn't help -- use forwarding
        _cache_addForwardEntry(cls, sel);
        methodPC = &_objc_msgForward;
    }

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

    meth = _class_getMethodNoSuper(cls, sel);

    if (meth) {
        // Hit in method list. Cache it.
        _cache_fill(cls, meth, sel);
        return method_getImplementation(meth);
    } else {
        // Miss in method list. Cache objc_msgForward.
        _cache_addForwardEntry(cls, sel);
        return &_objc_msgForward;
    }
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
* _strdupcat_internal
* _memdup_internal
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
    if (!str) return NULL;
    size_t len = strlen(str);
    char *dup = malloc_zone_malloc(_objc_internal_zone(), len + 1);
    memcpy(dup, str, len + 1);
    return dup;
}

// allocate a new string that concatenates s1+s2.
__private_extern__ char *_strdupcat_internal(const char *s1, const char *s2)
{
    size_t len1 = strlen(s1);
    size_t len2 = strlen(s2);
    char *dup = malloc_zone_malloc(_objc_internal_zone(), len1 + len2 + 1);
    memcpy(dup, s1, len1);
    memcpy(dup + len1, s2, len2 + 1);
    return dup;
}

__private_extern__ void *_memdup_internal(const void *mem, size_t len)
{
    void *dup = malloc_zone_malloc(_objc_internal_zone(), len);
    memcpy(dup, mem, len);
    return dup;
}

__private_extern__ void _free_internal(void *ptr)
{
    malloc_zone_free(_objc_internal_zone(), ptr);
}


const char *class_getName(Class cls)
{
    return _class_getName(cls);
}

Class class_getSuperclass(Class cls)
{
    return _class_getSuperclass(cls);
}

BOOL class_isMetaClass(Class cls)
{
    return _class_isMetaClass(cls);
}


size_t class_getInstanceSize(Class cls)
{
    return _class_getInstanceSize(cls);
}

void method_exchangeImplementations(Method m1, Method m2)
{
    // fixme thread safe
    IMP m1_imp;
    if (!m1  ||  !m2) return;
    m1_imp = method_getImplementation(m1);
    method_setImplementation(m1, method_setImplementation(m2, m1_imp));
}


/***********************************************************************
* method_getNumberOfArguments.
**********************************************************************/
unsigned int method_getNumberOfArguments(Method m)
{
    if (!m) return 0;
    return encoding_getNumberOfArguments(method_getTypeEncoding(m));
}


unsigned int method_getSizeOfArguments(Method m)
{
    OBJC_WARN_DEPRECATED;
    if (!m) return 0;
    return encoding_getSizeOfArguments(method_getTypeEncoding(m));
}


unsigned int method_getArgumentInfo(Method m, int arg,
                                    const char **type, int *offset)
{
    OBJC_WARN_DEPRECATED;
    if (!m) return 0;
    return encoding_getArgumentInfo(method_getTypeEncoding(m), 
                                    arg, type, offset);
}


void method_getReturnType(Method m, char *dst, size_t dst_len)
{
    return encoding_getReturnType(method_getTypeEncoding(m), dst, dst_len);
}


char * method_copyReturnType(Method m)
{
    return encoding_copyReturnType(method_getTypeEncoding(m));
}


void method_getArgumentType(Method m, unsigned int index, 
                            char *dst, size_t dst_len)
{
    return encoding_getArgumentType(method_getTypeEncoding(m),
                                    index, dst, dst_len);
}


char * method_copyArgumentType(Method m, unsigned int index)
{
    return encoding_copyArgumentType(method_getTypeEncoding(m), index);
}


/***********************************************************************
* _internal_class_createInstanceFromZone.  Allocate an instance of the
* specified class with the specified number of bytes for indexed
* variables, in the specified zone.  The isa field is set to the
* class, C++ default constructors are called, and all other fields are zeroed.
**********************************************************************/
__private_extern__ id 
_internal_class_createInstanceFromZone(Class cls, size_t extraBytes,
                                       void *zone)
{
    id obj;
    size_t size;

    // Can't create something for nothing
    if (!cls) return nil;

    // Allocate and initialize
    size = _class_getInstanceSize(cls) + extraBytes;
    if (UseGC) {
        obj = (id) auto_zone_allocate_object(gc_zone, size, 
                                             AUTO_OBJECT_SCANNED, false, true);
    } else if (zone) {
        obj = (id) malloc_zone_calloc (zone, 1, size);
    } else {
        obj = (id) calloc(1, size);
    }
    if (!obj) return nil;

    // Set the isa pointer
    obj->isa = cls;

    // Call C++ constructors, if any.
    if (!object_cxxConstruct(obj)) {
        // Some C++ constructor threw an exception. 
        if (UseGC) {
            auto_zone_retain(gc_zone, obj);  // gc free expects retain count==1
        }
        free(obj);
        return nil;
    }

    return obj;
}


__private_extern__ id 
_internal_object_dispose(id anObject) 
{
    if (anObject==nil) return nil;
    object_cxxDestruct(anObject);
    if (UseGC) {
        auto_zone_retain(gc_zone, anObject); // gc free expects retain count==1
    } else {
        // only clobber isa for non-gc
        anObject->isa = _objc_getFreedObjectClass (); 
    }
    free(anObject);
    return nil;
}

