/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
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

#include "llvm-DenseMap.h"

#import "objc-weak.h"
#import "objc-private.h"
#import "objc-internal.h"
#import "objc-os.h"
#import "runtime.h"

#include <stdint.h>
#include <stdbool.h>
//#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <libkern/OSAtomic.h>
#include <Block.h>
#include <map>
#include <execinfo.h>

#if SUPPORT_RETURN_AUTORELEASE
// We cannot peek at where we are returning to unless we always inline this:
__attribute__((always_inline))
static bool callerAcceptsFastAutorelease(const void * const ra0);
#endif


/***********************************************************************
* Weak ivar support
**********************************************************************/

static bool seen_weak_refs;

@protocol ReferenceCounted
+ (id)alloc;
+ (id)allocWithZone:(malloc_zone_t *)zone;
- (oneway void)dealloc;
- (id)retain;
- (oneway void)release;
- (id)autorelease;
- (uintptr_t)retainCount;
@end

#define ARR_LOGGING 0

#if ARR_LOGGING
struct {
    int retains;
    int releases;
    int autoreleases;
    int blockCopies;
} CompilerGenerated, ExplicitlyCoded;

PRIVATE_EXTERN void (^objc_arr_log)(const char *, id param) = 
    ^(const char *str, id param) { printf("%s %p\n", str, param); };
#endif


namespace {

#if TARGET_OS_EMBEDDED
#   define SIDE_TABLE_STRIPE 1
#else
#   define SIDE_TABLE_STRIPE 8
#endif

// should be a multiple of cache line size (64)
#define SIDE_TABLE_SIZE 64

typedef objc::DenseMap<id,size_t,true> RefcountMap;

class SideTable {
private:
    static uint8_t table_buf[SIDE_TABLE_STRIPE * SIDE_TABLE_SIZE];

public:
    OSSpinLock slock;
    RefcountMap refcnts;
    weak_table_t weak_table;

    SideTable() : slock(OS_SPINLOCK_INIT)
    {
        memset(&weak_table, 0, sizeof(weak_table));
    }
    
    ~SideTable() 
    {
        // never delete side_table in case other threads retain during exit
        assert(0);
    }

    static SideTable *tableForPointer(const void *p) 
    {
#     if SIDE_TABLE_STRIPE == 1
        return (SideTable *)table_buf;
#     else
        uintptr_t a = (uintptr_t)p;
        int index = ((a >> 4) ^ (a >> 9)) & (SIDE_TABLE_STRIPE - 1);
        return (SideTable *)&table_buf[index * SIDE_TABLE_SIZE];
#     endif
    }

    static void init() {
        // use placement new instead of static ctor to avoid dtor at exit
        for (int i = 0; i < SIDE_TABLE_STRIPE; i++) {
            new (&table_buf[i * SIDE_TABLE_SIZE]) SideTable;
        }
    }
};

STATIC_ASSERT(sizeof(SideTable) <= SIDE_TABLE_SIZE);
__attribute__((aligned(SIDE_TABLE_SIZE))) uint8_t 
SideTable::table_buf[SIDE_TABLE_STRIPE * SIDE_TABLE_SIZE];

// Avoid false-negative reports from tools like "leaks"
#define DISGUISE(x) ((id)~(uintptr_t)(x))

// anonymous namespace
};


//
// The -fobjc-arr flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//

