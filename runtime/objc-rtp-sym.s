/*
 * Copyright (c) 2004 Apple Inc. All rights reserved.
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
  This file is used to regenerate symbols for routines in the ObjC runtime pages.
  
  Build this file with:
    cc objc-rtp-syms.c -c -o objc-rtp-syms.o.temp
    ld -seg1addr kRTPagesLo objc-rtp-syms.o.temp -r -o objc-rtp-syms.o
  and then use `-sectcreate __DATA __commpage objc-rtp-syms.o` when linking.

  IMPORTANT - declarations need to be declared in address order.
*/

#undef  OBJC_ASM
#define OBJC_ASM
#include "objc-rtp.h"

    .text
    .globl  _objc_kIgnore_rtp
    .org    kRTAddress_ignoredSelector-kRTPagesLo  // unnormalized with ld -seg1addr kRTPagesLo
_objc_kIgnore_rtp:
    nop
 
    // note that macro expansion does not work well with .org, had to go long hand - jml
 
    .globl   _objc_assign_strongCast_rtp
    .org     kRTAddress_objc_assign_strongCast-kRTPagesLo // unnormalized with ld -seg1addr kRTPagesLo
_objc_assign_strongCast_rtp:
    nop
    
    .globl   _objc_assign_global_rtp
    .org     kRTAddress_objc_assign_global-kRTPagesLo // unnormalized with ld -seg1addr kRTPagesLo
_objc_assign_global_rtp:
    nop

    .globl   _objc_assign_ivar_rtp
    .org     kRTAddress_objc_assign_ivar-kRTPagesLo // unnormalized with ld -seg1addr kRTPagesLo
_objc_assign_ivar_rtp:
    nop

    .globl   _objc_msgSend_rtp
    .org     kRTAddress_objc_msgSend -kRTPagesLo // unnormalized with ld -seg1addr kRTPagesLo
_objc_msgSend_rtp:
    nop

    // Extra symbol at the end of the RTP area.
    // This pacifies gdb and other debugging tools.
    .globl   _objc_msgSend_rtp_exit
    .org     kRTPagesHi - kRTPagesLo // unnormalized with ld -seg1adr kRTPagesLo

    .data
    .long   0
