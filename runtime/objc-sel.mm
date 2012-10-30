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
 *	Utilities for registering and looking up selectors.  The sole
 *	purpose of the selector tables is a registry whereby there is
 *	exactly one address (selector) associated with a given string
 *	(method name).
 */

#include "objc.h"
#include "objc-private.h"
#include "objc-auto.h"
#include "objc-sel-set.h"

#if SUPPORT_BUILTINS
#include "objc-selopt.h"
#endif

__BEGIN_DECLS

#if SUPPORT_BUILTINS
// opt: the actual opt used at runtime
// builtins: the actual selector table used at runtime
// _objc_opt_data: opt data possibly written by dyld
// empty_opt_data: empty data to use if dyld didn't cooperate or DisablePreopt
using namespace objc_opt;
static const objc_selopt_t *builtins = NULL;
static const objc_opt_t *opt = NULL;
static BOOL preoptimized;

extern const objc_opt_t _objc_opt_data;  // in __TEXT, __objc_selopt
static const uint32_t empty_opt_data[] = OPT_INITIALIZER;
#endif


#define NUM_NONBUILTIN_SELS 3500
// objc_sel_set grows at 3571, 5778, 9349. 
// Most apps use 2000..7000 extra sels. Most apps will grow zero to two times.

static const char *_objc_empty_selector = "";
static struct __objc_sel_set *_objc_selectors = NULL;


#if SUPPORT_BUILTINS
PRIVATE_EXTERN void dump_builtins(void)
{
    uint32_t occupied = builtins->occupied;
    uint32_t capacity = builtins->capacity;

    _objc_inform("BUILTIN SELECTORS: %d selectors", occupied);
    _objc_inform("BUILTIN SELECTORS: %d/%d (%d%%) hash table occupancy", 
                 occupied, capacity, (int)(occupied/(double)capacity * 100));
    _objc_inform("BUILTIN SELECTORS: using __TEXT,__objc_selopt at %p", 
                 builtins);
    _objc_inform("BUILTIN SELECTORS: capacity: %u", builtins->capacity);
    _objc_inform("BUILTIN SELECTORS: occupied: %u", builtins->occupied);
    _objc_inform("BUILTIN SELECTORS: shift: %u", builtins->shift);
    _objc_inform("BUILTIN SELECTORS: mask: 0x%x", builtins->mask);
    _objc_inform("BUILTIN SELECTORS: zero: %u", builtins->zero);
    _objc_inform("BUILTIN SELECTORS: salt: 0x%llx", builtins->salt);

    const int32_t *offsets = builtins->offsets();
    uint32_t i;
    for (i = 0; i < capacity; i++) {
        if (offsets[i] != offsetof(objc_selopt_t, zero)) {
            const char *str = (const char *)builtins + offsets[i];
            _objc_inform("BUILTIN SELECTORS:     %6d: %+8d %s", 
                         i, offsets[i], str);
        } else {
            _objc_inform("BUILTIN SELECTORS:     %6d: ", i);
        }
    }
}
#endif


static SEL _objc_search_builtins(const char *key) 
{
#if defined(DUMP_SELECTORS)
    if (NULL != key) printf("\t\"%s\",\n", key);
#endif

    if (!key) return (SEL)0;
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
    if ((uintptr_t)key == kIgnore) return (SEL)kIgnore;
    if (ignoreSelectorNamed(key)) return (SEL)kIgnore;
#endif
    if ('\0' == *key) return (SEL)_objc_empty_selector;

#if SUPPORT_BUILTINS
    return (SEL)builtins->get(key);
#endif

    return (SEL)0;
}


const char *sel_getName(SEL sel) {
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
    if ((uintptr_t)sel == kIgnore) return "<ignored selector>";
#endif
    return sel ? (const char *)sel : "<null selector>";
}


BOOL sel_isMapped(SEL name) 
{
    SEL result;
    
    if (!name) return NO;
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
    if ((uintptr_t)name == kIgnore) return YES;
#endif

    result = _objc_search_builtins((const char *)name);
    if (result) return YES;

    rwlock_read(&selLock);
    if (_objc_selectors) {
        result = __objc_sel_set_get(_objc_selectors, name);
    }
    rwlock_unlock_read(&selLock);
    return result ? YES : NO;
}

static SEL __sel_registerName(const char *name, int lock, int copy) 
{
    SEL result = 0;

    if (lock) rwlock_assert_unlocked(&selLock);
    else rwlock_assert_writing(&selLock);

    if (!name) return (SEL)0;
    result = _objc_search_builtins(name);
    if (result) return result;
    
    if (lock) rwlock_read(&selLock);
    if (_objc_selectors) {
        result = __objc_sel_set_get(_objc_selectors, (SEL)name);
    }
    if (lock) rwlock_unlock_read(&selLock);
    if (result) return result;

    // No match. Insert.

    if (lock) rwlock_write(&selLock);

    if (!_objc_selectors) {
        _objc_selectors = __objc_sel_set_create(NUM_NONBUILTIN_SELS);
    }
    if (lock) {
        // Rescan in case it was added while we dropped the lock
        result = __objc_sel_set_get(_objc_selectors, (SEL)name);
    }
    if (!result) {
        result = (SEL)(copy ? _strdup_internal(name) : name);
        __objc_sel_set_add(_objc_selectors, result);
#if defined(DUMP_UNKNOWN_SELECTORS)
        printf("\t\"%s\",\n", name);
#endif
    }

    if (lock) rwlock_unlock_write(&selLock);
    return result;
}