id objc_retainBlock(id x) {
#if ARR_LOGGING
    objc_arr_log("objc_retain_block", x);
    ++CompilerGenerated.blockCopies;
#endif
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

BOOL objc_should_deallocate(id object) {
    return YES;
}

// WORKAROUND:
// <rdar://problem/9038601> clang remembers variadic bit across function cast
// <rdar://problem/9048030> Clang thinks that all ObjC vtable dispatches are variadic
// <rdar://problem/8873428> vararg function defeats tail-call optimization
id objc_msgSend_hack(id, SEL) asm("_objc_msgSend");

// public API entry points that might be optimized later

__attribute__((aligned(16)))
id
objc_retain(id obj)
{
	return objc_msgSend_hack(obj, @selector(retain));
}

__attribute__((aligned(16)))
void
objc_release(id obj)
{
	objc_msgSend_hack(obj, @selector(release));
}

__attribute__((aligned(16)))
id
objc_autorelease(id obj)
{
	return objc_msgSend_hack(obj, @selector(autorelease));
}

id
objc_retain_autorelease(id obj)
{
	return objc_autorelease(objc_retain(obj));
}

id
objc_storeWeak(id *location, id newObj)
{
    id oldObj;
    SideTable *oldTable;
    SideTable *newTable;
    OSSpinLock *lock1;
#if SIDE_TABLE_STRIPE > 1
    OSSpinLock *lock2;
#endif

    if (!seen_weak_refs) {
        seen_weak_refs = true;
    }

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
 retry:
    oldObj = *location;
    
    oldTable = SideTable::tableForPointer(oldObj);
    newTable = SideTable::tableForPointer(newObj);
    
    lock1 = &newTable->slock;
#if SIDE_TABLE_STRIPE > 1
    lock2 = &oldTable->slock;
    if (lock1 > lock2) {
        OSSpinLock *temp = lock1;
        lock1 = lock2;
        lock2 = temp;
    }
    if (lock1 != lock2) OSSpinLockLock(lock2);
#endif
    OSSpinLockLock(lock1);

    if (*location != oldObj) {
        OSSpinLockUnlock(lock1);
#if SIDE_TABLE_STRIPE > 1
        if (lock1 != lock2) OSSpinLockUnlock(lock2);
#endif
        goto retry;
    }

    if (oldObj) {
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }
    if (newObj) {
        newObj = weak_register_no_lock(&newTable->weak_table, newObj,location);
        // weak_register_no_lock returns NULL if weak store should be rejected
    }
    // Do not set *location anywhere else. That would introduce a race.
    *location = newObj;
    
    OSSpinLockUnlock(lock1);
#if SIDE_TABLE_STRIPE > 1
    if (lock1 != lock2) OSSpinLockUnlock(lock2);
#endif

    return newObj;
}

id
objc_loadWeakRetained(id *location)
{
    id result;

    SideTable *table;
    OSSpinLock *lock;
    
 retry:
    result = *location;
    if (!result) return NULL;
    
    table = SideTable::tableForPointer(result);
    lock = &table->slock;
    
    OSSpinLockLock(lock);
    if (*location != result) {
        OSSpinLockUnlock(lock);
        goto retry;
    }

    result = arr_read_weak_reference(&table->weak_table, location);

    OSSpinLockUnlock(lock);
    return result;
}

id
objc_loadWeak(id *location)
{
    return objc_autorelease(objc_loadWeakRetained(location));
}

id
objc_initWeak(id *addr, id val)
{
	*addr = 0;
	return objc_storeWeak(addr, val);
}

void
objc_destroyWeak(id *addr)
{
	objc_storeWeak(addr, 0);
}

void
objc_copyWeak(id *to, id *from)
{
	id val = objc_loadWeakRetained(from);
	objc_initWeak(to, val);
	objc_release(val);
}

void
objc_moveWeak(id *to, id *from)
{
	objc_copyWeak(to, from);
	objc_destroyWeak(from);
}


/* Autorelease pool implementation
   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_SENTINEL which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_SENTINEL for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
 */

extern "C" BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));

namespace {

struct magic_t {
    static const uint32_t M0 = 0xA1A1A1A1;
#   define M1 "AUTORELEASE!"
    static const size_t M1_len = 12;
    uint32_t m[4];
    
    magic_t() {
        assert(M1_len == strlen(M1));
        assert(M1_len == 3 * sizeof(m[1]));

        m[0] = M0;
        strncpy((char *)&m[1], M1, M1_len);
    }

    ~magic_t() {
        m[0] = m[1] = m[2] = m[3] = 0;
    }

    bool check() const {
        return (m[0] == M0 && 0 == strncmp((char *)&m[1], M1, M1_len));
    }

