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
	.file	"objc-msg-i386.s"
gcc2_compiled.:
___gnu_compiled_objc:
#ifdef KERNEL
.globl _objc_entryPoints
_objc_entryPoints:
	.long _objc_msgSend
	.long _objc_msgSendSuper
	.long _objc_msgSendv
	.long 0

.globl _objc_exitPoints
_objc_exitPoints:
	.long Lexit1
	.long Lexit2
	.long Lexit3
	.long Lexit4
	.long Lexit5
	.long Lexit6
	.long Lexit7
	.long Lexit8
	.long 0
#endif /* KERNEL */

/********************************************************************
 ********************************************************************
 *
 * Objective-C message dispatching for the Win32/i386
 *
 ********************************************************************
 ********************************************************************/

// Make this non-zero to use old style 32-bit-dirty structure returns
#define COMPATIBLE_CODE		0

/********************************************************************
 *
 * Stack frame definitions.
 *
 ********************************************************************/

	// standard word-return arguments
	self					= 4
	selector				= 8

	// standard struct-return arguments
	// These values are used when doing a struct return message.
	// The return value of the struct return is pushed on the stack
	// as a "hidden" first parameter so the remaining parameters
	// are 4 bytes further down the stack than they are in a 
	// normal message
	struct_return_addr		= self
	struct_return_self		= self + 4
	struct_return_selector	= selector + 4

	// additional arguments for _objc_msgForward
	margSize				= 12
	margs					= 16

	// additional arguments for _objc_msgForward_stret
	struct_return_margSize	= margSize + 4
	struct_return_margs		= margs + 4


	// special self argument for objc_msgSendSuper
	caller					= self

	// special self argument for objc_msgSendSuper_stret
	struct_return_caller	= caller + 4

/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

// objc_super parameter to objc_msgSendSuper
	receiver		= 0
	class			= 4

// Selected field offsets in class structure
	isa				= 0
	cache			= 32

// Method descriptor
	method_name		= 0
	method_imp		= 8

// Cache header
	mask			= 0
	occupied		= 4
	buckets			= 8		// variable length array (null terminated)

/********************************************************************
 *
 * Constants.
 *
 ********************************************************************/

// In case the implementation is _objc_msgForward, indicate to it
// whether the method was invoked as a word-return or struct-return.
// This flag is passed in a register that is caller-saved, and is
// not part of the parameter passing convention (i.e. it is "out of
// band").  This works because _objc_msgForward is only entered
// from here in the messenger.
	kFwdMsgSend			= 0
	kFwdMsgSendStret	= 1

/********************************************************************
 * id		objc_msgSend	   (id		self,
 *								SEL		op,
 *								...);
 *
 * On entry:	(sp+4) is the message receiver,
 *				(sp+8) is the selector
 *
 * And the structure-return version :
 *
 * struct_type	objc_msgSend_stret     (id		self,
 *										SEL		op,
 *										...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 *
 * On entry:	(sp+4)is the address where the structure is returned,
 *				(sp+8) is the message receiver,
 *				(sp+12) is the selector
 ********************************************************************/

	.text
	.globl	_objc_msgSend
	.globl	_objc_msgSend_stret
	.align	4, 0x90
_objc_msgSend_stret:
	movl	struct_return_self(%esp), %eax		// %eax = self
	movl	struct_return_selector(%esp), %ecx	// %ecx = selector
	pushl	$kFwdMsgSendStret					// flag struct-return for _objc_msgForward
	jmp		L1check_message

	.align	4, 0x90
_objc_msgSend:
#if COMPATIBLE_CODE
	movl	self(%esp), %eax
	andl	$0x80000000, %eax
	jne		_objc_msgSend_stret
#endif
	movl	self(%esp), %eax					// %eax = self
	movl	selector(%esp), %ecx				// %ecx = selector
	pushl	$kFwdMsgSend						// flag word-return for _objc_msgForward

L1check_message:
	pushl	%ecx								// Push selector
	pushl	%eax								// Push self
	movl	%eax, %edx							// Move self off to do a comparison
	andl	__objc_multithread_mask, %edx		// And it against the multithreading mask
												//   This will also tell us if it's a nil object
	je		L1nil_or_multi						// Jump if nil or multithreading is on

