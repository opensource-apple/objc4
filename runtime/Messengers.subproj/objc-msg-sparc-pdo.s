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
/*
 *	objc-msg-sparc.s
 *	Copyright 1994 NeXT, Inc.
 *	CREDITS: John Atkinson, Brad Taylor, Kresten Thorup,
 *		 Gordie Freedman, and everybody else and their dog too !
 *
 *
 *      id objc_msgSend(id self, SEL sel, ...) 
 *
 *      Implement [anObject aSelector] 
 *
 * 	NOTE: objc_msgSend() is defined as a C function in
 *            objc-dispatch.c.  This code is derived from 
 *            compiler generated assembly code. 
 *
 */

#define CLEARLOW22	0xffc00000	/* mask to clear low 22 bits */

#ifndef __svr4__
#define _class_lookupMethodAndLoadCache __class_lookupMethodAndLoadCache
#define objc_msgSend _objc_msgSend
#define objc_msgSendv _objc_msgSendv
#define objc_msgSendSuper _objc_msgSendSuper
#define _objc_msgForward __objc_msgForward
#define OBJC_METH_VAR_NAME_FORWARD _OBJC_METH_VAR_NAME_FORWARD
#define  _objc_error __objc_error
#define  _objc_multithread_mask __objc_multithread_mask
#define  messageLock _messageLock
#define  _objc_private_lock __objc_private_lock
#define  _objc_private_unlock __objc_private_unlock
#endif

.text
	.align 4
	.global objc_msgSend
	.type objc_msgSend,#function
	.proc 0110
//
// ObjC message send:	
// Arguments:	%i0   - receiver (self)
//		%i1   - selector
//		%i2.. - arguments

objc_msgSend:
	save	%sp,-96,%sp         // Save the stack
.Ls1:
	call .Ls2
	nop
.Ls2:
	sethi %hi(_GLOBAL_OFFSET_TABLE_-(.Ls1-.)),%l6
	or %l6,%lo(_GLOBAL_OFFSET_TABLE_-(.Ls1-.)),%l6
	add %l6,%o7,%l6

	tst	%i0                 // If (self == nil) 
	bz	.L_receiver_is_nil   // Then goto nil return
//	sethi	%hi(_objc_multithread_mask),%l2
//	ld	[%l2+%lo(_objc_multithread_mask)],%l2
	set _objc_multithread_mask,%l2
	ld [%l6+%l2],%l2
	ld [%l2],%l2
	
	tst	%l2     	// If zero 
	bz	.L_lock          // Then multithreaded
	ld	[%i0],%l1	// <ds> cls = self->isa
	ld	[%l1+32],%o0    // cache   = cls->cache
.L_continue:
	ld [%o0],%o4            // mask    = cache->mask  
	add %o0,8,%o3           // buckets = cache->buckets    
	and %i1,%o4,%o2		// index   = selector & mask   
.L_loop:
	sll %o2,2,%o1           // %o1 <= index << 2           
	ld [%o3+%o1],%o0        // %o0 <= buckets[index]       
	cmp %o0,0               // if (buckets[index] == 0)
	be,a .L_cacheMiss        // then goto cacheMiss  
	mov %l1,%o0             // <ds> Class goes into arg0
	ld [%o0],%l3            // %l3 <= buckets[index]->method_name
	cmp %l3,%i1             // if (method_name == sel)     
	be,a .L_cacheHit         // goto cacheHit             
	ld [%o0+8],%o0          // Fish out IMP address        
 	add %o2,1,%o2           // index++                      
	b .L_loop                // Loop
	and %o2,%o4,%o2         // <ds> index &= mask          
.L_cacheMiss:
	call _class_lookupMethodAndLoadCache,0
	mov %i1,%o1             // <ds> Selector goes into arg1
.L_cacheHit:
	tst	%l2     	// If mutithreaded is zero 
	bz,a	.L_unlocked      // Then multithreaded, so unlock
	swap	[%l7],%g0       // <ds> in the delay slot!
.L_unlocked:
	jmp %o0                 // Go to method imp
	restore                 // <ds> restore the stack
.L_receiver_is_nil:
	ld [%i7+8],%g3		// load instruction 
	sethi %hi(CLEARLOW22),%g2 // mask off low 22 bits 
	andcc %g3,%g2,%g0	// if 0, then its an UNIMP inst 
	bz .L_struct_returnSend  // and we will return a structure 
	mov 0,%i1		// Second half of long long ret is 0 
        ret                     // Get back, JoJo                      
	restore                 // <ds> 
.L_struct_returnSend:
	jmp %i7 + 12		// convention for returning structs 
	restore                 // <ds>
.L_lock:
	set	(messageLock),%l7 // get the lock addr
	ld [%l6+%l7],%l7
	set	1,%l3		// lock code (1)