    bool fastcheck() const {
#ifdef NDEBUG
        return (m[0] == M0);
#else
        return check();
#endif
    }

#   undef M1
};
    

// Set this to 1 to mprotect() autorelease pool contents
#define PROTECT_AUTORELEASEPOOL 0

class AutoreleasePoolPage 
{

#define POOL_SENTINEL 0
    static pthread_key_t const key = AUTORELEASE_POOL_KEY;
    static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
    static size_t const SIZE = 
#if PROTECT_AUTORELEASEPOOL
        4096;  // must be multiple of vm page size
#else
        4096;  // size and alignment, power of 2
#endif
    static size_t const COUNT = SIZE / sizeof(id);

    magic_t const magic;
    id *next;
    pthread_t const thread;
    AutoreleasePoolPage * const parent;
    AutoreleasePoolPage *child;
    uint32_t const depth;
    uint32_t hiwat;

    // SIZE-sizeof(*this) bytes of contents follow

    static void * operator new(size_t size) {
        return malloc_zone_memalign(malloc_default_zone(), SIZE, SIZE);
    }
    static void operator delete(void * p) {
        return free(p);
    }

    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        mprotect(this, SIZE, PROT_READ);
        check();
#endif
    }

    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        check();
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }

    AutoreleasePoolPage(AutoreleasePoolPage *newParent) 
        : magic(), next(begin()), thread(pthread_self()),
          parent(newParent), child(NULL), 
          depth(parent ? 1+parent->depth : 0), 
          hiwat(parent ? parent->hiwat : 0)
    { 
        if (parent) {
            parent->check();
            assert(!parent->child);
            parent->unprotect();
            parent->child = this;
            parent->protect();
        }
        protect();
    }

    ~AutoreleasePoolPage() 
    {
        check();
        unprotect();
        assert(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        assert(!child);
    }


    void busted(bool die = true) 
    {
        (die ? _objc_fatal : _objc_inform)
            ("autorelease pool page %p corrupted\n"
             "  magic %x %x %x %x\n  pthread %p\n", 
             this, magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             this->thread);
    }

    void check(bool die = true) 
    {
        if (!magic.check() || !pthread_equal(thread, pthread_self())) {
            busted(die);
        }
    }

    void fastcheck(bool die = true) 
    {
        if (! magic.fastcheck()) {
            busted(die);
        }
    }


    id * begin() {
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    id * end() {
        return (id *) ((uint8_t *)this+SIZE);
    }

    bool empty() {
        return next == begin();
    }

    bool full() { 
        return next == end();
    }

    bool lessThanHalfFull() {
        return (next - begin() < (end() - begin()) / 2);
    }

    id *add(id obj)
    {
        assert(!full());
        unprotect();
        *next++ = obj;
        protect();
        return next-1;
    }

    void releaseAll() 
    {
        releaseUntil(begin());
    }

    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        
        while (this->next != stop) {
            // Restart from hotPage() every time, in case -release 
            // autoreleased more objects
            AutoreleasePoolPage *page = hotPage();

            // fixme I think this `while` can be `if`, but I can't prove it
            while (page->empty()) {
                page = page->parent;
                setHotPage(page);
            }

            page->unprotect();
            id obj = *--page->next;
            memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
            page->protect();

            if (obj != POOL_SENTINEL) {
                objc_release(obj);
            }
        }

        setHotPage(this);

#ifndef NDEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            assert(page->empty());
        }
#endif
    }

    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        AutoreleasePoolPage *page = this;
        while (page->child) page = page->child;

        AutoreleasePoolPage *deathptr;
        do {
            deathptr = page;
            page = page->parent;
            if (page) {
                page->unprotect();
                page->child = NULL;
                page->protect();
            }
            delete deathptr;
        } while (deathptr != this);
    }

    static void tls_dealloc(void *p) 
    {
        // reinstate TLS value while we work
        setHotPage((AutoreleasePoolPage *)p);
        pop(0);
        setHotPage(NULL);
    }

    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        uintptr_t offset = p % SIZE;

        assert(offset >= sizeof(AutoreleasePoolPage));

        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }


    static inline AutoreleasePoolPage *hotPage() 
    {
        AutoreleasePoolPage *result = (AutoreleasePoolPage *)
            _pthread_getspecific_direct(key);
        if (result) result->fastcheck();
        return result;
    }

    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        _pthread_setspecific_direct(key, (void *)page);
    }

    static inline AutoreleasePoolPage *coldPage() 
    {
        AutoreleasePoolPage *result = hotPage();
        if (result) {
            while (result->parent) {
                result = result->parent;
                result->fastcheck();
            }
        }
        return result;
    }


    static inline id *autoreleaseFast(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page && !page->full()) {
            return page->add(obj);
        } else {
            return autoreleaseSlow(obj);
        }
    }

    static __attribute__((noinline))
    id *autoreleaseSlow(id obj)
    {
        AutoreleasePoolPage *page;
        page = hotPage();

        // The code below assumes some cases are handled by autoreleaseFast()
        assert(!page || page->full());

        if (!page) {
            assert(obj != POOL_SENTINEL);
            _objc_inform("Object %p of class %s autoreleased "
                         "with no pool in place - just leaking - "
                         "break on objc_autoreleaseNoPool() to debug", 
                         obj, object_getClassName(obj));
            objc_autoreleaseNoPool(obj);
            return NULL;
        }

        do {
            if (page->child) page = page->child;
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        setHotPage(page);
        return page->add(obj);
    }

public:
    static inline id autorelease(id obj)
    {
        assert(obj);
        assert(!OBJC_IS_TAGGED_PTR(obj));
        id *dest __unused = autoreleaseFast(obj);
        assert(!dest  ||  *dest == obj);
        return obj;
    }


    static inline void *push() 
    {
        if (!hotPage()) {
            setHotPage(new AutoreleasePoolPage(NULL));
        } 
        id *dest = autoreleaseFast(POOL_SENTINEL);
        assert(*dest == POOL_SENTINEL);
        return dest;
    }

    static inline void pop(void *token) 
    {
        AutoreleasePoolPage *page;
        id *stop;

        if (token) {
            page = pageForPointer(token);
            stop = (id *)token;
            assert(*stop == POOL_SENTINEL);
        } else {
            // Token 0 is top-level pool
            page = coldPage();
            assert(page);
            stop = page->begin();
        }

        if (PrintPoolHiwat) printHiwat();

        page->releaseUntil(stop);

        // memory: delete empty children
        // hysteresis: keep one empty child if this page is more than half full
        // special case: delete everything for pop(0)
        if (!token) {
            page->kill();
            setHotPage(NULL);
        } else if (page->child) {
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            else if (page->child->child) {
                page->child->child->kill();
            }
        }
    }

    static void init()
    {
        int r __unused = pthread_key_init_np(AutoreleasePoolPage::key, 
                                             AutoreleasePoolPage::tls_dealloc);
        assert(r == 0);
    }

    void print() 
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        check(false);
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_SENTINEL) {
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
                _objc_inform("[%p]  %#16lx  %s", 
                             p, (unsigned long)*p, object_getClassName(*p));
            }
        }
    }

    static void printAll()
    {        
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", pthread_self());

        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        for (page = coldPage(); page; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        for (page = coldPage(); page; page = page->child) {
            page->print();
        }

        _objc_inform("##############");
    }

    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat  &&  mark > 256) {
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
            }
            
            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending autoreleases for thread %p:", 
                         mark, pthread_self());
            
            void *stack[128];
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            char **sym = backtrace_symbols(stack, count);
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
                free(sym);
        }
    }

