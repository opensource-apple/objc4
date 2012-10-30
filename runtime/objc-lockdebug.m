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

#include "objc-private.h"

#if !defined(NDEBUG)  &&  !TARGET_OS_WIN32

/***********************************************************************
* Recording - per-thread list of mutexes and monitors held
**********************************************************************/

typedef struct {
    void *l;  // the lock itself
    int k;    // the kind of lock it is (MUTEX, MONITOR, etc)
    int i;    // the lock's nest count
} lockcount;

#define MUTEX 1
#define MONITOR 2
#define RDLOCK 3
#define WRLOCK 4
#define RECURSIVE 5

typedef struct _objc_lock_list {
    int allocated;
    int used;
    lockcount list[0];
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
            locks = _calloc_internal(1, sizeof(_objc_lock_list) + sizeof(lockcount) * 16);
            locks->allocated = 16;
            locks->used = 0;
            data->lockList = locks;
        }
    }

    if (locks->allocated == locks->used) {
        if (!create) {
            return locks;
        } else {
            data->lockList = _calloc_internal(1, sizeof(_objc_lock_list) + 2 * locks->used * sizeof(lockcount));
            data->lockList->used = locks->used;
            data->lockList->allocated = locks->used * 2;
            memcpy(data->lockList->list, locks->list, locks->used * sizeof(lockcount));
            _free_internal(locks);
            locks = data->lockList;
        }
    }

    return locks;
}

static BOOL 
hasLock(_objc_lock_list *locks, void *lock, int kind)
{
    int i;
    if (!locks) return NO;
    
    for (i = 0; i < locks->used; i++) {
        if (locks->list[i].l == lock  &&  locks->list[i].k == kind) return YES;
    }
    return NO;
}


static void 
setLock(_objc_lock_list *locks, void *lock, int kind)
{
    int i;
    for (i = 0; i < locks->used; i++) {
        if (locks->list[i].l == lock  &&  locks->list[i].k == kind) {
            locks->list[i].i++;
            return;
        }
    }

    locks->list[locks->used].l = lock;
    locks->list[locks->used].i = 1;
    locks->list[locks->used].k = kind;
    locks->used++;
}

static void 
clearLock(_objc_lock_list *locks, void *lock, int kind)
{
    int i;
    for (i = 0; i < locks->used; i++) {
        if (locks->list[i].l == lock  &&  locks->list[i].k == kind) {
            if (--locks->list[i].i == 0) {
                locks->list[i].l = NULL;
                locks->list[i] = locks->list[--locks->used];
            }
            return;
        }
    }

    _objc_fatal("lock not found!");
}

__private_extern__ void
_destroyLockList(struct _objc_lock_list *locks)
{
    // fixme complain about any still-held locks?
    if (locks) _free_internal(locks);
}


/***********************************************************************
* Mutex checking
**********************************************************************/

__private_extern__ int 
_mutex_lock_debug(mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);
    
    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, MUTEX)) {
            _objc_fatal("deadlock: relocking mutex %s\n", name+1);
        }
        setLock(locks, lock, MUTEX);
    }
    
    return _mutex_lock_nodebug(lock);
}

__private_extern__ int 
_mutex_try_lock_debug(mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    // attempting to relock in try_lock is OK
    int result = _mutex_try_lock_nodebug(lock);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (result) {
            setLock(locks, lock, MUTEX);
        }
    }
    return result;
}

__private_extern__ int 
_mutex_unlock_debug(mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, MUTEX)) {
            _objc_fatal("unlocking unowned mutex %s\n", name+1);
        }
        clearLock(locks, lock, MUTEX);
    }

    return _mutex_unlock_nodebug(lock);
}

__private_extern__ void 
_mutex_assert_locked_debug(mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, MUTEX)) {
            _objc_fatal("mutex %s incorrectly not held\n",name+1);
        }
    }
}


__private_extern__ void 
_mutex_assert_unlocked_debug(mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, MUTEX)) {
            _objc_fatal("mutex %s incorrectly held\n", name+1);
        }
    }
}


/***********************************************************************
* Recursive mutex checking
**********************************************************************/

__private_extern__ int 
_recursive_mutex_lock_debug(recursive_mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);
    
    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        setLock(locks, lock, RECURSIVE);
    }
    
    return _recursive_mutex_lock_nodebug(lock);
}

__private_extern__ int 
_recursive_mutex_try_lock_debug(recursive_mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    int result = _recursive_mutex_try_lock_nodebug(lock);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (result) {
            setLock(locks, lock, RECURSIVE);
        }
    }
    return result;
}

__private_extern__ int 
_recursive_mutex_unlock_debug(recursive_mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, RECURSIVE)) {
            _objc_fatal("unlocking unowned recursive mutex %s\n", name+1);
        }
        clearLock(locks, lock, RECURSIVE);
    }

    return _recursive_mutex_unlock_nodebug(lock);
}

