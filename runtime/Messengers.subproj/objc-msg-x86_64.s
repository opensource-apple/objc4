/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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

#ifdef __x86_64__

/********************************************************************
 ********************************************************************
 **
 **  objc-msg-x86_64.s - x86-64 code to support objc messaging.
 **
 ********************************************************************
 ********************************************************************/

#define __OBJC2__ 1
	
#undef  OBJC_ASM
#define OBJC_ASM
#include "objc-rtp.h"


/********************************************************************
* Data used by the ObjC runtime.
*
********************************************************************/

.data
// Substitute receiver for messages sent to nil (usually also nil)
// id _objc_nilReceiver
.align 4
.globl __objc_nilReceiver
__objc_nilReceiver:
	.quad   0

// _objc_entryPoints and _objc_exitPoints are used by objc
// to get the critical regions for which method caches 
// cannot be garbage collected.

.globl		_objc_entryPoints
_objc_entryPoints:
	.quad	__cache_getImp
	.quad	__cache_getMethod
	.quad	_objc_msgSend
	.quad	_objc_msgSend_fpret
	.quad	_objc_msgSend_fp2ret
	.quad	_objc_msgSend_stret
	.quad	_objc_msgSendSuper
	.quad	_objc_msgSendSuper_stret
	.quad	0

.globl		_objc_exitPoints
_objc_exitPoints:
	.quad	LGetImpExit
	.quad	LGetMethodExit
	.quad	LMsgSendExit
	.quad	LMsgSendFpretExit
	.quad	LMsgSendFp2retExit
	.quad	LMsgSendStretExit
	.quad	LMsgSendSuperExit
	.quad	LMsgSendSuperStretExit
	.quad	0


/********************************************************************
 *
 * Names for parameter registers.
 *
 ********************************************************************/

#define a1 rdi
#define a2 rsi
#define a3 rdx
#define a4 rcx
#define a5 r8
#define a6 r9
#define a6d r9d


/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

// objc_super parameter to sendSuper
	receiver        = 0
	class           = 8

// Selected field offsets in class structure
	isa             = 0
#if __OBJC2__
	cache           = 16
#else
	cache           = 64
#endif

// Method descriptor
	method_name     = 0
	method_imp      = 16

// Cache header
	mask            = 0
	occupied        = 8
	buckets         = 16		// variable length array

// typedef struct {
//	uint128_t floatingPointArgs[8];	// xmm0..xmm7
//	long linkageArea[4];		// r10, rax, ebp, ret
//	long registerArgs[6];		// a1..a6
//	long stackArgs[0];		// variable-size
// } *marg_list;
#define FP_AREA 0
#define LINK_AREA (FP_AREA+8*16)
#define REG_AREA (LINK_AREA+4*8)
#define STACK_AREA (REG_AREA+6*8)


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
	.align	2, 0x90
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


/* DWARF support
   These macros work for objc_msgSend variants and others that call
   CacheLookup/MethodTableLookup or SaveRegisters/RestoreRegisters
   without otherwise building a frame or clobbering callee-save registers

   The macros build appropriate FDEs and tie them to the CIE.
*/

#define DW_CFA_offset 0x80
#define DW_CFA_restore 0xc0
#define DW_CFA_advance_loc4 0x4
#define DW_CFA_same_value 0x8
#define DW_CFA_def_cfa 0xc
#define DW_CFA_def_cfa_register 0xd
#define DW_CFA_def_cfa_offset 0xe
#define DW_CFA_offset_extended_sf 0x11
#define DW_CFA_def_cfa_offset_sf 0x13
#define DW_rax 0
#define DW_rdx 1
#define DW_rcx 2
#define DW_rsi 4
#define DW_rdi 5
#define DW_rbp 6
#define DW_rsp 7
#define DW_r8  8
#define DW_r9  9
#define DW_r10 10
#define DW_ra 16
#define DW_xmm0 17
#define DW_xmm1 18
#define DW_xmm2 19
#define DW_xmm3 20
#define DW_xmm4 21
#define DW_xmm5 22
#define DW_xmm6 23
#define DW_xmm7 24
#define DW_a1  DW_rdi
#define DW_a2  DW_rsi
#define DW_a3  DW_rdx
#define DW_a4  DW_rcx
#define DW_a5  DW_r8
#define DW_a6  DW_r9

// CIE
// 8-byte data multiplier
// 1-byte insn multiplier
// PC-relative everything
// No prologue
	
	.section __TEXT,__eh_frame,coalesced,no_toc+strip_static_syms+live_support
CIE:
	.set	L$set$0,LECIE1-LSCIE1
	.long	L$set$0	# Length of Common Information Entry