// Load variables and save caller registers.
// Overlapped to prevent AGI
// At this point, self has been loaded into eax and selector has been 
// loaded into ecx.
	movl	isa(%eax), %eax						// class = self->isa
	pushl	%edi								//
	movl	cache(%eax), %eax					// cache = class->cache
	pushl	%esi								//

	lea		buckets(%eax), %edi					// buckets = &cache->buckets
	movl	mask(%eax), %esi					// mask = cache->mask
	movl	%ecx, %edx							// index = selector

L1probe_cache:
	andl	%esi, %edx							// index &= mask
	movl	(%edi, %edx, 4), %eax				// method_name = buckets[index]

	testl	%eax, %eax							// if (method != NULL) {
	je		L1cache_miss						//
	cmpl	method_name(%eax), %ecx				//    method_name = method->name
	jne		L1not_the_method					//	  if (method_name == selector) {

	movl	method_imp(%eax), %eax				//      imp = method->method_imp
	popl	%esi								//
	popl	%edi								//
	addl	$8, %esp							// dump saved self and selector
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit1:	jmp	*%eax								//      goto *imp
	.space 17									// area for moninitobjc to write
												//        }
L1not_the_method:
	inc		%edx								//    index++
	jmp		L1probe_cache						// }

	.align 4, 0x90
L1cache_miss:
	// restore caller registers
	popl	%esi								//
	popl	%edi								//

// self and selector are already on the stack, so just
// replace self with its class pointer
	popl	%eax								// pop self
	movl	isa(%eax), %eax						// load the class pointer
	pushl	%eax								// push class pointer, selector is already there
	call	__class_lookupMethodAndLoadCache	// lookup the method and load the cache
	addl	$8, %esp							// pop the args off the stack
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit2:	jmp	*%eax	
	.space 17									// area for moninitobjc to write

	.align 4, 0x90
L1nil_or_multi:
	testl	%eax,%eax							// Check for a nil object
	jne		L1multi_msgSend						// Jump to multi_msgSend if it's not a real object

	movl	__objc_msgNil, %eax					// Load nil message handler
	testl	%eax, %eax
	je		Ljust_return						// If NULL just return and don't do anything
	call	*%eax								//      call __objc_msgNil
	xorl	%eax, %eax							// Rezero $eax just in case
Ljust_return:
	addl	$12, %esp							// pop the args and flag off the stack
	ret


// locking version of send - its the same except for the lock/clear
	.align 4, 0x90
L1multi_msgSend:
	// spin lock
	movl	$1, %ecx							// Move 1 into ecx
	leal	_messageLock, %eax					// Then load the address of _messageLock 
L11spin:
	xchgl	%ecx, (%eax)
	cmpl	$0, %ecx
	jne		L11spin

	movl	0(%esp),%eax						// retrieve self
	movl	4(%esp),%ecx						// retrieve selector

// load variables and save caller registers.
// Overlapped to prevent AGI
// At this point, self has been loaded into eax and selector has been 
// loaded into ecx.
	movl	isa(%eax), %eax						// class = self->isa
	pushl	%edi								//
	movl	cache(%eax), %eax					// cache = class->cache
	pushl	%esi								//

	lea		buckets(%eax), %edi					// buckets = &cache->buckets
	movl	mask(%eax), %esi					// mask = cache->mask
	movl	%ecx, %edx							// index = selector

L11probe_cache:
	andl	%esi, %edx							// index &= mask
	movl	(%edi, %edx, 4), %eax				// method_name = buckets[index]

	testl	%eax, %eax							// if (method != NULL) {
	je		L11cache_miss						//
	cmpl	method_name(%eax), %ecx				//    method_name = method->name
	jne		L11not_the_method					//	  if (method_name == selector) {

	movl	method_imp(%eax), %eax				//      imp = method->method_imp
	popl	%esi								//
	popl	%edi								//
	addl	$8, %esp							// dump saved self and selector
	movl	$0, _messageLock					// unlock
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit3:	jmp	*%eax								//      goto *imp
	.space 17									// area for moninitobjc to write
												//        }
	.align 4, 0x90
L11not_the_method:
	inc	%edx									//    index++
	jmp	L11probe_cache							// }

	.align 4, 0x90
L11cache_miss:
	// restore caller registers
	popl	%esi								//
	popl	%edi								//

// self and selector are already on the stack, so just
// replace self with its class pointer
	popl	%eax								// pop self
	movl	isa(%eax), %eax						// load the class pointer
	pushl	%eax								// push class pointer, selector is already there
	call	__class_lookupMethodAndLoadCache
	addl	$8, %esp
	movl	$0, _messageLock					// unlock
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit4:	jmp	*%eax
	.space 17									// area for moninitobjc to write


