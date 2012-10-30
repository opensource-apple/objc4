/*
 * Copyright (c) 2005-2007 Apple Inc.  All Rights Reserved.
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
* objc-runtime-new.m
* Support for new-ABI classes and images.
**********************************************************************/

#if __OBJC2__

#include "objc-private.h"
#include "objc-runtime-new.h"
#include "objc-loadmethod.h"
#include "objc-rtp.h"
#include "maptable.h"
#include <assert.h>
#include <mach-o/dyld.h>
#include <mach-o/ldsyms.h>

#define newcls(cls) ((struct class_t *)cls)
#define newcat(cat) ((struct category_t *)cat)
#define newmethod(meth) ((struct method_t *)meth)
#define newivar(ivar) ((struct ivar_t *)ivar)
#define newcategory(cat) ((struct category_t *)cat)
#define newprotocol(p) ((struct protocol_t *)p)

static const char *getName(struct class_t *cls);
static uint32_t instanceSize(struct class_t *cls);
static BOOL isMetaClass(struct class_t *cls);
static struct class_t *getSuperclass(struct class_t *cls);
static void unload_class(class_t *cls);
static class_t *setSuperclass(class_t *cls, class_t *newSuper);
static class_t *realizeClass(class_t *cls);

static OBJC_DECLARE_LOCK (runtimeLock);
// fixme use more fine-grained locks


typedef struct {
    uint32_t count;
    category_t *list[0];  // variable-size
} category_list;

typedef struct chained_method_list {
    struct chained_method_list *next;
    uint32_t count;
    method_t list[0];  // variable-size
} chained_method_list;

static size_t chained_mlist_size(const chained_method_list *mlist)
{
    return sizeof(chained_method_list) + mlist->count * sizeof(method_t);
}

// fixme don't chain property lists
typedef struct chained_property_list {
    struct chained_property_list *next;
    uint32_t count;
    struct objc_property list[0];  // variable-size
} chained_property_list;

/*
static size_t chained_property_list_size(const chained_property_list *plist)
{
    return sizeof(chained_property_list) + 
        plist->count * sizeof(struct objc_property);
}

static size_t protocol_list_size(const protocol_list_t *plist)
{
    return sizeof(protocol_list_t) + plist->count * sizeof(protocol_t *);
}
*/

static size_t ivar_list_size(const ivar_list_t *ilist)
{
    return sizeof(ivar_list_t) + (ilist->count-1) * ilist->entsize;
}

static method_t *method_list_nth(const method_list_t *mlist, uint32_t i)
{
    return (method_t *)(i*mlist->entsize + (char *)&mlist->first);
}

static ivar_t *ivar_list_nth(const ivar_list_t *ilist, uint32_t i)
{
    return (ivar_t *)(i*ilist->entsize + (char *)&ilist->first);
}


static void try_free(const void *p) 
{
    if (p && malloc_size(p)) free((void *)p);
}


/***********************************************************************
* make_ro_writeable
* Reallocates rw->ro if necessary to make it writeable.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static class_ro_t *make_ro_writeable(class_rw_t *rw)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (rw->flags & RW_COPIED_RO) {
        // already writeable, do nothing
    } else {
        class_ro_t *ro = _memdup_internal(rw->ro, sizeof(*rw->ro));
        rw->ro = ro;
        rw->flags |= RW_COPIED_RO;
    }
    return (class_ro_t *)rw->ro;
}


/***********************************************************************
* unattachedCategories
* Returns the class => categories map of unattached categories.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static NXMapTable *unattachedCategories(void)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    static NXMapTable *category_map = NULL;

    if (category_map) return category_map;

    // fixme initial map size
    category_map = NXCreateMapTableFromZone(NXPtrValueMapPrototype, 16, 
                                            _objc_internal_zone());

    return category_map;
}


/***********************************************************************
* addUnattachedCategoryForClass
* Records an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addUnattachedCategoryForClass(category_t *cat, class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    // DO NOT use cat->cls! 
    // cls may be cat->cls->isa, or cat->cls may have been remapped.
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = NXMapGet(cats, cls);
    if (!list) {
        list = _calloc_internal(sizeof(*list) + sizeof(category_t *), 1);
    } else {
        list = _realloc_internal(list, sizeof(*list) + sizeof(category_t *) * (list->count + 1));
    }
    list->list[list->count++] = cat;
    NXMapInsert(cats, cls, list);
}


/***********************************************************************
* removeUnattachedCategoryForClass
* Removes an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeUnattachedCategoryForClass(category_t *cat, class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    // DO NOT use cat->cls! 
    // cls may be cat->cls->isa, or cat->cls may have been remapped.
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = NXMapGet(cats, cls);
    if (!list) return;

    uint32_t i;
    for (i = 0; i < list->count; i++) {
        if (list->list[i] == cat) {
            // shift entries to preserve list order
            memmove(&list->list[i], &list->list[i+1], 
                    (list->count-i-1) * sizeof(category_t *));
            list->count--;
            return;
        }
    }
}


/***********************************************************************
* unattachedCategoriesForClass
* Returns the list of unattached categories for a class, and 
* deletes them from the list. 
* The result must be freed by the caller. 
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static category_list *unattachedCategoriesForClass(class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    return NXMapRemove(unattachedCategories(), cls);
}


/***********************************************************************
* isRealized
* Returns YES if class cls has been realized.
* Locking: To prevent concurrent realization, hold runtimeLock.
**********************************************************************/
static BOOL isRealized(class_t *cls)
{
    return (cls->data->flags & RW_REALIZED) ? YES : NO;
}


/***********************************************************************
* isMethodized.
* Returns YES if class cls has ever been methodized.
* Note that its method lists may still be out of date.
* Locking: To prevent concurrent methodization, hold runtimeLock.
**********************************************************************/
static BOOL isMethodized(class_t *cls)
{
    if (!isRealized(cls)) return NO;
    return (cls->data->flags & RW_METHODIZED) ? YES : NO;
}

static chained_method_list *
buildMethodList(const method_list_t *mlist, category_list *cats, BOOL isMeta)
{
    // Do NOT use cat->cls! It may have been remapped.
    chained_method_list *newlist;
    uint32_t count = 0;
    uint32_t m, c;

    // Count methods in all lists.
    if (mlist) count = mlist->count;
    if (cats) {
        for (c = 0; c < cats->count; c++) {
            if (isMeta  &&  cats->list[c]->classMethods) {
                count += cats->list[c]->classMethods->count;
            }
            else if (!isMeta  &&  cats->list[c]->instanceMethods) {
                count += cats->list[c]->instanceMethods->count;
            }
        }
    }
    
    // Allocate new list. 
    newlist = _malloc_internal(sizeof(*newlist) + count * sizeof(method_t));
    newlist->count = 0;
    newlist->next = NULL;

    // Copy methods; newest categories first, then ordinary methods
    if (cats) {
        c = cats->count;
        while (c--) {
            method_list_t *cmlist;
            if (isMeta) {
                cmlist = cats->list[c]->classMethods;
            } else {
                cmlist = cats->list[c]->instanceMethods;
            }
            if (cmlist) {
                for (m = 0; m < cmlist->count; m++) {
                    newlist->list[newlist->count++] = 
                        *method_list_nth(cmlist, m);
                }
            }
        }
    }
    if (mlist) {
        for (m = 0; m < mlist->count; m++) {
            newlist->list[newlist->count++] = *method_list_nth(mlist, m);
        }
    }

    assert(newlist->count == count);
    for (m = 0; m < newlist->count; m++) {
        newlist->list[m].name = 
            sel_registerName((const char *)newlist->list[m].name);
        if (newlist->list[m].name == (SEL)kRTAddress_ignoredSelector) {
            newlist->list[m].imp = (IMP)&_objc_ignored_method;
        }
    }

    return newlist;
}


static chained_property_list *
buildPropertyList(const struct objc_property_list *plist, category_list *cats, BOOL isMeta)
{
    // Do NOT use cat->cls! It may have been remapped.
    chained_property_list *newlist;
    uint32_t count = 0;
    uint32_t p, c;

    // Count properties in all lists.
    if (plist) count = plist->count;
    if (cats) {
        for (c = 0; c < cats->count; c++) {
            /*
            if (isMeta  &&  cats->list[c]->classProperties) {
                count += cats->list[c]->classProperties->count;
            } 
            else*/
            if (!isMeta  &&  cats->list[c]->instanceProperties) {
                count += cats->list[c]->instanceProperties->count;
            }
        }
    }
    
    if (count == 0) return NULL;

    // Allocate new list. 
    newlist = _malloc_internal(sizeof(*newlist) + count * sizeof(struct objc_property));
    newlist->count = 0;
    newlist->next = NULL;

    // Copy properties; newest categories first, then ordinary properties
    if (cats) {
        c = cats->count;
        while (c--) {
            struct objc_property_list *cplist;
            /*
            if (isMeta) {
                cplist = cats->list[c]->classProperties;
                } else */
            {
                cplist = cats->list[c]->instanceProperties;
            }
            if (cplist) {
                for (p = 0; p < cplist->count; p++) {
                    newlist->list[newlist->count++] = 
                        *property_list_nth(cplist, p);
                }
            }
        }
    }
    if (plist) {
        for (p = 0; p < plist->count; p++) {
            newlist->list[newlist->count++] = *property_list_nth(plist, p);
        }
    }

    assert(newlist->count == count);

    return newlist;
}


static protocol_list_t **
buildProtocolList(category_list *cats, struct protocol_list_t *base, 
                  struct protocol_list_t **protos)
{
    // Do NOT use cat->cls! It may have been remapped.
    struct protocol_list_t **p, **newp;
    struct protocol_list_t **newprotos;
    int count = 0;
    int i;

    // count protocol list in base
    if (base) count++;

    // count protocol lists in cats
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i];
        if (cat->protocols) count++;
    }

    // no base or category protocols? return existing protocols unchanged
    if (count == 0) return protos;

    // count protocol lists in protos
    for (p = protos; p  &&  *p; p++) {
        count++;
    }

    if (count == 0) return NULL;
    
    newprotos = (struct protocol_list_t **)
        _malloc_internal((count+1) * sizeof(struct protocol_list_t *));
    newp = newprotos;

    if (base) {
        *newp++ = base;
    }

    for (p = protos; p  &&  *p; p++) {
        *newp++ = *p;
    }
    
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i];
        if (cat->protocols) {
            *newp++ = cat->protocols;
        }
    }

    *newp = NULL;

    return newprotos;
}


