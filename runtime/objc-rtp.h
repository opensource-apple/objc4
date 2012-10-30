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
/*
  Layout of the "objc runtime pages", an fixed area 
  in high memory that can be reached via an absolute branch.
  Basic idea is that, on ppc, a single "bla" instruction
  (branch & link to absolute address)
  can be issued by the compiler to get to high-value routines
  in the runtime, including the basic messenger and to the
  assignment helper intrinsics issued under -fobjc-gc.
  The implementation of the intrinsics is optimized based
  on whether the application (process) is running with GC enabled
  or not.
*/

#ifndef _OBJC_RTP_H_
#define _OBJC_RTP_H_

/*********************************************************************
  Layout of the runtime page.

  Some of these values must NEVER BE CHANGED, including:
  kRTPagesLo
  kRTPagesHi
  kRTPagesMaxSize
  kRTSize_objc_msgSend             
  kRTSize_objc_assign_ivar
  kRTAddress_objc_msgSend          ppc 0xfffeff00
  kRTAddress_objc_assign_ivar      ppc 0xfffefec0

*********************************************************************/

#undef OBJC_SIZE_T
#undef OBJC_INTPTR_T
#undef OBJC_UINTPTR_T

#ifdef OBJC_ASM
#define OBJC_SIZE_T(x) (x)
#define OBJC_INTPTR_T(x) (x)
#define OBJC_UINTPTR_T(x) (x)
#else
#define OBJC_SIZE_T(x) ((size_t)(x))
#define OBJC_INTPTR_T(x) ((intptr_t)(x))
#define OBJC_UINTPTR_T(x) ((uintptr_t)(x))
#endif

// Size of RTP area, in bytes (0x1000 = 4k bytes = 1 page)
#define kRTPagesMaxSize  OBJC_SIZE_T(4 * 0x1000)  // size reserved for runtime
#define kRTPagesSize     OBJC_SIZE_T(1 * 0x1000)  // size actually used
    
// Address of RTP area: [kRTPagesLo..kRTPagesHi)
// These are defined in negative numbers to reflect an offset from the highest address,
// which is what the ppc "bla" instruction is defined to do with "negative" addresses.
// This definition will establish the correct entry points for 64-bit if this mechanism
// is adopted for that architecture as well.
#if defined(__ppc__)  ||  defined(__ppc64__)
#   define kRTPagesLo    OBJC_UINTPTR_T(-20 * 0x1000) // ppc 0xfffec000
#elif defined(__i386__)
#   define kRTPagesLo    OBJC_UINTPTR_T(-24 * 0x1000) // i386 0xfffe8000
#elif defined(__x86_64__)
#   define kRTPagesLo    OBJC_UINTPTR_T(-24 * 0x1000) // x86_64 0xfffffffffffe8000
#else
    #error unknown architecture
#endif
#define kRTPagesHi       OBJC_UINTPTR_T(kRTPagesLo + kRTPagesMaxSize) // ppc 0xffff0000

// Sizes reserved for functions in the RTP area, in bytes
#define kRTSize_objc_msgSend           OBJC_SIZE_T(0x0100)
#define kRTSize_objc_assign_ivar       OBJC_SIZE_T(0x0040)
#define kRTSize_objc_assign_global     OBJC_SIZE_T(0x0010)
#define kRTSize_objc_assign_strongCast OBJC_SIZE_T(0x0010)
        
// Absolute address of functions in the RTP area
// These count backwards from the hi end of the RTP area. 
// New additions are added to the low side.
#define kRTAddress_objc_msgSend           OBJC_UINTPTR_T(kRTPagesHi - kRTSize_objc_msgSend) // ppc 0xfffeff00
#define kRTAddress_objc_assign_ivar       OBJC_UINTPTR_T(kRTAddress_objc_msgSend - kRTSize_objc_assign_ivar) // ppc 0xfffefec0
#define kRTAddress_objc_assign_global     OBJC_UINTPTR_T(kRTAddress_objc_assign_ivar - kRTSize_objc_assign_global) // ppc 0xfffefeb0
#define kRTAddress_objc_assign_strongCast OBJC_UINTPTR_T(kRTAddress_objc_assign_global - kRTSize_objc_assign_strongCast) // ppc 0xfffefea0

// Sizes reserved for data in the RTP area, in bytes
#define kRTSize_zero              OBJC_SIZE_T(16) // 16 zero bytes
#define kRTSize_ignoredSelector   OBJC_SIZE_T(19) // 1+strlen("<ignored selector>")

// Absolute address of data in the RTP area
// These count forwards from the lo end of the RTP area.
// These are not locked down and can be moved if necessary.
#define kRTAddress_zero OBJC_UINTPTR_T(kRTPagesHi-kRTPagesSize)
#define kRTAddress_ignoredSelector OBJC_UINTPTR_T(kRTAddress_zero+kRTSize_zero)

#define kIgnore kRTAddress_ignoredSelector  // ppc 0xfffef000

/*********************************************************************
  End of runtime page layout. 
*********************************************************************/

#endif