LSCIE1:
	.long	0	# CIE Identifier Tag
	.byte	0x3	# CIE Version
	.ascii	"zPR\0"	# CIE Augmentation: size + personality + FDE encoding
	.byte	0x1	# uleb128 0x1; CIE Code Alignment Factor
	.byte	0x78	# sleb128 -0x8; CIE Data Alignment Factor
	.byte	0x10	# CIE RA Column
	.byte	0x6	# uleb128 0x1; Augmentation size
	// Personality augmentation
	.byte	0x9b
	.long	___objc_personality_v0+4@GOTPCREL
	// FDE-encoding augmentation
	.byte	0x10
	// Prefix instructions
	// CFA is %rsp+8
	.byte	DW_CFA_def_cfa
	.byte	DW_rsp
	.byte	8
	// RA is at 0(%rsp) aka -8(CFA)
	.byte	DW_CFA_offset | DW_ra
	.byte	1
	
	.align 3
LECIE1:


.macro EMIT_FDE

	.section __TEXT,__eh_frame,coalesced,no_toc+strip_static_syms+live_support
	
// FDE header
.globl $0.eh
$0.eh:
LSFDE$0:
	.set 	LLENFDE$0, LEFDE$0-LASFDE$0
	.long 	LLENFDE$0		# FDE Length
LASFDE$0:
	.long 	LASFDE$0-CIE		# FDE CIE offset
	.quad	LF0$0-.			# FDE address start
	.quad	LLEN$0			# FDE address range
	.byte	0x0			# uleb128 0x0; Augmentation size

	// DW_START: set by CIE

.if $2 == 1

	// pushq %rbp
	.byte 	DW_CFA_advance_loc4
	.long	LFLEN0$0+1
	.byte	DW_CFA_def_cfa_offset
	.byte	16
	.byte	DW_CFA_offset | DW_rbp
	.byte	-16/-8
	// movq %rsp, %rbp
	.byte 	DW_CFA_advance_loc4
	.long	3
	.byte	DW_CFA_def_cfa_register
	.byte	DW_rbp

.endif

	.align 3
LEFDE$0:
	.text
	
.endmacro


.macro DW_START
LF0$0:
.endmacro
	
.macro DW_FRAME
LF1$0:	
	.set 	LFLEN0$0, LF1$0-LF0$0
.endmacro
	
.macro DW_END
	.set 	LLEN$0, .-LF0$0
	EMIT_FDE $0, LLEN$0, 1
.endmacro

.macro DW_END2
	.set 	LLEN$0, .-LF0$0
	EMIT_FDE $0, LLEN$0, 2
.endmacro


/////////////////////////////////////////////////////////////////////
//
// SaveRegisters
//
// Pushes a stack frame and saves all registers that might contain
// parameter values.
//
// On entry:
//	    $0 = 0 if normal, 1 if CacheLookup already saved a4, a5, a6
//	    stack = ret
//
// On exit: 
//	    %rsp is 16-byte aligned
//	
/////////////////////////////////////////////////////////////////////

.macro SaveRegisters
.if $0 == 0
	movq	%a4, -32(%rsp)
	movq	%a5, -24(%rsp)
	movq	%a6, -16(%rsp)
.else
	// a4-a6 already saved by CacheLookup
.endif

	DW_FRAME $1
	pushq	%rbp
	movq	%rsp, %rbp
	subq	$$ 128+64, %rsp

	movdqa	%xmm0, -192(%rbp)
	movdqa	%xmm1, -176(%rbp)
	movdqa	%xmm2, -160(%rbp)
	movdqa	%xmm3, -144(%rbp)
	movdqa	%xmm4, -128(%rbp)
	movdqa	%xmm5, -112(%rbp)
	movdqa	%xmm6,  -96(%rbp)
	movdqa	%xmm7,  -80(%rbp)
	movq	%r10,   -64(%rbp)	// fixme needed?
	movq	%rax,   -56(%rbp)	// might be xmm parameter count
	movq	%a1,    -48(%rbp)
	movq	%a2,    -40(%rbp)
	movq	%a3,    -32(%rbp)
	// movq	%a4,    -24(%rbp)
	// movq	%a5,    -16(%rbp)
	// movq	%a6,     -8(%rbp)
.endmacro

/////////////////////////////////////////////////////////////////////
//
// RestoreRegisters
//
// Pops a stack frame pushed by SaveRegisters
//
// On entry:
//	    %rbp unchanged since SaveRegisters
//
// On exit: 
//	    stack = ret
//	
/////////////////////////////////////////////////////////////////////

.macro RestoreRegisters
	movdqa	-192(%rbp), %xmm0
	movdqa	-176(%rbp), %xmm1
	movdqa	-160(%rbp), %xmm2
	movdqa	-144(%rbp), %xmm3
	movdqa	-128(%rbp), %xmm4
	movdqa	-112(%rbp), %xmm5
	movdqa	 -96(%rbp), %xmm6
	movdqa	 -80(%rbp), %xmm7
	movq	 -64(%rbp), %r10
	movq	 -56(%rbp), %rax
	movq	 -48(%rbp), %a1
	movq	 -40(%rbp), %a2
	movq	 -32(%rbp), %a3
	movq	 -24(%rbp), %a4
	movq	 -16(%rbp), %a5
	movq	  -8(%rbp), %a6
	movq	%rbp, %rsp
	popq	%rbp