/***********************************************************************
* methodizeClass
* Fixes up cls's method list, protocol list, and property list.
* Attaches any outstanding categories.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void methodizeClass(struct class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    category_list *cats;

    if (!cls) return;
    assert(isRealized(cls));

    if (!(cls->data->flags & RW_METHODIZED)) {
        // Methodizing for the first time
        if (PrintConnecting) {
            _objc_inform("CLASS: methodizing class '%s' %s", 
                         getName(cls), 
                         isMetaClass(cls) ? "(meta)" : "");
        }
        
        // Build method and protocol and property lists.
        // Include methods and protocols and properties from categories, if any
        // Do NOT use cat->cls! It may have been remapped.
        cats = unattachedCategoriesForClass(cls);        
        if (cats  ||  cls->data->ro->baseMethods) {
            cls->data->methods = 
                buildMethodList(cls->data->ro->baseMethods, cats, 
                                isMetaClass(cls));
        }

        if (cats  ||  cls->data->ro->baseProperties) {
            cls->data->properties = 
                buildPropertyList(cls->data->ro->baseProperties, cats, 
                                  isMetaClass(cls));
        }

        if (cats  ||  cls->data->ro->baseProtocols) {
            cls->data->protocols = 
                buildProtocolList(cats, cls->data->ro->baseProtocols, NULL);
        }

        if (PrintConnecting) {
            uint32_t i;
            if (cats) for (i = 0; i < cats->count; i++) {
                _objc_inform("CLASS: attached category %c%s(%s)", 
                             isMetaClass(cls) ? '+' : '-', 
                             getName(cls), cats->list[i]->name);
            }
        }

        if (cats) _free_internal(cats);

        cls->data->flags |= RW_METHODIZED;
    } 
    else {
        // Re-methodizing: check for more categories
        if ((cats = unattachedCategoriesForClass(cls))) {
            chained_method_list *newlist;
            chained_property_list *newproperties;
            struct protocol_list_t **newprotos;

            if (PrintConnecting) {
                _objc_inform("CLASS: attaching categories to class '%s' %s", 
                             getName(cls), 
                             isMetaClass(cls) ? "(meta)" : "");
            }

            newlist = buildMethodList(NULL, cats, isMetaClass(cls));
            newlist->next = cls->data->methods;
            cls->data->methods = newlist;

            newproperties = buildPropertyList(NULL, cats, isMetaClass(cls));
            if (newproperties) {
                newproperties->next = cls->data->properties;
                cls->data->properties = newproperties;
            }

            newprotos = buildProtocolList(cats, NULL, cls->data->protocols);
            if (cls->data->protocols  &&  cls->data->protocols != newprotos) {
                _free_internal(cls->data->protocols);
            }
            cls->data->protocols = newprotos;

            _free_internal(cats);
        }
    }
}


/***********************************************************************
* changeInfo
* Atomically sets and clears some bits in cls's info field.
* set and clear must not overlap.
**********************************************************************/
static OBJC_DECLARE_LOCK(infoLock);
// fixme use atomic ops instead of lock
static void changeInfo(class_t *cls, unsigned int set, unsigned int clear)
{
    assert(isRealized(cls));
    OBJC_LOCK(&infoLock);
    cls->data->flags = (cls->data->flags | set) & ~clear;
    OBJC_UNLOCK(&infoLock);
}


/***********************************************************************
* realizedClasses
* Returns the classname => class map for realized non-meta classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *realizedClasses(void)
{
    static NXMapTable *class_map = NULL;
    
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (class_map) return class_map;

    // fixme this doesn't work yet
    // class_map starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    class_map = NXCreateMapTableFromZone(NXStrValueMapPrototype, 16, 
                                         _objc_internal_zone());

    return class_map;
}


/***********************************************************************
* unrealizedClasses
* Returns the classname => class map for unrealized non-meta classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *unrealizedClasses(void)
{
    static NXMapTable *class_map = NULL;
    
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (class_map) return class_map;

    // fixme this doesn't work yet
    // class_map starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    class_map = NXCreateMapTableFromZone(NXStrValueMapPrototype, 16, 
                                         _objc_internal_zone());

    return class_map;
}


/***********************************************************************
* addRealizedClass
* Adds name => cls to the realized non-meta class map.
* Also removes name => cls from the unrealized non-meta class map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addRealizedClass(class_t *cls, const char *name)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    void *old;
    old = NXMapInsert(realizedClasses(), name, cls);
    assert(!isMetaClass(cls));
    NXMapRemove(unrealizedClasses(), name);
}


/***********************************************************************
* removeRealizedClass
* Removes cls from the realized class map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeRealizedClass(class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    assert(isRealized(cls));
    assert(!isMetaClass(cls));
    NXMapRemove(realizedClasses(), cls->data->ro->name);
}


/***********************************************************************
* addUnrealizedClass
* Adds name => cls to the unrealized non-meta class map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addUnrealizedClass(class_t *cls, const char *name)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    void *old;
    old = NXMapInsert(unrealizedClasses(), name, cls);
    assert(!isRealized(cls));
    assert(!(cls->data->flags & RO_META));
}


/***********************************************************************
* uninitializedClasses
* Returns the metaclass => class map for un-+initialized classes
* Replaces the 32-bit cls = objc_getName(metacls) during +initialize.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *uninitializedClasses(void)
{
    static NXMapTable *class_map = NULL;
    
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (class_map) return class_map;

    // fixme this doesn't work yet
    // class_map starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    class_map = NXCreateMapTableFromZone(NXPtrValueMapPrototype, 16, 
                                         _objc_internal_zone());

    return class_map;
}


/***********************************************************************
* addUninitializedClass
* Adds metacls => cls to the un-+initialized class map
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addUninitializedClass(class_t *cls, class_t *metacls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    void *old;
    old = NXMapInsert(uninitializedClasses(), metacls, cls);
    assert(isRealized(metacls) ? isMetaClass(metacls) : metacls->data->flags & RO_META);
    assert(! (isRealized(cls) ? isMetaClass(cls) : cls->data->flags & RO_META));
    assert(!old);
}


static void removeUninitializedClass(class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    NXMapRemove(uninitializedClasses(), cls->isa);
}


/***********************************************************************
* _class_getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Class _class_getNonMetaClass(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    OBJC_LOCK(&runtimeLock);
    if (isMetaClass(cls)) {
        cls = NXMapGet(uninitializedClasses(), cls);
        realizeClass(cls);
    }
    OBJC_UNLOCK(&runtimeLock);
    
    return (Class)cls;
}



/***********************************************************************
* futureClasses
* Returns the classname => future class map for unrealized future classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *futureClasses(void)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    static NXMapTable *future_class_map = NULL;
    
    if (future_class_map) return future_class_map;

    // future_class_map is big enough to hold CF's classes and a few others
    future_class_map = NXCreateMapTableFromZone(NXStrValueMapPrototype, 32, 
                                                _objc_internal_zone());

    return future_class_map;
}


/***********************************************************************
* addFutureClass
* Installs cls as the class structure to use for the named class if it appears.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addFutureClass(const char *name, class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", cls, name);
    }

    void *old;
    old = NXMapKeyCopyingInsert(futureClasses(), name, cls);
    assert(!old);
}


/***********************************************************************
* removeFutureClass
* Removes the named class from the unrealized future class list, 
* because it has been realized.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeFutureClass(const char *name)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    NXMapKeyFreeingRemove(futureClasses(), name);
}


/***********************************************************************
* remappedClasses
* Returns the oldClass => newClass map for realized future classes.
* Locking: remapLock must be held by the caller
**********************************************************************/
static OBJC_DECLARE_LOCK(remapLock);
static NXMapTable *remappedClasses(BOOL create)
{
    static NXMapTable *remapped_class_map = NULL;

    OBJC_CHECK_LOCKED(&remapLock);

    if (remapped_class_map) return remapped_class_map;

    if (!create) return NULL;

    // remapped_class_map is big enough to hold CF's classes and a few others
    remapped_class_map = NXCreateMapTableFromZone(NXPtrValueMapPrototype, 32, 
                                                  _objc_internal_zone());

    return remapped_class_map;
}


/***********************************************************************
* noClassesRemapped
* Returns YES if no classes have been remapped
* Locking: acquires remapLock
**********************************************************************/
static BOOL noClassesRemapped(void)
{
    OBJC_LOCK(&remapLock);
    BOOL result = (remappedClasses(NO) == NULL);
    OBJC_UNLOCK(&remapLock);
    return result;
}


/***********************************************************************
* addRemappedClass
* newcls is a realized future class, replacing oldcls.
* Locking: acquires remapLock
**********************************************************************/
static void addRemappedClass(class_t *oldcls, class_t *newcls)
{
    OBJC_LOCK(&remapLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s", 
                     oldcls, newcls, getName(newcls));
    }

    void *old;
    old = NXMapInsert(remappedClasses(YES), oldcls, newcls);
    assert(!old);

    OBJC_UNLOCK(&remapLock);
}


/***********************************************************************
* remapClass
* Returns the live class pointer for cls, which may be pointing to 
* a class struct that has been reallocated.
* Locking: acquires remapLock
**********************************************************************/
static class_t *remapClass(class_t *cls)
{
    OBJC_LOCK(&remapLock);
    class_t *newcls = NXMapGet(remappedClasses(YES), cls);
    OBJC_UNLOCK(&remapLock);
    return newcls ? newcls : cls;
}


/***********************************************************************
* remapClassRef
* Fix up a class ref, in case the class referenced has been reallocated.
* Locking: acquires remapLock
**********************************************************************/
static void remapClassRef(class_t **clsref)
{
    class_t *newcls = remapClass(*clsref);    
    if (*clsref != newcls) *clsref = newcls;
}


/***********************************************************************
* addSubclass
* Adds subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addSubclass(class_t *supercls, class_t *subcls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (supercls  &&  subcls) {
        assert(isRealized(supercls));
        assert(isRealized(subcls));
        subcls->data->nextSiblingClass = supercls->data->firstSubclass;
        supercls->data->firstSubclass = subcls;
    }
}


/***********************************************************************
* removeSubclass
* Removes subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeSubclass(class_t *supercls, class_t *subcls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    assert(getSuperclass(subcls) == supercls);

    class_t **cp;
    for (cp = &supercls->data->firstSubclass; 
         *cp  &&  *cp != subcls; 
         cp = &(*cp)->data->nextSiblingClass)
        ;
    assert(*cp == subcls);
    *cp = subcls->data->nextSiblingClass;
}



/***********************************************************************
* protocols
* Returns the protocol name => protocol map for protocols.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *protocols(void)
{
    static NXMapTable *protocol_map = NULL;
    
    OBJC_CHECK_LOCKED(&runtimeLock);

    if (protocol_map) return protocol_map;

    // fixme this doesn't work yet
    // class_map starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    protocol_map = NXCreateMapTableFromZone(NXStrValueMapPrototype, 16, 
                                            _objc_internal_zone());

    return protocol_map;
}


/***********************************************************************
* remapProtocol
* Returns the live protocol pointer for proto, which may be pointing to 
* a protocol struct that has been reallocated.
* Locking: fixme
**********************************************************************/
static protocol_t *remapProtocol(protocol_t *proto)
{
    // OBJC_LOCK(&remapLock);
    protocol_t *newproto = NXMapGet(protocols(), proto->name);
    // OBJC_UNLOCK(&remapLock);
    return newproto ? newproto : proto;
}


/***********************************************************************
* remapProtocolRef
* Fix up a protocol ref, in case the protocol referenced has been reallocated.
* Locking: fixme
**********************************************************************/
static void remapProtocolRef(protocol_t **protoref)
{
    protocol_t *newproto = remapProtocol(*protoref);
    if (*protoref != newproto) *protoref = newproto;
}


