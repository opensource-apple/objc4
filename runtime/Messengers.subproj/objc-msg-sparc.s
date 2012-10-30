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
#ifdef DYLIB
#warning Building of SPARC dynashlib not fully supported yet!
#endif

#ifdef KERNEL
#define OBJC_LOCK_ROUTINE _simple_lock
#else
#define OBJC_LOCK_ROUTINE _spin_lock
#endif /* KERNEL */

#define CLEARLOW22	0xffc00000	/* mask to clear off low 22 bits */


#define isa 0
#define cache 32
#define mask  0
#define buckets 8
#define method_name 0
#define method_imp 8
#define receiver 0
#define class 4

! optimized for sparc: 26 clocks (best case) + 7 clocks/probe

        .text
	.globl _objc_msgSend

! ObjC message send:	
! Arguments:	%i0   - receiver (self)
!		%i1   - selector
!		%i2.. - arguments
	
_objc_msgSend:
	save	%sp,-96,%sp	! save register windows
	
! test for nil argument and locking requirements
	sethi	%hi(__objc_multithread_mask),%l1
	ld	[%l1+%lo(__objc_multithread_mask)],%l1
	andcc	%l1,%i0,%l1	! if (self & multi) 
	bnz,a	L_normalCase	! then normalcase
	ld	[%i0+isa],%o0	! class = self->isa (class arg)
	
	tst	%i0		! if (self)
	bnz	L_sendLocking	! lockingcase
	nop
! self is NIL, return
	ld [%i7+8],%g3		// load instruction 
	sethi %hi(CLEARLOW22),%g2 // mask off low 22 bits 
	andcc %g3,%g2,%g0	// if 0, then its an UNIMP inst 
	bz L_struct_returnSend0  // and we will return a structure 
	nop		//
        ret                     // Get back, JoJo                      
	restore                 // <ds> 
L_struct_returnSend0:
	jmp %i7 + 12		// convention for returning structs 
	restore                 // <ds>

! Init pointers to class and cache
L_normalCase:
	ld	[%o0+cache],%l4	! cache <- class->cache
	ld	[%l4+mask],%l3	! mask <- cache->mask
	add	%l4,buckets,%l2	! buckets <- cache->buckets
	and	%i1,%l3,%l1	! index <- selector & mask
	
! Try to find a method in the cache
L_loop:
	sll	%l1,2,%l6	! adjust to word index
	ld	[%l2+%l6],%l4	! method = buckets[index]
	tst	%l4		! if (method == NULL)
	bz,a	L_cacheMiss	! handle cacheMiss case
	mov	%i1,%o1		! (DS) selector arg for LoadCache
	
	ld	[%l4+method_name],%l5! name = method->method_name
	cmp	%l5,%i1		! if (name == selector)
	be,a	L_cacheHit	! goto hit
	ld	[%l4+method_imp],%o0! load method_imp pointer to call
	
	inc	%l1		! index++
	b	L_loop		! check next cache entry
	and	%l1,%l3,%l1	! index = index & mask
L_cacheMiss:
        CALL_EXTERN(__class_lookupMethodAndLoadCache)
L_cacheHit:
	jmp	%o0		! 
	restore
	
! Locking version of objc_msgSend
! spins on the mutex lock.

L_sendLocking:
	set	(_messageLock),%l7! get the lock addr
	set	1,%l1		! lock code (1)	
L_lockspin:
	swap	[%l7],%l1	! try to set the lock
	tst	%l1		! if lock was already set
	bnz	L_lockspin	! try again
	set	1,%l1		! lock code (1)

	! got the lock, ready to proceed
	
	ld	[%i0+isa],%o0	! class = self->isa
	ld	[%o0+cache],%l4	! cache = class->cache
	ld	[%l4+mask],%l3	! mask = cache->mask
	add	%l4,buckets,%l2	! buckets = cache->buckets
	and	%i1,%l3,%l1	! index = selector & mask
	
L_loop_lk:
	sll	%l1,2,%l6	! adjust to word index
	ld	[%l2+%l6],%l4	! method = buckets[index]
	tst	%l4		! if (method == NULL)
	bz,a	L_cacheMiss_lk	! handle cacheMiss case
	mov	%i1,%o1		! (DS) selector arg for LoadCache
		
	ld	[%l4+method_name],%l5! name = method->method_name
	cmp	%l5,%i1		! if (name == selector)
	be,a	L_cacheHit_lk	! goto hit
	ld	[%l4+method_imp],%o0	! impl = method->method_imp
	
	inc	%l1		! index++
	b	L_loop_lk	! check next cache entry
	and	%l1,%l3,%l1	! index = index & mask
	