.endmacro


/////////////////////////////////////////////////////////////////////
//
//
// CacheLookup	selectorRegister, cacheMissLabel
//
// Locate the implementation for a selector in a class method cache.
//
// Takes: 
//	  $0 = register containing selector (%a1 or %a2 ONLY)
//	  $1 = if method is not cached then jmp LCacheMiss$1
//	  %r11 = class whose cache is to be searched
//	  stack = ret
//
// On exit: (found) method triplet in %r11
//	    (not found) jumps to cacheMissLabel
//	    stack = ret
//	
/////////////////////////////////////////////////////////////////////


.macro	CacheLookup

// load variables and save caller registers.

	movq	%a4, -32(%rsp)		// save scratch registers in red zone
	movq	%a5, -24(%rsp)
	movq	%a6, -16(%rsp)

	movq	cache(%r11), %a5	// cache = class->cache

	movl	mask(%a5), %a6d
	shlq	$$3, %a6		// %a6 = cache->mask << 3
	mov	$0, %a4			// bytes = sel
	andq	%a6, %a4		// bytes &= (mask << 3)
	
// search the receiver's cache
// r11 = method (soon)
// a4 = bytes
// a5 = cache
// a6 = mask << 3
// $0 = sel
LMsgSendProbeCache_$1:
	movq	buckets(%a5, %a4), %r11	// method = cache->buckets[bytes/8]
	testq	%r11, %r11			// if (method == NULL)
	je	LCacheMiss$1			//   goto cacheMissLabel

	addq	$$8, %a4			// bytes += 8
	andq	%a6, %a4			// bytes &= (mask << 3)
	cmpq	method_name(%r11), $0		// if (method_name != sel)
	jne	LMsgSendProbeCache_$1	//   goto loop

	// cache hit, r11 = method triplet

	// restore saved registers
	movq	-32(%rsp), %a4
	movq	-24(%rsp), %a5
	movq	-16(%rsp), %a6

.endmacro


/////////////////////////////////////////////////////////////////////
//
// MethodTableLookup classRegister, selectorRegister, fn
//
// Takes: $0 = class to search (%a1 or %a2 or %r11 ONLY)
//	  $1 = selector to search for (%a2 or %a3 ONLY)
//
// Stack: ret (%rsp+0), pad, %a4, %a5, %a6 (saved by CacheLookup)
//
// On exit: restores registers saved by CacheLookup
//	  imp in %r11
//
/////////////////////////////////////////////////////////////////////
.macro MethodTableLookup

	SaveRegisters 1, $2

	// _class_lookupMethodAndLoadCache(class, selector)
	movq	$0, %a1
	movq	$1, %a2
	call	__class_lookupMethodAndLoadCache

	// IMP is now in %rax
	movq	%rax, %r11

	RestoreRegisters $2

.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP msgForward_internal_imp)
 *
 * On entry:	a1 = class whose cache is to be searched
 *		a2 = selector to search for
 *		a3 = _objc_msgForward_internal IMP
 *
 * If found, returns method triplet pointer.
 * If not found, returns NULL.
 *
 * NOTE: _cache_getMethod never returns any cache entry whose implementation
 * is _objc_msgForward_internal. It returns 1 instead. This prevents thread-
 * thread-safety and memory management bugs in _class_lookupMethodAndLoadCache.
 * See _class_lookupMethodAndLoadCache for details.
 *
 * _objc_msgForward_internal is passed as a parameter because it's more 
 * efficient to do the (PIC) lookup once in the caller than repeatedly here.
 ********************************************************************/
        
	ENTRY __cache_getMethod
	DW_START __cache_getMethod

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup %a2, __cache_getMethod

// cache hit, method triplet in %r11
	cmpq    method_imp(%r11), %a3	// if (imp==_objc_msgForward_internal)
	je      1f			//     return (Method)1
	movq	%r11, %rax		// return method triplet address
	ret
1:	movq	$1, %rax
	ret

LCacheMiss__cache_getMethod:
// cache miss, return nil
	xorq    %rax, %rax      // erase %rax
	ret

LGetMethodExit:
	DW_END2		__cache_getMethod
	END_ENTRY 	__cache_getMethod


/********************************************************************
 * IMP _cache_getImp(Class cls, SEL sel)
 *
 * On entry:	a1 = class whose cache is to be searched
 *		a2 = selector to search for
 *
 * If found, returns method implementation.
 * If not found, returns NULL.
 ********************************************************************/

	ENTRY __cache_getImp
	DW_START __cache_getImp

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup %a2, __cache_getImp

