/*
 * Copyright (c) 2004-2006 Apple Inc. All rights reserved.
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
	
#import "../objc-config.h"

#if defined (__i386__) || defined (i386)
    #include "objc-msg-stub-i386.s"
#elif defined (__ppc__) || defined(ppc)
    #include "objc-msg-stub-ppc.s"
#elif defined (__ppc64__) || defined(ppc64)
    #include "objc-msg-stub-ppc64.s"
#elif defined (__x86_64__)
    #include "objc-msg-stub-x86_64.s"
#else
    #error Architecture not supported
#endif