/***********************************************************************
* moveIvars
* Slides a class's ivars to accommodate the given superclass size.
* Also slides ivar and weak GC layouts if provided.
* Ivars are NOT compacted to compensate for a superclass that shrunk.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void moveIvars(class_ro_t *ro, uint32_t superSize, 
                      layout_bitmap *ivarBitmap, layout_bitmap *weakBitmap)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    uint32_t diff;
    uint32_t gcdiff;
    uint32_t i;

    assert(superSize > ro->instanceStart);
    diff = superSize - ro->instanceStart;
    gcdiff = diff;
    *(uint32_t *)&ro->instanceStart += diff;

    if (ro->ivars) {
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            // naively slide ivar
            uint32_t oldOffset = (uint32_t)*ivar->offset;
            uint32_t newOffset = oldOffset + diff;
            // realign if needed
            uint32_t alignMask = (1<<ivar->alignment)-1;
            if (newOffset & alignMask) {
                uint32_t alignedOffset = (newOffset + alignMask) & ~alignMask;
                assert(alignedOffset > newOffset);
                diff += alignedOffset - newOffset;
                gcdiff += alignedOffset - newOffset;
                newOffset = alignedOffset;
            }
            // newOffset is ready
            *ivar->offset = newOffset;
            // update ivar layouts
            if (gcdiff != 0  &&  (oldOffset & 7) == 0) {
                // this ivar's alignment hasn't been accounted for yet
                if (ivarBitmap) {
                    layout_bitmap_slide(ivarBitmap, 
                                        (newOffset-gcdiff)>>3, newOffset>>3);
                }
                if (weakBitmap) {
                    layout_bitmap_slide(weakBitmap, 
                                        (newOffset-gcdiff)>>3, newOffset>>3);
                }
                gcdiff = 0;
            }

            if (PrintIvars) {
                _objc_inform("IVARS:    offset %u -> %u for %s (size %u, align %u)", 
                             oldOffset, newOffset, ivar->name, 
                             ivar->size, 1<<ivar->alignment);
            }
        }
    }

    *(uint32_t *)&ro->instanceSize += diff;  // diff now includes alignment pad

    if (!ro->ivars) {
        // No ivars slid, but superclass changed size. 
        // Expand bitmap in preparation for layout_bitmap_splat().
        if (ivarBitmap) layout_bitmap_grow(ivarBitmap, ro->instanceSize>>3);
        if (weakBitmap) layout_bitmap_grow(weakBitmap, ro->instanceSize>>3);
    }

#if !__LP64__
#error wrong word size used in this function
#endif
}


/***********************************************************************
* getIvar
* Look up an ivar by name.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static ivar_t *getIvar(class_t *cls, const char *name)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    const ivar_list_t *ivars;
    assert(isRealized(cls));
    if ((ivars = cls->data->ro->ivars)) {
        uint32_t i;
        for (i = 0; i < ivars->count; i++) {
            struct ivar_t *ivar = ivar_list_nth(ivars, i);
            // ivar->name may be NULL for anonymous bitfields etc.
            if (ivar->name  &&  0 == strcmp(name, ivar->name)) {
                return ivar;
            }
        }
    }

    return NULL;
}


/***********************************************************************
* realizeClass
* Performs first-time initialization on class cls, 
* including allocating its read-write data.
* Returns the real class structure for the class. 
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static class_t *realizeClass(class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    const class_ro_t *ro;
    class_rw_t *rw;
    class_t *supercls;
    class_t *metacls;
    BOOL isMeta;

    if (!cls) return NULL;
    if (isRealized(cls)) return cls;
    assert(cls == remapClass(cls));

    ro = (const class_ro_t *)cls->data;

    isMeta = (ro->flags & RO_META) ? YES : NO;

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' %s %p %p", 
                     ro->name, isMeta ? "(meta)" : "", cls, ro);
    }

    // Allocate writeable class data
    rw = _calloc_internal(sizeof(class_rw_t), 1);
    rw->flags = RW_REALIZED;
    rw->version = isMeta ? 7 : 0;  // old runtime went up to 6
    rw->ro = ro;

    cls->data = rw;

    // Realize superclass and metaclass, if they aren't already.
    // This needs to be done after RW_REALIZED is set above, for root classes.
    supercls = realizeClass(remapClass(cls->superclass));
    metacls = realizeClass(remapClass(cls->isa));

    // Check for remapped superclass
    // fixme doesn't handle remapped metaclass
    assert(metacls == cls->isa);
    if (supercls != cls->superclass) {
        cls->superclass = supercls;
    }

    /* debug: print them all
    if (ro->ivars) {
        uint32_t i;
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            _objc_inform("IVARS: %s.%s (offset %u, size %u, align %u)", 
                         ro->name, ivar->name, 
                         *ivar->offset, ivar->size, 1<<ivar->alignment);
        }
    }
    */


    if (supercls) {
        // Non-fragile ivars - reconcile this class with its superclass
        layout_bitmap ivarBitmap;
        layout_bitmap weakBitmap;
        BOOL layoutsChanged = NO;

        if (UseGC) {
            // fixme can optimize for "class has no new ivars", etc
            // WARNING: gcc c++ sets instanceStart/Size=0 for classes with  
            //   no local ivars, but does provide a layout bitmap. 
            //   Handle that case specially so layout_bitmap_create doesn't die
            //   The other ivar sliding code below still works fine, and 
            //   the final result is a good class.
            if (ro->instanceStart == 0  &&  ro->instanceSize == 0) {
                // We can't use ro->ivarLayout because we don't know
                // how long it is. Force a new layout to be created.
                if (PrintIvars) {
                    _objc_inform("IVARS: instanceStart/Size==0 for class %s; "
                                 "disregarding ivar layout", ro->name);
                }
                ivarBitmap = 
                    layout_bitmap_create(NULL, 
                                         supercls->data->ro->instanceSize, 
                                         supercls->data->ro->instanceSize, NO);
                weakBitmap = 
                    layout_bitmap_create(NULL, 
                                         supercls->data->ro->instanceSize, 
                                         supercls->data->ro->instanceSize, YES);
                layoutsChanged = YES;
            } else {
                ivarBitmap = 
                    layout_bitmap_create(ro->ivarLayout, 
                                         ro->instanceSize, 
                                         ro->instanceSize, NO);
                weakBitmap = 
                    layout_bitmap_create(ro->weakIvarLayout, 
                                         ro->instanceSize,
                                         ro->instanceSize, YES);
            }
        }

        if (ro->instanceStart < supercls->data->ro->instanceSize) {
            // Superclass has changed size. This class's ivars must move.
            // Also slide layout bits in parallel.
            // This code is incapable of compacting the subclass to 
            //   compensate for a superclass that shrunk, so don't do that.
            if (PrintIvars) {
                _objc_inform("IVARS: sliding ivars for class %s "
                             "(superclass was %u bytes, now %u)", 
                             ro->name, ro->instanceStart, 
                             supercls->data->ro->instanceSize);
            }
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            moveIvars(ro_w, supercls->data->ro->instanceSize, 
                      UseGC ? &ivarBitmap : NULL, UseGC ? &weakBitmap : NULL);
            layoutsChanged = YES;
        } 
        
        if (UseGC) {
            // Check superclass's layout against this class's layout.
            // This needs to be done even if the superclass is not bigger.
            layout_bitmap superBitmap = 
                layout_bitmap_create(supercls->data->ro->ivarLayout, 
                                     supercls->data->ro->instanceSize, 
                                     supercls->data->ro->instanceSize, NO);
            layoutsChanged |= layout_bitmap_splat(ivarBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);

            superBitmap = 
                layout_bitmap_create(supercls->data->ro->weakIvarLayout, 
                                     supercls->data->ro->instanceSize, 
                                     supercls->data->ro->instanceSize, YES);
            layoutsChanged |= layout_bitmap_splat(weakBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);

            if (layoutsChanged) {
                // Rebuild layout strings. 
                if (PrintIvars) {
                    _objc_inform("IVARS: gc layout changed for class %s",
                                 ro->name);
                }
                class_ro_t *ro_w = make_ro_writeable(rw);
                ro = rw->ro;
                ro_w->ivarLayout = layout_string_create(ivarBitmap);
                ro_w->weakIvarLayout = layout_string_create(weakBitmap);
            }

            layout_bitmap_free(ivarBitmap);
            layout_bitmap_free(weakBitmap);
        }
    }

    // Connect this class to its superclass's subclass lists
    if (supercls) {
        addSubclass(supercls, cls);
    }

    if (!isMeta) {
        addRealizedClass(cls, cls->data->ro->name);
    } else {
        // metaclasses don't go in the realized class map
    }

    return cls;
}


/***********************************************************************
* getClass
* Looks up a class by name with no hints, and realizes it.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static class_t *getClass(const char *name)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    class_t *result;

    // Try realized classes
    result = (class_t *)NXMapGet(realizedClasses(), name);
    if (result) return result;

    // Try unrealized classes
    result = (class_t *)NXMapGet(unrealizedClasses(), name);
    if (result) return result;

#if 0
    // Try a classname symbol
    result = getClassBySymbol(NULL, name);
    if (result) {
        result = realizeClass(remapClass(result));
        return result;
    }

    if (!result) {
        // fixme suck
        realizeAllClasses();
        result = (class_t *)NXMapGet(realizedClasses(), name);
    }
#endif


    // darn
    return NULL;
}


/***********************************************************************
* realizeAllClassesInImage
* Non-lazily realizes all unrealized classes in the given image.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClassesInImage(header_info *hi)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    size_t count, i;
    class_t **classlist;

    if (hi->allClassesRealized) return;

    classlist = _getObjc2ClassList(hi, &count);

    for (i = 0; i < count; i++) {
        realizeClass(remapClass(classlist[i]));
    }

    hi->allClassesRealized = YES;
}


/***********************************************************************
* realizeAllClasses
* Non-lazily realizes all unrealized classes in all known images.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClasses(void)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    header_info *hi;
    for (hi = _objc_headerStart(); hi; hi = hi->next) {
        realizeAllClassesInImage(hi);
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Class _objc_allocateFutureClass(const char *name)
{
    OBJC_LOCK(&runtimeLock);

    struct class_t *cls;
    NXMapTable *future_class_map = futureClasses();

    if ((cls = NXMapGet(future_class_map, name))) {
        // Already have a future class for this name.
        OBJC_UNLOCK(&runtimeLock);
        return (Class)cls;
    }

    cls = _calloc_internal(sizeof(*cls), 1);
    addFutureClass(name, cls);

    OBJC_UNLOCK(&runtimeLock);
    return (Class)cls;
}


/***********************************************************************
* 
**********************************************************************/
void objc_setFutureClass(Class cls, const char *name)
{
    // fixme hack do nothing - NSCFString handled specially elsewhere
}


static BOOL addrInSeg(const void *addr_ptr, const segmentType *segment, 
                      ptrdiff_t slide)
{
    uintptr_t base = segment->vmaddr + slide;
    uintptr_t addr = (uintptr_t)addr_ptr;
    size_t size = segment->filesize;

    return (addr >= base  &&  addr < base + size);
}

static BOOL ptrInImageList(header_info **hList, uint32_t hCount, 
                           const void *ptr)
{
    uint32_t i;

    for (i = 0; i < hCount; i++) {
        header_info *hi = hList[i];
        if (addrInSeg(ptr, hi->dataSegmentHeader, hi->image_slide)) {
            return YES;
        }
    }

    return NO;
}