/********************************************************************
 * id	objc_msgSendSuper	   (struct objc_super *	super,
 *								SEL					op,
 *								...);
 *
 * struct objc_super {
 *	id		receiver;
 *	Class	class;
 * };
 *
 * And the structure-return version:
 *
 * struct_type	objc_msgSendSuper_stret	   (objc_super *	super,
 *											SEL				op,
 *											...);
 *
 * struct objc_super {
 *	id		receiver;
 *	Class	class;
 * };
 *
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	(sp+4) is the address to which to copy the returned structure,
 *				(sp+8) is the address of the objc_super structure,
 *				(sp+12) is the selector
 *
 ********************************************************************/

	.globl	_objc_msgSendSuper
	.globl	_objc_msgSendSuper_stret
	.align 4, 0x90
_objc_msgSendSuper:
#if COMPATIBLE_CODE
	movl	caller(%esp), %eax
	andl	$0x80000000, %eax
	jne		_objc_msgSendSuper_stret
#endif
	movl	caller(%esp), %eax					// %eax = caller
	movl	receiver(%eax), %edx				// get receiver
	movl	%edx, caller(%esp)					// replace caller with receiver
	movl	selector(%esp), %ecx				// %ecx = selector
	pushl	$kFwdMsgSend						// flag word-return for _objc_msgForward
	jmp		L1check_message_sendSuper			// goto common code

_objc_msgSendSuper_stret:
	movl	struct_return_caller(%esp), %eax	// %eax = caller
	movl	receiver(%eax), %edx				// get receiver
	movl	%edx, struct_return_caller (%esp)	// replace caller with receiver
	movl	struct_return_selector(%esp), %ecx	// %ecx = selector
	pushl	$kFwdMsgSendStret					// flag struct-return for _objc_msgForward

	.align 4, 0x90
L1check_message_sendSuper:
	pushl	%ecx								// push selector
	movl	class(%eax), %eax					// class = caller->class
	pushl	%eax								// push callers class

	movl	__objc_multithread_mask, %edx		//
	testl	%edx, %edx							// if (multi)
	je		L2multi_msgSuperSend				//	goto locking version

// At this point, callers class is in eax and selector is in ecx
	pushl	%edi								//
	movl	cache(%eax), %eax					// cache = class->cache
	pushl	%esi								//

	lea		buckets(%eax), %edi					// buckets = &cache->buckets
	movl	mask(%eax), %esi					// mask = cache->mask
	movl	%ecx, %edx							// index = selector

L2probe_cache:
	andl	%esi, %edx							// index &= mask
	movl	(%edi, %edx, 4), %eax				// method_name = buckets[index]

	testl	%eax, %eax							// if (method != NULL) {
	je		L2cache_miss						//
	cmpl	method_name(%eax), %ecx				//    method_name = method->name
	jne		L2not_the_method					//	  if (method_name == selector) {

	// Cache hit
	popl	%esi								// restore caller register
	popl	%edi								// restore caller register
	addl	$8, %esp							// dump saved class/selector

	// extract imp
	movl	method_imp(%eax), %eax				// imp = method->method_imp
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit5:	jmp	*%eax								//      goto *imp
	.space 17									// area for moninitobjc to write
												//        }
	.align 4, 0x90
L2not_the_method:
	inc		%edx								//    index++
	jmp		L2probe_cache						// }

	.align 4, 0x90
L2cache_miss:
	popl	%esi								// restore register
	popl	%edi								// restore register

	// Go lookup the method.  Parameters are the class and
	// selector, which are already on the stack in the
	// proper order.
	call	__class_lookupMethodAndLoadCache
	addl	$8, %esp
	popl	%edx								// secret word/struct return flag to _objc_msgForward
Lexit6:	jmp	*%eax
	.space 17									// area for moninitobjc to write



// locking version of super send

	.align 4, 0x90
L2multi_msgSuperSend:
	// spin lock
	movl	$1, %ecx
	leal	_messageLock, %eax
L22spin:
	xchgl	%ecx, (%eax)
	cmpl	$0, %ecx
	jne		L22spin

	movl	0(%esp), %eax					// retrieve class
	movl	4(%esp), %ecx					// retrieve selector

	pushl	%edi							//
	movl	cache(%eax), %eax				// cache = class->cache
	pushl	%esi							//

	lea		buckets(%eax), %edi				// buckets = &cache->buckets
	movl	mask(%eax), %esi				// mask = cache->mask
	movl	%ecx, %edx						// index = selector