__private_extern__ void 
_recursive_mutex_assert_locked_debug(recursive_mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, RECURSIVE)) {
            _objc_fatal("recursive mutex %s incorrectly not held\n",name+1);
        }
    }
}


__private_extern__ void 
_recursive_mutex_assert_unlocked_debug(recursive_mutex_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, RECURSIVE)) {
            _objc_fatal("recursive mutex %s incorrectly held\n", name+1);
        }
    }
}


/***********************************************************************
* Monitor checking
**********************************************************************/

__private_extern__ int 
_monitor_enter_debug(monitor_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, MONITOR)) {
            _objc_fatal("deadlock: relocking monitor %s\n", name+1);
        }
        setLock(locks, lock, MONITOR);
    }

    return _monitor_enter_nodebug(lock);
}

__private_extern__ int 
_monitor_exit_debug(monitor_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, MONITOR)) {
            _objc_fatal("unlocking unowned monitor%s\n", name+1);
        }
        clearLock(locks, lock, MONITOR);
    }

    return _monitor_exit_nodebug(lock);
}

__private_extern__ int 
_monitor_wait_debug(monitor_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, MONITOR)) {
            _objc_fatal("waiting in unowned monitor%s\n", name+1);
        }
    }

    return _monitor_wait_nodebug(lock);
}

__private_extern__ void 
_monitor_assert_locked_debug(monitor_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, MONITOR)) {
            _objc_fatal("monitor %s incorrectly not held\n",name+1);
        }
    }
}

__private_extern__ void 
_monitor_assert_unlocked_debug(monitor_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, MONITOR)) {
            _objc_fatal("monitor %s incorrectly held\n", name+1);
        }
    }
}


/***********************************************************************
* rwlock checking
**********************************************************************/

__private_extern__ void
_rwlock_read_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, RDLOCK)) {
            // Recursive rwlock read is bad (may deadlock vs pending writer)
            _objc_fatal("recursive rwlock read %s\n", name+1);
        }
        if (hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("deadlock: read after write for rwlock %s\n", name+1);
        }
        setLock(locks, lock, RDLOCK);
    }

    _rwlock_read_nodebug(lock);
}

__private_extern__ int 
_rwlock_try_read_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    // try-read when already reading is OK (won't deadlock against writer)
    // try-read when already writing is OK (will fail)
    int result = _rwlock_try_read_nodebug(lock);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (result) {
            setLock(locks, lock, RDLOCK);
        }
    }
    return result;
}

__private_extern__ void 
_rwlock_unlock_read_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, RDLOCK)) {
            _objc_fatal("un-reading unowned rwlock %s\n", name+1);
        }
        clearLock(locks, lock, RDLOCK);
    }

    _rwlock_unlock_read_nodebug(lock);
}

__private_extern__ void
_rwlock_write_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, RDLOCK)) {
            // Lock promotion not allowed (may deadlock)
            _objc_fatal("deadlock: write after read for rwlock %s\n", name+1);
        }
        if (hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("recursive rwlock write %s\n", name+1);
        }
        setLock(locks, lock, WRLOCK);
    }

    _rwlock_write_nodebug(lock);
}


__private_extern__ int 
_rwlock_try_write_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(YES);

    // try-write when already reading is OK (will fail)
    // try-write when already writing is OK (will fail)
    int result = _rwlock_try_write_nodebug(lock);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (result) {
            setLock(locks, lock, WRLOCK);
        }
    }
    return result;
}

__private_extern__ void 
_rwlock_unlock_write_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("un-writing unowned rwlock %s\n", name+1);
        }
        clearLock(locks, lock, WRLOCK);
    }

    _rwlock_unlock_write_nodebug(lock);
}


__private_extern__ void 
_rwlock_assert_reading_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, RDLOCK)) {
            _objc_fatal("rwlock %s incorrectly not reading\n", name+1);
        }
    }
}

__private_extern__ void 
_rwlock_assert_writing_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("rwlock %s incorrectly not writing\n", name+1);
        }
    }
}

__private_extern__ void 
_rwlock_assert_locked_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (!hasLock(locks, lock, RDLOCK)  &&  !hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("rwlock %s incorrectly neither reading nor writing\n", 
                        name+1);
        }
    }
}

__private_extern__ void 
_rwlock_assert_unlocked_debug(rwlock_t *lock, const char *name)
{
    _objc_lock_list *locks = getLocks(NO);

    if (! (DebuggerMode  &&  isManagedDuringDebugger(lock))) {
        if (hasLock(locks, lock, RDLOCK)  ||  hasLock(locks, lock, WRLOCK)) {
            _objc_fatal("rwlock %s incorrectly not unlocked\n", name+1);
        }
    }
}


#endif