#define FOREACH_SUBCLASS(c, cls, code) \
do { \
    OBJC_CHECK_LOCKED(&runtimeLock); \
    class_t *top = cls; \
    class_t *c = top; \
    if (c) while (1) { \
        code \
        if (c->data->firstSubclass) { \
            c = c->data->firstSubclass; \
        } else { \
            while (!c->data->nextSiblingClass  &&  c != top) { \
                c = getSuperclass(c); \
            } \
            if (c == top) break; \
            c = c->data->nextSiblingClass; \
        } \
    } \
} while (0)


/***********************************************************************
* flushCaches
* Flushes caches for cls and its subclasses.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void flushCaches(class_t *cls)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    FOREACH_SUBCLASS(c, cls, {
        flush_cache((Class)c);
    });
}


/***********************************************************************
* flush_caches
* Flushes caches for cls, its subclasses, and optionally its metaclass.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ void flush_caches(Class cls, BOOL flush_meta)
{
    OBJC_LOCK(&runtimeLock);
    flushCaches(newcls(cls));
    if (flush_meta) flushCaches(newcls(cls)->isa);
    OBJC_UNLOCK(&runtimeLock);
}


/***********************************************************************
* _read_images
* Perform initial processing of the headers in the linked 
* list beginning with headerList. 
*
* Called by: map_images
*
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ void _read_images(header_info **hList, uint32_t hCount)
{
    header_info *hi;
    uint32_t hIndex;
    size_t count;
    size_t i, j;
    class_t **resolvedFutureClasses = NULL;
    size_t resolvedFutureClassCount = 0;

#define EACH_HEADER \
    hIndex = 0; \
    hIndex < hCount && (hi = hList[hIndex]);    \
    hIndex++

    OBJC_LOCK(&runtimeLock);
    
    // Complain about images that contain old-ABI data
    // fixme new-ABI compiler still emits some bits into __OBJC segment
    for (EACH_HEADER) {
        size_t count;
        if (_getObjcSelectorRefs(hi, &count)  || 
            _getObjcModules(hi->mhdr, hi->image_slide, &count)) 
        {
            _objc_inform("found old-ABI metadata in image %s !", 
                         hi->dl_info.dli_fname);
        }
    }

    // fixme hack
    static BOOL hackedNSCFString = NO;
    if (!hackedNSCFString) {
        // Insert future class __CFConstantStringClassReference == NSCFString
        void *dlh = dlopen("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
        if (dlh) {
            void *addr = dlsym(dlh, "__CFConstantStringClassReference");
            if (addr) {
                addFutureClass("NSCFString", (class_t *)addr);
                hackedNSCFString = YES;
            }
            dlclose(dlh);
        }
    }

    // Discover classes. Fix up unresolved future classes
    NXMapTable *future_class_map = futureClasses();
    for (EACH_HEADER) {
        class_t **classlist = _getObjc2ClassList(hi, &count);
        for (i = 0; i < count; i++) {
            const char *name = getName(classlist[i]);
            if (NXCountMapTable(future_class_map) > 0) {
                class_t *newCls = NXMapGet(future_class_map, name);
                if (newCls) {
                    memcpy(newCls, classlist[i], sizeof(class_t));
                    removeFutureClass(name);
                    addRemappedClass(classlist[i], newCls);
                    classlist[i] = newCls;
                    // Non-lazily realize the class below.
                    resolvedFutureClasses = (class_t **)
                        _realloc_internal(resolvedFutureClasses, 
                                          (resolvedFutureClassCount+1) 
                                          * sizeof(class_t *));
                    resolvedFutureClasses[resolvedFutureClassCount++] = newCls;
                }
            }
            addUnrealizedClass(classlist[i], name);
            addUninitializedClass(classlist[i], classlist[i]->isa);
        }
    }

    // Fix up remapped classes
    // classlist is up to date, but classrefs may not be
    
    if (!noClassesRemapped()) {
        for (EACH_HEADER) {
            class_t **classrefs = _getObjc2ClassRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
            // fixme why doesn't test future1 catch the absence of this?
            classrefs = _getObjc2SuperRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
        }
    }


    // Fix up @selector references
    sel_lock();
    for (EACH_HEADER) {
        SEL *sels = _getObjc2SelectorRefs(hi, &count);
        BOOL isBundle = hi->mhdr->filetype == MH_BUNDLE;
        for (i = 0; i < count; i++) {
            sels[i] = sel_registerNameNoLock((const char *)sels[i], isBundle);
        }
    }
    sel_unlock();

    // Discover protocols. Fix up protocol refs.
    NXMapTable *protocol_map = protocols();
    for (EACH_HEADER) {
        extern struct class_t OBJC_CLASS_$_Protocol;
        Class cls = (Class)&OBJC_CLASS_$_Protocol;
        assert(cls);
        protocol_t **protocols = _getObjc2ProtocolList(hi, &count);
        // fixme duplicate protocol from bundle
        for (i = 0; i < count; i++) {
            if (!NXMapGet(protocol_map, protocols[i]->name)) {
                protocols[i]->isa = cls;
                NXMapKeyCopyingInsert(protocol_map, 
                                      protocols[i]->name, protocols[i]);
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s",
                                 protocols[i], protocols[i]->name);
                }
            } else {
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s (duplicate)",
                                 protocols[i], protocols[i]->name);
                }
            }
        }
    }
    for (EACH_HEADER) {
        protocol_t **protocols;
        protocols = _getObjc2ProtocolRefs(hi, &count);
        for (i = 0; i < count; i++) {
            remapProtocolRef(&protocols[i]);
        }

        protocols = _getObjc2ProtocolList(hi, &count);
        for (i = 0; i < count; i++) {
            protocol_t *protocol = NXMapGet(protocol_map, protocols[i]->name);
            assert(protocol);
            if (protocol == protocols[i]  &&  protocol->protocols) {
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: remapping superprotocols of %p %s", 
                                 protocol, protocol->name);
                }
                for (j = 0; j < protocol->protocols->count; j++) {
                    remapProtocolRef(&protocol->protocols->list[j]);
                }
            }
        }
    }

    // Discover categories. 
    for (EACH_HEADER) {
        category_t **catlist = 
            _getObjc2CategoryList(hi, &count);
        for (i = 0; i < count; i++) {
            category_t *cat = catlist[i];
            // Do NOT use cat->cls! It may have been remapped.
            class_t *cls = remapClass(cat->cls);

            // Process this category. 
            // First, register the category with its target class. 
            // Then, flush the class's cache (and its subclasses) if 
            // the class is methodized. The ptrInImageList() check 
            // can discover !methodized without touching the class's memory.
            // GrP fixme class's memory is already touched.
            BOOL classExists = NO;
            if (cat->instanceMethods ||  cat->protocols  
                ||  cat->instanceProperties) 
            {
                addUnattachedCategoryForClass(cat, cls);
                if (!ptrInImageList(hList, hCount, cls)  &&  
                    isMethodized(cls))
                {
                    flushCaches(cls);
                    classExists = YES;
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category -%s(%s) %s\n", 
                                 getName(cls), cat->name, 
                                 classExists ? "on existing class" : "");
                }
            }

            if (cat->classMethods  ||  cat->protocols  
                /* ||  cat->classProperties */) 
            {
                addUnattachedCategoryForClass(cat, cls->isa);
                if (!ptrInImageList(hList, hCount, cls->isa)  &&  
                    isRealized(cls->isa))
                {
                    flushCaches(cls->isa);
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category +%s(%s)", 
                                 getName(cls), cat->name);
                }
            }
        }
    }


    // Realize non-lazy classes (for +load methods and static instances)

    for (EACH_HEADER) {
        class_t **classlist = 
            _getObjc2NonlazyClassList(hi, &count);
        for (i = 0; i < count; i++) {
            realizeClass(remapClass(classlist[i]));
        }
    }    

    // Realize newly-resolved future classes, in case CF manipulates them
    if (resolvedFutureClasses) {
        for (i = 0; i < resolvedFutureClassCount; i++) {
            realizeClass(resolvedFutureClasses[i]);
        }
        _free_internal(resolvedFutureClasses);
    }    

    // +load handled by prepare_load_methods()    


    OBJC_UNLOCK(&runtimeLock);

#undef EACH_HEADER
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed 
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
static void schedule_class_load(class_t *cls)
{
    assert(isRealized(cls));  // _read_images should realize

    if (cls->data->flags & RW_LOADED) return;

    class_t *supercls = getSuperclass(cls);
    if (supercls) schedule_class_load(supercls);

    add_class_to_loadable_list((Class)cls);
    changeInfo(cls, RW_LOADED, 0); 
}

__private_extern__ void prepare_load_methods(header_info *hi)
{
    size_t count, i;

    OBJC_LOCK(&runtimeLock);

    class_t **classlist = 
        _getObjc2NonlazyClassList(hi, &count);
    for (i = 0; i < count; i++) {
        class_t *cls = remapClass(classlist[i]);
        schedule_class_load(cls);
    }

    category_t **categorylist = _getObjc2NonlazyCategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = categorylist[i];
        // Do NOT use cat->cls! It may have been remapped.
        class_t *cls = remapClass(cat->cls);
        realizeClass(cls);
        assert(isRealized(cls->isa));
        add_category_to_loadable_list((Category)cat);
    }

    OBJC_UNLOCK(&runtimeLock);
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
**********************************************************************/
__private_extern__ void _unload_image(header_info *hi)
{
    size_t count, i;

    OBJC_LOCK(&runtimeLock);

    // Unload unattached categories and categories waiting for +load.

    category_t **catlist = _getObjc2CategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = catlist[i];
        class_t *cls = remapClass(cat->cls);
        // fixme for MH_DYLIB cat's class may have been unloaded already

        // unattached list
        removeUnattachedCategoryForClass(cat, cls);

        // +load queue
        remove_category_from_loadable_list((Category)cat);
    }

    // Unload classes.

    class_t **classlist = _getObjc2ClassList(hi, &count);
    for (i = 0; i < count; i++) {
        class_t *cls = classlist[i];
        const char *name = getName(cls);
        // fixme remapped classes?

        // +load queue
        remove_class_from_loadable_list((Class)cls);

        // categories not yet attached to this class
        category_list *cats;
        cats = unattachedCategoriesForClass(cls);
        if (cats) free(cats);
        cats = unattachedCategoriesForClass(cls);
        if (cats) free(cats);

        // subclass lists
        class_t *supercls;
        if ((supercls = getSuperclass(cls))) {
            removeSubclass(supercls, cls);
        }
        if ((supercls = getSuperclass(cls->isa))) {
            removeSubclass(supercls, cls->isa);
        }
        
        // class tables
        NXMapRemove(unrealizedClasses(), name);
        NXMapRemove(realizedClasses(), name);
        NXMapRemove(uninitializedClasses(), cls->isa);

        // the class itself
        if (isRealized(cls->isa)) unload_class(cls->isa);
        if (isRealized(cls)) unload_class(cls);
    }
    
    // Clean up protocols.
#warning fixme protocol unload

    // fixme DebugUnload

    OBJC_UNLOCK(&runtimeLock);
}


/***********************************************************************
* method_getDescription
* Returns a pointer to this method's objc_method_description.
* Locking: none
**********************************************************************/
struct objc_method_description *
method_getDescription(Method m)
{
    if (!m) return NULL;
    return (struct objc_method_description *)newmethod(m);
}