// cache hit, method triplet in %r11
	movq	method_imp(%r11), %rax	// return method imp address
	ret

LCacheMiss__cache_getImp:
// cache miss, return nil
	xorq    %rax, %rax      // erase %rax
	ret

LGetImpExit:
	DW_END2 	__cache_getImp
	END_ENTRY 	__cache_getImp


/********************************************************************
 *
 * id objc_msgSend(id self, SEL	_cmd,...);
 *
 ********************************************************************/
	
	ENTRY	_objc_msgSend
	DW_START _objc_msgSend

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendReturnSelf	// ignore and return self

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, _objc_msgSend
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSend:
	MethodTableLookup isa(%a1), %a2, _objc_msgSend
	// MethodTableLookup placed IMP in r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendNilSelf:
	movq	__objc_nilReceiver(%rip), %a1
	testq	%a1, %a1		// if (receiver != nil)
	jne	LMsgSendReceiverOk	//   send to new receiver

	// message sent to nil - return 0
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret
	
LMsgSendReturnSelf:
	movq	%a1, %rax
	ret

LMsgSendExit:
	DW_END 		_objc_msgSend
	END_ENTRY	_objc_msgSend

#if __OBJC2__
	ENTRY _objc_msgSend_fixup
	DW_START _objc_msgSend_fixup

	testq	%a1, %a1
	je	LMsgSendFixupNilSelf

	SaveRegisters 0, _objc_msgSend_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %r11		// selector
	movq	isa(%a1), %a6		// isa = *receiver
	movq	cache(%a6), %a5		// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

LMsgSendFixupNilSelf:
	// message sent to nil - return 0
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret
	
	DW_END 		_objc_msgSend_fixup
	END_ENTRY 	_objc_msgSend_fixup


	ENTRY _objc_msgSend_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend
	END_ENTRY _objc_msgSend_fixedup
#endif

	
/********************************************************************
 *
 * id objc_msgSendSuper(struct objc_super *super, SEL _cmd,...);
 *
 * struct objc_super {
 *		id	receiver;
 *		Class	class;
 * };
 ********************************************************************/
	
	ENTRY	_objc_msgSendSuper
	DW_START _objc_msgSendSuper

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendSuperReturnSelf

// search the cache (objc_super in %a1)
	movq	class(%a1), %r11	// class = objc_super->class
	CacheLookup %a2, _objc_msgSendSuper
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	movq	receiver(%a1), %a1	// load real receiver
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSendSuper:
	MethodTableLookup class(%a1), %a2, _objc_msgSendSuper
	// MethodTableLookup placed IMP in r11
	movq	receiver(%a1), %a1	// load real receiver
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

LMsgSendSuperReturnSelf:
	movq    receiver(%a1), %rax
	ret
	
LMsgSendSuperExit:
	DW_END 		_objc_msgSendSuper
	END_ENTRY	_objc_msgSendSuper

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_fixup
	DW_START _objc_msgSendSuper2_fixup

	SaveRegisters 0, _objc_msgSendSuper2_fixup
	// a1 = address of objc_super2
	// a2 = address of message ref
	movq	%a2, %a3
	movq	%a1, %a2
	movq	receiver(%a1), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters _objc_msgSendSuper2_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	// Load receiver from objc_super2
	movq	receiver(%a1), %a1
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11
	
	DW_END 		_objc_msgSendSuper2_fixup
	END_ENTRY 	_objc_msgSendSuper2_fixup


	ENTRY _objc_msgSendSuper2_fixedup
	// objc_super->class is superclass of class to search
	movq	class(%a1), %r11	// cls = objc_super->class
	movq	8(%a2), %a2		// load _cmd from message_ref
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a1)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper
	END_ENTRY _objc_msgSendSuper2_fixedup


	ENTRY _objc_msgSendSuper2
	// objc_super->class is superclass of class to search
	movq	class(%a1), %r11	// cls = objc_super->class
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a1)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper
	END_ENTRY _objc_msgSendSuper2
#endif


/********************************************************************
 *
 * double objc_msgSend_fpret(id self, SEL _cmd,...);
 * Used for `long double` return only. `float` and `double` use objc_msgSend.
 *
 ********************************************************************/

	ENTRY	_objc_msgSend_fpret
	DW_START _objc_msgSend_fpret

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendFpretReturnZero

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendFpretNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendFpretReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, _objc_msgSend_fpret
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSend_fpret:
	MethodTableLookup isa(%a1), %a2, _objc_msgSend_fpret
	// MethodTableLookup placed IMP in r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendFpretNilSelf:
1:	movq	__objc_nilReceiver(%rip),%a1
	testq	%a1, %a1		// if (receiver != nil)
	jne	LMsgSendFpretReceiverOk	//   send to new receiver