.L_lockspin:
	swap	[%l7],%l3	// try to set the lock
	tst	%l3		// if lock was already set
	bnz	.L_lockspin	// try again
	set	1,%l3		// <ds> lock code (1)
	b	.L_continue      // Head back to mainline
	ld	[%l1+32],%o0    // <ds> cache = cls->cache
	
/* 
 *      Implement [super aSelector] 
 *
 *      id objc_msgSendSuper(struct objc_super *caller, SEL sel, ...)
 *
 * 	NOTE: objc_msgSendSuper() is defined as a C function in
 *            objc-dispatch.c.  This code is derived from 
 *            compiler generated assembly code. 
 */
	.align 4
	.global objc_msgSendSuper
	.type objc_msgSendSuper,#function
	.proc	0110
objc_msgSendSuper:
	// receiver and cls won't be nil on entry, can skip check
	save %sp,-112,%sp
.Lsu1:
	call .Lsu2
	nop
.Lsu2:
	sethi %hi(_GLOBAL_OFFSET_TABLE_-(.Lsu1-.)),%l6
	or %l6,%lo(_GLOBAL_OFFSET_TABLE_-(.Lsu1-.)),%l6
	add %l6,%o7,%l6

//	sethi	%hi(_objc_multithread_mask),%l2
//	ld	[%l2+%lo(_objc_multithread_mask)],%l2
	set _objc_multithread_mask,%l2
	ld [%l6+%l2],%l2
	ld [%l2],%l2
	tst	%l2     	  // If zero 
	bz	.L_super_lock      // Then multithreaded
	ld [%i0],%l1              // <ds> Put caller->receiver in %l1
	st %l1,[%fp+68]           // Save receiver for later
.L_super_continue:
	ld [%i0+4],%o3            // Put caller->cls into %o3
	ld [%o3+32],%o0           // cache   = cls->cache          
	ld [%o0],%o2              // mask    = cls->cache->mask    
	add %o0,8,%l0             // buckets = cache->buckets      
	and %i1,%o2,%i0           // index   = selector & mask     
.L_super_loop:
	sll %i0,2,%o0             // Adjust to word index
	ld [%l0+%o0],%o1          // method = buckets[index]
	cmp %o1,0                 // if (method == NULL) ...
	be .L_super_cacheMiss      // ... then have a cache miss
	mov %o3,%o0               // <ds> Class arg for LoadCache
	ld [%o1],%o0              // Method name into o0
	cmp %o0,%i1               // Compare method name to one we want
	be .L_super_cacheHit       // Equal, got a hit
	ld [%o1+8],%g1            // <ds> Get implementation address
	add %i0,1,%i0             // Increment index
	b .L_super_loop            // Loop again
	and %i0,%o2,%i0           // <ds> and with mask
.L_super_cacheMiss:
	call _class_lookupMethodAndLoadCache,0
	mov %i1,%o1               // <ds> Selector into arg1
	mov %o0,%g1               // Save result from LoadCache
.L_super_cacheHit:
	tst	%l2     	  // If multithread is zero 
	bz,a	.L_super_unlocked  // Then multithreaded, so unlock
	swap	[%l7],%g0         // <ds> in the delay slot!
.L_super_unlocked:
	restore                   // Restore the stack
	jmp %g1                   // Go to the method
	ld [%sp+68],%o0           // <ds> Put receiver in arg0
.L_super_lock:
	set	(messageLock),%l7 // get the lock addr
	ld [%l6+%l7],%l7
	set	1,%l3		// lock code (1)
.L_super_lockspin:
	swap	[%l7],%l3	// try to set the lock
	tst	%l3		// if lock was already set
	bnz	.L_super_lockspin// try again
	set	1,%l3		// <ds> lock code (1)
	b	.L_super_continue// Head back to mainline
	st %l1,[%fp+68]         // <ds> Save receiver for later

//
//      id __objc_msgForward(id self, SEL sel, ...)
//
	.align 4
	.global _objc_msgForward
	.type _objc_msgForward,#function
	.proc	0110
_objc_msgForward:
	save %sp,-96,%sp
.Lmf1:
	call .Lmf2
	nop
.Lmf2:
	sethi %hi(_GLOBAL_OFFSET_TABLE_-(.Lmf1-.)),%l6
	or %l6,%lo(_GLOBAL_OFFSET_TABLE_-(.Lmf1-.)),%l6
	add %l6,%o7,%l6

