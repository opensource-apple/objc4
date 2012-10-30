/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
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
  Implementation of the weak / associative references for non-GC mode.
*/


#include "objc-private.h"
#include <objc/message.h>


// wrap all the murky C++ details in a namespace to get them out of the way.

namespace objc_references_support {
    struct ObjcPointerEqual {
        bool operator()(void *p1, void *p2) const {
            return p1 == p2;
        }
    };
    
    struct ObjcPointerClear {
        void operator() (void *pointer) {
            void **location = (void **)pointer;
            *location = NULL;
        }
    };

    struct ObjcPointerHash {
        uintptr_t operator()(void *p) const {
            uintptr_t k = (uintptr_t)p;

            // borrowed from CFSet.c
        #if __LP64__
            uintptr_t a = 0x4368726973746F70ULL;
            uintptr_t b = 0x686572204B616E65ULL;
        #else
            uintptr_t a = 0x4B616E65UL;
            uintptr_t b = 0x4B616E65UL; 
        #endif
            uintptr_t c = 1;
            a += k;
        #if __LP64__
            a -= b; a -= c; a ^= (c >> 43);
            b -= c; b -= a; b ^= (a << 9);
            c -= a; c -= b; c ^= (b >> 8);
            a -= b; a -= c; a ^= (c >> 38);
            b -= c; b -= a; b ^= (a << 23);
            c -= a; c -= b; c ^= (b >> 5);
            a -= b; a -= c; a ^= (c >> 35);
            b -= c; b -= a; b ^= (a << 49);
            c -= a; c -= b; c ^= (b >> 11);
            a -= b; a -= c; a ^= (c >> 12);
            b -= c; b -= a; b ^= (a << 18);
            c -= a; c -= b; c ^= (b >> 22);
        #else
            a -= b; a -= c; a ^= (c >> 13);
            b -= c; b -= a; b ^= (a << 8);
            c -= a; c -= b; c ^= (b >> 13);
            a -= b; a -= c; a ^= (c >> 12);
            b -= c; b -= a; b ^= (a << 16);
            c -= a; c -= b; c ^= (b >> 5);
            a -= b; a -= c; a ^= (c >> 3);
            b -= c; b -= a; b ^= (a << 10);
            c -= a; c -= b; c ^= (b >> 15);
        #endif
            return c;
        }
    };

    // STL allocator that uses the runtime's internal allocator.
    
    template <typename T> struct ObjcAllocator {
        typedef T                 value_type;
        typedef value_type*       pointer;
        typedef const value_type *const_pointer;
        typedef value_type&       reference;
        typedef const value_type& const_reference;
        typedef size_t            size_type;
        typedef ptrdiff_t         difference_type;

        template <typename U> struct rebind { typedef ObjcAllocator<U> other; };

        template <typename U> ObjcAllocator(const ObjcAllocator<U>&) {}
        ObjcAllocator() {}
        ObjcAllocator(const ObjcAllocator&) {}
        ~ObjcAllocator() {}

        pointer address(reference x) const { return &x; }
        const_pointer address(const_reference x) const { 
            return x;
        }

        pointer allocate(size_type n, const_pointer = 0) {
            return static_cast<pointer>(::_malloc_internal(n * sizeof(T)));
        }

        void deallocate(pointer p, size_type) { ::_free_internal(p); }

        size_type max_size() const { 
            return static_cast<size_type>(-1) / sizeof(T);
        }

        void construct(pointer p, const value_type& x) { 
            new(p) value_type(x); 
        }

        void destroy(pointer p) { p->~value_type(); }

        void operator=(const ObjcAllocator&);

    };

    template<> struct ObjcAllocator<void> {
        typedef void        value_type;
        typedef void*       pointer;
        typedef const void *const_pointer;
        template <typename U> struct rebind { typedef ObjcAllocator<U> other; };
    };
    
    struct ObjcAssociation {
        uintptr_t policy;
        id value;
        ObjcAssociation(uintptr_t newPolicy, id newValue) : policy(newPolicy), value(newValue) { }
        ObjcAssociation() : policy(0), value(0) { }
    };

    // typedef vector<void *, ObjcAllocator<void *> > PtrVector;
    // typedef hash_set<void *, ObjcPointerHash, ObjcPointerEqual, ObjcAllocator<void *> > PtrHashSet;
    // typedef hash_map<void *, void *, ObjcPointerHash, ObjcPointerEqual, ObjcAllocator<void *> > PtrPtrHashMap;
#if TARGET_OS_WIN32
    typedef hash_map<void *, ObjcAssociation> ObjectAssocationHashMap;
    typedef hash_map<void *, ObjectAssocationHashMap> AssocationsHashMap;
#else
    typedef hash_map<void *, ObjcAssociation, ObjcPointerHash, ObjcPointerEqual, ObjcAllocator<void *> > ObjectAssocationHashMap;
    typedef hash_map<void *, ObjectAssocationHashMap, ObjcPointerHash, ObjcPointerEqual, ObjcAllocator<void *> > AssocationsHashMap;
#endif
}

using namespace objc_references_support;

// class AssociationsManager manages a lock / hash table singleton pair.
// Allocating an instance acquires the lock, and calling its assocations() method
// lazily allocates it.

