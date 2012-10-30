/*
 * Copyright (c) 1999-2002, 2005-2008 Apple Inc.  All Rights Reserved.
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

#include <TargetConditionals.h>

// Define NO_GC to disable garbage collection.
// Be sure to edit OBJC_NO_GC in objc-auto.h as well.
#if TARGET_OS_EMBEDDED  ||  TARGET_OS_WIN32
#   define NO_GC 1
#endif

// Define NO_ENVIRON to disable getenv().
#if TARGET_OS_EMBEDDED
#   define NO_ENVIRON 1
#endif

// Define NO_ZONES to disable malloc zone support in NXHashTable.
#if TARGET_OS_EMBEDDED
#   define NO_ZONES 1
#endif

// Define NO_MOD to avoid the mod operator in NXHashTable and objc-sel-set.
#if defined(__arm__)
#   define NO_MOD 1
#endif

// Define NO_BUILTINS to disable the builtin selector table from dyld
#if TARGET_OS_WIN32
#   define NO_BUILTINS 1
#endif

// Define NO_DEBUGGER_MODE to disable lock-avoiding execution for debuggers
#if TARGET_OS_WIN32
#   define NO_DEBUGGER_MODE 1
#endif

#if __OBJC2__

// Define NO_FIXUP to use non-fixup messaging for OBJC2.
#if defined(__arm__)
#   define NO_FIXUP 1
#endif

// Define NO_VTABLE to disable vtable dispatch for OBJC2.
#if defined(NO_FIXUP)  ||  defined(__ppc64__)
#   define NO_VTABLE 1
#endif

// Define NO_ZEROCOST_EXCEPTIONS to use sjlj exceptions for OBJC2.
// Be sure to edit objc-exception.h as well (objc_add/removeExceptionHandler)
#if defined(__arm__)
#   define NO_ZEROCOST_EXCEPTIONS 1
#endif

#endif


// OBJC_INSTRUMENTED controls whether message dispatching is dynamically
// monitored.  Monitoring introduces substantial overhead.
// NOTE: To define this condition, do so in the build command, NOT by
// uncommenting the line here.  This is because objc-class.h heeds this
// condition, but objc-class.h can not #include this file (objc-config.h)
// because objc-class.h is public and objc-config.h is not.
//#define OBJC_INSTRUMENTED

// Get the nice macros for subroutine calling, etc.
// Not available on all architectures.  Not needed
// (by us) on some configurations.
#if defined (__i386__) || defined (i386)
#   include <architecture/i386/asm_help.h>
#elif defined (__ppc__) || defined(ppc)
#   include <architecture/ppc/asm_help.h>
#endif
