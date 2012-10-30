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
 *	Copyright 1988-1996 NeXT Software, Inc.
 *
 *	objc-msg.s
 *
 *	31-Dec-96  Umesh Vaishampayan  (umeshv@NeXT.com)
 *		Added support for ppc. cleaned m98k and m88k stuff.
 */

#import "../objc-config.h"

#if defined (__i386__) || defined (i386)
    #include "objc-msg-i386.s"
#elif defined (__ppc__) || defined(ppc)
    #include "objc-msg-ppc.s"

#else
    #error Architecture not supported
#endif