LMsgSendFpretReturnZero:
	// Long double return.
	fldz
	// Clear int and float/double return too.
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret

LMsgSendFpretExit:
	DW_END 		_objc_msgSend_fpret
	END_ENTRY	_objc_msgSend_fpret
	
#if __OBJC2__
	ENTRY _objc_msgSend_fpret_fixup
	DW_START _objc_msgSend_fpret_fixup

	testq	%a1, %a1
	je	LMsgSendFpretFixupNilSelf

	SaveRegisters 0, _objc_msgSend_fpret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %r11		// selector
	movq	isa(%a1), %a6		// isa = *receiver
	movq	cache(%a6), %a5		// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fpret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

LMsgSendFpretFixupNilSelf:
	// Long double return.
	fldz
	// Clear int and float/double return too.
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret
	
	DW_END 		_objc_msgSend_fpret_fixup
	END_ENTRY 	_objc_msgSend_fpret_fixup


	ENTRY _objc_msgSend_fpret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend_fpret
	END_ENTRY _objc_msgSend_fpret_fixedup
#endif


/********************************************************************
 *
 * double objc_msgSend_fp2ret(id self, SEL _cmd,...);
 * Used for `complex long double` return only.
 *
 ********************************************************************/

	ENTRY	_objc_msgSend_fp2ret
	DW_START _objc_msgSend_fp2ret

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendFp2retReturnZero

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendFp2retNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendFp2retReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, _objc_msgSend_fp2ret
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSend_fp2ret:
	MethodTableLookup isa(%a1), %a2, _objc_msgSend_fp2ret
	// MethodTableLookup placed IMP in r11
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp	*%r11			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendFp2retNilSelf:
1:	movq	__objc_nilReceiver(%rip),%a1
	testq	%a1, %a1		// if (receiver != nil)
	jne	LMsgSendFp2retReceiverOk	//   send to new receiver

LMsgSendFp2retReturnZero:
	// complex long double return.
	fldz
	fldz
	// Clear int and float/double return too.
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret

LMsgSendFp2retExit:
	DW_END 		_objc_msgSend_fp2ret
	END_ENTRY	_objc_msgSend_fp2ret

#if __OBJC2__
	ENTRY _objc_msgSend_fp2ret_fixup
	DW_START _objc_msgSend_fp2ret_fixup

	testq	%a1, %a1
	je	LMsgSendFp2retFixupNilSelf

	SaveRegisters 0, _objc_msgSend_fp2ret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a2), %r11		// selector
	movq	isa(%a1), %a6		// isa = *receiver
	movq	cache(%a6), %a5		// cache = *isa
	movq	mask(%a5), %a4		// *cache
	
	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_fp2ret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	cmp	%r11, %r11		// set nonstret (eq) for forwarding
	jmp 	*%r11

LMsgSendFp2retFixupNilSelf:
	// complex long double return.
	fldz
	fldz
	// Clear int and float/double return too.
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret
	
	DW_END 		_objc_msgSend_fp2ret_fixup
	END_ENTRY 	_objc_msgSend_fp2ret_fixup


	ENTRY _objc_msgSend_fp2ret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp	_objc_msgSend_fp2ret
	END_ENTRY _objc_msgSend_fp2ret_fixedup
#endif


/********************************************************************
 *
 * void	objc_msgSend_stret(void *st_addr, id self, SEL _cmd, ...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for %a1 to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 *
 * On entry:	%a1 is the address where the structure is returned,
 *		%a2 is the message receiver,
 *		%a3 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSend_stret
	DW_START _objc_msgSend_stret

// check whether receiver is nil 
	testq	%a2, %a2
	je	LMsgSendStretNilSelf

// receiver (in %a2) is non-nil: search the cache
LMsgSendStretReceiverOk:
	movq	isa(%a2), %r11			//   class = self->isa
	CacheLookup %a3, _objc_msgSend_stret
	// CacheLookup placed method in %r11
	movq	method_imp(%r11), %r11
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSend_stret:
	MethodTableLookup isa(%a2), %a3, _objc_msgSend_stret
	// MethodTableLookup placed IMP in r11
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendStretNilSelf:
	movq	__objc_nilReceiver(%rip), %a2
	testq	%a2, %a2			// if (receiver != nil)
	jne	LMsgSendStretReceiverOk		//   send to new receiver
	ret					// else just return

LMsgSendStretExit:
	DW_END 		_objc_msgSend_stret
	END_ENTRY	_objc_msgSend_stret

#if __OBJC2__
	ENTRY _objc_msgSend_stret_fixup
	DW_START _objc_msgSend_stret_fixup

	testq	%a2, %a2
	je	LMsgSendStretFixupNilSelf

	SaveRegisters 0, _objc_msgSend_stret_fixup

	// Dereference obj/isa/cache to crash before _objc_fixupMessageRef
	movq	8(%a3), %r11		// selector
	movq	isa(%a2), %a6		// isa = *receiver
	movq	cache(%a6), %a5		// cache = *isa
	movq	mask(%a5), %a4		// *cache

	// a2 = receiver
	// a3 = address of message ref
	movq	%a2, %a1
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11

	RestoreRegisters _objc_msgSend_stret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

LMsgSendStretFixupNilSelf:
	ret
	
	DW_END 		_objc_msgSend_stret_fixup
	END_ENTRY 	_objc_msgSend_stret_fixup


	ENTRY _objc_msgSend_stret_fixedup
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	jmp	_objc_msgSend_stret
	END_ENTRY _objc_msgSend_stret_fixedup
#endif


/********************************************************************
 *
 * void objc_msgSendSuper_stret(void *st_addr, struct objc_super *super, SEL _cmd, ...);
 *
 * struct objc_super {
 *		id	receiver;
 *		Class	class;
 * };
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	%a1 is the address where the structure is returned,
 *		%a2 is the address of the objc_super structure,
 *		%a3 is the selector
 *
 ********************************************************************/

	ENTRY	_objc_msgSendSuper_stret
	DW_START _objc_msgSendSuper_stret

