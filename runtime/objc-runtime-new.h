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

#ifndef _OBJC_RUNTIME_NEW_H
#define _OBJC_RUNTIME_NEW_H

__BEGIN_DECLS

// SEL points to characters
// struct objc_cache is stored in class object

typedef uintptr_t cache_key_t;

#if __LP64__
    typedef uint32_t mask_t;
#   define MASK_SHIFT ((mask_t)0)
#else
    typedef uint16_t mask_t;
#   define MASK_SHIFT ((mask_t)0)
#endif

struct cache_t {
    struct bucket_t *buckets;
    mask_t shiftmask;
    mask_t occupied;

    mask_t mask() { 
        return shiftmask >> MASK_SHIFT; 
    }
    mask_t capacity() { 
        return shiftmask ? (shiftmask >> MASK_SHIFT) + 1 : 0; 
    }
    void setCapacity(uint32_t capacity) { 
        uint32_t newmask = (capacity - 1) << MASK_SHIFT;
        assert(newmask == (uint32_t)(mask_t)newmask);
        shiftmask = newmask;
    }

    void expand();
    void reallocate(mask_t oldCapacity, mask_t newCapacity);
    struct bucket_t * find(cache_key_t key);

    static void bad_cache(id receiver, SEL sel, Class isa, bucket_t *bucket) __attribute__((noreturn));
};


// We cannot store flags in the low bits of the 'data' field until we work with
// the 'leaks' team to not think that objc is leaking memory. See radar 8955342
// for more info.
#define CLASS_FAST_FLAGS_VIA_RW_DATA 0


// Values for class_ro_t->flags
// These are emitted by the compiler and are part of the ABI. 
// class is a metaclass
#define RO_META               (1<<0)
// class is a root class
#define RO_ROOT               (1<<1)
// class has .cxx_construct/destruct implementations
#define RO_HAS_CXX_STRUCTORS  (1<<2)
// class has +load implementation
// #define RO_HAS_LOAD_METHOD    (1<<3)
// class has visibility=hidden set
#define RO_HIDDEN             (1<<4)
// class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
#define RO_EXCEPTION          (1<<5)
// this bit is available for reassignment
// #define RO_REUSE_ME           (1<<6) 
// class compiled with -fobjc-arc (automatic retain/release)
#define RO_IS_ARR             (1<<7)
// class has .cxx_destruct but no .cxx_construct (with RO_HAS_CXX_STRUCTORS)
#define RO_HAS_CXX_DTOR_ONLY  (1<<8)

// class is in an unloadable bundle - must never be set by compiler
#define RO_FROM_BUNDLE        (1<<29)
// class is unrealized future class - must never be set by compiler
#define RO_FUTURE             (1<<30)
// class is realized - must never be set by compiler
#define RO_REALIZED           (1<<31)

// Values for class_rw_t->flags
// These are not emitted by the compiler and are never used in class_ro_t. 
// Their presence should be considered in future ABI versions.
// class_t->data is class_rw_t, not class_ro_t
#define RW_REALIZED           (1<<31)
// class is unresolved future class
#define RW_FUTURE             (1<<30)
// class is initialized
#define RW_INITIALIZED        (1<<29)
// class is initializing
#define RW_INITIALIZING       (1<<28)
// class_rw_t->ro is heap copy of class_ro_t
#define RW_COPIED_RO          (1<<27)
// class allocated but not yet registered
#define RW_CONSTRUCTING       (1<<26)
// class allocated and registered
#define RW_CONSTRUCTED        (1<<25)
// GC:  class has unsafe finalize method
#define RW_FINALIZE_ON_MAIN_THREAD (1<<24)
// class +load has been called
#define RW_LOADED             (1<<23)
// class does not share super's vtable
#define RW_SPECIALIZED_VTABLE (1<<22)
// class instances may have associative references
#define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<21)
// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<20)
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<19)
// class has instance-specific GC layout
#define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 18)
// class's method list is an array of method lists
#define RW_METHOD_ARRAY       (1<<17)
// class or superclass has custom allocWithZone: implementation
#define RW_HAS_CUSTOM_AWZ     (1<<16)
// class or superclass has custom retain/release/autorelease/retainCount
#define RW_HAS_CUSTOM_RR   (1<<15)

