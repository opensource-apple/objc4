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

#ifndef NO_BUILTINS
#include "objc-selopt.h"
#endif

__BEGIN_DECLS

#ifndef NO_BUILTINS
// builtins: the actual table used at runtime
// _objc_selopt_data: the usual builtin table, possibly rewritten by dyld
// empty_selopt_data: an empty table to use if DisablePreopt is set
using namespace objc_selopt;
static const objc_selopt_t *builtins = NULL;
extern const objc_selopt_t _objc_selopt_data;  // in __TEXT, __objc_selopt
static const uint32_t empty_selopt_data[] = SELOPT_INITIALIZER;
#endif


#define NUM_NONBUILTIN_SELS 3500
// objc_sel_set grows at 3571, 5778, 9349. 
// Most apps use 2000..7000 extra sels. Most apps will grow zero to two times.

static const char *_objc_empty_selector = "";
static struct __objc_sel_set *_objc_selectors = NULL;


#ifndef NO_GC
static inline int ignore_selector(const char *sel)
{
    // force retain/release/autorelease to be a constant value when GC is on
    // note that the selectors for "Protocol" are registered before we can
    // see the executable image header that sets _WantsGC, so we can't cache
    // this result (sigh).
    return (UseGC &&
            (  (sel[0] == 'r' && sel[1] == 'e' &&
                (_objc_strcmp(&sel[2], "lease") == 0 || 
                 _objc_strcmp(&sel[2], "tain") == 0 ||
                 _objc_strcmp(&sel[2], "tainCount") == 0 ))
               ||
               (_objc_strcmp(sel, "dealloc") == 0)
               || 
               (sel[0] == 'a' && sel[1] == 'u' && 
                _objc_strcmp(&sel[2], "torelease") == 0)));
}
#endif


#ifndef NO_BUILTINS
__private_extern__ void dump_builtins(void)
{
    if (builtins->version != VERSION) {
        _objc_inform("BUILTIN SELECTORS: unknown version %d (want %d)", 
                     builtins->version, VERSION);
        return;
    }

    uint32_t occupied = builtins->occupied;
    uint32_t capacity = builtins->capacity;

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

    _objc_inform("BUILTIN SELECTORS: %d selectors", occupied);
    _objc_inform("BUILTIN SELECTORS: %d/%d (%d%%) hash table occupancy", 
                 occupied, capacity, (int)(occupied/(double)capacity * 100));
    _objc_inform("BUILTIN SELECTORS: using __TEXT,__objc_selopt at %p", 
                 builtins);
    _objc_inform("BUILTIN SELECTORS: version: %u", builtins->version);
    _objc_inform("BUILTIN SELECTORS: capacity: %u", builtins->capacity);
    _objc_inform("BUILTIN SELECTORS: occupied: %u", builtins->occupied);
    _objc_inform("BUILTIN SELECTORS: shift: %u", builtins->shift);
    _objc_inform("BUILTIN SELECTORS: mask: 0x%x", builtins->mask);
    _objc_inform("BUILTIN SELECTORS: zero: %u", builtins->zero);
    _objc_inform("BUILTIN SELECTORS: salt: 0x%llx", builtins->salt);
    _objc_inform("BUILTIN SELECTORS: base: 0x%llx", builtins->base);
}
#endif


static SEL _objc_search_builtins(const char *key) 
{
#if defined(DUMP_SELECTORS)
    if (NULL != key) printf("\t\"%s\",\n", key);
#endif

    if (!key) return (SEL)0;
#ifndef NO_GC
    if ((uintptr_t)key == kIgnore) return (SEL)kIgnore;
    if (ignore_selector(key)) return (SEL)kIgnore;
#endif
    if ('\0' == *key) return (SEL)_objc_empty_selector;

#ifndef NO_BUILTINS
    return (SEL)builtins->get(key);
#endif

    return (SEL)0;
}


const char *sel_getName(SEL sel) {
#ifndef NO_GC
    if ((uintptr_t)sel == kIgnore) return "<ignored selector>";
#endif
    return sel ? (const char *)sel : "<null selector>";
}


BOOL sel_isMapped(SEL name) 
{
    SEL result;
    
    if (!name) return NO;
    if ((uintptr_t)name == kIgnore) return YES;

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

__private_extern__ SEL sel_registerNameNoLock(const char *name, BOOL copy) {
    return __sel_registerName(name, 0, copy);  // NO lock, maybe copy
}

__private_extern__ void sel_lock(void)
{
    rwlock_write(&selLock);
}

__private_extern__ void sel_unlock(void)
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
__private_extern__ BOOL sel_preoptimizationValid(const header_info *hi)
{
#ifdef NO_BUILTINS

    return NO;

#else

# ifndef NO_GC
    // shared cache can't fix ignored selectors
    if (UseGC) return NO;
# endif

    // image not from shared cache, or not fixed inside shared cache
    if (!_objcHeaderOptimizedByDyld(hi)) return NO;

    // libobjc not from shared cache, or from shared cache but slid
    if (builtins->base != (uintptr_t)builtins) return NO;

    return YES;

#endif
}


/***********************************************************************
* sel_init
* Initialize selector tables and register selectors used internally.
**********************************************************************/
__private_extern__ void sel_init(BOOL wantsGC)
{
#ifdef NO_BUILTINS

    disableSelectorPreoptimization();

#else
    // not set at compile time in order to detect too-early selector operations
    builtins = &_objc_selopt_data;

    // Check selector table (possibly built by dyld shared cache)
    if (builtins->base == (uintptr_t)builtins && !UseGC && !DisablePreopt) {
        // Valid selector table written by dyld shared cache
        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: selector preoptimization ENABLED "
                         "(version %d)", builtins->version);
        }
    }
    else {
        // Selector table written by dyld shared cache, but slid
        // OR selector table not written by dyld shared cache
        // OR gc is on which renames ignored selectors
        // OR disabled by environment variable
        // All preoptimized selector references are invalid.

        // But keep the builtins table itself unless disabled by environment
        if (DisablePreopt) builtins = (objc_selopt_t *)empty_selopt_data;

        disableSelectorPreoptimization();

        if (PrintPreopt) {
            const char *why;
            if (DisablePreopt) why = "(by OBJC_DISABLE_PREOPTIMIZATION)";
            else if (UseGC) why = "(GC is on)";
            else why = "(dyld shared cache is absent or out of date)";
            _objc_inform("PREOPTIMIZATION: selector preoptimization DISABLED %s", why);
        }
    }

    // Die if the table looks bad.
    // We should always end up with a good dyld table, 
    // or the compiled-in table, or the compiled-in empty table.
    // Failure probably means you forgot to update the compiled-in table data.
    // Don't do this before checking DisablePreopt.
    if (builtins->version != VERSION) {
        _objc_fatal("bad objc selector table (want %d, got %d)", 
                    VERSION, builtins->version);
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
    s(copy);
    s(finalize);

    sel_unlock();

#undef s
#undef t
}

__END_DECLS
