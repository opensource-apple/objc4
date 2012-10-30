/*
 * Copyright (c) 2006-2008 Apple Inc.  All Rights Reserved.
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

#import <string.h>
#import <stddef.h>

#import <libkern/OSAtomic.h>

#import "objc-private.h"
#import "objc-auto.h"
#import "runtime.h"
#import "objc-accessors.h"

// stub interface declarations to make compiler happy.

@interface __NSCopyable
- (id)copyWithZone:(void *)zone;
@end

@interface __NSMutableCopyable
- (id)mutableCopyWithZone:(void *)zone;
@end


typedef uintptr_t spin_lock_t;
extern void _spin_lock(spin_lock_t *lockp);
extern int  _spin_lock_try(spin_lock_t *lockp);
extern void _spin_unlock(spin_lock_t *lockp);

/* need to consider cache line contention - space locks out XXX */

#define GOODPOWER 7
#define GOODMASK ((1<<GOODPOWER)-1)
#define GOODHASH(x) (((long)x >> 5) & GOODMASK)
static spin_lock_t PropertyLocks[1 << GOODPOWER] = { 0 };

PRIVATE_EXTERN id objc_getProperty_gc(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    return *(id*) ((char*)self + offset);
}

PRIVATE_EXTERN id objc_getProperty_non_gc(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    // Retain release world
    id *slot = (id*) ((char*)self + offset);
    if (!atomic) return *slot;
        
    // Atomic retain release world
    spin_lock_t *slotlock = &PropertyLocks[GOODHASH(slot)];
    _spin_lock(slotlock);
    id value = objc_retain(*slot);
    _spin_unlock(slotlock);
    
    // for performance, we (safely) issue the autorelease OUTSIDE of the spinlock.
    return objc_autoreleaseReturnValue(value);
}

id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    return 
#if SUPPORT_GC
        (UseGC ? objc_getProperty_gc : objc_getProperty_non_gc)
#else
        objc_getProperty_non_gc
#endif
            (self, _cmd, offset, atomic);
}

enum { OBJC_PROPERTY_RETAIN = 0, OBJC_PROPERTY_COPY = 1, OBJC_PROPERTY_MUTABLECOPY = 2 };

#if SUPPORT_GC
PRIVATE_EXTERN void objc_setProperty_gc(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy) {
    if (shouldCopy) {
        newValue = (shouldCopy == OBJC_PROPERTY_MUTABLECOPY ? [newValue mutableCopyWithZone:NULL] : [newValue copyWithZone:NULL]);
    }
    objc_assign_ivar_gc(newValue, self, offset);
}
#endif

PRIVATE_EXTERN void objc_setProperty_non_gc(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy) {
    // Retain release world
    id oldValue, *slot = (id*) ((char*)self + offset);

    // atomic or not, if slot would be unchanged, do nothing.
    if (!shouldCopy && *slot == newValue) return;
   
    if (shouldCopy) {
        newValue = (shouldCopy == OBJC_PROPERTY_MUTABLECOPY ? [newValue mutableCopyWithZone:NULL] : [newValue copyWithZone:NULL]);
    } else {
        newValue = objc_retain(newValue);
    }

    if (!atomic) {
        oldValue = *slot;
        *slot = newValue;
    } else {
        spin_lock_t *slotlock = &PropertyLocks[GOODHASH(slot)];
        _spin_lock(slotlock);
        oldValue = *slot;
        *slot = newValue;        
        _spin_unlock(slotlock);        
    }

    objc_release(oldValue);
}

void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy) {
#if SUPPORT_GC
    (UseGC ? objc_setProperty_gc : objc_setProperty_non_gc)
#else
    objc_setProperty_non_gc
#endif
        (self, _cmd, offset, newValue, atomic, shouldCopy);
}


// This entry point was designed wrong.  When used as a getter, src needs to be locked so that
// if simultaneously used for a setter then there would be contention on src.
// So we need two locks - one of which will be contended.
void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong) {
    static spin_lock_t StructLocks[1 << GOODPOWER] = { 0 };
    spin_lock_t *lockfirst = NULL;
    spin_lock_t *locksecond = NULL;
    if (atomic) {
        lockfirst = &StructLocks[GOODHASH(src)];
        locksecond = &StructLocks[GOODHASH(dest)];
        // order the locks by address so that we don't deadlock
        if (lockfirst > locksecond) {
            lockfirst = locksecond;
            locksecond = &StructLocks[GOODHASH(src)];
        }
        else if (lockfirst == locksecond) {
            // lucky - we only need one lock
            locksecond = NULL;
        }
        _spin_lock(lockfirst);
        if (locksecond) _spin_lock(locksecond);
    }
#if SUPPORT_GC
    if (UseGC && hasStrong) {
        auto_zone_write_barrier_memmove(gc_zone, dest, src, size);
    } else 
#endif
    {
        memmove(dest, src, size);
    }
    if (atomic) {
        _spin_unlock(lockfirst);
        if (locksecond) _spin_unlock(locksecond);
    }
}

