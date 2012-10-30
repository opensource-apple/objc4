/*
 * Copyright (c) 1999-2003, 2005-2007 Apple Inc.  All Rights Reserved.
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
 *	objc-errors.m
 * 	Copyright 1988-2001, NeXT Software, Inc., Apple Computer, Inc.
 */


#include <stdarg.h>
#include <unistd.h>
#include <syslog.h>
#include <sys/fcntl.h>

#import "objc-private.h"

__private_extern__ char *__crashreporter_info__ = NULL;

OBJC_EXPORT void	(*_error)(id, const char *, va_list);

static void _objc_trap(void) __attribute__((noreturn));

// Add "message" to any forthcoming crash log.
static void _objc_crashlog(const char *message)
{
    char *newmsg;

    if (!__crashreporter_info__) {
        newmsg = strdup(message);
    } else {
        asprintf(&newmsg, "%s\n%s", __crashreporter_info__, message);
    }

    if (newmsg) {
        // Strip trailing newline
        char *c = &newmsg[strlen(newmsg)-1];
        if (*c == '\n') *c = '\0';
        
        if (__crashreporter_info__) free(__crashreporter_info__);
        __crashreporter_info__ = newmsg;
    }
}

// Print "message" to the console.
static void _objc_syslog(const char *message)
{
    if (fcntl(STDERR_FILENO, F_GETFL, 0) != -1) {
        // stderr is open - use it
        write(STDERR_FILENO, message, strlen(message));
        if (message[strlen(message)-1] != '\n') {
            write(STDERR_FILENO, "\n", 1);
        }
    } else {
        syslog(LOG_ERR, "%s", message);
    }
}
/*
 * this routine handles errors that involve an object (or class).
 */
__private_extern__ void __objc_error(id rcv, const char *fmt, ...) 
{ 
    va_list vp; 

    va_start(vp,fmt); 
#if !__OBJC2__
    (*_error)(rcv, fmt, vp); 
#endif
    _objc_error (rcv, fmt, vp);  /* In case (*_error)() returns. */
    va_end(vp);
}

/*
 * _objc_error is the default *_error handler.
 */
#if __OBJC2__
__private_extern__
#endif
void _objc_error(id self, const char *fmt, va_list ap) 
{ 
    char *buf1;
    char *buf2;

    vasprintf(&buf1, fmt, ap);
    asprintf(&buf2, "objc[%d]: %s: %s\n", 
             getpid(), object_getClassName(self), buf1);
    _objc_syslog(buf2);
    _objc_crashlog(buf2);

    _objc_trap();
}

/*
 * this routine handles severe runtime errors...like not being able
 * to read the mach headers, allocate space, etc...very uncommon.
 */
__private_extern__ void _objc_fatal(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start(ap,fmt); 
    vasprintf(&buf1, fmt, ap);
    va_end (ap);

    asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_syslog(buf2);
    _objc_crashlog(buf2);

    _objc_trap();
}

/*
 * this routine handles soft runtime errors...like not being able
 * add a category to a class (because it wasn't linked in).
 */
__private_extern__ void _objc_inform(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    vasprintf(&buf1, fmt, ap);
    va_end (ap);

    asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_syslog(buf2);

    free(buf2);
    free(buf1);
}


/* 
 * Like _objc_inform(), but prints the message only in any 
 * forthcoming crash log, not to the console.
 */
__private_extern__ void _objc_inform_on_crash(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    vasprintf(&buf1, fmt, ap);
    va_end (ap);

    asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_crashlog(buf2);

    free(buf2);
    free(buf1);
}


/* 
 * Like calling both _objc_inform and _objc_inform_on_crash.
 */
__private_extern__ void _objc_inform_now_and_on_crash(const char *fmt, ...)
{
    va_list ap; 
    char *buf1;
    char *buf2;

    va_start (ap,fmt); 
    vasprintf(&buf1, fmt, ap);
    va_end (ap);

    asprintf(&buf2, "objc[%d]: %s\n", getpid(), buf1);
    _objc_crashlog(buf2);
    _objc_syslog(buf2);

    free(buf2);
    free(buf1);
}


/* Kill the process in a way that generates a crash log. 
 * This is better than calling exit(). */
static void _objc_trap(void) 
{
    __builtin_trap();
}

/* Try to keep _objc_warn_deprecated out of crash logs 
 * caused by _objc_trap(). rdar://4546883 */
__attribute__((used))
static void _objc_trap2(void)
{
    __builtin_trap();
}

__private_extern__ void _objc_warn_deprecated(const char *old, const char *new)
{
    if (PrintDeprecation) {
        if (new) {
            _objc_inform("The function %s is obsolete. Use %s instead. Set a breakpoint on _objc_warn_deprecated to find the culprit.", old, new);
        } else {
            _objc_inform("The function %s is obsolete. Do not use it. Set a breakpoint on _objc_warn_deprecated to find the culprit.", old);
        }
    }
}


/* Entry points for breakable errors. For some reason, can't inhibit the compiler's inlining aggression.
 */
 
__private_extern__ void objc_assign_ivar_error(id base, ptrdiff_t offset) {
}

__private_extern__ void objc_assign_global_error(id value, id *slot) {
}

__private_extern__ void objc_exception_during_finalize_error(void) {
}

