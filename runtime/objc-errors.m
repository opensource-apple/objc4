/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Portions Copyright (c) 1999 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.1 (the "License").  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON- INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
/*
 *	objc-errors.m
 * 	Copyright 1988-1996, NeXT Software, Inc.
 */

/*
	NXLogObjcError was snarfed from "logErrorInc.c" in the kit.
  
	Contains code for writing error messages to stderr or syslog.
  
	This code is included in errors.m in the kit, and in pbs.c
	so pbs can use it also.
*/

#if defined(WIN32)
    #import <winnt-pdo.h>
    #import <windows.h>
    #import <sys/types.h>
    #import <sys/stat.h>
    #import <io.h>
    #define syslog(a, b, c) 	fprintf(stderr, b, c)
#else 
    #import <syslog.h>
#endif

    #if defined(NeXT_PDO)
        #if !defined(WIN32)
            #include	<syslog.h>	// major head banging in attempt to find syslog
            #import 	<stdarg.h>
            #include 	<unistd.h>	// close
        #endif
        #import 	<fcntl.h>	// file open flags
    #endif

#import "objc-private.h"

/*	
 *	this routine handles errors that involve an object (or class).
 */
volatile void __objc_error(id rcv, const char *fmt, ...) 
{ 
	va_list vp; 

	va_start(vp,fmt); 
	(*_error)(rcv, fmt, vp); 
	va_end(vp);
	_objc_error (rcv, fmt, vp);	/* In case (*_error)() returns. */
}

/*
 * 	this routine is never called directly...it is only called indirectly
 * 	through "_error", which can be overriden by an application. It is
 *	not declared static because it needs to be referenced in 
 *	"objc-globaldata.m" (this file organization simplifies the shlib
 *	maintenance problem...oh well). It is, however, a "private extern".
 */
volatile void _objc_error(id self, const char *fmt, va_list ap) 
{ 
    char bigBuffer[4*1024];

    vsprintf (bigBuffer, fmt, ap);
    _NXLogError ("objc: %s: %s", object_getClassName (self), bigBuffer);

#if defined(WIN32)
    RaiseException(0xdead, EXCEPTION_NONCONTINUABLE, 0, NULL);
#else
    abort();		/* generates a core file */
#endif
}

/*	
 *	this routine handles severe runtime errors...like not being able
 * 	to read the mach headers, allocate space, etc...very uncommon.
 */
volatile void _objc_fatal(const char *msg)
{
    _NXLogError("objc: %s\n", msg);
#if defined(WIN32)
    RaiseException(0xdead, EXCEPTION_NONCONTINUABLE, 0, NULL);
#else
    exit(1);
#endif
}

/*
 *	this routine handles soft runtime errors...like not being able
 *      add a category to a class (because it wasn't linked in).
 */
void _objc_inform(const char *fmt, ...)
{
    va_list ap; 
    char bigBuffer[4*1024];

    va_start (ap,fmt); 
    vsprintf (bigBuffer, fmt, ap);
    _NXLogError ("objc: %s", bigBuffer);
    va_end (ap);
}