#undef POOL_SENTINEL
};

// anonymous namespace
};

// API to only be called by root classes like NSObject or NSProxy

extern "C" {
__attribute__((used,noinline,nothrow))
static id _objc_rootRetain_slow(id obj);
__attribute__((used,noinline,nothrow))
static bool _objc_rootReleaseWasZero_slow(id obj);
};

id
_objc_rootRetain_slow(id obj)
{
    SideTable *table = SideTable::tableForPointer(obj);
    OSSpinLockLock(&table->slock);
    table->refcnts[DISGUISE(obj)] += 2;
    OSSpinLockUnlock(&table->slock);

    return obj;
}

id
_objc_rootRetain(id obj)
{
    assert(obj);
    assert(!UseGC);

    if (OBJC_IS_TAGGED_PTR(obj)) return obj;

    SideTable *table = SideTable::tableForPointer(obj);

    if (OSSpinLockTry(&table->slock)) {
        table->refcnts[DISGUISE(obj)] += 2;
        OSSpinLockUnlock(&table->slock);
        return obj;
    }
    return _objc_rootRetain_slow(obj);
}

bool
_objc_rootTryRetain(id obj) 
{
    assert(obj);
    assert(!UseGC);

    if (OBJC_IS_TAGGED_PTR(obj)) return true;

    SideTable *table = SideTable::tableForPointer(obj);

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.
    if (table->slock == 0) {
        _objc_fatal("Do not call -_tryRetain.");
    }

    bool result = true;
    RefcountMap::iterator it = table->refcnts.find(DISGUISE(obj));
    if (it == table->refcnts.end()) {
        table->refcnts[DISGUISE(obj)] = 2;
    } else if (it->second & 1) {
        result = false;
    } else {
        it->second += 2;
    }
    
    return result;
}