/***********************************************************************
* method_getImplementation
* Returns this method's IMP.
* Locking: none
**********************************************************************/
IMP 
method_getImplementation(Method m)
{
    if (!m) return NULL;
    if (newmethod(m)->name == (SEL)kRTAddress_ignoredSelector) {
        return (IMP)_objc_ignored_method;
    }
    return newmethod(m)->imp;
}


/***********************************************************************
* method_getName
* Returns this method's selector.
* The method must not be NULL.
* The method must already have been fixed-up.
* Locking: none
**********************************************************************/
SEL 
method_getName(Method m_gen)
{
    struct method_t *m = newmethod(m_gen);
    if (!m) return NULL;
    assert((SEL)m->name == sel_registerName((char *)m->name));
    return (SEL)m->name;
}


/***********************************************************************
* method_getTypeEncoding
* Returns this method's old-style type encoding string.
* The method must not be NULL.
* Locking: none
**********************************************************************/
const char *
method_getTypeEncoding(Method m)
{
    if (!m) return NULL;
    return newmethod(m)->types;
}


/***********************************************************************
* method_setImplementation
* Sets this method's implementation to imp.
* The previous implementation is returned.
**********************************************************************/
IMP 
method_setImplementation(Method m, IMP imp)
{
    static OBJC_DECLARE_LOCK(impLock);
    IMP old;

    OBJC_LOCK(&impLock);
    old = method_getImplementation(m);
    newmethod(m)->imp = imp;
    OBJC_UNLOCK(&impLock);

    // No cache flushing needed.
    // fixme update vtables if necessary
    // fixme update monomorphism if necessary
    return old;
}


/***********************************************************************
* _class_realize
* Realizes the given class.
* Called by _class_lookupMethodAndLoadCache only.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ void
_class_realize(struct class_t *cls)
{
    OBJC_LOCK(&runtimeLock);
    realizeClass(cls);
    OBJC_UNLOCK(&runtimeLock);
}



/***********************************************************************
* ivar_getOffset
* fixme
* Locking: none
**********************************************************************/
ptrdiff_t
ivar_getOffset(Ivar ivar)
{
    if (!ivar) return 0;
    return *newivar(ivar)->offset;
}


/***********************************************************************
* ivar_getName
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getName(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->name;
}


/***********************************************************************
* ivar_getTypeEncoding
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getTypeEncoding(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->type;
}


/***********************************************************************
* _protocol_getMethod_nolock
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static Method 
_protocol_getMethod_nolock(protocol_t *proto, SEL sel, 
                           BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    uint32_t i;
    if (!proto  ||  !sel) return NULL;

    method_list_t *mlist = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlist = proto->instanceMethods;
        } else {
            mlist = proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlist = proto->optionalInstanceMethods;
        } else {
            mlist = proto->optionalClassMethods;
        }
    }

    if (mlist) {
        for (i = 0; i < mlist->count; i++) {
            method_t *m = method_list_nth(mlist, i);
            if (sel != m->name) {
                m->name = sel_registerName((char *)m->name);
            }
            if (sel == m->name) {
                return (Method)m;
            }
        }
    }

    if (proto->protocols) {
        Method m;
        for (i = 0; i < proto->protocols->count; i++) {
            protocol_t *realProto = remapProtocol(proto->protocols->list[i]);
            m = _protocol_getMethod_nolock(realProto, sel, 
                                           isRequiredMethod, isInstanceMethod);
            if (m) return m;
        }
    }

    return NULL;
}


/***********************************************************************
* _protocol_getMethod
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Method 
_protocol_getMethod(Protocol *p, SEL sel, BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    OBJC_LOCK(&runtimeLock);
    Method result = _protocol_getMethod_nolock(newprotocol(p), sel, 
                                               isRequiredMethod,
                                               isInstanceMethod);
    OBJC_UNLOCK(&runtimeLock);
    return result;
}


/***********************************************************************
* protocol_getName
* Returns the name of the given protocol.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
const char *
protocol_getName(Protocol *proto)
{
    return newprotocol(proto)->name;
}


/***********************************************************************
* protocol_getInstanceMethodDescription
* Returns the description of a named instance method.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
struct objc_method_description 
protocol_getMethodDescription(Protocol *p, SEL aSel, 
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    Method m = 
        _protocol_getMethod(p, aSel, isRequiredMethod, isInstanceMethod);
    if (m) return *method_getDescription(m);
    else return (struct objc_method_description){NULL, NULL};
}


/***********************************************************************
* protocol_conformsToProtocol
* Returns YES if self conforms to other.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
BOOL protocol_conformsToProtocol(Protocol *self_gen, Protocol *other_gen)
{
    protocol_t *self = newprotocol(self_gen);
    protocol_t *other = newprotocol(other_gen);

    if (!self  ||  !other) {
        return NO;
    }

    if (0 == strcmp(self->name, other->name)) {
        return YES;
    }

    if (self->protocols) {
        int i;
        for (i = 0; i < self->protocols->count; i++) {
            protocol_t *proto = self->protocols->list[i];
            if (0 == strcmp(other->name, proto->name)) {
                return YES;
            }
            if (protocol_conformsToProtocol((Protocol *)proto, other_gen)) {
                return YES;
            }
        }
    }

    return NO;
}


/***********************************************************************
* protocol_isEqual
* Return YES if two protocols are equal (i.e. conform to each other)
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES;
    if (!self  ||  !other) return NO;

    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns descriptions of a protocol's methods.
* Locking: acquires runtimeLock
**********************************************************************/
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p, 
                                   BOOL isRequiredMethod,BOOL isInstanceMethod,
                                   unsigned int *outCount)
{
    struct protocol_t *proto = newprotocol(p);
    struct objc_method_description *result = NULL;
    unsigned int count = 0;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    method_list_t *mlist = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlist = proto->instanceMethods;
        } else {
            mlist = proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlist = proto->optionalInstanceMethods;
        } else {
            mlist = proto->optionalClassMethods;
        }
    }

    if (mlist) {
        unsigned int i;
        count = mlist->count;
        result = calloc(count + 1, sizeof(struct objc_method_description));
        for (i = 0; i < count; i++) {
            method_t *m = method_list_nth(mlist, i);
            result[i].name = sel_registerName((const char *)m->name);
            result[i].types = (char *)m->types;
        }
    }

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* protocol_getProperty
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static Property 
_protocol_getProperty_nolock(protocol_t *proto, const char *name, 
                             BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!isRequiredProperty  ||  !isInstanceProperty) {
        // Only required instance properties are currently supported
        return NULL;
    }

    struct objc_property_list *plist;
    if ((plist = proto->instanceProperties)) {
        uint32_t i;
        for (i = 0; i < plist->count; i++) {
            Property prop = property_list_nth(plist, i);
            if (0 == strcmp(name, prop->name)) {
                return prop;
            }
        }
    }

    if (proto->protocols) {
        uintptr_t i;
        for (i = 0; i < proto->protocols->count; i++) {
            Property prop = 
                _protocol_getProperty_nolock(proto->protocols->list[i], name, 
                                             isRequiredProperty, 
                                             isInstanceProperty);
            if (prop) return prop;
        }
    }

    return NULL;
}

Property protocol_getProperty(Protocol *p, const char *name, 
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    Property result;

    if (!p  ||  !name) return NULL;

    OBJC_LOCK(&runtimeLock);
    result = _protocol_getProperty_nolock(newprotocol(p), name, 
                                          isRequiredProperty, 
                                          isInstanceProperty);
    OBJC_UNLOCK(&runtimeLock);
    
    return result;
}