// search the cache (objc_super in %a2)
	movq	class(%a2), %r11		// class = objc_super->class
	CacheLookup %a3, _objc_msgSendSuper_stret
	// CacheLookup placed method in %r11
	movq	method_imp(%r11), %r11
	movq	receiver(%a2), %a2	// load real receiver
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LCacheMiss_objc_msgSendSuper_stret:
	MethodTableLookup class(%a2), %a3, _objc_msgSendSuper_stret
	// MethodTableLookup placed IMP in r11
	movq	receiver(%a2), %a2	// load real receiver
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp

LMsgSendSuperStretExit:
	DW_END 		_objc_msgSendSuper_stret
	END_ENTRY	_objc_msgSendSuper_stret

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_stret_fixup
	DW_START _objc_msgSendSuper2_stret_fixup

	SaveRegisters 0, _objc_msgSendSuper2_stret_fixup
	// a2 = address of objc_super2
	// a3 = address of message ref
	movq	receiver(%a2), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters _objc_msgSendSuper2_stret_fixup

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	// Load receiver from objc_super2
	movq	receiver(%a2), %a2
	test	%r11, %r11		// set stret (ne) for forward; r11!=0
	jmp	*%r11			// goto *imp
	
	DW_END 		_objc_msgSendSuper2_stret_fixup
	END_ENTRY 	_objc_msgSendSuper2_stret_fixup

	
	ENTRY _objc_msgSendSuper2_stret_fixedup
	// objc_super->class is superclass of class to search
	movq	class(%a2), %r11	// cls = objc_super->class
	movq	8(%a3), %a3		// load _cmd from message_ref
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a2)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper_stret
	END_ENTRY _objc_msgSendSuper2_stret_fixedup


	ENTRY _objc_msgSendSuper2_stret
	// objc_super->class is superclass of class to search
	movq	class(%a2), %r11	// cls = objc_super->class
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a2)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper_stret
	END_ENTRY _objc_msgSendSuper2_stret
#endif


/********************************************************************
 *
 * id _objc_msgForward(id self, SEL _cmd,...);
 *
 ********************************************************************/

// _FwdSel is @selector(forward::), set up in map_images().
// ALWAYS dereference _FwdSel to get to "forward::" !!
	.data
	.align 3
	.private_extern _FwdSel
_FwdSel: .quad 0

	.cstring
	.align 3
LUnkSelStr: .ascii "Does not recognize selector %s\0"

	.data
	.align 3
	.private_extern __objc_forward_handler
__objc_forward_handler:	.quad 0

	.data
	.align 3
	.private_extern __objc_forward_stret_handler
__objc_forward_stret_handler:	.quad 0


	ENTRY	__objc_msgForward_internal
	.private_extern __objc_msgForward_internal
	// Method cache version

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band condition register is NE for stret, EQ otherwise.

	jne	__objc_msgForward_stret
	jmp	__objc_msgForward

	END_ENTRY	__objc_msgForward_internal
	
	
	ENTRY	__objc_msgForward
	// Non-stret version

	// Call user handler, if any
	movq	__objc_forward_handler(%rip), %r11
	testq	%r11, %r11		// if (handler == NULL)
	je	1f			//   skip handler
	jmp	*%r11			// else goto handler
