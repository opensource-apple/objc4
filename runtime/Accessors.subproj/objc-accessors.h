/*
 * Copyright (c) 2006-2007 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_ACCESSORS_H_
#define _OBJC_ACCESSORS_H_

#import <objc/objc.h>
#import <stddef.h>

__BEGIN_DECLS

// Called under non-GC for retain or copy attributed properties
void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy);
id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic);

// GC-specific accessors.
void objc_setProperty_gc(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy);
id objc_getProperty_gc(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic);

// Non-GC accessors.
void objc_setProperty_non_gc(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy);
id objc_getProperty_non_gc(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic);

// Called under GC by compiler for copying structures containing objects or other strong pointers when
// the destination memory is not known to be stack local memory.
// Called to read instance variable structures (or other non-word sized entities) atomically 
void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong);

// OBSOLETE

@protocol NSCopying;

// called for @property(copy)
id <NSCopying> object_getProperty_bycopy(id object, SEL _cmd, ptrdiff_t offset);
void object_setProperty_bycopy(id object, SEL _cmd, id <NSCopying> value, ptrdiff_t offset);

// called for @property(retain)
id object_getProperty_byref(id object, SEL _cmd, ptrdiff_t offset);
void object_setProperty_byref(id object, SEL _cmd, id value, ptrdiff_t offset);

__END_DECLS

#endif
