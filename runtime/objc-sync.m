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
//
//  objc_sync.h
//
//  Copyright (c) 2002 Apple Computer, Inc. All rights reserved.
//

#include <stdbool.h>
#include <stdlib.h>
#include <sys/time.h>
#include <pthread.h>
#define PTHREAD_MUTEX_RECURSIVE          2
#include <CoreFoundation/CFDictionary.h>
#include <AssertMacros.h>

#include "objc-sync.h"

//
// Code by Nick Kledzik
//

// revised comments by Blaine

//
// Allocate a lock only when needed.  Since few locks are needed at any point
// in time, keep them on a single list.
//

static pthread_mutexattr_t	sRecursiveLockAttr;
static bool			sRecursiveLockAttrIntialized = false;

static pthread_mutexattr_t* recursiveAttributes()
{
    if ( !sRecursiveLockAttrIntialized ) {
	int err = pthread_mutexattr_init(&sRecursiveLockAttr);
        require_noerr_string(err, done, "pthread_mutexattr_init failed");

	err = pthread_mutexattr_settype(&sRecursiveLockAttr, PTHREAD_MUTEX_RECURSIVE);
        require_noerr_string(err, done, "pthread_mutexattr_settype failed");

	sRecursiveLockAttrIntialized = true;
   }

done:
    return &sRecursiveLockAttr;
}


struct SyncData
{
	struct SyncData*	nextData;
	id			object;
	unsigned int		lockCount;
	pthread_mutex_t 	mutex;
	pthread_cond_t		conditionVariable;
};
typedef struct SyncData SyncData;

static pthread_mutex_t		sTableLock = PTHREAD_MUTEX_INITIALIZER;
static SyncData*		sDataList = NULL;

static SyncData* id2data(id object)
{
    SyncData* result = NULL;
    int err;
    
    pthread_mutex_lock(&sTableLock);
    
    // Walk in-use list looking for matching object
    // sTableLock keeps other threads from winning an allocation race
    // for the same new object.
    // We could keep the nodes in some hash table if we find that there are
    // more than 20 or so distinct locks active, but we don't do that now.
    
    SyncData* firstUnused = NULL;
    SyncData* p;
    for (p = sDataList; p != NULL; p = p->nextData) {
        if ( p->object == object ) {
            result = p;
            goto done;
        }
        if ( (firstUnused == NULL) && (p->object == NULL) )
            firstUnused = p;
    }
    
    // if no corresponding SyncData found, but an unused one was found, use it
    if ( firstUnused != NULL ) {
        result = firstUnused;
        result->object = object;
        result->lockCount = 0;	// sanity
        goto done;
    }
                            
    // malloc a new SyncData and add to list.
    // XXX calling malloc with a global lock held is bad practice,
    // might be worth releasing the lock, mallocing, and searching again.
    // But since we never free these guys we won't be stuck in malloc very often.
    result = (SyncData*)malloc(sizeof(SyncData));
    result->object = object;
    result->lockCount = 0;
    err = pthread_mutex_init(&result->mutex, recursiveAttributes());
    require_noerr_string(err, done, "pthread_mutex_init failed");
    err = pthread_cond_init(&result->conditionVariable, NULL);
    require_noerr_string(err, done, "pthread_cond_init failed");
    result->nextData = sDataList;
    sDataList = result;
    
done:
    pthread_mutex_unlock(&sTableLock);
    return result;
}



// Begin synchronizing on 'obj'.  
// Allocates recursive pthread_mutex associated with 'obj' if needed.
// Returns OBJC_SYNC_SUCCESS once lock is acquired.  
int objc_sync_enter(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
    
    SyncData* data = id2data(obj);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");
	
    result = pthread_mutex_lock(&data->mutex);
    require_noerr_string(result, done, "pthread_mutex_lock failed");
	
    data->lockCount++;	// note: lockCount is only modified when corresponding mutex is held
	
done: 
    return result;
}


// End synchronizing on 'obj'. 
// Returns OBJC_SYNC_SUCCESS or OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_exit(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
    
    SyncData* data;
    data = id2data(obj); // XXX should assert that we didn't create it
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");

    int oldLockCount = data->lockCount--;
    if ( oldLockCount == 1 ) {
        // XXX should move off the main chain to speed id2data searches
        data->object = NULL;	// recycle data
    }
    
    result = pthread_mutex_unlock(&data->mutex);
    require_noerr_string(result, done, "pthread_mutex_unlock failed");
	
done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;

    return result;
}


// Temporarily release lock on 'obj' and wait for another thread to notify on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR, OBJC_SYNC_TIMED_OUT, OBJC_SYNC_INTERRUPTED
int objc_sync_wait(id obj, long long milliSecondsMaxWait)
{
    int result = OBJC_SYNC_SUCCESS;
            
    SyncData* data = id2data(obj);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");
    
    
    // XXX need to retry cond_wait under out-of-our-control failures
    if ( milliSecondsMaxWait == 0 ) {
        result = pthread_cond_wait(&data->conditionVariable, &data->mutex);
        require_noerr_string(result, done, "pthread_cond_wait failed");
    }
    else {
       	struct timespec maxWait;
        maxWait.tv_sec  = milliSecondsMaxWait / 1000;
        maxWait.tv_nsec = (milliSecondsMaxWait - (maxWait.tv_sec * 1000)) * 1000000;
        result = pthread_cond_timedwait_relative_np(&data->conditionVariable, &data->mutex, &maxWait);
     	require_noerr_string(result, done, "pthread_cond_timedwait_relative_np failed");
    }
    // no-op to keep compiler from complaining about branch to next instruction
    data = NULL;

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    else if ( result == ETIMEDOUT )
        result = OBJC_SYNC_TIMED_OUT;
    
    return result;
}


// Wake up another thread waiting on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_notify(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
        
    SyncData* data = id2data(obj);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");

    result = pthread_cond_signal(&data->conditionVariable);
    require_noerr_string(result, done, "pthread_cond_signal failed");

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    
    return result;
}


// Wake up all threads waiting on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_notifyAll(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
        
    SyncData* data = id2data(obj);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");

    result = pthread_cond_broadcast(&data->conditionVariable);
    require_noerr_string(result, done, "pthread_cond_broadcast failed");

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    
    return result;
}