// Flags may be stored in low bits of rw->data_NEVER_USE for fastest access
#define CLASS_FAST_FLAG_MASK 3
#if CLASS_FAST_FLAGS_VIA_RW_DATA
    // reserved for future expansion
#   define CLASS_FAST_FLAG_RESERVED       (1<<0)
    // class or superclass has custom retain/release/autorelease/retainCount
#   define CLASS_FAST_FLAG_HAS_CUSTOM_RR  (1<<1)
#   undef RW_HAS_CUSTOM_RR
#endif

// classref_t is unremapped class_t*
typedef struct classref * classref_t;

struct method_t {
    SEL name;
    const char *types;
    IMP imp;

    struct SortBySELAddress :
        public std::binary_function<const method_t&,
                                    const method_t&, bool>
    {
        bool operator() (const method_t& lhs,
                         const method_t& rhs)
        { return lhs.name < rhs.name; }
    };
};

struct method_list_t {
    uint32_t entsize_NEVER_USE;  // high bits used for fixup markers
    uint32_t count;
    method_t first;

    uint32_t getEntsize() const { 
        return entsize_NEVER_USE & ~(uint32_t)3; 
    }
    uint32_t getCount() const { 
        return count; 
    }
    method_t& getOrEnd(uint32_t i) const { 
        assert(i <= count);
        return *(method_t *)((uint8_t *)&first + i*getEntsize()); 
    }
    method_t& get(uint32_t i) const { 
        assert(i < count);
        return getOrEnd(i);
    }

    // iterate methods, taking entsize into account
    // fixme need a proper const_iterator
    struct method_iterator {
        uint32_t entsize;
        uint32_t index;  // keeping track of this saves a divide in operator-
        method_t* method;

        typedef std::random_access_iterator_tag iterator_category;
        typedef method_t value_type;
        typedef ptrdiff_t difference_type;
        typedef method_t* pointer;
        typedef method_t& reference;

        method_iterator() { }

        method_iterator(const method_list_t& mlist, uint32_t start = 0)
            : entsize(mlist.getEntsize())
            , index(start)
            , method(&mlist.getOrEnd(start))
        { }

        const method_iterator& operator += (ptrdiff_t delta) {
            method = (method_t*)((uint8_t *)method + delta*entsize);
            index += (int32_t)delta;
            return *this;
        }
        const method_iterator& operator -= (ptrdiff_t delta) {
            method = (method_t*)((uint8_t *)method - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        const method_iterator operator + (ptrdiff_t delta) const {
            return method_iterator(*this) += delta;
        }
        const method_iterator operator - (ptrdiff_t delta) const {
            return method_iterator(*this) -= delta;
        }

        method_iterator& operator ++ () { *this += 1; return *this; }
        method_iterator& operator -- () { *this -= 1; return *this; }
        method_iterator operator ++ (int) {
            method_iterator result(*this); *this += 1; return result;
        }
        method_iterator operator -- (int) {
            method_iterator result(*this); *this -= 1; return result;
        }

        ptrdiff_t operator - (const method_iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }

        method_t& operator * () const { return *method; }
        method_t* operator -> () const { return method; }

        operator method_t& () const { return *method; }

        bool operator == (const method_iterator& rhs) {
            return this->method == rhs.method;
        }
        bool operator != (const method_iterator& rhs) {
            return this->method != rhs.method;
        }

        bool operator < (const method_iterator& rhs) {
            return this->method < rhs.method;
        }
        bool operator > (const method_iterator& rhs) {
            return this->method > rhs.method;
        }
    };

    method_iterator begin() const { return method_iterator(*this, 0); }
    method_iterator end() const { return method_iterator(*this, getCount()); }

};

struct ivar_t {
#if __x86_64__
    // *offset was originally 64-bit on some x86_64 platforms.
    // We read and write only 32 bits of it.
    // Some metadata provides all 64 bits. This is harmless for unsigned 
    // little-endian values.
    // Some code uses all 64 bits. class_addIvar() over-allocates the 
    // offset for their benefit.
#endif
    int32_t *offset;
    const char *name;
    const char *type;
    // alignment is sometimes -1; use alignment() instead
    uint32_t alignment_raw;
    uint32_t size;