bool
_objc_rootIsDeallocating(id obj) 
{
    assert(obj);
    assert(!UseGC);

    if (OBJC_IS_TAGGED_PTR(obj)) return false;

    SideTable *table = SideTable::tableForPointer(obj);

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.
    if (table->slock == 0) {
        _objc_fatal("Do not call -_isDeallocating.");
    }

    RefcountMap::iterator it = table->refcnts.find(DISGUISE(obj));
    return (it != table->refcnts.end()) && ((it->second & 1) == 1);
}


void 
objc_clear_deallocating(id obj) 
{
    assert(obj);
    assert(!UseGC);

    SideTable *table = SideTable::tableForPointer(obj);

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    OSSpinLockLock(&table->slock);
    if (seen_weak_refs) {
        arr_clear_deallocating(&table->weak_table, obj);
    }
    table->refcnts.erase(DISGUISE(obj));
    OSSpinLockUnlock(&table->slock);
}


bool
_objc_rootReleaseWasZero_slow(id obj)
{
    SideTable *table = SideTable::tableForPointer(obj);

    bool do_dealloc = false;

    OSSpinLockLock(&table->slock);
    RefcountMap::iterator it = table->refcnts.find(DISGUISE(obj));
    if (it == table->refcnts.end()) {
        do_dealloc = true;
        table->refcnts[DISGUISE(obj)] = 1;
    } else if (it->second == 0) {
        do_dealloc = true;
        it->second = 1;
    } else {
        it->second -= 2;
    }
    OSSpinLockUnlock(&table->slock);
    return do_dealloc;
}

bool
_objc_rootReleaseWasZero(id obj)
{
    assert(obj);
    assert(!UseGC);

    if (OBJC_IS_TAGGED_PTR(obj)) return false;

    SideTable *table = SideTable::tableForPointer(obj);

    bool do_dealloc = false;

    if (OSSpinLockTry(&table->slock)) {
        RefcountMap::iterator it = table->refcnts.find(DISGUISE(obj));
        if (it == table->refcnts.end()) {
            do_dealloc = true;
            table->refcnts[DISGUISE(obj)] = 1;
        } else if (it->second == 0) {
            do_dealloc = true;
            it->second = 1;
        } else {
            it->second -= 2;
        }
        OSSpinLockUnlock(&table->slock);
        return do_dealloc;
    }
    return _objc_rootReleaseWasZero_slow(obj);
}

void
_objc_rootRelease(id obj)
{
    assert(obj);
    assert(!UseGC);

    if (_objc_rootReleaseWasZero(obj) == false) {
        return;
    }
    objc_msgSend_hack(obj, @selector(dealloc));
}

__attribute__((noinline,used))
static id _objc_rootAutorelease2(id obj)
{
    if (OBJC_IS_TAGGED_PTR(obj)) return obj;
    return AutoreleasePoolPage::autorelease(obj);
}