1:	
	// No user handler

	// Die if forwarding "forward::"
	cmpq	%a2, _FwdSel(%rip)
	je	LMsgForwardError

	// Record current return address. It will be copied elsewhere in 
	// the marg_list because this location is needed for register args
	movq	(%rsp), %r11

	// Push stack frame
	// Space for: fpArgs + regArgs + linkage - ret (already on stack)
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp

	// Save return address in linkage area.
	movq	%r11, 16+LINK_AREA(%rsp)
	
	// Save parameter registers
	movq	%a1,  0+REG_AREA(%rsp)
	movq	%a2,  8+REG_AREA(%rsp)
	movq	%a3, 16+REG_AREA(%rsp)
	movq	%a4, 24+REG_AREA(%rsp)
	movq	%a5, 32+REG_AREA(%rsp)
	movq	%a6, 40+REG_AREA(%rsp)

	// Save side parameter registers
	movq	%r10, 0+LINK_AREA(%rsp)	// static chain (fixme needed?)
	movq	%rax, 8+LINK_AREA(%rsp)	// xmm count
	// 16+LINK_AREA is return address

	// Save xmm registers
	movdqa	%xmm0, 0+FP_AREA(%rsp)
	movdqa	%xmm1, 16+FP_AREA(%rsp)
	movdqa	%xmm2, 32+FP_AREA(%rsp)
	movdqa	%xmm3, 48+FP_AREA(%rsp)
	movdqa	%xmm4, 64+FP_AREA(%rsp)
	movdqa	%xmm5, 80+FP_AREA(%rsp)
	movdqa	%xmm6, 96+FP_AREA(%rsp)
	movdqa	%xmm7, 112+FP_AREA(%rsp)

	// Call [receiver forward:sel :margs]
	movq	%rsp, %a4		// marg_list
	movq	%a2, %a3		// sel
	movq	_FwdSel(%rip), %a2	// forward::
	// %a1 is already the receiver

	call	_objc_msgSend
	
	// Retrieve return address from linkage area
	movq	16+LINK_AREA(%rsp), %r11
	// Pop stack frame
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp
	// Put return address back
	movq	%r11, (%rsp)
	ret

LMsgForwardError:
	// Tail-call __objc_error(receiver, "unknown selector %s", "forward::")
	// %a1 is already the receiver
	leaq	LUnkSelStr(%rip), %a2	// "unknown selector %s"
	movq	_FwdSel(%rip), %a3	// forward::
	jmp	___objc_error		// never returns

	END_ENTRY	__objc_msgForward


	ENTRY	__objc_msgForward_stret
	// Struct-return version
	
	// Call user handler, if any
	movq	__objc_forward_stret_handler(%rip), %r11
	testq	%r11, %r11		// if (handler == NULL)
	je	1f			//   skip handler
	jmp	*%r11			// else goto handler
1:	
	// No user handler
	// Die if forwarding "forward::"
	cmpq	%a3, _FwdSel(%rip)
	je	LMsgForwardStretError

	// Record current return address. It will be copied elsewhere in 
	// the marg_list because this location is needed for register args
	movq	(%rsp), %r11

	// Push stack frame
	// Space for: fpArgs + regArgs + linkage - ret (already on stack)
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp

	// Save return address in linkage area.
	movq	%r11, 16+LINK_AREA(%rsp)
	
	// Save parameter registers
	movq	%a1,  0+REG_AREA(%rsp)
	movq	%a2,  8+REG_AREA(%rsp)
	movq	%a3, 16+REG_AREA(%rsp)
	movq	%a4, 24+REG_AREA(%rsp)
	movq	%a5, 32+REG_AREA(%rsp)
	movq	%a6, 40+REG_AREA(%rsp)

	// Save side parameter registers
	movq	%r10, 0+LINK_AREA(%rsp)	// static chain (fixme needed?)
	movq	%rax, 8+LINK_AREA(%rsp)	// xmm count
	// 16+LINK_AREA is return address

	// Save xmm registers
	movdqa	%xmm0, 0+FP_AREA(%rsp)
	movdqa	%xmm1, 16+FP_AREA(%rsp)
	movdqa	%xmm2, 32+FP_AREA(%rsp)
	movdqa	%xmm3, 48+FP_AREA(%rsp)
	movdqa	%xmm4, 64+FP_AREA(%rsp)
	movdqa	%xmm5, 80+FP_AREA(%rsp)
	movdqa	%xmm6, 96+FP_AREA(%rsp)
	movdqa	%xmm7, 112+FP_AREA(%rsp)

	// Call [receiver forward:sel :margs]
	movq	%a2, %a1		// receiver
	movq	_FwdSel(%rip), %a2	// forward::
	// %a3 is already the selector
	movq	%rsp, %a4		// marg_list

	call	_objc_msgSend		// forward:: is NOT struct-return
	
	// Retrieve return address from linkage area
	movq	16+LINK_AREA(%rsp), %r11
	// Pop stack frame
	subq	$ 8*16 + 6*8 + (4-1)*8, %rsp
	// Put return address back
	movq	%r11, (%rsp)
	ret

