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

/* 
 * Interposing support.
 * When OBJC_ALLOW_INTERPOSING is set, calls to objc_msgSend_rtp
 * jump to the ordinary messenger via this stub. If objc_msgSend 
 * itself is interposed, dyld will find and change this stub.
 * This stub must be compiled into a separate linker module.
 */

	.data
	.align 4, 0x90
L_get_pc_thunk.edx:
	movl	(%esp,1), %edx
	ret

	.data
	.picsymbol_stub
L_objc_msgSend$stub:
	.indirect_symbol _objc_msgSend
	call	L_get_pc_thunk.edx
1:
	movl	L_objc_msgSend$lz-1b(%edx),%ecx
	jmp	*%ecx
L_objc_msgSend$stub_binder:
	lea	L_objc_msgSend$lz-1b(%edx),%eax
	pushl	%eax
	jmp	dyld_stub_binding_helper
	nop

	.data
	.lazy_symbol_pointer
L_objc_msgSend$lz:
	.indirect_symbol _objc_msgSend
	.long L_objc_msgSend$stub_binder

	.text
	.align 4, 0x90
	.private_extern _objc_msgSend_stub		
_objc_msgSend_stub:
	jmp	L_objc_msgSend$stub