    uint32_t alignment() {
        if (alignment_raw == ~(uint32_t)0) return 1U << WORD_SHIFT;
        return 1 << alignment_raw;
    }
};

struct ivar_list_t {
    uint32_t entsize;
    uint32_t count;
    ivar_t first;
};

struct property_t {
    const char *name;
    const char *attributes;
};

struct property_list_t {
    uint32_t entsize;
    uint32_t count;
    property_t first;
};

typedef uintptr_t protocol_ref_t;  // protocol_t *, but unremapped

#define PROTOCOL_FIXED_UP (1<<31)  // must never be set by compiler

struct protocol_t : objc_object {
    const char *name;
    struct protocol_list_t *protocols;
    method_list_t *instanceMethods;
    method_list_t *classMethods;
    method_list_t *optionalInstanceMethods;
    method_list_t *optionalClassMethods;
    property_list_t *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;
    const char **extendedMethodTypes;

    bool isFixedUp() const {
        return flags & PROTOCOL_FIXED_UP;
    }

    bool hasExtendedMethodTypesField() const {
        return size >= (offsetof(protocol_t, extendedMethodTypes) 
                        + sizeof(extendedMethodTypes));
    }
    bool hasExtendedMethodTypes() const {
        return hasExtendedMethodTypesField() && extendedMethodTypes;
    }
};

struct protocol_list_t {
    // count is 64-bit by accident. 
    uintptr_t count;
    protocol_ref_t list[0]; // variable-size
};

struct class_ro_t {
    uint32_t flags;
    uint32_t instanceStart;
    uint32_t instanceSize;
#ifdef __LP64__
    uint32_t reserved;
#endif

    const uint8_t * ivarLayout;
    
    const char * name;
    const method_list_t * baseMethods;
    const protocol_list_t * baseProtocols;
    const ivar_list_t * ivars;

    const uint8_t * weakIvarLayout;
    const property_list_t *baseProperties;
};

struct class_rw_t {
    uint32_t flags;
    uint32_t version;

    const class_ro_t *ro;

    union {
        method_list_t **method_lists;  // RW_METHOD_ARRAY == 1
        method_list_t *method_list;    // RW_METHOD_ARRAY == 0
    };
    struct chained_property_list *properties;
    const protocol_list_t ** protocols;

    Class firstSubclass;
    Class nextSiblingClass;
};

struct objc_class : objc_object {
    // Class ISA;
    Class superclass;
    cache_t cache;
    uintptr_t data_NEVER_USE;  // class_rw_t * plus custom rr/alloc flags

    class_rw_t *data() { 
        return (class_rw_t *)(data_NEVER_USE & ~CLASS_FAST_FLAG_MASK); 
    }
    void setData(class_rw_t *newData) {
        uintptr_t flags = (uintptr_t)data_NEVER_USE & CLASS_FAST_FLAG_MASK;
        data_NEVER_USE = (uintptr_t)newData | flags;
    }

    void setInfo(uint32_t set) {
        assert(isFuture()  ||  isRealized());
        OSAtomicOr32Barrier(set, (volatile uint32_t *)&data()->flags);
    }

    void clearInfo(uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        OSAtomicXor32Barrier(clear, (volatile uint32_t *)&data()->flags);
    }

    // set and clear must not overlap
    void changeInfo(uint32_t set, uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        assert((set & clear) == 0);

        uint32_t oldf, newf;
        do {
            oldf = data()->flags;
            newf = (oldf | set) & ~clear;
        } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&data()->flags));
    }

    bool hasCustomRR() {
#if CLASS_FAST_FLAGS_VIA_RW_DATA
        return data_NEVER_USE & CLASS_FAST_FLAG_HAS_CUSTOM_RR;
#else
        return data()->flags & RW_HAS_CUSTOM_RR;
#endif
    }
    void setHasCustomRR(bool inherited = false);

    bool hasCustomAWZ() {
        return true;
        // return data()->flags & RW_HAS_CUSTOM_AWZ;
    }
    void setHasCustomAWZ(bool inherited = false);