SEL sel_registerName(const char *name) {
    return __sel_registerName(name, 1, 1);     // YES lock, YES copy
}

PRIVATE_EXTERN SEL sel_registerNameNoLock(const char *name, BOOL copy) {
    return __sel_registerName(name, 0, copy);  // NO lock, maybe copy
}

PRIVATE_EXTERN void sel_lock(void)
{
    rwlock_write(&selLock);
}

PRIVATE_EXTERN void sel_unlock(void)
{
    rwlock_unlock_write(&selLock);
}


// 2001/1/24
// the majority of uses of this function (which used to return NULL if not found)
// did not check for NULL, so, in fact, never return NULL
//
SEL sel_getUid(const char *name) {
    return __sel_registerName(name, 2, 1);  // YES lock, YES copy
}


BOOL sel_isEqual(SEL lhs, SEL rhs)
{
    return (lhs == rhs) ? YES : NO;
}


/***********************************************************************
* sel_preoptimizationValid
* Return YES if this image's selector fixups are valid courtesy 
* of the dyld shared cache.
**********************************************************************/
PRIVATE_EXTERN BOOL sel_preoptimizationValid(const header_info *hi)
{
#if !SUPPORT_BUILTINS

    return NO;

#else

# if SUPPORT_IGNORED_SELECTOR_CONSTANT
    // shared cache can't fix constant ignored selectors
    if (UseGC) return NO;
# endif

    // preoptimization disabled for some reason
    if (!preoptimized) return NO;

    // image not from shared cache, or not fixed inside shared cache
    if (!_objcHeaderOptimizedByDyld(hi)) return NO;

    return YES;

#endif
}


/***********************************************************************
* sel_init
* Initialize selector tables and register selectors used internally.
**********************************************************************/
PRIVATE_EXTERN void sel_init(BOOL wantsGC)
{
#if !SUPPORT_BUILTINS

    disableSharedCacheOptimizations();    

#else
    // not set at compile time in order to detect too-early selector operations
    const char *failure = NULL;
    opt = &_objc_opt_data;

    if (DisablePreopt) {
        // OBJC_DISABLE_PREOPTIMIZATION is set
        // If opt->version != VERSION then you continue at your own risk.
        failure = "(by OBJC_DISABLE_PREOPTIMIZATION)";
    } 
    else if (opt->version != objc_opt::VERSION) {
        // This shouldn't happen. You probably forgot to 
        // change OPT_INITIALIZER and objc-sel-table.s.
        // If dyld really did write the wrong optimization version, 
        // then we must halt because we don't know what bits dyld twiddled.
        _objc_fatal("bad objc opt version (want %d, got %d)", 
                    objc_opt::VERSION, opt->version);
    }
    else if (!opt->selopt()) {
        // No selector table. dyld must not have written one.
        failure = "(dyld shared cache is absent or out of date)";
    }
#if SUPPORT_IGNORED_SELECTOR_CONSTANT
    else if (UseGC) {
        // GC is on, which renames some selectors
        // Non-selector optimizations are still valid, but we don't have
        // any of those yet
        failure = "(GC is on)";
    }
#endif

    if (failure) {
        // All preoptimized selector references are invalid.
        preoptimized = NO;
        opt = (objc_opt_t *)empty_opt_data;
        builtins = opt->selopt();
        disableSharedCacheOptimizations();

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: is DISABLED %s", failure);
        }
    }
    else {
        // Valid optimization data written by dyld shared cache
        preoptimized = YES;
        builtins = opt->selopt();

        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: is ENABLED "
                         "(version %d)", opt->version);
        }
    }

#endif

    // Register selectors used by libobjc

    if (wantsGC) {
        // Registering retain/release/autorelease requires GC decision first.
        // sel_init doesn't actually need the wantsGC parameter, it just 
        // helps enforce the initialization order.
    }

#define s(x) SEL_##x = sel_registerNameNoLock(#x, NO)
#define t(x,y) SEL_##y = sel_registerNameNoLock(#x, NO)

    sel_lock();

    s(load);
    s(initialize);
    t(resolveInstanceMethod:, resolveInstanceMethod);
    t(resolveClassMethod:, resolveClassMethod);
    t(.cxx_construct, cxx_construct);
    t(.cxx_destruct, cxx_destruct);
    s(retain);
    s(release);
    s(autorelease);
    s(retainCount);
    s(alloc);
    s(copy);
    s(new);
    s(finalize);
    t(forwardInvocation:, forwardInvocation);

    sel_unlock();

#undef s
#undef t
}

__END_DECLS
