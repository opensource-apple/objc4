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

#include "objc-private.h"
#include <objc/message.h>


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

static IMP lookupMethodInClassAndLoadCache(Class cls, SEL sel);
static Method look_up_method(Class cls, SEL sel, BOOL withCache, BOOL withResolver);


/***********************************************************************
* Static data internal to this module.
**********************************************************************/

#if !TARGET_OS_WIN32  &&  !defined(__arm__)
#   define MESSAGE_LOGGING
#endif

#if defined(MESSAGE_LOGGING)
// Method call logging
static int		LogObjCMessageSend		(BOOL isClassMethod, const char * objectsClass, const char * implementingClass, SEL selector);
typedef int	(*ObjCLogProc)(BOOL, const char *, const char *, SEL);

static int			objcMsgLogFD		= (-1);
static ObjCLogProc	objcMsgLogProc		= &LogObjCMessageSend;
static int			objcMsgLogEnabled	= 0;
#endif

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
    if (obj) {
        Class old;
        do {
            old = obj->isa;
        } while (! OSAtomicCompareAndSwapPtrBarrier(old, cls, (void*)&obj->isa));
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
            lookupMethodInClassAndLoadCache(cls, SEL_cxx_destruct);
        if (dtor != (void(*)(id))&_objc_msgForward_internal) {
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
    ctor = (id(*)(id))lookupMethodInClassAndLoadCache(cls, SEL_cxx_construct);
    if (ctor == (id(*)(id))&_objc_msgForward_internal) return YES;  // no ctor - ok
    
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

    if (!look_up_method(cls, SEL_resolveClassMethod, 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    // GrP fixme same hack as +initialize
    if (strncmp(_class_getName(cls), "_%", 2) == 0) {
        // Posee's meta's name is smashed and isn't in the class_hash, 
        // so objc_getClass doesn't work.
        const char *baseName = strchr(_class_getName(cls), '%'); // get posee's real name
        clsInstance = (Class)objc_getClass(baseName);
    } else {
        clsInstance = (Class)objc_getClass(_class_getName(cls));
    }
    
    resolved = ((BOOL(*)(id, SEL, SEL))objc_msgSend)((id)clsInstance, SEL_resolveClassMethod, sel);

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

    if (!look_up_method(((id)cls)->isa, SEL_resolveInstanceMethod, 
                        YES /*cache*/, NO /*resolver*/))
    {
        return NULL;
    }

    resolved = ((BOOL(*)(id, SEL, SEL))objc_msgSend)((id)cls, SEL_resolveInstanceMethod, sel);

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
__private_extern__ Method _class_resolveMethod(Class cls, SEL sel)
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
        meth = _cache_getMethod(cls, sel, &_objc_msgForward_internal);
        if (meth == (Method)1) {
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

    return look_up_method(cls, sel, YES/*cache*/, YES/*resolver*/);
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
* gdb_objc_class_changed
* Tell gdb that a class changed. Currently used for OBJC2 ivar layouts only
**********************************************************************/
void gdb_objc_class_changed(Class cls, unsigned long changes, const char *classname)
{
    // do nothing; gdb sets a breakpoint here to listen
#if TARGET_OS_WIN32
    __asm { }
#else
    asm("");
#endif
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
* class_respondsToSelector.
**********************************************************************/
BOOL class_respondsToMethod(Class cls, SEL sel)
{
    OBJC_WARN_DEPRECATED;

    return class_respondsToSelector(cls, sel);
}


BOOL class_respondsToSelector(Class cls, SEL sel)
{
    IMP imp;

    if (!sel  ||  !cls) return NO;

    // Avoids +initialize because it historically did so.
    // We're not returning a callable IMP anyway.
    imp = lookUpMethod(cls, sel, NO/*initialize*/, YES/*cache*/);
    return (imp != (IMP)_objc_msgForward_internal) ? YES : NO;
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
        __objc_error((id)cls, "invalid selector (null)");
    }

    return class_getMethodImplementation(cls, sel);
}

IMP class_getMethodImplementation(Class cls, SEL sel)
{
    IMP imp;

    if (!cls  ||  !sel) return NULL;

    imp = lookUpMethod(cls, sel, YES/*initialize*/, YES/*cache*/);

    // Translate forwarding function to C-callable external version
    if (imp == (IMP)&_objc_msgForward_internal) {
        return (IMP)&_objc_msgForward;
    }

    return imp;
}


IMP class_getMethodImplementation_stret(Class cls, SEL sel)
{
    IMP imp = class_getMethodImplementation(cls, sel);

    // Translate forwarding function to struct-returning version
    if (imp == (IMP)&_objc_msgForward /* not _internal! */) {
        return (IMP)&_objc_msgForward_stret;
    }
    return imp;
}


// Ignored selectors get method->imp = &_objc_ignored_method
__private_extern__ id _objc_ignored_method(id self, SEL _cmd) { return self; }


/***********************************************************************
* instrumentObjcMessageSends/logObjcMessageSends.
**********************************************************************/
#if defined(MESSAGE_LOGGING)
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

    static OSSpinLock lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&lock);
    write (objcMsgLogFD, buf, strlen(buf));
    OSSpinLockUnlock(&lock);

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
#endif

/***********************************************************************
* log_and_fill_cache
* Log this method call. If the logger permits it, fill the method cache.
* cls is the method whose cache should be filled. 
* implementer is the class that owns the implementation in question.
**********************************************************************/
__private_extern__ void
log_and_fill_cache(Class cls, Class implementer, Method meth, SEL sel)
{
#if defined(MESSAGE_LOGGING)
    BOOL cacheIt = YES;

    if (objcMsgLogEnabled) {
        cacheIt = objcMsgLogProc (_class_isMetaClass(implementer) ? YES : NO,
                                  _class_getName(cls),
                                  _class_getName(implementer), 
                                  sel);
    }
    if (cacheIt)
#endif
        _cache_fill (cls, meth, sel);
}


/***********************************************************************
* _class_lookupMethodAndLoadCache.
* Method lookup for dispatchers ONLY. OTHER CODE SHOULD USE lookUpMethod().
* This lookup avoids optimistic cache scan because the dispatcher 
* already tried that.
**********************************************************************/
__private_extern__ IMP _class_lookupMethodAndLoadCache(Class cls, SEL sel)
{
    return lookUpMethod(cls, sel, YES/*initialize*/, NO/*cache*/);
}


/***********************************************************************
* lookUpMethod.
* The standard method lookup. 
* initialize==NO tries to avoid +initialize (but sometimes fails)
* cache==NO skips optimistic unlocked lookup (but uses cache elsewhere)
* Most callers should use initialize==YES and cache==YES.
* May return _objc_msgForward_internal. IMPs destined for external use 
*   must be converted to _objc_msgForward or _objc_msgForward_stret.
**********************************************************************/
__private_extern__ IMP lookUpMethod(Class cls, SEL sel, 
                                    BOOL initialize, BOOL cache)
{
    Class curClass;
    IMP methodPC = NULL;
    Method meth;
    BOOL triedResolver = NO;

    // Optimistic cache lookup
    if (cache) {
        methodPC = _cache_getImp(cls, sel);
        if (methodPC) return methodPC;    
    }

    // realize, +initialize, and any special early exit
    methodPC = prepareForMethodLookup(cls, sel, initialize);
    if (methodPC) return methodPC;


    // The lock is held to make method-lookup + cache-fill atomic 
    // with respect to method addition. Otherwise, a category could 
    // be added but ignored indefinitely because the cache was re-filled 
    // with the old value after the cache flush on behalf of the category.
 retry:
    lockForMethodLookup();

    // Try this class's cache.

    methodPC = _cache_getImp(cls, sel);
    if (methodPC) goto done;

    // Try this class's method lists.

    meth = _class_getMethodNoSuper_nolock(cls, sel);
    if (meth) {
        log_and_fill_cache(cls, cls, meth, sel);
        methodPC = method_getImplementation(meth);
        goto done;
    }

    // Try superclass caches and method lists.

    curClass = cls;
    while ((curClass = _class_getSuperclass(curClass))) {
        // Superclass cache.
        meth = _cache_getMethod(curClass, sel, &_objc_msgForward_internal);
        if (meth) {
            if (meth != (Method)1) {
                // Found the method in a superclass. Cache it in this class.
                log_and_fill_cache(cls, curClass, meth, sel);
                methodPC = method_getImplementation(meth);
                goto done;
            }
            else {
                // Found a forward:: entry in a superclass.
                // Stop searching, but don't cache yet; call method 
                // resolver for this class first.
                break;
            }
        }

        // Superclass method list.
        meth = _class_getMethodNoSuper_nolock(curClass, sel);
        if (meth) {
            log_and_fill_cache(cls, curClass, meth, sel);
            methodPC = method_getImplementation(meth);
            goto done;
        }
    }

    // No implementation found. Try method resolver once.

    if (!triedResolver) {
        unlockForMethodLookup();
        _class_resolveMethod(cls, sel);
        // Don't cache the result; we don't hold the lock so it may have 
        // changed already. Re-do the search from scratch instead.
        triedResolver = YES;
        goto retry;
    }

    // No implementation found, and method resolver didn't help. 
    // Use forwarding.

    _cache_addForwardEntry(cls, sel);
    methodPC = &_objc_msgForward_internal;

 done:
    unlockForMethodLookup();

    // paranoia: look for ignored selectors with non-ignored implementations
    assert(!(sel == (SEL)kIgnore  &&  methodPC != (IMP)&_objc_ignored_method));

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

    // fixme this still has the method list vs method cache race 
    // because it doesn't hold a lock across lookup+cache_fill, 
    // but it's only used for .cxx_construct/destruct and we assume 
    // categories don't change them.

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
        return &_objc_msgForward_internal;
    }
}


/***********************************************************************
* _objc_create_zone.
**********************************************************************/

void *_objc_create_zone(void)
{
    return malloc_default_zone();
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
    size_t len;
    char *dup;
    if (!str) return NULL;
    len = strlen(str);
    dup = malloc_zone_malloc(_objc_internal_zone(), len + 1);
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


__private_extern__ Class _calloc_class(size_t size)
{
#if !defined(NO_GC)
    if (UseGC) return (Class) malloc_zone_calloc(gc_zone, 1, size);
#endif
    return (Class) _calloc_internal(1, size);
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
    encoding_getReturnType(method_getTypeEncoding(m), dst, dst_len);
}


char * method_copyReturnType(Method m)
{
    return encoding_copyReturnType(method_getTypeEncoding(m));
}


void method_getArgumentType(Method m, unsigned int index, 
                            char *dst, size_t dst_len)
{
    encoding_getArgumentType(method_getTypeEncoding(m),
                             index, dst, dst_len);
}


char * method_copyArgumentType(Method m, unsigned int index)
{
    return encoding_copyArgumentType(method_getTypeEncoding(m), index);
}


/***********************************************************************
* objc_constructInstance
* Creates an instance of `cls` at the location pointed to by `bytes`. 
* `bytes` must point to at least class_getInstanceSize(cls) bytes of 
*   well-aligned zero-filled memory.
* The new object's isa is set. Any C++ constructors are called.
* Returns `bytes` if successful. Returns nil if `cls` or `bytes` is 
*   NULL, or if C++ constructors fail.
**********************************************************************/
id objc_constructInstance(Class cls, void *bytes) 
{
    id obj;

    if (!cls  ||  !bytes) return nil;
    obj = (id)bytes;

    // Set the isa pointer
    obj->isa = cls;

    // Call C++ constructors, if any.
    if (!object_cxxConstruct(obj)) {
        // Some C++ constructor threw an exception. 
        return nil;
    }

    return obj;
}


/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory. 
* Any C++ destructors are called. Any associative references are removed.
* Returns `obj`. Does nothing if `obj` is nil.
**********************************************************************/
void *objc_destructInstance(id obj) 
{
    if (obj) {
        object_cxxDestruct(obj);

        // don't call this if the class has never had associative references.
        if (_class_instancesHaveAssociatedObjects(obj->isa)) {
            _object_remove_assocations(obj);
        }
    }

    return obj;
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
    void *bytes;
    id obj;
    size_t size;

    // Can't create something for nothing
    if (!cls) return nil;

    // Allocate and initialize
    size = _class_getInstanceSize(cls) + extraBytes;

    // CF requires all objects be at least 16 bytes.
    if (size < 16) size = 16;

#if !defined(NO_GC)
    if (UseGC) {
        bytes = auto_zone_allocate_object(gc_zone, size,
                                          AUTO_OBJECT_SCANNED, 0, 1);
    } else 
#endif
    if (zone) {
        bytes = malloc_zone_calloc (zone, 1, size);
    } else {
        bytes = calloc(1, size);
    }
    if (!bytes) return nil;

    obj = objc_constructInstance(cls, bytes);
    if (!obj) {
#if !defined(NO_GC)
        if (UseGC) {
            auto_zone_retain(gc_zone, bytes);  // gc free expects rc==1
        }
#endif
        free(bytes);
        return nil;
    }

    return obj;
}


__private_extern__ id 
_internal_object_dispose(id anObject) 
{
    if (anObject==nil) return nil;

    objc_destructInstance(anObject);
    
#if !defined(NO_GC)
    if (UseGC) {
        auto_zone_retain(gc_zone, anObject); // gc free expects rc==1
    } else 
#endif
    {
#if !__OBJC2__
        // only clobber isa for non-gc
        anObject->isa = _objc_getFreedObjectClass (); 
#endif
    }
    free(anObject);
    return nil;
}


/***********************************************************************
* inform_duplicate. Complain about duplicate class implementations.
**********************************************************************/
__private_extern__ void 
inform_duplicate(const char *name, Class oldCls, Class cls)
{
#if TARGET_OS_WIN32
    _objc_inform ("Class %s is implemented in two different images.", name);
#else
    const header_info *oldHeader = _headerForClass(oldCls);
    const header_info *newHeader = _headerForClass(cls);
    const char *oldName = oldHeader ? _nameForHeader(oldHeader->mhdr) : "??";
    const char *newName = newHeader ? _nameForHeader(newHeader->mhdr) : "??";
        
    _objc_inform ("Class %s is implemented in both %s and %s. "
                  "One of the two will be used. "
                  "Which one is undefined.",
                  name, oldName, newName);
#endif
}