L_cacheMiss_lk:
        CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)
L_cacheHit_lk:	
	swap	[%l7],%g0	! clear the lock
	jmp	%o0
	restore


        .globl _objc_msgSendSuper
_objc_msgSendSuper:
	save	%sp,-120,%sp	! save register window
	ld	[%i0+receiver],%l0	! receiver = caller->receiver
	tst	%l0		! if (receiver)
	bnz	L_receiver	! work on it
	st	%l0,[%fp+68]	! <delay slot> save a copy
L_noreceiver:			! return on NULL receiver
	ld [%i7+8],%g3		// load instruction 
	sethi %hi(CLEARLOW22),%g2 // mask off low 22 bits 
	andcc %g3,%g2,%g0	// if 0, then its an UNIMP inst 
	bz L_struct_returnSend1 // and we will return a structure 
	nop			//
        ret                     // Get back, JoJo                      
	restore                 // <ds> 
L_struct_returnSend1:
	jmp %i7 + 12		// convention for returning structs 
	restore                 // <ds>
	
L_receiver:
	sethi	%hi(__objc_multithread_mask),%l1
	ld	[%l1+%lo(__objc_multithread_mask)],%l1
	tst	%l1
	bz	L_superLock
	ld	[%i0+class],%o0	! class = caller->class
	ld	[%o0+cache],%l4	! cache = class->cache
	ld	[%l4+mask],%l3	! mask = cache->mask
	add	%l4,buckets,%l2	! buckets = cache->buckets
	and	%i1,%l3,%l1	! index = selector & mask
	
L_super_loop:
	sll	%l1,2,%l6	! adjust to word index
	ld	[%l2+%l6],%l4	! method = buckets[index]
	tst	%l4		! if (method == NULL)
	bz,a	L_super_cacheMiss	! handle cacheMiss case
	mov	%i1,%o1		! (DS) selector arg for LoadCache
		
	ld	[%l4+method_name],%l5! name = method->method_name
	cmp	%l5,%i1		! if (name == selector)
	be	L_super_cacheHit	! goto hit
	ld	[%l4+method_imp],%g1	! method = buckets[index]
	
	inc	%l1		! index++
	b	L_super_loop	! check next cache entry
	and	%l1,%l3,%l1	! index = index & mask
	
L_super_cacheMiss:
        CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)
	mov	%o0,%g1		! save result from Loadcache
	restore 
	jmp	%g1
	ld	[%sp+68],%o0		! restore receiver

	
L_super_cacheHit:
	restore
	jmp	%g1
	ld	[%sp+68],%o0		! restore receiver


! locking version of objc_msgSendSuper
! spins on the mutex lock

L_superLock:
	sethi	%hi(_messageLock),%l1! aquire the lock addr
	or	%l1,%lo(_messageLock),%l7
L_super_lockspin:
	ldstub	[%l7],%l1	! try to set the lock
	tst	%l1		! if lock was already set
	bne	L_super_lockspin	! try again
	nop

	! got the lock, ready to proceed
				! %o0 = class [set above]
	ld	[%o0+cache],%l4	! cache = class->cache
	ld	[%l4+mask],%l3	! mask = cache->mask
	add	%l4,buckets,%l2	! buckets = cache->buckets
	and	%i1,%l3,%l1	! index = selector & mask
	
L_super_loop_lk:
	sll	%l1,2,%l6	! adjust to word index
	ld	[%l2+%l6],%l4	! method = buckets[index]
	tst	%l4		! if (method == NULL)
	bz,a	L_super_cacheMiss_lk	! handle cacheMiss case
	mov	%i1,%o1		! (DS) selector arg for LoadCache
		
	ld	[%l4+method_name],%l5! name = method->method_name
	cmp	%l5,%i1		! if (name == selector)
	be	L_super_cacheHit_lk	! goto hit
	ld	[%l4+method_imp],%g1	! impl = method->method_imp
	
	inc	%l1		! index++
	b	L_super_loop_lk	! check next cache entry
	and	%l1,%l3,%l1	! index = index & mask
	
L_super_cacheMiss_lk:
        CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)
	mov	%o0,%g1		! save result from Loadcache
	st	%g0,[%l7]       ! clear lock
	restore
	jmp	%g1
	ld	[%sp+68],%o0		! restore receiver
	
