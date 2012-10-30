/*
 * Copyright (c) 2006 Apple Inc.  All Rights Reserved.
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

//////////////////////////////////////////////////////////////////////
//
// ENTRY		functionName
//
// Assembly directives to begin an exported function.
//
// Takes: functionName - name of the exported function
//////////////////////////////////////////////////////////////////////

.macro ENTRY
	.text
	.globl	$0
$0:
.endmacro

//////////////////////////////////////////////////////////////////////
//
// END_ENTRY	functionName
//
// Assembly directives to end an exported function.  Just a placeholder,
// a close-parenthesis for ENTRY, until it is needed for something.
//
// Takes: functionName - name of the exported function
//////////////////////////////////////////////////////////////////////

.macro END_ENTRY
.endmacro

//////////////////////////////////////////////////////////////////////
//
// OBJC_GET_PROPERTY_OFFSET     offset
//
// Optimized id typed accessor methods.
// Generates an accesssor for a specified compile time offset.
//
// Takes: offset - offset of an id typed instance variable
//////////////////////////////////////////////////////////////////////

.macro OBJC_GET_PROPERTY_OFFSET
	.private_extern __objc_getProperty_offset_$0
    ENTRY __objc_getProperty_offset_$0
	movl	4(%esp), %eax
	movl	$0(%eax), %eax
    ret
    END_ENTRY __objc_getProperty_offset_$0
.endmacro

/* 
 * Thunk to retrieve PC.
 * `call 1; 1: pop` sequence breaks any branch-prediction stack. 
 */
L_get_pc_thunk.edx:
	movl	(%esp,1), %edx
	ret

.macro LAZY_PIC_FUNCTION_STUB
.data
.picsymbol_stub
L$0$stub:
	.indirect_symbol $0
	call	L_get_pc_thunk.edx
L0$$0:
	movl	L$0$lz - L0$$0(%edx), %ecx
	jmp		*%ecx
L$0$stub_binder:
	lea		L$0$lz - L0$$0(%edx),%eax
	pushl	%eax
	jmp		dyld_stub_binding_helper
	nop
.data
.lazy_symbol_pointer
L$0$lz:
	.indirect_symbol $0
	.long L$0$stub_binder
.endmacro

LAZY_PIC_FUNCTION_STUB  _objc_assign_ivar_gc
#define OBJC_ASSIGN_IVAR L_objc_assign_ivar_gc$stub // call objc_assign_ivar_gc() directly to avoid extra levels of testing/branching

.macro OBJC_SET_PROPERTY_OFFSET
	.private_extern __objc_setProperty_offset_$0
	ENTRY __objc_setProperty_offset_$0
	movl	4(%esp), %eax
	movl	%eax, 8(%esp)					// pass self as the second parameter.
	movl	12(%esp), %eax
	movl	%eax, 4(%esp)					// pass value as the first parameter.
	movl	$$$0, 12(%esp)					// pass the offset as the third parameter.
	jmp		OBJC_ASSIGN_IVAR				// objc_assign_ivar_gc() is __private_extern__
	END_ENTRY __objc_setProperty_offset_$0
.endmacro

/********************************************************************
 * id _objc_getProperty_offset_N(id self, SEL _cmd);
 ********************************************************************/

	OBJC_GET_PROPERTY_OFFSET	0
	OBJC_GET_PROPERTY_OFFSET	4
	OBJC_GET_PROPERTY_OFFSET	8
	OBJC_GET_PROPERTY_OFFSET	12
	OBJC_GET_PROPERTY_OFFSET	16
	OBJC_GET_PROPERTY_OFFSET	20
	OBJC_GET_PROPERTY_OFFSET	24
	OBJC_GET_PROPERTY_OFFSET	28
	OBJC_GET_PROPERTY_OFFSET	32
	OBJC_GET_PROPERTY_OFFSET	36
	OBJC_GET_PROPERTY_OFFSET	40
	OBJC_GET_PROPERTY_OFFSET	44
	OBJC_GET_PROPERTY_OFFSET	48
	OBJC_GET_PROPERTY_OFFSET	52
	OBJC_GET_PROPERTY_OFFSET	56
	OBJC_GET_PROPERTY_OFFSET	60
	OBJC_GET_PROPERTY_OFFSET	64

/********************************************************************
 * id _objc_setProperty_offset_N(id self, SEL _cmd, id value);
 ********************************************************************/

	OBJC_SET_PROPERTY_OFFSET	0
	OBJC_SET_PROPERTY_OFFSET	4
	OBJC_SET_PROPERTY_OFFSET	8
	OBJC_SET_PROPERTY_OFFSET	12
	OBJC_SET_PROPERTY_OFFSET	16
	OBJC_SET_PROPERTY_OFFSET	20
	OBJC_SET_PROPERTY_OFFSET	24
	OBJC_SET_PROPERTY_OFFSET	28
	OBJC_SET_PROPERTY_OFFSET	32
	OBJC_SET_PROPERTY_OFFSET	36
	OBJC_SET_PROPERTY_OFFSET	40
	OBJC_SET_PROPERTY_OFFSET	44
	OBJC_SET_PROPERTY_OFFSET	48
	OBJC_SET_PROPERTY_OFFSET	52
	OBJC_SET_PROPERTY_OFFSET	56
	OBJC_SET_PROPERTY_OFFSET	60
	OBJC_SET_PROPERTY_OFFSET	64
