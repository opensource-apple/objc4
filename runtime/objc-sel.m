/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
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
#include <CoreFoundation/CFSet.h>
#import "objc-private.h"

// NUM_BUILTIN_SELS, LG_NUM_BUILTIN_SELS, _objc_builtin_selectors
#include "objc-sel-table.h"

#define NUM_NONBUILTIN_SELS 3500
// Panther CFSet grows at 3571, 5778, 9349. 
// Most apps use 2000..7000 extra sels. Most apps will grow zero to two times.

static const char *_objc_empty_selector = "";

static SEL _objc_search_builtins(const char *key) {
    int c, idx, lg = LG_NUM_BUILTIN_SELS;
    const char *s;

#if defined(DUMP_SELECTORS)
    if (NULL != key) printf("\t\"%s\",\n", key);
#endif
    /* The builtin table contains only sels starting with '[A-z]', including '_' */
    if (!key) return (SEL)0;
    if ('\0' == *key) return (SEL)_objc_empty_selector;
    if (*key < 'A' || 'z' < *key) return (SEL)0;
    s = _objc_builtin_selectors[-1 + (1 << lg)];
    c = _objc_strcmp(s, key);
    if (c == 0) return (SEL)s;
    idx = (c < 0) ? NUM_BUILTIN_SELS - (1 << lg) : -1;
    while (--lg >= 0) {
	s = _objc_builtin_selectors[idx + (1 << lg)];
	c = _objc_strcmp(s, key);
	if (c == 0) return (SEL)s;
	if (c < 0) idx += (1 << lg);
    }
    return (SEL)0;
}

static OBJC_DECLARE_LOCK(_objc_selector_lock);
static CFMutableSetRef _objc_selectors = NULL;

static Boolean _objc_equal_selector(const void *v1, const void *v2) {
    if (v1 == v2) return TRUE;
    if ((v1 == NULL) || (v2 == NULL)) return FALSE;
    return _objc_strcmp((const unsigned char *)v1, (const unsigned char *)v2) == 0;
}

static CFHashCode _objc_hash_selector(const void *v) {
    if (!v) return 0;
    return (CFHashCode)_objc_strhash(v);
}

const char *sel_getName(SEL sel) {
    return sel ? (const char *)sel : "<null selector>";
}


BOOL sel_isMapped(SEL name) {
    SEL result;
    const void *value;
    
    if (NULL == name) return NO;
    result = _objc_search_builtins((const char *)name);
    if ((SEL)0 != result) return YES;
    OBJC_LOCK(&_objc_selector_lock);
    if (_objc_selectors && CFSetGetValueIfPresent(_objc_selectors, name, &value)) {
        result = (SEL)value;
    }
    OBJC_UNLOCK(&_objc_selector_lock);
    return ((SEL)0 != (SEL)result) ? YES : NO;
}

// CoreFoundation private API
extern void _CFSetSetCapacity(CFMutableSetRef set, CFIndex cap);

static SEL __sel_registerName(const char *name, int lockAndCopy) {
    SEL result = 0;
    const void *value;
    if (NULL == name) return (SEL)0;
    result = _objc_search_builtins(name);
    if ((SEL)0 != result) return result;
    
    if (lockAndCopy) OBJC_LOCK(&_objc_selector_lock);
    if (!_objc_selectors || !CFSetGetValueIfPresent(_objc_selectors, name, &value)) {
	if (!_objc_selectors) {
	    CFSetCallBacks cb = {0, NULL, NULL, NULL,
		_objc_equal_selector, _objc_hash_selector};
	    _objc_selectors = CFSetCreateMutable(kCFAllocatorDefault, 0, &cb);
	    _CFSetSetCapacity(_objc_selectors, NUM_NONBUILTIN_SELS);
	    CFSetAddValue(_objc_selectors, (void *)NULL);
	}
	//if (lockAndCopy > 1) printf("registering %s for sel_getUid\n",name);
	value = lockAndCopy ? strdup(name) : name;
	CFSetAddValue(_objc_selectors, (void *)value);
#if defined(DUMP_UNKNOWN_SELECTORS)
	printf("\t\"%s\",\n", value);
#endif
    }
    result = (SEL)value;
    if (lockAndCopy) OBJC_UNLOCK(&_objc_selector_lock);
    return result;
}

SEL sel_registerName(const char *name) {
    return __sel_registerName(name, 1);
}

__private_extern__ SEL sel_registerNameNoCopyNoLock(const char *name) {
    return __sel_registerName(name, 0);
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
    return __sel_registerName(name, 2);
}