L_super_cacheHit_lk:	
	st	%g0,[%l7]	! clear the lock
	restore
	jmp	%g1
	ld	[%sp+68],%o0		! restore receiver

        
        .objc_meth_var_names
	.align 1
L30:    .ascii "forward::\0"

        .objc_message_refs
	.align 2
L31:    .long L30

        .cstring
	.align 1
L32:    .ascii "Does not recognize selector %s\0"

        .text
        .align 2

	.globl __objc_msgForward
__objc_msgForward:
	save    %sp,-96,%sp
	sethi	%hi(L31),%g2
	ld	[%g2+%lo(L31)],%g2
	cmp	%i1,%g2		! if (selector == @selector(forward::))
	be	L_error
	nop
	add	%fp,68,%g1	!  ptr to stack area
	st	%i0,[%g1]
	st	%i1,[%g1+4]
	st	%i2,[%g1+8]
	st	%i3,[%g1+12]
	st	%i4,[%g1+16]
	st	%i5,[%g1+20]
	mov	%i1,%o2
	mov	%g2,%o1
	mov	%g1,%o3	
	ld [%i7+8],%g3				! load instruction 
	sethi %hi(CLEARLOW22),%g2	! mask off low 22 bits 
	andcc %g3,%g2,%g0			! if 0, then its an UNIMP inst 
	be Lstruct_returnForward	! and we will return a structure 
	nop							! fill me in later 

	! No structure is returned
	call _objc_msgSend			! send the message 
	mov %i0,%o0					! <ds> Set self 
	mov %o0,%i0					! Restore return parameter 
	ret							! Return
	restore %o1,0,%o1			!In case long long returned

Lstruct_returnForward:
	ld [%fp+64],%g2				! get return struct ptr 
	st %g2,[%sp+64]				! save return struct pointer 
	call _objc_msgSend			! send the message 
	mov %i0,%o0					! Set self
	unimp 0						! let 0 mean size = unknown 
	jmp %i7 + 12				! convention for returning structs 
	restore
	
L_error:
	mov	%i1, %o2
	set	L32,%i1
	BRANCH_EXTERN(__objc_error)	! never returns


! id objc_msgSendv(id self, SEL sel, unsigned size, marg_list args)
	
	.globl	_objc_msgSendv
_objc_msgSendv:
	add %g0,-96,%g1		! Get min stack size + 4 (rounded by 8)
	subcc %o2,28,%g2	! Get size of non reg params + 4
	ble Lsave_stack		! None or 1, so skip making stack larger
	sub %g1,%g2,%g2		! Add local size to minimum stack
	and %g2,-8,%g1		! Need to round to 8 bit boundary
Lsave_stack:
	save %sp,%g1,%sp	! Save min stack + 4 for 8 byte bound! ...
	mov	%i0,%o0
	mov	%i1,%o1
	addcc	%i2,-8,%i2	! adjust for first 2 args (self & sel)
	be	L_send_msg
	nop

	ld	[%i3+8],%o2	! get 3rd arg
	addcc	%i2,-4,%i2	! size--
	be	L_send_msg
	nop

	ld	[%i3+12],%o3	! arg 4
	addcc	%i2,-4,%i2	! size--
	be	L_send_msg
	nop

	ld	[%i3+16],%o4	! arg 5
	addcc	%i2,-4,%i2	! size--
	be	L_send_msg
	nop

	ld	[%i3+20],%o5	! arg 6
	addcc	%i2,-4,%i2	! size--
	be	L_send_msg
	nop
	add	%i3,24,%i1	! %i1 = args + 24
	add	%sp,92,%i5
L_loopv:				! deal with remaining args
	ld	[%i1],%i3
	addcc	%i2,-4,%i2	! size--
	st	%i3,[%i5]
	add	%i5,4,%i5
	bnz	L_loopv
	add	%i1,4,%i1	! arg++
	
L_send_msg:
	ld	[%i7+8],%g3	! load instruction
	sethi	%hi(CLEARLOW22),%g2
	andcc	%g3,%g2,%g0	! if 0 it is an UNIMP inst
	be	L_struct_returnSendv! return a structure
	nop

! Case of no struct returned

	call	_objc_msgSend
	nop
	mov %o0,%i0			! Ret int, 1st half
	ret				! ... of long long
	restore %o1,0,%o1		! 2nd half of ll

L_struct_returnSendv:
	ld	[%fp+64],%g2
	st	%g2,[%sp+64]
	call	_objc_msgSend
	nop
	unimp	0
	jmp	%i7+12
	restore
