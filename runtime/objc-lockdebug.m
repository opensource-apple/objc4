/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-lock.m
* Error-checking locks for debugging.
**********************************************************************/

#import "objc-private.h"

typedef struct _objc_lock_list {
    int allocated;
    int used;
    mutex_t list[0];  // variable-size
} _objc_lock_list;

static struct _objc_lock_list *
getLocks(BOOL create)
{
    _objc_pthread_data *data;
    _objc_lock_list *locks;

    data = _objc_fetch_pthread_data(create);
    if (!data  &&  !create) return NULL;

    locks = data->lockList;
    if (!locks) {
        if (!create) {
            return NULL;
        } else {
            locks = _calloc_internal(1, sizeof(_objc_lock_list) + sizeof(mutex_t) * 4);
            locks->allocated = 4;
            locks->used = 0;
            data->lockList = locks;
        }
    }

    if (locks->allocated == locks->used) {
        if (!create) {
            return locks;
        } else {
            data->lockList = _calloc_internal(1, sizeof(_objc_lock_list) + 2 * locks->used * sizeof(mutex_t));
            data->lockList->used = locks->used;
            data->lockList->allocated = locks->used * 2;
            memcpy(data->lockList->list, locks->list, locks->used * sizeof(mutex_t));
            _free_internal(locks);
            locks = data->lockList;
        }
    }

    return locks;
}


static BOOL 
hasLock(_objc_lock_list *locks, mutex_t lock)
{
    int i;
    if (!locks) return NO;
    
    for (i = 0; i < locks->used; i++) {
        if (locks->list[i] == lock) return YES;
    }
    return NO;
}


static void 
setLock(_objc_lock_list *locks, mutex_t lock)
{
    locks->list[locks->used++] = lock;
}

static void 
clearLock(_objc_lock_list *locks, mutex_t lock)
{
    int i;
    for (i = 0; i < locks->used; i++) {
        if (locks->list[i] == lock) {
            locks->list[i] = locks->list[--locks->used];
            return;
        }
    }
}


__private_extern__ void 
_lock_debug(mutex_t lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);
    if (hasLock(locks, lock)) _objc_fatal("deadlock: relocking %s\n", name+1);
    setLock(locks, lock);
    mutex_lock(lock);
}


__private_extern__ void 
_checklock_debug(mutex_t lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);
    if (!hasLock(locks, lock)) _objc_fatal("%s incorrectly not held\n",name+1);
}


__private_extern__ void 
_checkunlock_debug(mutex_t lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);
    if (hasLock(locks, lock)) _objc_fatal("%s incorrectly held\n", name+1);
}


__private_extern__ void 
_unlock_debug(mutex_t lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);
    if (!hasLock(locks, lock)) _objc_fatal("unlocking unowned %s\n", name+1);
    clearLock(locks, lock);
    mutex_unlock(lock);
}


__private_extern__ void
_destroyLockList(struct _objc_lock_list *locks)
{
    // fixme complain about any still-held locks?
    if (locks) _free_internal(locks);
}