/***********************************************************************
* protocol_copyPropertyList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Property *protocol_copyPropertyList(Protocol *proto, unsigned int *outCount)
{
    Property *result = NULL;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    struct objc_property_list *plist = newprotocol(proto)->instanceProperties;
    result = copyPropertyList(plist, outCount);

    OBJC_UNLOCK(&runtimeLock);

    return result;
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols. 
* Does not copy those protocol's incorporated protocols in turn.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol **protocol_copyProtocolList(Protocol *p, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = NULL;
    protocol_t *proto = newprotocol(p);
    
    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    if (proto->protocols) {
        count = (unsigned int)proto->protocols->count;
    }
    if (count > 0) {
        result = malloc((count+1) * sizeof(Protocol *));

        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)remapProtocol(proto->protocols->list[i]);
        }
        result[i] = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
* Locking: acquires runtimeLock
**********************************************************************/
int 
objc_getClassList(Class *buffer, int bufferLen) 
{
    OBJC_LOCK(&runtimeLock);

    int count;
    Class cls;
    const char *name;
    NXMapState state;
    NXMapTable *classes = realizedClasses();
    NXMapTable *unrealized = unrealizedClasses();

    if (!buffer) {
        count = NXCountMapTable(classes) + NXCountMapTable(unrealized);
        OBJC_UNLOCK(&runtimeLock);
        return count;
    }

    if (bufferLen > NXCountMapTable(classes)  &&
        NXCountMapTable(unrealized) != 0) 
    {
        // bummer
        realizeAllClasses();
    }

    count = 0;
    state = NXInitMapState(classes);
    while (count < bufferLen  &&  
           NXNextMapState(classes, &state, 
                          (const void **)&name, (const void **)&cls))
    {
        buffer[count++] = (Class)cls;
    }

    OBJC_UNLOCK(&runtimeLock);

    return count;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol **
objc_copyProtocolList(unsigned int *outCount) 
{
    OBJC_LOCK(&runtimeLock);

    int count, i;
    Protocol *proto;
    const char *name;
    NXMapState state;
    NXMapTable *protocol_map = protocols();
    Protocol **result;

    count = NXCountMapTable(protocol_map);
    if (count == 0) {
        OBJC_UNLOCK(&runtimeLock);
        if (outCount) *outCount = 0;
        return NULL;
    }

    result = calloc(1 + count, sizeof(Protocol *));

    i = 0;
    state = NXInitMapState(protocol_map);
    while (NXNextMapState(protocol_map, &state, 
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }
    
    result[i++] = NULL;
    assert(i == count+1);

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or return NULL
* Locking: acquires runtimeLock
**********************************************************************/
Protocol *objc_getProtocol(const char *name)
{
    OBJC_LOCK(&runtimeLock); 
    Protocol *result = (Protocol *)NXMapGet(protocols(), name);
    OBJC_UNLOCK(&runtimeLock);
    return result;
}


/***********************************************************************
* class_copyMethodList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Method *
class_copyMethodList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    chained_method_list *mlist;
    unsigned int count = 0;
    Method *result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);
    
    assert(isRealized(cls));

    methodizeClass(cls);

    for (mlist = cls->data->methods; mlist; mlist = mlist->next) {
        count += mlist->count;
    }

    if (count > 0) {
        unsigned int m;
        result = malloc((count + 1) * sizeof(Method));
        
        m = 0;
        for (mlist = cls->data->methods; mlist; mlist = mlist->next) {
            unsigned int i;
            for (i = 0; i < mlist->count; i++) {
                result[m++] = (Method)&mlist->list[i];
            }
        }
        result[m] = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyIvarList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Ivar *
class_copyIvarList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    const ivar_list_t *ivars;
    Ivar *result = NULL;
    unsigned int count = 0;
    unsigned int i;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));
    
    if ((ivars = cls->data->ro->ivars)  &&  (count = ivars->count)) {
        result = malloc((count+1) * sizeof(Ivar));
        
        for (i = 0; i < ivars->count; i++) {
            result[i] = (Ivar)ivar_list_nth(ivars, i);
        }
        result[i] = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);
    
    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the 
* properties declared in the class, or NULL if the class 
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
* Locking: acquires runtimeLock
**********************************************************************/
Property *
class_copyPropertyList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    chained_property_list *plist;
    unsigned int count = 0;
    Property *result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));

    // Attach any categories because they may provide more properties
    methodizeClass(cls);

    for (plist = cls->data->properties; plist; plist = plist->next) {
        count += plist->count;
    }

    if (count > 0) {
        unsigned int p;
        result = malloc((count + 1) * sizeof(Property));
        
        p = 0;
        for (plist = cls->data->properties; plist; plist = plist->next) {
            unsigned int i;
            for (i = 0; i < plist->count; i++) {
                result[p++] = (Property)&plist->list[i];
            }
        }
        result[p] = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* _class_getLoadMethod
* fixme
* Called only from add_class_to_loadable_list.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
__private_extern__ IMP 
_class_getLoadMethod(Class cls_gen)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    struct class_t *cls = newcls(cls_gen);
    const method_list_t *mlist;
    int i;

    assert(isRealized(cls));
    assert(isRealized(cls->isa));
    assert(!isMethodized(cls));
    assert(!isMethodized(cls->isa));
    assert(!isMetaClass(cls));
    assert(isMetaClass(cls->isa));

    mlist = cls->isa->data->ro->baseMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* _category_getName
* Returns a category's name.
* Locking: none
**********************************************************************/
__private_extern__ const char *
_category_getName(Category cat)
{
    return newcategory(cat)->name;
}


/***********************************************************************
* _category_getClassName
* Returns a category's class's name
* Called only from add_category_to_loadable_list and 
* remove_category_from_loadable_list.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
__private_extern__ const char *
_category_getClassName(Category cat)
{
    OBJC_CHECK_LOCKED(&runtimeLock);
    // cat->cls may have been remapped
    return getName(remapClass(newcategory(cat)->cls));
}


/***********************************************************************
* _category_getClass
* Returns a category's class
* Called only by call_category_loads.
* Locking: none
**********************************************************************/
__private_extern__ Class 
_category_getClass(Category cat)
{
    // cat->cls may have been remapped
    struct class_t *result = remapClass(newcategory(cat)->cls);
    assert(isRealized(result));  // ok for call_category_loads' usage
    return (Class)result;
}


/***********************************************************************
* _category_getLoadMethod
* fixme
* Called only from add_category_to_loadable_list
* Locking: runtimeLock must be held by the caller
**********************************************************************/
__private_extern__ IMP 
_category_getLoadMethod(Category cat)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    const method_list_t *mlist;
    int i;

    mlist = newcategory(cat)->classMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* class_copyProtocolList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Protocol **
class_copyProtocolList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    Protocol **r;
    struct protocol_list_t **p;
    unsigned int count = 0;
    unsigned int i;
    Protocol **result = NULL;
    
    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));
    
    // Attach any categories because they may provide more protocols
    methodizeClass(cls);
    
    for (p = cls->data->protocols; p  &&  *p; p++) {
        count += (uint32_t)(*p)->count;
    }

    if (count) {
        result = malloc((count+1) * sizeof(Protocol *));
        r = result;
        for (p = cls->data->protocols; p  &&  *p; p++) {
            for (i = 0; i < (*p)->count; i++) {
                *r++ = (Protocol *)remapProtocol((*p)->list[i]);
            }
        }
        *r++ = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* _objc_copyClassNamesForImage
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ const char **
_objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount)
{
    size_t count, i;
    class_t **classlist;
    const char **names;
    
    OBJC_LOCK(&runtimeLock);
    
    classlist = _getObjc2ClassList(hi, &count);
    names = malloc((count+1) * sizeof(const char *));
    
    for (i = 0; i < count; i++) {
        names[i] = getName(classlist[i]);
    }
    names[count] = NULL;

    OBJC_UNLOCK(&runtimeLock);

    if (outCount) *outCount = (unsigned int)count;
    return names;
}


/***********************************************************************
* _class_getCache
* fixme
* Locking: none
**********************************************************************/
__private_extern__ Cache 
_class_getCache(Class cls)
{
    return newcls(cls)->cache;
}


/***********************************************************************
* _class_getInstanceSize
* fixme
* Locking: none
**********************************************************************/
__private_extern__ size_t 
_class_getInstanceSize(Class cls)
{
    if (!cls) return 0;
    return instanceSize(newcls(cls));
}

static uint32_t
instanceSize(struct class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    // fixme rdar://5244378
    return (uint32_t)((cls->data->ro->instanceSize + 7) & ~7UL);
}


/***********************************************************************
* class_getVersion
* fixme
* Locking: none
**********************************************************************/
int 
class_getVersion(Class cls)
{
    if (!cls) return 0;
    assert(isRealized(newcls(cls)));
    return newcls(cls)->data->version;
}


/***********************************************************************
* _class_setCache
* fixme
* Locking: none
**********************************************************************/
__private_extern__ void 
_class_setCache(Class cls, Cache cache)
{
    newcls(cls)->cache = cache;
}


/***********************************************************************
* class_setVersion
* fixme
* Locking: none
**********************************************************************/
void 
class_setVersion(Class cls, int version)
{
    if (!cls) return;
    assert(isRealized(newcls(cls)));
    newcls(cls)->data->version = version;
}


