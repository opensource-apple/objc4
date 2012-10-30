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

#import <string.h>
#import <stddef.h>

#import <libkern/OSAtomic.h>

#import "objc-accessors.h"
#import <objc/objc-auto.h>
#import <objc/runtime.h>
#import "../objc-private.h"

#import "/usr/local/include/auto_zone.h"

#import "objc-accessors-table.h"

// stub interface declarations to make compiler happy.

@interface __NSCopyable
- (id)copyWithZone:(void *)zone;
@end

@interface __NSRetained
- (id)retain;
- (oneway void)release;
- (id)autorelease;
@end

static /*inline*/ IMP optimized_getter_for_gc(id self, SEL name, ptrdiff_t offset) {
    // replace this method with a faster version that does no message sends, and fewer tests.
    IMP getter = GETPROPERTY_IMP(offset);
    if (getter != NULL) {
        // HACK ALERT:  replaces the IMP in the cache!
        Class cls = self->isa;
        Method method = class_getInstanceMethod(cls, name);
        if (method_getImplementation(method) != getter)
            method_setImplementation(method, getter);
    }
    return getter;
}

static /*inline*/ IMP optimized_setter_for_gc(id self, SEL name, ptrdiff_t offset) {
    // replace this method with a faster version that does no message sends.
    IMP setter = SETPROPERTY_IMP(offset);
    if (setter != NULL) {
        // HACK ALERT:  replaces the IMP in the cache!
        Class cls = self->isa;
        Method method = class_getInstanceMethod(cls, name);
        if (method_getImplementation(method) != setter)
            method_setImplementation(method, setter);
    }
    return setter;
}

// ATOMIC entry points

typedef uintptr_t spin_lock_t;
extern void _spin_lock(spin_lock_t *lockp);
extern int  _spin_lock_try(spin_lock_t *lockp);
extern void _spin_unlock(spin_lock_t *lockp);

/* need to consider cache line contention - space locks out XXX */

#define GOODPOWER 7
#define GOODMASK ((1<<GOODPOWER)-1)
#define GOODHASH(x) (((long)x >> 5) & GOODMASK)
static spin_lock_t PropertyLocks[1 << GOODPOWER] = { 0 };

id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    if (UseGC) {
        // FIXME:  we could optimize getters when a class is first initialized, then KVO won't get confused.
        if (false) {
            IMP getter = optimized_getter_for_gc(self, _cmd, offset);
            if (getter) return getter(self, _cmd);
        }
        return *(id*) ((char*)self + offset);
    }
    
    // Retain release world
    id *slot = (id*) ((char*)self + offset);
    if (!atomic) return *slot;
        
    // Atomic retain release world
    spin_lock_t *slotlock = &PropertyLocks[GOODHASH(slot)];
    _spin_lock(slotlock);
    id value = [*slot retain];
    _spin_unlock(slotlock);
    
    // for performance, we (safely) issue the autorelease OUTSIDE of the spinlock.
    return [value autorelease];
}


void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, BOOL shouldCopy) {
    if (UseGC) {
        if (shouldCopy) {
            newValue = [newValue copyWithZone:NULL];
        }
        else if (false) {
            IMP setter = optimized_setter_for_gc(self, _cmd, offset);
            if (setter) {
                setter(self, _cmd, newValue);
                return;
            }
        }
        objc_assign_ivar_internal(newValue, self, offset);
        return;
    }

    // Retain release world
    id oldValue, *slot = (id*) ((char*)self + offset);

    // atomic or not, if slot would be unchanged, do nothing.
    if (!shouldCopy && *slot == newValue) return;
   
    newValue = (shouldCopy ? [newValue copyWithZone:NULL] : [newValue retain]);

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

    [oldValue release];
}


__private_extern__ auto_zone_t *gc_zone;

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
    if (UseGC && hasStrong) {
        auto_zone_write_barrier_memmove(gc_zone, dest, src, size);
    }
    else {
        memmove(dest, src, size);
    }
    if (atomic) {
        _spin_unlock(lockfirst);
        if (locksecond) _spin_unlock(locksecond);
    }
}

// PRE-ATOMIC entry points

id <NSCopying> object_getProperty_bycopy(id self, SEL _cmd, ptrdiff_t offset) {
    if (UseGC) {
        IMP getter = optimized_getter_for_gc(self, _cmd, offset);
        if (getter) return getter(self, _cmd);
    }
    id *slot = (id*) ((char*)self + offset);
    return *slot;
}

void object_setProperty_bycopy(id self, SEL _cmd, id <NSCopying> value, ptrdiff_t offset) {
    id *slot = (id*) ((char*)self + offset);
    id oldValue = *slot;
    objc_assign_ivar_internal([value copyWithZone:NULL], self, offset);
    [oldValue release];
}

id object_getProperty_byref(id self, SEL _cmd, ptrdiff_t offset) {
    if (UseGC) {
        IMP getter = optimized_getter_for_gc(self, _cmd, offset);
        if (getter) return getter(self, _cmd);
    }
    id *slot = (id*) ((char*)self + offset);
    return *slot;
}

void object_setProperty_byref(id self, SEL _cmd, id value, ptrdiff_t offset) {
    if (UseGC) {
        IMP setter = optimized_setter_for_gc(self, _cmd, offset);
        if (setter) {
            setter(self, _cmd, value);
            return;
        }
    }
    id *slot = (id*) ((char*)self + offset);
    id oldValue = *slot;
    if (oldValue != value) {
        objc_assign_ivar_internal([value retain], self, offset);
        [oldValue release];
    }
}