__attribute__((aligned(16)))
id
_objc_rootAutorelease(id obj)
{
    assert(obj); // root classes shouldn't get here, since objc_msgSend ignores nil
    assert(!UseGC);

    if (UseGC) {
        return obj;
    }

    // no tag check here: tagged pointers DO use fast autoreleasing

#if SUPPORT_RETURN_AUTORELEASE
    assert(_pthread_getspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY) == NULL);

    if (callerAcceptsFastAutorelease(__builtin_return_address(0))) {
        _pthread_setspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY, obj);
        return obj;
    }
#endif
    return _objc_rootAutorelease2(obj);
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    assert(obj);
    assert(!UseGC);

    // XXX -- There is no way that anybody can use this API race free in a
    // threaded environment because the result is immediately stale by the
    // time the caller receives it.

    if (OBJC_IS_TAGGED_PTR(obj)) return (uintptr_t)obj;    

    SideTable *table = SideTable::tableForPointer(obj);

    size_t refcnt_result = 1;
    
    OSSpinLockLock(&table->slock);
    RefcountMap::iterator it = table->refcnts.find(DISGUISE(obj));
    if (it != table->refcnts.end()) {
        refcnt_result = (it->second >> 1) + 1;
    }
    OSSpinLockUnlock(&table->slock);
    return refcnt_result;
}

id
_objc_rootInit(id obj)
{
	// In practice, it will be hard to rely on this function.
	// Many classes do not properly chain -init calls.
	return obj;
}

id
_objc_rootAllocWithZone(Class cls, malloc_zone_t *zone)
{
#if __OBJC2__
	// allocWithZone under __OBJC2__ ignores the zone parameter
	(void)zone;
	return class_createInstance(cls, 0);
#else
	if (!zone || UseGC) {
		return class_createInstance(cls, 0);
	}
	return class_createInstanceFromZone(cls, 0, zone);
#endif
}

id
_objc_rootAlloc(Class cls)
{
#if 0
	// once we get a bit in the class, data structure, we can call this directly
	// because allocWithZone under __OBJC2__ ignores the zone parameter
	return class_createInstance(cls, 0);
#else
	return [cls allocWithZone: nil];
#endif
}

void
_objc_rootDealloc(id obj)
{
    assert(obj);
    assert(!UseGC);

    if (OBJC_IS_TAGGED_PTR(obj)) return;

    object_dispose(obj);
}

void
_objc_rootFinalize(id obj __unused)
{
    assert(obj);
    assert(UseGC);

    if (UseGC) {
        return;
    }
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}

malloc_zone_t *
_objc_rootZone(id obj)
{
	(void)obj;
	if (gc_zone) {
		return gc_zone;
	}
#if __OBJC2__
	// allocWithZone under __OBJC2__ ignores the zone parameter
	return malloc_default_zone();
#else
	malloc_zone_t *rval = malloc_zone_from_ptr(obj);
	return rval ? rval : malloc_default_zone();
#endif
}

uintptr_t
_objc_rootHash(id obj)
{
	if (UseGC) {
		return _object_getExternalHash(obj);
	}
	return (uintptr_t)obj;
}

// make CF link for now
void *_objc_autoreleasePoolPush(void) { return objc_autoreleasePoolPush(); }
void _objc_autoreleasePoolPop(void *ctxt) { objc_autoreleasePoolPop(ctxt); }

void *
objc_autoreleasePoolPush(void)
{
    if (UseGC) return NULL;
    return AutoreleasePoolPage::push();
}

void
objc_autoreleasePoolPop(void *ctxt)
{
    if (UseGC) return;

    // fixme rdar://9167170
    if (!ctxt) return;

    AutoreleasePoolPage::pop(ctxt);
}

void 
_objc_autoreleasePoolPrint(void)
{
    if (UseGC) return;
    AutoreleasePoolPage::printAll();
}

#if SUPPORT_RETURN_AUTORELEASE