L22probe_cache:
	andl	%esi, %edx						// index &= mask
	movl	(%edi, %edx, 4), %eax			// method_name = buckets[index]

	testl	%eax, %eax						// if (method != NULL) {
	je		L22cache_miss					//

	cmpl	method_name(%eax), %ecx			//    method_name = method->name
	jne		L22not_the_method				//	  if (method_name == selector) {
	
	// Cache hit
	movl	method_imp(%eax), %eax			// imp = method->method_imp
	popl	%esi							// restore caller register
	popl	%edi							// restore caller register
	addl	$8, %esp						// dump saved caller/selector
	movl	$0, _messageLock				// unlock
	popl	%edx							// secret word/struct return flag to _objc_msgForward
Lexit7:	jmp	*%eax							//      goto *imp
	.space 17								// area for moninitobjc to write
											//        }
	.align 4, 0x90
L22not_the_method:
	inc		%edx							//    index++
	jmp		L22probe_cache					// }

	.align 4, 0x90
L22cache_miss:
	popl	%esi								// restore caller register
	popl	%edi								// restore caller register

	// Go lookup the method.  Parameters are the class and
	// selector, which are already on the stack in the
	// proper order.
	call	__class_lookupMethodAndLoadCache
	addl	$8, %esp
	movl	$0, _messageLock				// unlock
	popl	%edx							// secret word/struct return flag to _objc_msgForward
Lexit8:	jmp	*%eax
	.space 17								// area for moninitobjc to write

/********************************************************************
 *
 * Out-of-band parameter %edx indicates whether it was objc_msgSend or
 * objc_msgSend_stret that triggered the message forwarding.  The 
 *
 * Iff %edx == kFwdMsgSend, it is the word-return (objc_msgSend) case,
 * and the interface is:
 *
 * id		_objc_msgForward	   (id		self,
 *									SEL		selector,
 *									...);
 *
 * Iff %edx != kFwdMsgSend, it is the structure-return
 * (objc_msgSend_stret) case, and the interface is:
 *
 * struct_type	_objc_msgForward   (id		self,
 *									SEL		selector,
 *									...);
 *
 * There are numerous reasons why it is better to have one
 * _objc_msgForward, rather than adding _objc_msgForward_stret.
 * The best one is that _objc_msgForward is the method that
 * gets cached when respondsToMethod returns false, and it
 * wouldnt know which one to use.
 * 
 * Sends the message to a method having the signature
 *
 *      - forward: (SEL) selector : (marg_list) margs;
 ********************************************************************/

// Location LFwdStr contains the string "forward::"
// Location LFwdSel contains a pointer to LFwdStr, that can be changed
// to point to another forward:: string for selector uniquing
// purposes.  ALWAYS dereference LFwdSel to get to "forward::" !!
        .global objc_meth_var_names
objc_meth_var_names:
 	.align	2, 0x90
LFwdStr:	.ascii "forward::\0"

        .global objc_message_refs
objc_message_refs:
 	.align	2, 0x90
//LFwdSel:	.long	LFwdStr
LFwdSel:	.long	_OBJC_METH_VAR_NAME_FORWARD

 	.align	2, 0x90
LUnkSelStr:	.ascii "Does not recognize selector %s\0"

        .text
        .globl __objc_msgForward
	.align	4, 0x90
__objc_msgForward:
	cmpl	$kFwdMsgSend, %edx					// check secret flag for word vs struct return
	jne		LMsgForwardStretSel					// jump if struct return

	// word-return
	movl	selector(%esp), %eax				// %eax = selector
	movl	self(%esp), %edx					// %edx = self
	leal	(self)(%esp), %ecx					// %ecx = &parameters
	jmp		LMsgForwardCommon

	// structure return
	.align 4, 0x90
LMsgForwardStretSel:
	movl	struct_return_selector(%esp), %eax	// %eax = selector
	movl	struct_return_self(%esp), %edx		// %edx = self
	leal	(struct_return_addr)(%esp), %ecx	// %ecx = &parameters

	// common code
LMsgForwardCommon:
	cmpl	LFwdSel, %eax						// forwarding "forward::"?
	je		LMsgForwardError					// that would be an error

	pushl	%ecx								// push &parameters
	pushl	%eax								// push original selector
	pushl	LFwdSel								// push "forward::" selector
	pushl	%edx								// push self
	call	_objc_msgSend						// send the message
	addl	$16, %esp							// dump parameters
	ret

	// die because the receiver does not implement forward:: 
 	.align	4, 0x90
