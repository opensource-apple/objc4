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
 * 	Copyright 1988-2001, NeXT Software, Inc., Apple Computer, Inc.
 */


#include <stdarg.h>
#include <unistd.h>
#include <syslog.h>
#include <sys/fcntl.h>


#import "objc-private.h"
static int hasTerminal()
{
    static char hasTerm = -1;

    if (hasTerm == -1) {
	int fd = open("/dev/tty", O_RDWR, 0);
	if (fd >= 0) {
	    (void)close(fd);
	    hasTerm = 1;
	} else
	    hasTerm = 0;
    }
    return hasTerm;
}

void _objc_syslog(const char *format, ...)
{
    va_list ap;
    char bigBuffer[4*1024];

    va_start(ap, format);
    vsnprintf(bigBuffer, sizeof(bigBuffer), format, ap);
    va_end(ap);


    if (hasTerminal()) {
	fwrite(bigBuffer, sizeof(char), strlen(bigBuffer), stderr);
	if (bigBuffer[strlen(bigBuffer)-1] != '\n')
	    fputc('\n', stderr);
    } else {
	syslog(LOG_ERR, "%s", bigBuffer);
    }
}
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

    vsnprintf (bigBuffer, sizeof(bigBuffer), fmt, ap);
    _objc_syslog ("objc: %s: %s", object_getClassName (self), bigBuffer);

    abort();		/* generates a core file */
}

/*	
 *	this routine handles severe runtime errors...like not being able
 * 	to read the mach headers, allocate space, etc...very uncommon.
 */
volatile void _objc_fatal(const char *msg)
{
    _objc_syslog("objc: %s\n", msg);
    exit(1);
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
    vsnprintf (bigBuffer, sizeof(bigBuffer), fmt, ap);
    _objc_syslog ("objc: %s", bigBuffer);
    va_end (ap);
}