    bool hasCxxCtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return data()->flags & RW_HAS_CXX_CTOR;
    }

    bool hasCxxDtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return data()->flags & RW_HAS_CXX_DTOR;
    }

    bool instancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        return data()->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS;
    }

    void setInstancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        setInfo(RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
    }

    bool shouldGrowCache() {
        return true;
    }

    void setShouldGrowCache(bool) {
        // fixme good or bad for memory use?
    }

    bool shouldFinalizeOnMainThread() {
        // finishInitializing() propagates this flag from the superclass.
        assert(isRealized());
        return data()->flags & RW_FINALIZE_ON_MAIN_THREAD;
    }

    void setShouldFinalizeOnMainThread() {
        assert(isRealized());
        setInfo(RW_FINALIZE_ON_MAIN_THREAD);
    }

    bool isInitializing() {
        return getMeta()->data()->flags & RW_INITIALIZING;
    }

    void setInitializing() {
        assert(!isMetaClass());
        ISA()->setInfo(RW_INITIALIZING);
    }

    bool isInitialized() {
        return getMeta()->data()->flags & RW_INITIALIZED;
    }

    // assumes this is a metaclass already
    bool isInitialized_meta() {
        return (data()->flags & RW_INITIALIZED);
    }

    void setInitialized();

    bool isLoadable() {
        assert(isRealized());
        return true;  // any class registered for +load is definitely loadable
    }

    IMP getLoadMethod();

    // Locking: To prevent concurrent realization, hold runtimeLock.
    bool isRealized() {
        return data()->flags & RW_REALIZED;
    }

    // Returns true if this is an unrealized future class.
    // Locking: To prevent concurrent realization, hold runtimeLock.
    bool isFuture() { 
        return data()->flags & RW_FUTURE;
    }

    bool isMetaClass() {
        assert(this);
        assert(isRealized());
        return data()->ro->flags & RO_META;
    }

    // NOT identical to this->ISA when this is a metaclass
    Class getMeta() {
        if (isMetaClass()) return (Class)this;
        else return this->ISA();
    }

    bool isRootClass() {
        return superclass == nil;
    }
    bool isRootMetaclass() {
        return ISA() == (Class)this;
    }

    const char *getName() { return name(); }
    const char *name() { 
        // fixme can't assert locks here
        assert(this);

        if (isRealized()  ||  isFuture()) {
            return data()->ro->name;
        } else {
            return ((const class_ro_t *)data())->name;
        }
    }

    // May be unaligned depending on class's ivars.
    uint32_t unalignedInstanceSize() {
        assert(isRealized());
        return data()->ro->instanceSize;
    }

    // Class's ivar size rounded up to a pointer-size boundary.
    uint32_t alignedInstanceSize() {
        return (unalignedInstanceSize() + WORD_MASK) & ~WORD_MASK;
    }
};

struct category_t {
    const char *name;
    classref_t cls;
    struct method_list_t *instanceMethods;
    struct method_list_t *classMethods;
    struct protocol_list_t *protocols;
    struct property_list_t *instanceProperties;
};

struct objc_super2 {
    id receiver;
    Class current_class;
};

struct message_ref_t {
    IMP imp;
    SEL sel;
};


extern Method protocol_getMethod(protocol_t *p, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive);


#define FOREACH_REALIZED_CLASS_AND_SUBCLASS(_c, _cls, code)             \
    do {                                                                \
        rwlock_assert_writing(&runtimeLock);                            \
        assert(_cls);                                                   \
        Class _top = _cls;                                              \
        Class _c = _top;                                                \
        while (1) {                                                     \
            code                                                        \
            if (_c->data()->firstSubclass) {                            \
                _c = _c->data()->firstSubclass;                         \
            } else {                                                    \
                while (!_c->data()->nextSiblingClass  &&  _c != _top) { \
                    _c = _c->superclass;                                \
                }                                                       \
                if (_c == _top) break;                                  \
                _c = _c->data()->nextSiblingClass;                      \
            }                                                           \
        }                                                               \
    } while (0)


__END_DECLS

#endif
