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
// Copyright 1988-1996 NeXT Software, Inc.
// objc-config.h created by kthorup on Fri 24-Mar-1995

// OBJC_INSTRUMENTED controls whether message dispatching is dynamically
// monitored.  Monitoring introduces substantial overhead.
// NOTE: To define this condition, do so in the build command, NOT by
// uncommenting the line here.  This is because objc-class.h heeds this
// condition, but objc-class.h can not #import this file (objc-config.h)
// because objc-class.h is public and objc-config.h is not.
//#define OBJC_INSTRUMENTED

// Turn on support for class refs
#define OBJC_CLASS_REFS

    #define __S(x) x

// Get the nice macros for subroutine calling, etc.
// Not available on all architectures.  Not needed
// (by us) on some configurations.
#if defined (__i386__) || defined (i386)
    #import <architecture/i386/asm_help.h>
#elif defined (__ppc__) || defined(ppc)
    #import <architecture/ppc/asm_help.h>
#else
    #error We need asm_help.h for this architecture
#endif