/***********************************************************************
* _class_getName
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ const char *_class_getName(Class cls)
{
    if (!cls) return "nil";
    // fixme hack OBJC_LOCK(&runtimeLock);
    const char *name = getName(newcls(cls));
    // OBJC_UNLOCK(&runtimeLock);
    return name;
}


/***********************************************************************
* getName
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static const char *
getName(struct class_t *cls)
{
    // fixme hack OBJC_CHECK_LOCKED(&runtimeLock);
    assert(cls);

    if (isRealized(cls)) {
        return cls->data->ro->name;
    } else {
        return ((const struct class_ro_t *)cls->data)->name;
    }
}


/***********************************************************************
* _class_getMethodNoSuper_nolock
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static Method 
_class_getMethodNoSuper_nolock(struct class_t *cls, SEL sel)
{
    OBJC_CHECK_LOCKED(&runtimeLock);

    chained_method_list *mlist;
    uint32_t i;

    assert(isRealized(cls));
    // fixme nil cls? 
    // fixme NULL sel?

    methodizeClass(cls);

    for (mlist = cls->data->methods; mlist; mlist = mlist->next) {
        for (i = 0; i < mlist->count; i++) {
            method_t *m = &mlist->list[i];
            if (m->name == sel) return (Method)m;
        }
    }

    return NULL;
}


/***********************************************************************
* _class_getMethodNoSuper
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Method 
_class_getMethodNoSuper(Class cls, SEL sel)
{
    OBJC_LOCK(&runtimeLock);
    Method result = _class_getMethodNoSuper_nolock(newcls(cls), sel);
    OBJC_UNLOCK(&runtimeLock);
    return result;
}


/***********************************************************************
* _class_getMethod
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Method _class_getMethod(Class cls, SEL sel)
{
    Method m = NULL;

    // fixme nil cls?
    // fixme NULL sel?

    assert(isRealized(newcls(cls)));

    while (cls  &&  ((m = _class_getMethodNoSuper(cls, sel))) == NULL) {
        cls = class_getSuperclass(cls);
    }

    return m;
}


/***********************************************************************
* class_getProperty
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Property class_getProperty(Class cls_gen, const char *name)
{
    Property result = NULL;
    chained_property_list *plist;
    struct class_t *cls = newcls(cls_gen);

    if (!cls  ||  !name) return NULL;

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));
    methodizeClass(cls);

    for ( ; cls; cls = getSuperclass(cls)) {
        for (plist = cls->data->properties; plist; plist = plist->next) {
            uint32_t i;
            for (i = 0; i < plist->count; i++) {
                if (0 == strcmp(name, plist->list[i].name)) {
                    result = &plist->list[i];
                    goto done;
                }
            }
        }
    }

 done:
    OBJC_UNLOCK(&runtimeLock);

    return result;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL _class_isMetaClass(Class cls)
{
    if (!cls) return NO;
    return isMetaClass(newcls(cls));
}

static BOOL 
isMetaClass(struct class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    return (cls->data->ro->flags & RO_META) ? YES : NO;
}


__private_extern__ Class _class_getMeta(Class cls)
{
    assert(cls);
    if (isMetaClass(newcls(cls))) return cls;
    else return ((id)cls)->isa;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_isInitializing(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data->flags & RW_INITIALIZING) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_isInitialized(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data->flags & RW_INITIALIZED) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void 
_class_setInitializing(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    changeInfo(cls, RW_INITIALIZING, 0);
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void 
_class_setInitialized(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    changeInfo(cls, RW_INITIALIZED, RW_INITIALIZING);
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_shouldGrowCache(Class cls)
{
    return YES; // fixme good or bad for memory use?
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void 
_class_setGrowCache(Class cls, BOOL grow)
{
    // fixme good or bad for memory use?
}


/***********************************************************************
* _class_isLoadable
* fixme
* Locking: none
**********************************************************************/
__private_extern__ BOOL 
_class_isLoadable(Class cls)
{
    assert(isRealized(newcls(cls)));
    return YES;  // any class registered for +load is definitely loadable
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_hasCxxStructorsNoSuper(Class cls)
{
    assert(isRealized(newcls(cls)));
    return (newcls(cls)->data->ro->flags & RO_HAS_CXX_STRUCTORS) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL
_class_shouldFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    return (newcls(cls)->data->flags & RW_FINALIZE_ON_MAIN_THREAD) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void
_class_setFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    changeInfo(newcls(cls), RW_FINALIZE_ON_MAIN_THREAD, 0);
}


/***********************************************************************
* Locking: none
* fixme assert realized to get superclass remapping?
**********************************************************************/
__private_extern__ Class 
_class_getSuperclass(Class cls)
{
    return (Class)getSuperclass(newcls(cls));
}

static struct class_t *
getSuperclass(struct class_t *cls)
{
    if (!cls) return NULL;
    return cls->superclass;
}


/***********************************************************************
* class_getIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const char *
class_getIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return (const char *)cls->data->ro->ivarLayout;
    else return NULL;
}


/***********************************************************************
* class_getWeakIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const char *
class_getWeakIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return (const char *)cls->data->ro->weakIvarLayout;
    else return NULL;
}


/***********************************************************************
* class_setIvarLayout
* Changes the class's GC scan layout.
* NULL layout means no unscanned ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setIvarLayout(Class cls_gen, const char *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    OBJC_LOCK(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set ivar layout for already-registered "
                     "class '%s'", getName(cls));
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    try_free(ro_w->ivarLayout);
    ro_w->ivarLayout = (unsigned char *)_strdup_internal(layout);

    OBJC_UNLOCK(&runtimeLock);
}


/***********************************************************************
* class_setWeakIvarLayout
* Changes the class's GC weak layout.
* NULL layout means no weak ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setWeakIvarLayout(Class cls_gen, const char *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    OBJC_LOCK(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set weak ivar layout for already-registered "
                     "class '%s'", getName(cls));
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    try_free(ro_w->weakIvarLayout);
    ro_w->weakIvarLayout = (unsigned char *)_strdup_internal(layout);

    OBJC_UNLOCK(&runtimeLock);
}


/***********************************************************************
* _class_getVariable
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Ivar 
_class_getVariable(Class cls, const char *name)
{
    OBJC_LOCK(&runtimeLock);

    for ( ; cls != Nil; cls = class_getSuperclass(cls)) {
        struct ivar_t *ivar = getIvar(newcls(cls), name);
        if (ivar) {
            OBJC_UNLOCK(&runtimeLock);
            return (Ivar)ivar;
        }
    }

    OBJC_UNLOCK(&runtimeLock);

    return NULL;
}


/***********************************************************************
* class_conformsToProtocol
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_conformsToProtocol(Class cls_gen, Protocol *proto)
{
    Protocol **protocols;
    unsigned int count, i;
    BOOL result = NO;

    // fixme null cls?

    protocols = class_copyProtocolList(cls_gen, &count);

    for (i = 0; i < count; i++) {
        if (protocols[i] == proto  ||  
            protocol_conformsToProtocol(protocols[i], proto)) 
        {
            result = YES;
            break;
        }
    }

    if (protocols) free(protocols);

    return result;
}


/***********************************************************************
* class_addMethod
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static IMP 
_class_addMethod(Class cls_gen, SEL name, IMP imp, 
                 const char *types, BOOL replace)
{
    struct class_t *cls = newcls(cls_gen);
    IMP result = NULL;

    if (!types) types = "";

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));
    // methodizeClass(cls);  _class_getMethodNoSuper() does this below

    Method m;
    if ((m = _class_getMethodNoSuper_nolock(cls, name))) {
        // already exists
        // fixme atomic
        result = method_getImplementation(m);
        if (replace) {
            method_setImplementation(m, imp);
        }
    } else {
        // fixme optimize
        chained_method_list *newlist;
        newlist = _calloc_internal(sizeof(*newlist) + sizeof(method_t), 1);
        newlist->count = 1;
        newlist->list[0].name = name;
        newlist->list[0].types = strdup(types);
        newlist->list[0].imp = imp;

        newlist->next = cls->data->methods;
        cls->data->methods = newlist;
        flushCaches(cls);
        result = NULL;
    }

    OBJC_UNLOCK(&runtimeLock);

    return result;
}


BOOL 
class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NO;

    IMP old = _class_addMethod(cls, name, imp, types, NO);
    return old ? NO : YES;
}


IMP 
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NULL;

    return _class_addMethod(cls, name, imp, types, YES);
}


/***********************************************************************
* class_addIvar
* Adds an ivar to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL 
class_addIvar(Class cls_gen, const char *name, size_t size, 
              uint8_t alignment, const char *type)
{
    struct class_t *cls = newcls(cls_gen);

    if (!cls) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = NULL;

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));

    // No class variables
    if (isMetaClass(cls)) {
        OBJC_UNLOCK(&runtimeLock);
        return NO;
    }

    // Can only add ivars to in-construction classes.
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        OBJC_UNLOCK(&runtimeLock);
        return NO;
    }

    // Check for existing ivar with this name, unless it's anonymous.
    // Check for too-big ivar.
    // fixme check for superclass ivar too?
    if ((name  &&  getIvar(cls, name))  ||  size > UINT32_MAX) {
        OBJC_UNLOCK(&runtimeLock);
        return NO;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    // fixme allocate less memory here
    
    ivar_list_t *oldlist, *newlist;
    if ((oldlist = (ivar_list_t *)cls->data->ro->ivars)) {
        size_t oldsize = ivar_list_size(oldlist);
        newlist = _calloc_internal(oldsize + oldlist->entsize, 1);
        memcpy(newlist, oldlist, oldsize);
        _free_internal(oldlist);
    } else {
        newlist = _calloc_internal(sizeof(ivar_list_t), 1);
        newlist->entsize = (uint32_t)sizeof(ivar_t);
    }

    uint32_t offset = instanceSize(cls);
    uint32_t alignMask = (1<<alignment)-1;
    offset = (offset + alignMask) & ~alignMask;

    ivar_t *ivar = ivar_list_nth(newlist, newlist->count++);
    ivar->offset = _malloc_internal(sizeof(*ivar->offset));
    *ivar->offset = offset;
    ivar->name = name ? _strdup_internal(name) : NULL;
    ivar->type = _strdup_internal(type);
    ivar->alignment = alignment;
    ivar->size = (uint32_t)size;

    ro_w->ivars = newlist;
    ro_w->instanceSize = (uint32_t)(offset + size);

    // Ivar layout updated in registerClass.

    OBJC_UNLOCK(&runtimeLock);

    return YES;
}


/***********************************************************************
* class_addProtocol
* Adds a protocol to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_addProtocol(Class cls_gen, Protocol *protocol_gen)
{
    class_t *cls = newcls(cls_gen);
    protocol_t *protocol = newprotocol(protocol_gen);
    protocol_list_t *plist;
    protocol_list_t **plistp;

    if (!cls) return NO;
    if (class_conformsToProtocol(cls_gen, protocol_gen)) return NO;

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(cls));
    
    // fixme optimize
    plist = _malloc_internal(sizeof(protocol_list_t) + sizeof(protocol_t *));
    plist->count = 1;
    plist->list[0] = protocol;
    
    unsigned int count = 0;
    for (plistp = cls->data->protocols; plistp && *plistp; plistp++) {
        count++;
    }

    cls->data->protocols = 
        _realloc_internal(cls->data->protocols, 
                          (count+2) * sizeof(protocol_list_t *));
    cls->data->protocols[count] = plist;
    cls->data->protocols[count+1] = NULL;

    // fixme metaclass?

    OBJC_UNLOCK(&runtimeLock);

    return YES;
}


/***********************************************************************
* look_up_class
* Look up a class by name, and realize it.
* Locking: acquires runtimeLock
* GrP fixme zerolink needs class handler for objc_getClass
**********************************************************************/
__private_extern__ id 
look_up_class(const char *name, 
              BOOL includeUnconnected __attribute__((unused)), 
              BOOL includeClassHandler __attribute__((unused)))
{
    if (!name) return nil;

    OBJC_LOCK(&runtimeLock);
    id result = (id)getClass(name);
    realizeClass(result);
    OBJC_UNLOCK(&runtimeLock);
    return result;
}


/***********************************************************************
* objc_duplicateClass
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class 
objc_duplicateClass(Class original_gen, const char *name, 
                    size_t extraBytes)
{
    struct class_t *original = newcls(original_gen);
    chained_method_list **m;
    struct class_t *duplicate;

    OBJC_LOCK(&runtimeLock);

    assert(isRealized(original));
    methodizeClass(original);
    assert(!isMetaClass(original));

    duplicate = (struct class_t *)
        calloc(instanceSize(original->isa) + extraBytes, 1);
    if (instanceSize(original->isa) < sizeof(class_t)) {
        _objc_inform("busted! %s\n", original->data->ro->name);
    }


    duplicate->isa = original->isa;
    duplicate->superclass = original->superclass;
    duplicate->cache = (Cache)&_objc_empty_cache;
#warning GrP fixme vtable
    // duplicate->vtable = (IMP *)&_objc_empty_vtable;

    duplicate->data = _calloc_internal(sizeof(*original->data), 1);
    duplicate->data->flags = original->data->flags | RW_COPIED_RO;
    duplicate->data->version = original->data->version;
    duplicate->data->firstSubclass = NULL;
    duplicate->data->nextSiblingClass = NULL;

    duplicate->data->ro = 
        _memdup_internal(original->data->ro, sizeof(*original->data->ro));
    *(char **)&duplicate->data->ro->name = _strdup_internal(name);
    
    duplicate->data->methods = original->data->methods;
    for (m = &duplicate->data->methods; *m != NULL; m = &(*m)->next) {
        *m = _memdup_internal(*m, chained_mlist_size(*m));
    }

    // fixme dies when categories are added to the base
    duplicate->data->properties = original->data->properties;
    duplicate->data->protocols = original->data->protocols;

    if (duplicate->superclass) {
        addSubclass(duplicate->superclass, duplicate);
    }

    addRealizedClass(duplicate, duplicate->data->ro->name);

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' (duplicate of %s) %p %p", 
                     name, original->data->ro->name, 
                     duplicate, duplicate->data->ro);
    }

    OBJC_UNLOCK(&runtimeLock);

    return (Class)duplicate;
}


/***********************************************************************
* objc_allocateClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class objc_allocateClassPair(Class superclass_gen, const char *name, 
                             size_t extraBytes)
{
    class_t *superclass = newcls(superclass_gen);
    class_t *cls, *meta;
    class_ro_t *cls_ro_w, *meta_ro_w;

    OBJC_LOCK(&runtimeLock);

    if (getClass(name)) {
        OBJC_UNLOCK(&runtimeLock);
        return NO;
    }
    // fixme reserve class against simmultaneous allocation

    if (superclass) assert(isRealized(superclass));

    if (superclass  &&  superclass->data->flags & RW_CONSTRUCTING) {
        // Can't make subclass of an in-construction class
        OBJC_UNLOCK(&runtimeLock);
        return NO;
    }

    // Allocate new classes.
    if (superclass) {
        cls = _calloc_internal(instanceSize(superclass->isa) + extraBytes, 1);
        meta = _calloc_internal(instanceSize(superclass->isa->isa) + extraBytes, 1);
    } else {
        cls = _calloc_internal(sizeof(class_t) + extraBytes, 1);
        meta = _calloc_internal(sizeof(class_t) + extraBytes, 1);
    }
    
    cls->data = _calloc_internal(sizeof(class_rw_t), 1);
    meta->data = _calloc_internal(sizeof(class_rw_t), 1);
    cls_ro_w = _calloc_internal(sizeof(class_ro_t), 1);
    meta_ro_w = _calloc_internal(sizeof(class_ro_t), 1);
    cls->data->ro = cls_ro_w;
    meta->data->ro = meta_ro_w;

    // Set basic info
    cls->cache = (Cache)&_objc_empty_cache;
    meta->cache = (Cache)&_objc_empty_cache;
    cls->vtable = (IMP *)&_objc_empty_vtable;
    meta->vtable = (IMP *)&_objc_empty_vtable;

    cls->data->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    meta->data->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    cls->data->version = 0;
    meta->data->version = 7;

    cls_ro_w->flags = 0;
    meta_ro_w->flags = RO_META;
    if (!superclass) {
        cls_ro_w->flags |= RO_ROOT;
        meta_ro_w->flags |= RO_ROOT;
    }
    if (superclass) {
        cls_ro_w->instanceStart = instanceSize(superclass);
        meta_ro_w->instanceStart = instanceSize(superclass->isa);
        cls_ro_w->instanceSize = cls_ro_w->instanceStart;
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    } else {
        cls_ro_w->instanceStart = 0;
        meta_ro_w->instanceStart = (uint32_t)sizeof(class_t);
        cls_ro_w->instanceSize = (uint32_t)sizeof(id);  // just an isa
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    }

    cls_ro_w->name = _strdup_internal(name);
    meta_ro_w->name = _strdup_internal(name);

    // Connect to superclasses and metaclasses
    cls->isa = meta;
    if (superclass) {
        meta->isa = superclass->isa->isa;
        cls->superclass = superclass;
        meta->superclass = superclass->isa;
        addSubclass(superclass, cls);
        addSubclass(superclass->isa, meta);
    } else {
        meta->isa = meta;
        cls->superclass = Nil;
        meta->superclass = cls;
        addSubclass(cls, meta);
    }

    OBJC_UNLOCK(&runtimeLock);

    return (Class)cls;
}


/***********************************************************************
* objc_registerClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    
    OBJC_LOCK(&runtimeLock);

    if ((cls->data->flags & RW_CONSTRUCTED)  ||  
        (cls->isa->data->flags & RW_CONSTRUCTED)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->data->ro->name);
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    if (!(cls->data->flags & RW_CONSTRUCTING)  ||  
        !(cls->isa->data->flags & RW_CONSTRUCTING))
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data->ro->name);
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    // Build ivar layouts
    if (UseGC) {
        struct class_t *supercls = getSuperclass(cls);
        class_ro_t *ro_w = (class_ro_t *)cls->data->ro;

        if (ro_w->ivarLayout) {
            // Class builder already called class_setIvarLayout.
        }
        else if (!supercls) {
            // Root class. Scan conservatively (should be isa ivar only).
            // ivar_layout is already NULL.
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layouts.
            ro_w->ivarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->ivarLayout);
        }
        else {
            // Has local ivars. Build layouts based on superclass.
            layout_bitmap bitmap = 
                layout_bitmap_create(supercls->data->ro->ivarLayout, 
                                     instanceSize(supercls), 
                                     instanceSize(cls), NO);
            uint32_t i;
            for (i = 0; i < ro_w->ivars->count; i++) {
                ivar_t *iv = ivar_list_nth(ro_w->ivars, i);
                layout_bitmap_set_ivar(bitmap, iv->type, *iv->offset);
            }
            ro_w->ivarLayout = layout_string_create(bitmap);
            layout_bitmap_free(bitmap);
        }

        if (ro_w->weakIvarLayout) {
            // Class builder already called class_setWeakIvarLayout.
        }
        else if (!supercls) {
            // Root class. No weak ivars (should be isa ivar only).
            // weak_ivar_layout is already NULL.
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layout.
            ro_w->weakIvarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->weakIvarLayout);
        }
        else {
            // Has local ivars. Build layout based on superclass.
            // No way to add weak ivars yet.
            ro_w->weakIvarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->weakIvarLayout);
        }
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->data->flags &= ~RW_CONSTRUCTING;
    cls->isa->data->flags &= ~RW_CONSTRUCTING;
    cls->data->flags |= RW_CONSTRUCTED;
    cls->isa->data->flags |= RW_CONSTRUCTED;

    // Add to realized and uninitialized classes
    addRealizedClass(cls, cls->data->ro->name);
    addUninitializedClass(cls, cls->isa);

    OBJC_UNLOCK(&runtimeLock);
}


static void unload_class(class_t *cls)
{
    uint32_t i;

    chained_method_list *mlist = cls->data->methods;
    while (mlist) {
        chained_method_list *dead = mlist;
        mlist = mlist->next;
        for (i = 0; i < dead->count; i++) {
            try_free(dead->list[i].types);
        }
        try_free(dead);
    }

    const ivar_list_t *ilist = cls->data->ro->ivars;
    if (ilist) {
        for (i = 0; i < ilist->count; i++) {
            const ivar_t *ivar = ivar_list_nth(ilist, i);
            try_free(ivar->offset);
            try_free(ivar->name);
            try_free(ivar->type);
        }
        try_free(ilist);
    }

    protocol_list_t **plistp = cls->data->protocols;
    for (plistp = cls->data->protocols; plistp && *plistp; plistp++) {
        try_free(*plistp);
    }
    try_free(cls->data->protocols);

    // fixme:
    // properties

    try_free(cls->data->ro->ivarLayout);
    try_free(cls->data->ro->weakIvarLayout);
    try_free(cls->data->ro->name);
    try_free(cls->data->ro);
    try_free(cls->data);
    if (cls->cache != (Cache)&_objc_empty_cache) _cache_free(cls->cache);
    try_free(cls);
}

void objc_disposeClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);

    OBJC_LOCK(&runtimeLock);

    if (!(cls->data->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))  ||  
        !(cls->isa->data->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))) 
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data->ro->name);
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    if (isMetaClass(cls)) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->data->ro->name);
        OBJC_UNLOCK(&runtimeLock);
        return;
    }

    class_t *supercls = getSuperclass(cls);

    // Shouldn't have any live subclasses.
    if (cls->data->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data->ro->name, 
                     getName(cls->data->firstSubclass));
    }
    if (cls->isa->data->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data->ro->name, 
                     getName(cls->isa->data->firstSubclass));
    }

    // Remove from superclass's subclass list
    // Note that cls and cls->isa may have different lists.
    if (supercls) {
        removeSubclass(getSuperclass(cls), cls);
        removeSubclass(getSuperclass(cls->isa), cls->isa);
    }

    // Remove from class hashes
    removeRealizedClass(cls);
    removeUninitializedClass(cls);

    // Deallocate memory
    unload_class(cls->isa);
    unload_class(cls);

    OBJC_UNLOCK(&runtimeLock);
}



/***********************************************************************
* class_createInstanceFromZone
* fixme
* Locking: none
**********************************************************************/
id
class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    if (cls) assert(isRealized(newcls(cls)));
    return _internal_class_createInstanceFromZone(cls, extraBytes, zone);
}