LMsgForwardError:
	pushl	$LFwdSel							// push "forward::" selector 
	pushl	$LUnkSelStr							// push "unknown selector" string
	pushl	%edx								// push self
	call	___objc_error						// volatile, will not return

/********************************************************************
 * id		objc_msgSendv  (id			self,
 *							SEL			selector,
 *							unsigned	margSize,
 *							marg_list	margs);
 *
 * On entry:	(sp+4)  is the message receiver,
 *				(sp+8)  is the selector,
 *				(sp+12) is the size of the marg_list, in bytes,
 *				(sp+16) is the address of the marg_list
 * 
 ********************************************************************/

	.text
	.globl _objc_msgSendv
 	.align	4, 0x90
_objc_msgSendv:
#if COMPATIBLE_CODE
	movl	(margs + 4)(%ebp), %eax
	andl	$0x80000000, %eax
	jne		_objc_msgSendv_stret
#endif
	pushl	%ebp							// save %ebp
	movl	%esp, %ebp						// set stack frame base pointer
	movl	(margs + 4)(%ebp), %edx			// get address of method arguments
	addl	$8, %edx						// skip self & selector
	movl	(margSize + 4)(%ebp), %ecx		// get byte count
	subl	$5, %ecx						// skip self & selector and begin rounding
	shrl	$2, %ecx						// make it a word count (rounding up)
	jle		LMsgSendvArgsOK					// jump if self/selector are the only parameters

LMsgSendvArgLoop:
	decl	%ecx							// decrement counter
	movl	0(%edx, %ecx, 4), %eax			// load one word
	pushl	%eax							// store one word
	jg		LMsgSendvArgLoop				// check counter, iterate if non-zero

LMsgSendvArgsOK:
	movl	(selector + 4)(%ebp), %ecx		// push selector
	pushl	%ecx
	movl	(self + 4)(%ebp),%ecx			// push self
	pushl	%ecx
	call	_objc_msgSend					// send the message
	movl	%ebp,%esp						// restore stack
	popl	%ebp							// restore %ebp

	ret

/********************************************************************
 * struct_type	objc_msgSendv_stret    (id			self,
 *										SEL			op,
 *										unsigned	arg_size,
 *										marg_list	arg_frame); 
 *
 * objc_msgSendv_stret is the struct-return form of msgSendv.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 * 
 * An equally correct way to prototype this routine is:
 *
 * void		objc_msgSendv_stret    (void *		structStorage,
 *									id			self,
 *									SEL			op,
 *									unsigned	arg_size,
 *									marg_list	arg_frame);
 *
 * which is useful in, for example, message forwarding where the
 * structure-return address needs to be passed in.
 *
 * On entry:	(sp+4)  is the address in which the returned struct is put,
 *				(sp+8)  is the message receiver,
 *				(sp+12) is the selector,
 *				(sp+16) is the size of the marg_list, in bytes,
 *				(sp+20) is the address of the marg_list
 ********************************************************************/

	.text
	.globl _objc_msgSendv_stret
 	.align	4, 0x90
_objc_msgSendv_stret:
	pushl	%ebp									// save %ebp
	movl	%esp, %ebp								// set stack frame base pointer
	movl	(struct_return_margs + 4)(%ebp), %edx	// get address of method arguments
	addl	$12, %edx								// skip struct return, self & selector
	movl	(struct_return_margSize + 4)(%ebp), %ecx // get byte count
	subl	$9, %ecx								// skip struct addr, self & selector and begin rounding
	shrl	$2, %ecx								// make it a word count (rounding up)
	jle		LMsgSendvStretArgsOK					// jump if self/selector are the only parameters

LMsgSendvStretArgLoop:
	decl	%ecx									// decrement counter
	pushl	0(%edx, %ecx, 4)						// copy one word
	jg		LMsgSendvStretArgLoop					// check counter, iterate if non-zero

LMsgSendvStretArgsOK:
	pushl	(struct_return_selector + 4)(%ebp)		// push selector
	pushl	(struct_return_self + 4)(%ebp)			// push self
	pushl	(struct_return_addr + 4)(%ebp)			// push structure return address
	call	_objc_msgSend_stret						// send the message
	movl	%ebp,%esp								// restore stack
	popl	%ebp									// restore %ebp

	ret
