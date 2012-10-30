/*
 * Copyright (c) 2004, 2006 Apple Inc. All rights reserved.
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
 
 
 ;
 ; This section includes declarations of routines that will be used to populate
 ; the runtime pages during auto initialization.  Each wb_routine definition 
 ; creates an absolute branch into the rtp plus a non-gc version of code for
 ; non collecting apps.  Note - the blr is necessary at the end of the non-gc 
 ; routine for code copying to behave correctly. 
 ;
 
#undef  OBJC_ASM
#define OBJC_ASM
#include "objc-rtp.h"
 
    .macro  wb_routine
    .globl  _$0                ; primary entry name
;   .abs    _abs_$0,kRTAddress_$0
_$0:                           ; primary entry point
    ba      $1                 ; branch to runtime page
    
    .private_extern _$0_non_gc ; non_gc entry point name
_$0_non_gc:                    ; non_gc entry point
    .endmacro

    .text
    
// note - unfortunately ba does not accept constant expressions
    
    ; non-gc routines
    
    ; id objc_assign_strongCast(id value, id *dest)
    wb_routine  objc_assign_strongCast,0xfffefea0
    stw         r3,0(r4)        ; store value at dest
    blr                         ; return
    
    ; id objc_assign_global(id value, id *dest)
    wb_routine  objc_assign_global,0xfffefeb0
    stw         r3,0(r4)        ; store value at dest
    blr                         ; return

    ; id objc_assign_ivar(id value, id dest, unsigned int offset)
    wb_routine  objc_assign_ivar,0xfffefec0
    stwx        r3,r4,r5        ; store value at (dest+offset)
    blr                         ; return
    