class AssociationsManager {
    static OSSpinLock _lock;
    static AssocationsHashMap *_map;               // associative references:  object pointer -> PtrPtrHashMap.
public:
    AssociationsManager()   { OSSpinLockLock(&_lock); }
    ~AssociationsManager()  { OSSpinLockUnlock(&_lock); }
    
    AssocationsHashMap &associations() {
        if (_map == NULL)
            _map = new(::_malloc_internal(sizeof(AssocationsHashMap))) AssocationsHashMap();
        return *_map;
    }
};

OSSpinLock AssociationsManager::_lock = OS_SPINLOCK_INIT;
AssocationsHashMap *AssociationsManager::_map = NULL;

// expanded policy bits.

enum { 
    OBJC_ASSOCIATION_SETTER_ASSIGN      = 0,
    OBJC_ASSOCIATION_SETTER_RETAIN      = 1,
    OBJC_ASSOCIATION_SETTER_COPY        = 3,            // NOTE:  both bits are set, so we can simply test 1 bit in releaseValue below.
    OBJC_ASSOCIATION_GETTER_READ        = (0 << 8), 
    OBJC_ASSOCIATION_GETTER_RETAIN      = (1 << 8), 
    OBJC_ASSOCIATION_GETTER_AUTORELEASE = (2 << 8)
}; 

__private_extern__ id _object_get_associative_reference(id object, void *key) {
    id value = nil;
    uintptr_t policy = OBJC_ASSOCIATION_ASSIGN;
    {
        AssociationsManager manager;
        AssocationsHashMap &associations(manager.associations());
        AssocationsHashMap::iterator i = associations.find(object);
        if (i != associations.end()) {
            ObjectAssocationHashMap &refs = i->second;
            ObjectAssocationHashMap::iterator j = refs.find(key);
            if (j != refs.end()) {
                ObjcAssociation &entry = j->second;
                value = (id)entry.value;
                policy = entry.policy;
                if (policy & OBJC_ASSOCIATION_GETTER_RETAIN) objc_msgSend(value, SEL_retain);
            }
        }
    }
    if (value && (policy & OBJC_ASSOCIATION_GETTER_AUTORELEASE)) {
        objc_msgSend(value, SEL_autorelease);
    }
    return value;
}

static id acquireValue(id value, uintptr_t policy) {
    switch (policy & 0xFF) {
    case OBJC_ASSOCIATION_SETTER_RETAIN:
        return objc_msgSend(value, SEL_retain);
    case OBJC_ASSOCIATION_SETTER_COPY:
        return objc_msgSend(value, SEL_copy);
    }
    return value;
}

static void releaseValue(id value, uintptr_t policy) {
    if (policy & OBJC_ASSOCIATION_SETTER_RETAIN) {
        objc_msgSend(value, SEL_release);
    }
}

struct ReleaseValue {
    void operator() (ObjcAssociation &association) {
        releaseValue(association.value, association.policy);
    }
};

__private_extern__ void _object_set_associative_reference(id object, void *key, id value, uintptr_t policy) {
    // retain the new value (if any) outside the lock.
    uintptr_t old_policy = 0; // NOTE:  old_policy is always assigned to when old_value is non-nil.
    id new_value = value ? acquireValue(value, policy) : nil, old_value = nil;
    {
        AssociationsManager manager;
        AssocationsHashMap &associations(manager.associations());
        if (new_value) {
            // break any existing association.
            AssocationsHashMap::iterator i = associations.find(object);
            if (i != associations.end()) {
                // secondary table exists
                ObjectAssocationHashMap &refs = i->second;
                ObjectAssocationHashMap::iterator j = refs.find(key);
                if (j != refs.end()) {
                    ObjcAssociation &old_entry = j->second;
                    old_policy = old_entry.policy;
                    old_value = old_entry.value;
                    old_entry.policy = policy;
                    old_entry.value = new_value;
                } else {
                    refs[key] = ObjcAssociation(policy, new_value);
                }
            } else {
                // create the new association (first time).
                associations[object][key] = ObjcAssociation(policy, new_value);
                _class_assertInstancesHaveAssociatedObjects(object->isa);
            }
        } else {
            // setting the association to nil breaks the association.
            AssocationsHashMap::iterator i = associations.find(object);
            if (i !=  associations.end()) {
                ObjectAssocationHashMap &refs = i->second;
                ObjectAssocationHashMap::iterator j = refs.find(key);
                if (j != refs.end()) {
                    ObjcAssociation &old_entry = j->second;
                    old_policy = old_entry.policy;
                    old_value = (id) old_entry.value;
                    refs.erase(j);
                }
            }
        }
    }
    // release the old value (outside of the lock).
    if (old_value) releaseValue(old_value, old_policy);
}

__private_extern__ void _object_remove_assocations(id object) {
    vector<ObjcAssociation> elements;
    {
        AssociationsManager manager;
        AssocationsHashMap &associations(manager.associations());
        if (associations.size() == 0) return;
        AssocationsHashMap::iterator i = associations.find(object);
        if (i != associations.end()) {
            // copy all of the associations that need to be removed.
            ObjectAssocationHashMap &refs = i->second;
            for (ObjectAssocationHashMap::iterator j = refs.begin(); j != refs.end(); ++j) {
                elements.push_back(j->second);
            }
            // remove the secondary table.
            associations.erase(i);
        }
    }
    // the calls to releaseValue() happen outside of the lock.
    for_each(elements.begin(), elements.end(), ReleaseValue());
}
