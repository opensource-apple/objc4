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

#include <objc/objc.h>
#import "objc-private.h"
#import "objc-auto.h"
#import "objc-rtp.h"
#import "objc-sel-set.h"

// _objc_builtin_selectors[]
#include "objc-sel-table.h"

// from phash.c
extern uint32_t phash(const char *key, int len);

#define NUM_NONBUILTIN_SELS 3500
// objc_sel_set grows at 3571, 5778, 9349. 
// Most apps use 2000..7000 extra sels. Most apps will grow zero to two times.

static const char *_objc_empty_selector = "";
static OBJC_DECLARE_LOCK(_objc_selector_lock);
static struct __objc_sel_set *_objc_selectors = NULL;


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


static SEL _objc_search_builtins(const char *key) {
    const char *sel;
    uint32_t hash;

#if defined(DUMP_SELECTORS)
    if (NULL != key) printf("\t\"%s\",\n", key);
#endif

    /* The builtin table contains only sels starting with '[.A-z]', including '_' */
    if (!key) return (SEL)0;
    if ((intptr_t)key == kIgnore) return (SEL)kIgnore;
    if ('\0' == *key) return (SEL)_objc_empty_selector;
    if ((*key < 'A' || 'z' < *key)  &&  *key != '.') return (SEL)0;
    if (ignore_selector(key)) return (SEL)kIgnore;

    hash = phash(key, (int)__builtin_strlen(key));
    sel = _objc_builtin_selectors[hash];
    if (sel  &&  0 == __builtin_strcmp(key, sel)) return (SEL)sel;
    else return (SEL)0;
}


const char *sel_getName(SEL sel) {
    if ((intptr_t)sel == kIgnore) return "<ignored selector>";
    return sel ? (const char *)sel : "<null selector>";
}


BOOL sel_isMapped(SEL name) {
    SEL result;
    
    if (NULL == name) return NO;
    result = _objc_search_builtins((const char *)name);
    if ((SEL)0 != result) return YES;
    OBJC_LOCK(&_objc_selector_lock);
    if (_objc_selectors) {
        result = __objc_sel_set_get(_objc_selectors, name);
    }
    OBJC_UNLOCK(&_objc_selector_lock);
    return ((SEL)0 != (SEL)result) ? YES : NO;
}

static SEL __sel_registerName(const char *name, int lock, int copy) {
    SEL result = 0;

    if (NULL == name) return (SEL)0;
    result = _objc_search_builtins(name);
    if (result != NULL) return result;
    
    if (lock) OBJC_LOCK(&_objc_selector_lock);

    if (_objc_selectors) {
        result = __objc_sel_set_get(_objc_selectors, (SEL)name);
    }
    if (result == NULL) {
        if (!_objc_selectors) {
            _objc_selectors = __objc_sel_set_create(NUM_NONBUILTIN_SELS);
        }
        result = (SEL)(copy ? _strdup_internal(name) : name);
        __objc_sel_set_add(_objc_selectors, result);
#if defined(DUMP_UNKNOWN_SELECTORS)
        printf("\t\"%s\",\n", name);
#endif
    }

    if (lock) OBJC_UNLOCK(&_objc_selector_lock);
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
    OBJC_LOCK(&_objc_selector_lock);
}

__private_extern__ void sel_unlock(void)
{
    OBJC_UNLOCK(&_objc_selector_lock);
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