//	sethi %hi(OBJC_METH_VAR_NAME_FORWARD),%g2
//	or %g2,%lo(OBJC_METH_VAR_NAME_FORWARD),%g2
	set OBJC_METH_VAR_NAME_FORWARD,%g2
	ld [%l6+%g2],%g2

	cmp %g2,%i1             // if (sel==@selector(forward::)) 
	be .LERROR               //   goto ERROR                   
	mov %i1,%o2             // <ds> Put selector into %o2
	add %fp,68,%g1          // Pointer to %i3 stack homing area 
	st %i0,[%g1]            // Store first 6 parameters onto stack
	st %i1,[%g1+4]
	st %i2,[%g1+8]
	st %i3,[%g1+12]
	st %i4,[%g1+16]
	st %i5,[%g1+20]
	mov %g2,%o1             // Put forward:: into %o1
	mov %g1,%o3             // Set margv vector as 4th parm

	ld [%i7+8],%g3			// load instruction 
	sethi %hi(CLEARLOW22),%g2	// mask off low 22 bits 
	andcc %g3,%g2,%g0		// if 0, then its an UNIMP inst 
	be .Lstruct_returnForward	// and we will return a structure 
	nop				// fill me in later 

	// No structure is returned
	call objc_msgSend,0	// send the message 
	mov %i0,%o0             // <ds> Set self 
	mov %o0,%i0		// Restore return parameter 
	ret			// Return
	restore %o1,0,%o1	// In case long long returned

.Lstruct_returnForward:
	ld [%fp+64],%g2		// get return struct ptr 
	st %g2,[%sp+64]		// save return struct pointer 
	call objc_msgSend,0	// send the message 
	mov %i0,%o0             // Set self
	unimp 0			// let 0 mean size = unknown 
	jmp %i7 + 12		// convention for returning structs 
	restore
.LERROR:                         // Error: Does not respond to sel 
	sethi %hi(.LC0), %o1
	or %o1,%lo(.LC0),%o1
	b _objc_error           // __objc_error never returns,    
	nop
.LC0:
	.ascii "Does not recognize selector %s\0"
	.align 4

//
//	id objc_msgSendv(id self, SEL sel, unsigned size, marg_list args)
//
	.align 4
	.global objc_msgSendv
	.type objc_msgSendv,#function
objc_msgSendv:
	add %g0,-96,%g1		// Get min stack size + 4 (rounded by 8)
	subcc %o2,28,%g2	// Get size of non reg params + 4
	ble .Lsave_stack		// None or 1, so skip making stack larger
	sub %g1,%g2,%g2		// Add local size to minimum stack
	and %g2,-8,%g1		// Need to round to 8 bit boundary
.Lsave_stack:
	save %sp,%g1,%sp	// Save min stack + 4 for 8 byte bound ...
	mov %i0,%o0
	mov %i1,%o1
	addcc %i2,-8,%i2           // The first 6 args go in registers 
        be .Lsend_msg
	nop
	ld [%i3+8],%o2             // Got at least 1 arg 
	addcc %i2,-4,%i2
        be .Lsend_msg
	nop
	ld [%i3+12],%o3		   // Got at least 2 args 
	addcc %i2,-4,%i2
        be .Lsend_msg
	nop
	ld [%i3+16],%o4            // Got at least 3 args 
	addcc %i2,-4,%i2
        be .Lsend_msg
	nop
	ld [%i3+20],%o5            // Got at least 4 args
	addcc %i2,-4,%i2	   // Decrement count past 4th arg
	be .Lsend_msg
	nop
	add %i3,24,%i1             // %i1 <== args += 24
	add %sp,92,%i5
.Loop2:
        ld [%i1],%i3		   // Deal with remaining args
        addcc %i2,-4,%i2
        st %i3,[%i5]
        add %i5,4,%i5
        bne .Loop2
        add %i1,4,%i1
.Lsend_msg:

	ld [%i7+8],%g3			// load instruction
	sethi %hi(CLEARLOW22),%g2	// mask off low 22 bits
	andcc %g3,%g2,%g0		// if 0, then its an UNIMP inst
	be .Lstruct_returnSendv		// and we will return a structure
	nop				// fill me in later

	// No structure is returned
	call objc_msgSend,0		// send the message 
	nop				// fill me in later 
	mov %o0,%i0			// Ret int, 1st half
	ret				// ... of long long 
	restore %o1,0,%o1		// 2nd half of ll   

.Lstruct_returnSendv:
 	ld [%fp+64],%g2		// get return struct ptr 
	st %g2,[%sp+64]		// save return struct pointer 
	call objc_msgSend,0	// send the message 
	nop			// fill me in later 
	unimp 0			// let 0 mean size = unknown 
	jmp %i7 + 12		// convention for returning structs 
	restore

//
//	void _objc_private_lock (long* lock)
//
	.align 4
	.global _objc_private_lock	
	.type _objc_private_lock,#function
_objc_private_lock:
	save	%sp,-96,%sp     // Save the stack
	set	1,%l3		// lock code (1)
.L_private_loop:
	swap	[%i0],%l3	// try to set the lock
	tst	%l3		// if lock was already set
	bnz,a	.L_private_loop	// try again
	set	1,%l3		// <ds> lock code (1)
	jmp %i7+8
	restore 

//
//	void _objc_private_unlock (long* lock)
//
	.align 4
	.global _objc_private_unlock	
	.type _objc_private_unlock,#function
_objc_private_unlock:
	swap	[%o0],%g0	// clear the lock
	jmp %o7+8
	nop