/*
  Fast handling of returned autoreleased values.
  The caller and callee cooperate to keep the returned object 
  out of the autorelease pool.

  Caller:
    ret = callee();
    objc_retainAutoreleasedReturnValue(ret);
    // use ret here

  Callee:
    // compute ret
    [ret retain];
    return objc_autoreleaseReturnValue(ret);

  objc_autoreleaseReturnValue() examines the caller's instructions following
  the return. If the caller's instructions immediately call
  objc_autoreleaseReturnValue, then the callee omits the -autorelease and saves
  the result in thread-local storage. If the caller does not look like it
  cooperates, then the callee calls -autorelease as usual.

  objc_autoreleaseReturnValue checks if the returned value is the same as the
  one in thread-local storage. If it is, the value is used directly. If not,
  the value is assumed to be truly autoreleased and is retained again.  In
  either case, the caller now has a retained reference to the value.

  Tagged pointer objects do participate in the fast autorelease scheme, 
  because it saves message sends. They are not entered in the autorelease 
  pool in the slow case.
*/

# if __x86_64__

static bool callerAcceptsFastAutorelease(const void * const ra0)
{
    const uint8_t *ra1 = (const uint8_t *)ra0;
    const uint16_t *ra2;
    const uint32_t *ra4 = (const uint32_t *)ra1;
    const void **sym;

#define PREFER_GOTPCREL 0
#if PREFER_GOTPCREL
    // 48 89 c7    movq  %rax,%rdi
    // ff 15       callq *symbol@GOTPCREL(%rip)
    if (*ra4 != 0xffc78948) {
        return false;
    }
    if (ra1[4] != 0x15) {
        return false;
    }
    ra1 += 3;
#else
    // 48 89 c7    movq  %rax,%rdi
    // e8          callq symbol
    if (*ra4 != 0xe8c78948) {
        return false;
    }
    ra1 += (long)*(const int32_t *)(ra1 + 4) + 8l;
    ra2 = (const uint16_t *)ra1;
    // ff 25       jmpq *symbol@DYLDMAGIC(%rip)
    if (*ra2 != 0x25ff) {
        return false;
    }
#endif
    ra1 += 6l + (long)*(const int32_t *)(ra1 + 2);
    sym = (const void **)ra1;
    if (*sym != objc_retainAutoreleasedReturnValue)
    {
        return false;
    }

    return true;
}

// __x86_64__
# else

#warning unknown architecture

static bool callerAcceptsFastAutorelease(const void *ra)
{
    return false;
}

# endif

// SUPPORT_RETURN_AUTORELEASE
#endif


id 
objc_autoreleaseReturnValue(id obj)
{
#if SUPPORT_RETURN_AUTORELEASE
    assert(_pthread_getspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY) == NULL);

    if (callerAcceptsFastAutorelease(__builtin_return_address(0))) {
        _pthread_setspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY, obj);
        return obj;
    }
#endif

    return objc_autorelease(obj);
}

id 
objc_retainAutoreleaseReturnValue(id obj)
{
    return objc_autoreleaseReturnValue(objc_retain(obj));
}

id
objc_retainAutoreleasedReturnValue(id obj)
{
#if SUPPORT_RETURN_AUTORELEASE
    if (obj == _pthread_getspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY)) {
        _pthread_setspecific_direct(AUTORELEASE_POOL_RECLAIM_KEY, 0);
        return obj;
    }
#endif
    return objc_retain(obj);
}

void
objc_storeStrong(id *location, id obj)
{
	// XXX FIXME -- GC support?
	id prev = *location;
	if (obj == prev) {
		return;
	}
	objc_retain(obj);
	*location = obj;
	objc_release(prev);
}

id
objc_retainAutorelease(id obj)
{
	return objc_autorelease(objc_retain(obj));
}

void
_objc_deallocOnMainThreadHelper(void *context)
{
	id obj = (id)context;
	objc_msgSend_hack(obj, @selector(dealloc));
}

// convert objc_objectptr_t to id, callee must take ownership.
NS_RETURNS_RETAINED id objc_retainedObject(objc_objectptr_t CF_CONSUMED pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
NS_RETURNS_NOT_RETAINED id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
CF_RETURNS_NOT_RETAINED objc_objectptr_t objc_unretainedPointer(id object) { return object; }


PRIVATE_EXTERN void arr_init(void) 
{
    AutoreleasePoolPage::init();
    SideTable::init();
}