/***********************************************************************
* class_createInstance
* fixme
* Locking: none
**********************************************************************/
id 
class_createInstance(Class cls, size_t extraBytes)
{
    return class_createInstanceFromZone(cls, extraBytes, NULL);
}


/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id 
object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    id obj;
    size_t size;

    if (!oldObj) return nil;

    size = _class_getInstanceSize(oldObj->isa) + extraBytes;
    obj = malloc_zone_calloc(zone, size, 1);
    if (!obj) return nil;

    // fixme this doesn't handle C++ ivars correctly (#4619414)
    bcopy(oldObj, obj, size);

    return obj;
}


/***********************************************************************
* object_copy
* fixme
* Locking: none
**********************************************************************/
id 
object_copy(id oldObj, size_t extraBytes)
{
    return object_copyFromZone(oldObj, extraBytes, malloc_default_zone());
}


/***********************************************************************
* object_dispose
* fixme
* Locking: none
**********************************************************************/
id 
object_dispose(id obj)
{
    return _internal_object_dispose(obj);
}


/***********************************************************************
* _class_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
__private_extern__ Class 
_class_getFreedObjectClass(void)
{
    return Nil;  // fixme
}

/***********************************************************************
* _class_getNonexistentObjectClass
* fixme
* Locking: none
**********************************************************************/
__private_extern__ Class 
_class_getNonexistentObjectClass(void)
{
    return Nil;  // fixme
}

/***********************************************************************
* _objc_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
Class _objc_getFreedObjectClass (void)
{
    return _class_getFreedObjectClass();
}

extern id objc_msgSend_fixup(id, SEL, ...);
extern id objc_msgSend_fixedup(id, SEL, ...);
extern id objc_msgSendSuper2_fixup(id, SEL, ...);
extern id objc_msgSendSuper2_fixedup(id, SEL, ...);
extern id objc_msgSend_stret_fixup(id, SEL, ...);
extern id objc_msgSend_stret_fixedup(id, SEL, ...);
extern id objc_msgSendSuper2_stret_fixup(id, SEL, ...);
extern id objc_msgSendSuper2_stret_fixedup(id, SEL, ...);

/***********************************************************************
* _objc_fixupMessageRef
* Fixes up message ref *msg. 
* obj is the receiver. supr is NULL for non-super messages
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ IMP 
_objc_fixupMessageRef(id obj, struct objc_super2 *supr, message_ref *msg)
{
    IMP imp;
    class_t *isa;

    OBJC_CHECK_UNLOCKED(&runtimeLock);

    if (!supr) {
        // normal message - search obj->isa for the method implementation
        isa = (class_t *)obj->isa;
        
        if (!isRealized(isa)) {
            // obj is a class object, isa is its metaclass
            class_t *cls;
            OBJC_LOCK(&runtimeLock);
            if (!isRealized(isa)) {
                cls = realizeClass((class_t *)obj);
                
                // shouldn't have instances of unrealized classes!
                assert(isMetaClass(isa));
                // shouldn't be relocating classes here!
                assert(cls == (class_t *)obj);
            }
            OBJC_UNLOCK(&runtimeLock);
        }
    }
    else {
        // this is objc_msgSend_super, and supr->current_class->superclass
        // is the class to search for the method implementation
        assert(isRealized((class_t *)supr->current_class));
        isa = getSuperclass((class_t *)supr->current_class);
    }

    msg->sel = sel_registerName((const char *)msg->sel);
    imp = _class_lookupMethodAndLoadCache((Class)isa, msg->sel);

    if (msg->imp == (IMP)&objc_msgSend_fixup) { 
        msg->imp = (IMP)&objc_msgSend_fixedup;
    } 
    else if (msg->imp == (IMP)&objc_msgSendSuper2_fixup) { 
        msg->imp = (IMP)&objc_msgSendSuper2_fixedup;
    } 
    else if (msg->imp == (IMP)&objc_msgSend_stret_fixup) { 
        msg->imp = (IMP)&objc_msgSend_stret_fixedup;
    } 
    else if (msg->imp == (IMP)&objc_msgSendSuper2_stret_fixup) { 
        msg->imp = (IMP)&objc_msgSendSuper2_stret_fixedup;
    } 
    else {
        // The ref may already have been fixed up, either by another thread, 
        // or by +initialize via class_lookupMethodAndLoadCache above.
    }

    return imp;
}

#warning fixme delete after #4586306
Class class_poseAs(Class imposter, Class original)
{
    _objc_fatal("Don't call class_poseAs.");
}


// ProKit SPI
static class_t *setSuperclass(class_t *cls, class_t *newSuper)
{
    class_t *oldSuper;

    OBJC_CHECK_LOCKED(&runtimeLock);

    oldSuper = cls->superclass;
    removeSubclass(oldSuper, cls);
    removeSubclass(oldSuper->isa, cls->isa);

    cls->superclass = newSuper;
    cls->isa->superclass = newSuper->isa;
    addSubclass(newSuper, cls);
    addSubclass(newSuper->isa, cls->isa);

    flushCaches(cls);
    flushCaches(cls->isa);

    return oldSuper;
}


Class class_setSuperclass(Class cls_gen, Class newSuper_gen)
{
    class_t *cls = newcls(cls_gen);
    class_t *newSuper = newcls(newSuper_gen);
    class_t *oldSuper;

    OBJC_LOCK(&runtimeLock);
    oldSuper = setSuperclass(cls, newSuper);
    OBJC_UNLOCK(&runtimeLock);

    return (Class)oldSuper;
}

#endif
