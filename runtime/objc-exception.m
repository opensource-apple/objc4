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
//  objc_exception.m
//  Support minimal stand-alone implementation plus hooks for swapping
//  in a richer implementation.
//
//  Created by Blaine Garst on Fri Nov 01 2002.
//  Copyright (c) 2002 Apple Computer, Inc. All rights reserved.
//

#undef _BUILDING_OBJC

#import "objc-exception.h"

static objc_exception_functions_t xtab;

// forward declaration
static void set_default_handlers();


extern void objc_raise_error(const char *);


/*
 * Exported functions
 */

// get table; version tells how many
void objc_exception_get_functions(objc_exception_functions_t *table) {
    // only version 0 supported at this point
    if (table && table->version == 0)
        *table = xtab;
}

// set table
void objc_exception_set_functions(objc_exception_functions_t *table) {
    // only version 0 supported at this point
    if (table && table->version == 0)
        xtab = *table;
}

/*
 * The following functions are
 * synthesized by the compiler upon encountering language constructs
 */
 
void objc_exception_throw(id exception) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.throw_exc(exception);
}

void objc_exception_try_enter(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.try_enter(localExceptionData);
}


void objc_exception_try_exit(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.try_exit(localExceptionData);
}


id objc_exception_extract(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    return xtab.extract(localExceptionData);
}


int objc_exception_match(Class exceptionClass, id exception) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    return xtab.match(exceptionClass, exception);
}


// quick and dirty exception handling code
// default implementation - mostly a toy for use outside/before Foundation
// provides its implementation
// Perhaps the default implementation should just complain loudly and quit



#import <pthread.h>
#import <setjmp.h>

extern void _objc_inform(const char *fmt, ...);

typedef struct { jmp_buf buf; void *pointers[4]; } LocalData_t;

typedef struct _threadChain {
    LocalData_t *topHandler;
    void *perThreadID;
    struct _threadChain *next;
}
    ThreadChainLink_t;

#define _ExceptionDebug 0

static ThreadChainLink_t ThreadChainLink;

static ThreadChainLink_t *getChainLink() {
    // follow links until thread_self() found (someday) XXX
    pthread_t self = pthread_self();
    ThreadChainLink_t *walker = &ThreadChainLink;
    while (walker->perThreadID != (void *)self) {
        if (walker->next != NULL) {
            walker = walker->next;
            continue;
        }
        // create a new one
        // XXX not thread safe (!)
        // XXX Also, we don't register to deallocate on thread death
        walker->next = (ThreadChainLink_t *)malloc(sizeof(ThreadChainLink_t));
        walker = walker->next;
        walker->next = NULL;
        walker->topHandler = NULL;
        walker->perThreadID = self;
    }
    return walker;
}

static void default_try_enter(void *localExceptionData) {
    ThreadChainLink_t *chainLink = getChainLink();
    ((LocalData_t *)localExceptionData)->pointers[1] = chainLink->topHandler;
    chainLink->topHandler = localExceptionData;
    if (_ExceptionDebug) _objc_inform("entered try block %x\n", chainLink->topHandler);
}

static void default_throw(id value) {
    ThreadChainLink_t *chainLink = getChainLink();
    if (value == nil) {
        if (_ExceptionDebug) _objc_inform("objc_exception_throw with nil value\n");
        return;
    }
    if (chainLink == NULL) {
        if (_ExceptionDebug) _objc_inform("No handler in place!\n");
        return;
    }
    if (_ExceptionDebug) _objc_inform("exception thrown, going to handler block %x\n", chainLink->topHandler);
    LocalData_t *led = chainLink->topHandler;
    chainLink->topHandler = led->pointers[1];	// pop top handler
    led->pointers[0] = value;			// store exception that is thrown
    _longjmp(led->buf, 1);
}
    
static void default_try_exit(void *led) {
    ThreadChainLink_t *chainLink = getChainLink();
    if (!chainLink || led != chainLink->topHandler) {
        if (_ExceptionDebug) _objc_inform("!!! mismatched try block exit handlers !!!\n");
        return;
    }
    if (_ExceptionDebug) _objc_inform("removing try block handler %x\n", chainLink->topHandler);
    chainLink->topHandler = chainLink->topHandler->pointers[1];	// pop top handler
}

static id default_extract(void *localExceptionData) {
    LocalData_t *led = (LocalData_t *)localExceptionData;
    return (id)led->pointers[0];
}

static int default_match(Class exceptionClass, id exception) {
    //return [exception isKindOfClass:exceptionClass];
    Class cls;
    for (cls = exception->isa; nil != cls; cls = cls->super_class) 
	if (cls == exceptionClass) return 1;
    return 0;
}

static void set_default_handlers() {
    objc_exception_functions_t default_functions = {
        0, default_throw, default_try_enter, default_try_exit, default_extract, default_match };

    // should this always print?
    if (_ExceptionDebug) _objc_inform("*** Setting default (non-Foundation) exception mechanism\n");
    objc_exception_set_functions(&default_functions);
}
    