LMsgForwardStretError:
	// Tail-call __objc_error(receiver, "unknown selector %s", "forward::")
	movq	%a2, %a1		// receiver
	leaq	LUnkSelStr(%rip), %a2	// "unknown selector %s"
	movq	_FwdSel(%rip), %a3	// forward::
	jmp	___objc_error		// never returns

	END_ENTRY	__objc_msgForward_stret


	ENTRY _method_invoke

	movq	method_imp(%a2), %r11
	movq	method_name(%a2), %a2
	jmp	*%r11
	
	END_ENTRY _method_invoke


	ENTRY _method_invoke_stret

	movq	method_imp(%a3), %r11
	movq	method_name(%a3), %a3
	jmp	*%r11
	
	END_ENTRY _method_invoke_stret

	
/********************************************************************
 *
 * id vtable_prototype(id self, message_ref *msg, ...)
 *
 * This code is copied to create vtable trampolines.
 * The instruction following LvtableIndex is modified to
 * insert each vtable index.
 *
 * This code is placed in its own section to prevent dtrace from
 * instrumenting it. Otherwise, dtrace would insert an INT3, the
 * code would be copied, and the copied INT3 would cause a crash.
 *
 ********************************************************************/

.macro VTABLE /* byte-offset, name */

	.align 2
	.private_extern _$1
_$1:
	test	%a1, %a1
	je	LvtableReturnZero_$1	// nil check
	movq	8(%a2), %a2		// load _cmd (fixme schedule?)
	movq	0(%a1), %r10		// load isa
	movq	24(%r10), %r11		// load vtable
LvtableIndex_$1:
	movq	$0 (%r11), %r10	// load imp (DO NOT CHANGE)
	jmp	*%r10
LvtableReturnZero_$1:
	// integer registers only; not used for fpret / stret / etc
	movq	$$0, %rax
	movq	$$0, %rdx
	ret
LvtableEnd_$1:
	nop

.endmacro

	.section __TEXT,__objc_codegen,regular
	VTABLE	0x7fff, vtable_prototype
	
	.data
	.align 2
	.private_extern _vtable_prototype_size
_vtable_prototype_size:
	.long	LvtableEnd_vtable_prototype - _vtable_prototype

	.private_extern _vtable_prototype_index_offset
_vtable_prototype_index_offset:
	.long	LvtableIndex_vtable_prototype - _vtable_prototype


/********************************************************************
 *
 * id vtable_ignored(id self, message_ref *msg, ...)
 *
 * Vtable trampoline for GC-ignored selectors. Immediately returns self.
 *
 ********************************************************************/	

	.text
	.align 2
	.private_extern _vtable_ignored
_vtable_ignored:
	movq	%a1, %rax
	ret


/********************************************************************
 *
 * id objc_msgSend_vtable<n>(id self, message_ref *msg, ...)
 *
 * Built-in expansions of vtable_prototype for the default vtable.
 *
 ********************************************************************/
	
	.text

	.align	4
	.private_extern _defaultVtableTrampolineDescriptors
_defaultVtableTrampolineDescriptors:
	// objc_trampoline_header
	.short	16  // headerSize
	.short	8   // descSize
	.long	16  // descCount
	.quad	0   // next
	
	// objc_trampoline_descriptor[16]
.macro TDESC /* n */
L_tdesc$0:
	.long	_objc_msgSend_vtable$0 - L_tdesc$0
	.long	(1<<0) + (1<<2)  // MESSAGE and VTABLE
.endmacro
	
	TDESC	0
	TDESC	1
	TDESC	2
	TDESC	3
	TDESC	4
	TDESC	5
	TDESC	6
	TDESC	7
	TDESC	8
	TDESC	9
	TDESC	10
	TDESC	11
	TDESC	12
	TDESC	13
	TDESC	14
	TDESC	15

	// trampoline code
	.align	4
	VTABLE	 0*8, objc_msgSend_vtable0
	VTABLE	 1*8, objc_msgSend_vtable1
	VTABLE	 2*8, objc_msgSend_vtable2
	VTABLE	 3*8, objc_msgSend_vtable3
	VTABLE	 4*8, objc_msgSend_vtable4
	VTABLE	 5*8, objc_msgSend_vtable5
	VTABLE	 6*8, objc_msgSend_vtable6
	VTABLE	 7*8, objc_msgSend_vtable7
	VTABLE	 8*8, objc_msgSend_vtable8
	VTABLE	 9*8, objc_msgSend_vtable9
	VTABLE	10*8, objc_msgSend_vtable10
	VTABLE	11*8, objc_msgSend_vtable11
	VTABLE	12*8, objc_msgSend_vtable12
	VTABLE	13*8, objc_msgSend_vtable13
	VTABLE	14*8, objc_msgSend_vtable14
	VTABLE	15*8, objc_msgSend_vtable15

#endif
