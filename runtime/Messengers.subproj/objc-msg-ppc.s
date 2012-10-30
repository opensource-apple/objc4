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
/********************************************************************
 *
 *  objc-msg-ppc.s - PowerPC code to support objc messaging.
 *
 *  Copyright 1988-1996 NeXT Software, Inc.
 *
 *  8-Nov-2000	Laurent Ramontianu (ramontia@apple.com)
 *		Added "few args" params. to CacheLookup and MethodTableLookup
 *		Added the alternate entry points:
 *			objc_msgSendFew, objc_msgSendFew_stret,
 *			objc_msgSendSuperFew, objc_msgSendSuperFew_stret
 *
 *  18-Jun-97	David Harrison  (harrison@apple.com)
 *		Restructured.
 *
 *  1-May-97	Umesh Vaishampayan  (umeshv@NeXT.com)
 *		Incorporated locking code fixes from
 *		David Harrison  (harrison@NeXT.com) 
 *
 *  2-Apr-97	Umesh Vaishampayan  (umeshv@NeXT.com)
 *		Incorporated changes for messenger with struct return
 *		Cleaned up the labels to use local labels
 *		Fixed bug in the msgSendSuper that did not do the locking.
 *
 *  31-Dec-96	Umesh Vaishampayan  (umeshv@NeXT.com)
 *		Created from m98k.
 ********************************************************************/

; _objc_entryPoints and _objc_exitPoints are used by method dispatch
; caching code to figure out whether any threads are actively 
; in the cache for dispatching.  The labels surround the asm code
; that do cache lookups.  The tables are zero-terminated.
	.data
.globl _objc_entryPoints
_objc_entryPoints:
	.long	__cache_getImp
	.long	__cache_getMethod
	.long	_objc_msgSend
	.long	_objc_msgSend_stret
	.long	_objc_msgSendSuper
	.long	_objc_msgSendSuper_stret
	.long	_objc_msgSendFew
	.long	_objc_msgSendFew_stret
	.long	_objc_msgSendSuperFew
	.long	_objc_msgSendSuperFew_stret
	.long	0

.globl _objc_exitPoints
_objc_exitPoints:
	.long	LGetImpExit
	.long	LGetMethodExit
	.long	LMsgSendExit
	.long	LMsgSendStretExit
	.long	LMsgSendSuperExit
	.long	LMsgSendSuperStretExit
	.long	LMsgSendFewExit
	.long	LMsgSendFewStretExit
	.long	LMsgSendSuperFewExit
	.long	LMsgSendSuperFewStretExit
	.long	0

/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

; objc_super parameter to sendSuper
	receiver		= 0
	class			= 4

; Selected field offsets in class structure
	isa			= 0
	cache			= 32

; Method descriptor
	method_name		= 0
	method_imp		= 8

; Cache header
	mask			= 0
	occupied		= 4
	buckets			= 8	// variable length array

#if defined(OBJC_INSTRUMENTED)
; Cache instrumentation data, follows buckets
	hitCount		= 0
	hitProbes		= hitCount + 4
	maxHitProbes		= hitProbes + 4
	missCount		= maxHitProbes + 4
	missProbes		= missCount + 4
	maxMissProbes		= missProbes + 4
	flushCount		= maxMissProbes + 4
	flushedEntries		= flushCount + 4
#endif

/********************************************************************
 *
 * Constants.
 *
 ********************************************************************/

// In case the implementation is _objc_msgForward, indicate to it
// whether the method was invoked as a word-return or struct-return.
// The li instruction costs nothing because it fits into spare
// processor cycles.

kFwdMsgSend		= 0
kFwdMsgSendStret	= 1

/********************************************************************
 *
 * Useful macros.  Macros are used instead of subroutines, for speed.
 *
 ********************************************************************/

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; LOAD_STATIC_WORD	targetReg, symbolName, LOCAL_SYMBOL | EXTERNAL_SYMBOL
;
; Load the value of the named static data word.
;
; Takes: targetReg	 - the register, other than r0, to load
;	 symbolName	 - the name of the symbol
;	 LOCAL_SYMBOL	 - symbol name used as-is
;	 EXTERNAL_SYMBOL - symbol name gets nonlazy treatment
;
; Eats: r0 and targetReg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Values to specify whether the symbols is plain or nonlazy
LOCAL_SYMBOL	= 0
EXTERNAL_SYMBOL	= 1

.macro	LOAD_STATIC_WORD

#if defined(__DYNAMIC__)
	mflr		r0
	bcl		20,31,1f	; 31 is cr7[so]
1:	mflr		$0
	mtlr		r0
.if $2 == EXTERNAL_SYMBOL
	addis		$0,$0,ha16(L$1-1b)
	lwz		$0,lo16(L$1-1b)($0)
	lwz		$0,0($0)
.elseif $2 == LOCAL_SYMBOL
	addis		$0,$0,ha16($1-1b)
	lwz		$0,lo16($1-1b)($0)
.else
	!!! Unknown symbol type !!!
.endif
#else
	lis		$0,ha16($1)
	lwz		$0,lo16($1)($0)
#endif

.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; LEA_STATIC_DATA	targetReg, symbolName, LOCAL_SYMBOL | EXTERNAL_SYMBOL
;
; Load the address of the named static data.
;
; Takes: targetReg	 - the register, other than r0, to load
;	 symbolName	 - the name of the symbol
;	 LOCAL_SYMBOL	 - symbol is local to this module
;	 EXTERNAL_SYMBOL - symbol is imported from another module
;
; Eats: r0 and targetReg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro	LEA_STATIC_DATA
#if defined(__DYNAMIC__)
	mflr		r0
	bcl		20,31,1f	; 31 is cr7[so]
1:	mflr		$0
	mtlr		r0
.if $2 == EXTERNAL_SYMBOL
	addis		$0,$0,ha16(L$1-1b)
	lwz		$0,lo16(L$1-1b)($0)
.elseif $2 == LOCAL_SYMBOL
	addis		$0,$0,ha16($1-1b)
	addi		$0,$0,lo16($1-1b)
.else
	!!! Unknown symbol type !!!
.endif
#else
	lis		$0,hi16($1)
	ori		$0,$0,lo16($1)
#endif

.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; ENTRY		functionName
;
; Assembly directives to begin an exported function.
;
; Takes: functionName - name of the exported function
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro ENTRY
	.text
	.align		2
	.globl		$0
$0:
.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; END_ENTRY	functionName
;
; Assembly directives to end an exported function.  Just a placeholder,
; a close-parenthesis for ENTRY, until it is needed for something.
;
; Takes: functionName - name of the exported function
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro END_ENTRY
.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PLOCK		scratchReg, lockName
;
; Acquire named spinlock.
;
; Takes: scratchReg - a register, other than r0, that can be mangled
;	lockName   - the name of a static, aligned, 32-bit lock word
;
; Eats: r0 and scratchReg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro PLOCK
	LEA_STATIC_DATA	$0, $1, EXTERNAL_SYMBOL
	b		.+16			; jump into loop at the reserving check
	lwz		r0,0($0)		; check with fast, less intrusive lwz versus lwarx
	cmplwi		r0,0			; lock held?
	bne		.-8			; if so, spin until it appears unlocked
	lwarx		r0,0,$0			; get lock value, acquire memory reservation 
	cmplwi		r0,0			; lock held?
	bne		.-20			; if locked, go spin waiting for unlock
	li		r0,1			; get value that means locked
	stwcx.		r0,0,$0			; store it iff reservation still holds
	bne-		.-20			; if reservation was lost, go re-reserve
	isync					; discard effects of prefetched instructions 
.endmacro	

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PUNLOCK	scratchReg, lockName
;
; Release named spinlock.
;
; Takes: scratchReg - a register, other than r0, that can be mangled
;	lockName   - the name of a static, aligned, 32-bit lock word
;
; Eats: r0 and scratchReg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro PUNLOCK
	sync					; force out changes before unlocking
	LEA_STATIC_DATA	$0, $1, EXTERNAL_SYMBOL
	li		r0,0			; get value meaning "unlocked"
	stw		r0,0($0)		; unlock the lock
.endmacro


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; CacheLookup	WORD_RETURN | STRUCT_RETURN, MSG_SEND | MSG_SENDSUPER | CACHE_GET, cacheMissLabel, FEW_ARGS | MANY_ARGS
;
; Locate the implementation for a selector in a class method cache.
;
; Takes: WORD_RETURN	(r3 is first parameter)
;	STRUCT_RETURN	(r3 is structure return address, r4 is first parameter)
;	MSG_SEND	(first parameter is receiver)
;	MSG_SENDSUPER	(first parameter is address of objc_super structure)
;	CACHE_GET	(first parameter is class; return method triplet)
;
;	cacheMissLabel = label to branch to iff method is not cached
;
; Eats: r0, r11, r12
; On exit:	(found) MSG_SEND and MSG_SENDSUPER: return imp in r12 and ctr
;		(found) CACHE_GET: return method triplet in r12
;		(not found) jumps to cacheMissLabel
;
; For MSG_SEND and MSG_SENDSUPER, the messenger jumps to the imp 
; in ctr. The same imp in r12 is used by the method itself for its
; relative addressing. This saves the usual "jump to next line and 
; fetch link register" construct inside the method.
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Values to specify to method lookup macros whether the return type of
; the method is an integer or structure.
WORD_RETURN	= 0
STRUCT_RETURN	= 1

; Values to specify to method lookup macros whether the return type of
; the method is an integer or structure.
MSG_SEND	= 0
MSG_SENDSUPER	= 1
CACHE_GET	= 2

; Values to specify to method lookup macros whether this is a "few args" call or not
; (number of args < 5 , including self and _cmd)
FEW_ARGS	= 0
MANY_ARGS	= 1

.macro	CacheLookup

#if defined(OBJC_INSTRUMENTED)
	; when instrumented, we use r6 and r7
	stw		r6,36(r1)		; save r6 for use as cache pointer
	stw		r7,40(r1)		; save r7 for use as probe count
	li		r7,0			; no probes so far!
#endif

.if $3 == MANY_ARGS
	stw		r9,48(r1)		; save r9 and r10
	stw		r10,52(r1)		;
.endif

.if $0 == WORD_RETURN				; WORD_RETURN

.if $1 == MSG_SEND				; MSG_SEND
	lwz		r12,isa(r3)		; class = receiver->isa
.elseif $1 == MSG_SENDSUPER			; MSG_SENDSUPER
	lwz		r12,class(r3)		; class = super->class
.else						; CACHE_GET
	mr		r12,r3	 		; class = class
.endif

.else	
						; STRUCT_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	lwz		r12,isa(r4)		; class = receiver->isa
.elseif $1 == MSG_SENDSUPER			; MSG_SENDSUPER
	lwz		r12,class(r4)		; class = super->class
.else						; CACHE_GET
	mr		r12,r4	 		; class = class
.endif

.endif


	lwz		r12,cache(r12)		; cache = class->cache
#if defined(OBJC_INSTRUMENTED)
	mr		r6,r12			; save cache pointer
#endif
	lwz		r11,mask(r12)		; mask = cache->mask

	addi		r9,r12,buckets		; buckets = cache->buckets
	slwi		r11,r11,2		; r11 = mask << 2 
.if $0 == WORD_RETURN				; WORD_RETURN
	and		r12,r4,r11		; bytes = sel & (mask<<2)
.else						; STRUCT_RETURN
	and		r12,r5,r11		; bytes = sel & (mask<<2)
.endif

#if defined(OBJC_INSTRUMENTED)
	b		LLoop_$0_$1_$2

LMiss_$0_$1_$2:
	; r6 = cache, r7 = probeCount
	lwz		r9,mask(r6)		; entryCount = mask + 1
	addi		r9,r9,1			;
	slwi		r9,r9,2			; tableSize = entryCount * sizeof(entry)
	addi		r9,r9,buckets		; offset = buckets + tableSize
	add		r11,r6,r9		; cacheData = &cache->buckets[mask+1]
	lwz		r9,missCount(r11)	; cacheData->missCount += 1
	addi		r9,r9,1			; 
	stw		r9,missCount(r11)	; 
	lwz		r9,missProbes(r11)	; cacheData->missProbes += probeCount
	add		r9,r9,r7		; 
	stw		r9,missProbes(r11)	; 
	lwz		r9,maxMissProbes(r11)	; if (probeCount > cacheData->maxMissProbes)
	cmplw		r7,r9			; maxMissProbes = probeCount
	ble		.+8			; 
	stw		r7,maxMissProbes(r11)	;

	lwz		r6,36(r1)		; restore r6
	lwz		r7,40(r1)		; restore r7

	b		$2			; goto cacheMissLabel
#endif

; search the cache
LLoop_$0_$1_$2:
#if defined(OBJC_INSTRUMENTED)
	addi		r7,r7,1			; probeCount += 1
#endif

	lwzx		r10,r9,r12		; method = buckets[bytes/4]
	addi		r12,r12,4		; bytes += 4
	cmplwi		r10,0			; if (method == NULL)
#if defined(OBJC_INSTRUMENTED)
	beq		LMiss_$0_$1_$2
#else
	beq		$2			; goto cacheMissLabel
#endif

	lwz		r0,method_name(r10)	; name  = method->method_name
	and		r12,r12,r11		; bytes &= (mask<<2)
.if $0 == WORD_RETURN				; WORD_RETURN
	cmplw		r0,r4			; if (name != selector)
.else						; STRUCT_RETURN
	cmplw		r0,r5			; if (name != selector)
.endif
	bne		LLoop_$0_$1_$2		; goto loop

; cache hit, r10 == method triplet address
.if $1 == CACHE_GET
	;  return method triplet in r12
	mr		r12,r10
.else
	; return method imp in ctr and r12
	lwz		r10,method_imp(r10)	; imp = method->method_imp
	mr		r12,r10			; copy implementation to r12
	mtctr		r10			; ctr = imp
.endif

#if defined(OBJC_INSTRUMENTED)
	; r6 = cache, r7 = probeCount
	lwz		r9,mask(r6)		; entryCount = mask + 1
	addi		r9,r9,1			;
	slwi		r9,r9,2			; tableSize = entryCount * sizeof(entry)
	addi		r9,r9,buckets		; offset = buckets + tableSize
	add		r11,r6,r9		; cacheData = &cache->buckets[mask+1]
	lwz		r9,hitCount(r11)	; cache->hitCount += 1
	addi		r9,r9,1			; 
	stw		r9,hitCount(r11)	; 
	lwz		r9,hitProbes(r11)	; cache->hitProbes += probeCount
	add		r9,r9,r7		; 
	stw		r9,hitProbes(r11)	; 
	lwz		r9,maxHitProbes(r11)	; if (probeCount > cache->maxMissProbes)
	cmplw		r7,r9			;maxMissProbes = probeCount
	ble		.+8			; 
	stw		r7,maxHitProbes(r11)	; 

	lwz		r6,36(r1)		; restore r6
	lwz		r7,40(r1)		; restore r7
#endif

.if $3 == MANY_ARGS
	lwz		r9,48(r1)		; restore r9 and r10
	lwz		r10,52(r1)		;
.endif

.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; CacheLookup cache locking - 2001-11-12
; The collecting cache mechanism precludes the need for a cache lock 
; in objc_msgSend. The cost of the collecting cache is small: a few 
; K of memory for uncollected caches, and less than 1 ms per collection. 
; A large app will only run collection a few times.
; Using the code below to lock the cache almost doubles messaging time, 
; costing several seconds of CPU across several minutes of operation.
; The code below probably could be improved, but almost all of the 
; locking slowdown is in the sync and isync.
;
; 40 million message test times (G4 1x667):
;   no lock  4.390u 0.030s 0:04.59 96.2%     0+0k 0+1io 0pf+0w
; with lock  9.120u 0.010s 0:09.83 92.8%     0+0k 0+0io 0pf+0w
;
;; LockCache mask_dest, cache
;.macro LockCache
;        ; LOCKED mask is NEGATIVE
;        lwarx   $0, mask, $1    ; mask = reserve(cache->mask)
;        cmpwi   $0, 0           ;
;        blt     .-8             ; try again if mask < 0
;        neg     r0, $0          ;
;        stwcx.  r0, mask, $1    ; cache->mask = -mask ($0 keeps +mask)
;        bne     .-20            ; try again if lost reserve
;        isync                   ; flush prefetched instructions after locking
;.endmacro
;        
;; UnlockCache (mask<<2), cache
;.macro UnlockCache
;        sync                    ; finish previous instructions before unlocking
;        srwi    r0, $0, 2       ; r0 = (mask<<2) >> 2
;        stw     r0, mask($1)    ; cache->mask = +mask
;.endmacro
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
;
; MethodTableLookup WORD_RETURN | STRUCT_RETURN, MSG_SEND | MSG_SENDSUPER, FEW_ARGS | MANY_ARGS
;
; Takes: WORD_RETURN	(r3 is first parameter)
;	STRUCT_RETURN	(r3 is structure return address, r4 is first parameter)
;	MSG_SEND	(first parameter is receiver)
;	MSG_SENDSUPER	(first parameter is address of objc_super structure)
;
; Eats: r0, r11, r12
; On exit: if MANY_ARGS, restores r9,r10 saved by CacheLookup
;	imp in ctr
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

HAVE_CALL_EXTERN_lookupMethodAndLoadCache	= 0

.macro  MethodTableLookup
	stw		r3, 24(r1)		; save arguments
	stw		r4, 28(r1)		; 
	stw		r5, 32(r1)		;
	stw		r6, 36(r1)		;
	stw		r7, 40(r1)		;
	stw		r8, 44(r1)		;
	; if MANY_ARGS, r9 and r10 were saved by CacheLookup

	mflr		r0			; save lr
	stw		r0,8(r1)		;

#if defined(KERNEL)
	stwu		r1,-64(r1)		; grow the stack
#else

.if $2 == MANY_ARGS
	stfd		f13, -8(r1)		; save the fp parameter registers
	stfd		f12, -16(r1)		;
	stfd		f11, -24(r1)		;
	stfd		f10, -32(r1)		;
	stfd		f9, -40(r1)		;
	stfd		f8, -48(r1)		;
	stfd		f7, -56(r1)		;
	stfd		f6, -64(r1)		;
	stfd		f5, -72(r1)		;
.endif
	stfd		f4, -80(r1)		;
	stfd		f3, -88(r1)		;
	stfd		f2, -96(r1)		;
	stfd		f1, -104(r1)		;

	stwu		r1,-56-(13*8)(r1)	; grow the stack
#endif

; Pass parameters to __class_lookupMethodAndLoadCache.  First parameter is
; the class pointer.  Second parameter is the selector.  Where they come
; from depends on who called us.  In the int return case, the selector is
; already in r4.
.if $0 == WORD_RETURN				; WORD_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	lwz		r3,isa(r3)		; class = receiver->isa
.else						; MSG_SENDSUPER
	lwz		r3,class(r3)		; class = super->class
.endif

.else						; STRUCT_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	lwz		r3,isa(r4)		; class = receiver->isa
.else						; MSG_SENDSUPER
	lwz		r3,class(r4)		; class = super->class
.endif
	mr		r4,r5			; selector = selector 
.endif

.if HAVE_CALL_EXTERN_lookupMethodAndLoadCache == 0
HAVE_CALL_EXTERN_lookupMethodAndLoadCache = 1
	CALL_EXTERN(__class_lookupMethodAndLoadCache)
.else
	CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)
.endif

	mr		r12,r3			; copy implementation to r12
	mtctr		r3			; copy imp to ctr
	lwz		r1,0(r1)		; restore the stack pointer
	lwz		r0,8(r1)		;
	mtlr		r0			; restore return pc

#if !defined(KERNEL)

.if $2 == MANY_ARGS
	lfd		f13, -8(r1)		; restore fp parameter registers
	lfd		f12, -16(r1)		;
	lfd		f11, -24(r1)		;
	lfd		f10, -32(r1)		;
	lfd		f9, -40(r1)		;
	lfd		f8, -48(r1)		;
	lfd		f7, -56(r1)		;
	lfd		f6, -64(r1)		;
	lfd		f5, -72(r1)		;
.endif
	lfd		f4, -80(r1)		;
	lfd		f3, -88(r1)		;
	lfd		f2, -96(r1)		;
	lfd		f1, -104(r1)		;
#endif

	lwz		r3, 24(r1)		; restore parameter registers
	lwz		r4, 28(r1)		;
	lwz		r5, 32(r1)		;
	lwz		r6, 36(r1)		;
	lwz		r7, 40(r1)		;
	lwz		r8, 44(r1)		;

.if $2 == MANY_ARGS
	lwz		r9, 48(r1)		; restore saves from CacheLookup
	lwz		r10,52(r1)		;
.endif

.endmacro


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; CALL_MCOUNT
;
; Macro to call mcount function in profiled builds.
;
; NOTE: Makes sure to save/restore r11 and r12, even though they
; are not defined to be volatile, because they are used during
; forwarding.
;
; Takes: lr			    Callers return PC
;
; Eats: r0
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

HAVE_CALL_EXTERN_mcount	= 0

	.macro	CALL_MCOUNT
#if defined(PROFILE)
	mflr		r0			; save return pc
	stw		r0,8(r1)		;

	stwu		r1,-208(r1)		; push aligned areas, set stack link

	stw		r3, 56(r1)		; save all volatile registers
	stw		r4, 60(r1)		; 
	stw		r5, 64(r1)		;
	stw		r6, 68(r1)		; 
	stw		r7, 72(r1)		;
	stw		r8, 76(r1)		;
	stw		r9, 80(r1)		;
	stw		r10,84(r1)		;
	stw		r11,88(r1)		; save r11 and r12, too
	stw		r12,92(r1)		;

	stfd		f1, 96(r1)		;
	stfd		f2, 104(r1)		;
	stfd		f3, 112(r1)		;
	stfd		f4, 120(r1)		;
	stfd		f5, 128(r1)		;
	stfd		f6, 136(r1)		;
	stfd		f7, 144(r1)		;
	stfd		f8, 152(r1)		;
	stfd		f9, 160(r1)		;
	stfd		f10, 168(r1)		;
	stfd		f11, 176(r1)		;
	stfd		f12, 184(r1)		;
	stfd		f13, 192(r1)		;

	mflr		r3			; pass our callers address
.if HAVE_CALL_EXTERN_mcount == 0
HAVE_CALL_EXTERN_mcount = 1
	CALL_EXTERN(mcount)
.else
	CALL_EXTERN_AGAIN(mcount)
.endif

	lwz		r3, 56(r1)		; restore all volatile registers
	lwz		r4, 60(r1)		; 
	lwz		r5, 64(r1)		;
	lwz		r6, 68(r1)		; 
	lwz		r7, 72(r1)		;
	lwz		r8, 76(r1)		;
	lwz		r9, 80(r1)		;
	lwz		r10,84(r1)		;
	lwz		r11,88(r1)		; restore r11 and r12, too
	lwz		r12,92(r1)		;

	lfd		f1, 96(r1)		;
	lfd		f2, 104(r1)		;
	lfd		f3, 112(r1)		;
	lfd		f4, 120(r1)		;
	lfd		f5, 128(r1)		;
	lfd		f6, 136(r1)		;
	lfd		f7, 144(r1)		;
	lfd		f8, 152(r1)		;
	lfd		f9, 160(r1)		;
	lfd		f10, 168(r1)		;
	lfd		f11, 176(r1)		;
	lfd		f12, 184(r1)		;
	lfd		f13, 192(r1)		;

	lwz		r1,0(r1)		; restore the stack pointer
	lwz		r0,8(r1)		;
	mtlr		r0			; restore return pc
#endif
	.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel)
 *
 * On entry:    r3 = class whose cache is to be searched
 *              r4 = selector to search for
 *
 * If found, returns method triplet pointer.
 * If not found, returns NULL.
 *
 * NOTE: _cache_getMethod never returns any cache entry whose implementation
 * is _objc_msgForward. It returns NULL instead. This prevents thread-
 * safety and memory management bugs in _class_lookupMethodAndLoadCache. 
 * See _class_lookupMethodAndLoadCache for details. 
 ********************************************************************/
        
        ENTRY __cache_getMethod
; do profiling if enabled
        CALL_MCOUNT

; do lookup
        CacheLookup     WORD_RETURN, CACHE_GET, LGetMethodMiss, MANY_ARGS
        
; cache hit, method triplet in r12
; check for _objc_msgForward
        lwz     r11, method_imp(r12)    ; get the imp
        LEA_STATIC_DATA r10, __objc_msgForward, LOCAL_SYMBOL
        cmplw   r11, r10
        beq     LGetMethodMiss          ; if (imp==_objc_msgForward) return nil
        mr      r3, r12                 ; else return method triplet address
        blr
        
LGetMethodMiss:
; cache miss, return nil
        li      r3, 0           ; return nil
        blr

LGetMethodExit: 
        END_ENTRY __cache_getMethod


/********************************************************************
 * IMP _cache_getImp(Class cls, SEL sel)
 *
 * On entry:    r3 = class whose cache is to be searched
 *              r4 = selector to search for
 *
 * If found, returns method implementation.
 * If not found, returns NULL.
 ********************************************************************/

        ENTRY __cache_getImp
; do profiling if enabled
        CALL_MCOUNT

; do lookup
        CacheLookup WORD_RETURN, CACHE_GET, LGetImpMiss, MANY_ARGS
        
; cache hit, method triplet in r12
        lwz     r3, method_imp(r12)    ; return method imp address
        blr
        
LGetImpMiss:
; cache miss, return nil
        li      r3, 0           ; return nil
        blr

LGetImpExit: 
        END_ENTRY __cache_getImp


/********************************************************************
 * id		objc_msgSend(id	self,
 *			SEL	op,
 *			...);
 *
 * On entry:	r3 is the message receiver,
 *		r4 is the selector
 ********************************************************************/

#if defined(__DYNAMIC__)
/* Allocate reference to external static data */
	.non_lazy_symbol_pointer
L__objc_msgNil:
	.indirect_symbol __objc_msgNil
	.long	0
	.text
#endif

	ENTRY	_objc_msgSend
; do profiling when enabled
	CALL_MCOUNT

; check whether receiver is nil
	cmplwi		r3,0			; receiver nil?
	beq		LMsgSendNilSelf		; if so, call handler or return nil

; receiver is non-nil: search the cache
	CacheLookup WORD_RETURN, MSG_SEND, LMsgSendCacheMiss, MANY_ARGS
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SEND, MANY_ARGS
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; message sent to nil object call: optional handler and return nil
LMsgSendNilSelf:
	LOAD_STATIC_WORD r11, __objc_msgNil, EXTERNAL_SYMBOL
	cmplwi		r11,0			; handler nil?
	beqlr					; if no handler, return nil

	mflr		r0			; save return pc
	stw		r0,8(r1)		;
	subi		r1,r1,64		; allocate linkage area
	mtctr		r11			; 
	bctrl					; call handler
	addi		r1,r1,64		; deallocate linkage area
	lwz		r0,8(r1)		; restore return pc
	mtlr		r0			; 

	li		r3,0		; re-zero return value, in case handler changed it
	blr					; return to caller

LMsgSendExit:
	END_ENTRY	_objc_msgSend


/********************************************************************
 * struct_type	objc_msgSend_stret(id	self,
 *				SEL	op,
 *					...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	r3 is the address where the structure is returned,
 *		r4 is the message receiver,
 *		r5 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSend_stret
; do profiling when enabled
	CALL_MCOUNT

; check whether receiver is nil
	cmplwi		r4,0			; receiver nil?
	beq		LMsgSendStretNilSelf	; if so, call handler or just return

; receiver is non-nil: search the cache
	CacheLookup STRUCT_RETURN, MSG_SEND, LMsgSendStretCacheMiss, MANY_ARGS
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SEND, MANY_ARGS
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; message sent to nil object call optional handler and return nil
LMsgSendStretNilSelf:
	LOAD_STATIC_WORD r11, __objc_msgNil, EXTERNAL_SYMBOL
	cmplwi		r11,0			; handler nil?
	beqlr					; if no handler, return

	mflr		r0			; save return pc
	stw		r0,8(r1)		;
	subi		r1,r1,64		; allocate linkage area
	mr		r3,r4			; move self to r3
	mr		r4,r5			; move SEL to r4
	mtctr		r11					; 
	bctrl					; call handler
	addi		r1,r1,64		; deallocate linkage area
	lwz		r0,8(r1)		; restore return pc
	mtlr		r0			; 

	blr					; return to caller

LMsgSendStretExit:
	END_ENTRY	_objc_msgSend_stret


/********************************************************************
 * id	objc_msgSendSuper(struct objc_super	*super,
 *			SEL			op,
 *						...);
 *
 * struct objc_super {
 *	id	receiver;
 *	Class	class;
 * };
 ********************************************************************/

	ENTRY	_objc_msgSendSuper
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	CacheLookup WORD_RETURN, MSG_SENDSUPER, LMsgSendSuperCacheMiss, MANY_ARGS
	lwz		r3,receiver(r3)		; receiver is the first arg
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SENDSUPER, MANY_ARGS
	lwz		r3,receiver(r3)		; receiver is the first arg
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

LMsgSendSuperExit:
	END_ENTRY	_objc_msgSendSuper


/********************************************************************
 * struct_type	objc_msgSendSuper_stret(objc_super	*super,
 *					SEL		op,
 *							...);
 *
 * struct objc_super {
 *	id	receiver;
 *	Class	class;
 * };
 *
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	r3 is the address to which to copy the returned structure,
 *		r4 is the address of the objc_super structure,
 *		r5 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSendSuper_stret
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	CacheLookup STRUCT_RETURN, MSG_SENDSUPER, LMsgSendSuperStretCacheMiss, MANY_ARGS
	lwz		r4,receiver(r4)		; receiver is the first arg
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SENDSUPER, MANY_ARGS
	lwz		r4,receiver(r4)		; receiver is the first arg
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

LMsgSendSuperStretExit:
	END_ENTRY	_objc_msgSendSuper_stret


/********************************************************************
 *
 * Out-of-band parameter r11 indicates whether it was objc_msgSend or
 * objc_msgSend_stret that triggered the message forwarding.  The 
 *
 * Iff r11 == kFwdMsgSend, it is the word-return (objc_msgSend) case,
 * and the interface is:
 *
 * id		_objc_msgForward(id	self,
 *				SEL	sel,
 *					...);
 *
 * Iff r11 == kFwdMsgSendStret, it is the structure-return
 * (objc_msgSend_stret) case, and the interface is:
 *
 * struct_type	_objc_msgForward(id	self,
 *				SEL	sel,
 *					...);
 *
 * There are numerous reasons why it is better to have one
 * _objc_msgForward, rather than adding _objc_msgForward_stret.
 * The best one is that _objc_msgForward is the method that
 * gets cached when respondsToMethod returns false, and it
 * wouldnt know which one to use.
 * 
 * Sends the message to a method having the signature
 *
 *      - forward:(SEL)sel :(marg_list)args;
 * 
 * But the marg_list is prepended with the 13 double precision
 * floating point registers that could be used as parameters into
 * the method (fortunately, the same registers are used for either
 * single or double precision floats).  These registers are layed
 * down by _objc_msgForward, and picked up by _objc_msgSendv.  So
 * the "marg_list" is actually:
 *
 * typedef struct objc_sendv_margs {
 *	double		floatingPointArgs[13];
 *	int		linkageArea[6];
 *	int		registerArgs[8];
 *	int		stackArgs[variable];
 * };
 *
 ********************************************************************/

; Location LFwdStr contains the string "forward::"
; Location LFwdSel contains a pointer to LFwdStr, that can be changed
; to point to another forward:: string for selector uniquing
; purposes.  ALWAYS dereference LFwdSel to get to "forward::" !!
	.objc_meth_var_names
	.align 1
LFwdStr:	.ascii "forward::\0"

	.objc_message_refs
	.align	2
LFwdSel:.long	LFwdStr

	.cstring
	.align	1
LUnkSelStr:	.ascii	"Does not recognize selector %s\0"

	ENTRY	__objc_msgForward
; do profiling when enabled
	CALL_MCOUNT

#if defined(KERNEL)
	trap					; _objc_msgForward is not for the kernel
#else
	LOAD_STATIC_WORD r12, LFwdSel, LOCAL_SYMBOL	; get uniqued selector for "forward::"
	cmplwi		r11,kFwdMsgSend		; via objc_msgSend or objc_msgSend_stret?
	bne		LMsgForwardStretSel	; branch for objc_msgSend_stret
	cmplw		r12,r4			; if (sel == @selector (forward::))
	b		LMsgForwardSelCmpDone	; check the result in common code
LMsgForwardStretSel:
	cmplw		r12,r5			; if (sel == @selector (forward::))
LMsgForwardSelCmpDone:
	beq		LMsgForwardError	;   goto error

	mflr		r0
	stw		r0,8(r1)		; save lr
	
	stw		r3, 24(r1)		; put register arguments on stack for forwarding
	stw		r4, 28(r1)		; (stack based args already follow this area)
	stw		r5, 32(r1)		;
	stw		r6, 36(r1)		; 
	stw		r7, 40(r1)		;
	stw		r8, 44(r1)
	stw		r9, 48(r1)
	stw		r10,52(r1)

	stfd		f13, -8(r1)		; prepend floating point registers to marg_list
	stfd		f12, -16(r1)		;
	stfd		f11, -24(r1)		;
	stfd		f10, -32(r1)		;
	stfd		f9, -40(r1)		;
	stfd		f8, -48(r1)		;
	stfd		f7, -56(r1)		;
	stfd		f6, -64(r1)		;
	stfd		f5, -72(r1)		;
	stfd		f4, -80(r1)		;
	stfd		f3, -88(r1)		;
	stfd		f2, -96(r1)		;
	stfd		f1, -104(r1)		;

	cmplwi		r11,kFwdMsgSend		; via objc_msgSend or objc_msgSend_stret?
	bne		LMsgForwardStretParams	; branch for objc_msgSend_stret
						; first arg (r3) remains self
	mr		r5,r4			; third arg is previous selector
	b		LMsgForwardParamsDone
LMsgForwardStretParams:
	mr		r3,r4			; first arg is self
						; third arg (r5) remains previous selector
LMsgForwardParamsDone:
	mr		r4,r12			; second arg is "forward::"
	subi		r6,r1,13*8		; fourth arg is &objc_sendv_margs

	stwu		r1,-56-(13*8)(r1)	; push aligned linkage and parameter areas, set stack link
	bl		_objc_msgSend		; [self forward:sel :objc_sendv_margs]
	addi		r1,r1,56+13*8		; deallocate linkage and parameters areas

	lwz		r0,8(r1)		; restore lr
	mtlr		r0			;
	blr					;

; call error handler with unrecognized selector message
LMsgForwardError:
	cmplwi		r11,kFwdMsgSendStret	; via objc_msgSend or objc_msgSend_stret?
	bne		LMsgForwardErrorParamsOK;  branch for objc_msgSend
	mr		r3,r4			; first arg is self
LMsgForwardErrorParamsOK:
	LEA_STATIC_DATA r4, LUnkSelStr, LOCAL_SYMBOL
	mr		r5,r12			; third arg is "forward::"
	CALL_EXTERN(___objc_error)		; never returns
	trap					; ___objc_error should never return
#endif

	END_ENTRY	__objc_msgForward


/********************************************************************
 * id		objc_msgSendv(id	self,
 *			SEL		op,
 *			unsigned	arg_size,
 *			marg_list	arg_frame);
 *
 * But the marg_list is prepended with the 13 double precision
 * floating point registers that could be used as parameters into
 * the method (fortunately, the same registers are used for either
 * single or double precision floats).  These registers are layed
 * down by _objc_msgForward, and picked up by _objc_msgSendv.  So
 * the "marg_list" is actually:
 *
 * typedef struct objc_sendv_margs {
 *	double		floatingPointArgs[13];
 *	int		linkageArea[6];
 *	int		registerArgs[8];
 *	int		stackArgs[variable];
 * };
 *
 * arg_size is the number of bytes of parameters in registerArgs and
 * stackArgs combined (i.e. it is method_getSizeOfArguments(method)).
 * Specifically, it is NOT the overall arg_frame size, because that
 * would include the floatingPointArgs and linkageArea, which are
 * PowerPC-specific.  This is consistent with the other architectures.
 ********************************************************************/

	ENTRY	_objc_msgSendv

#if defined(KERNEL)
	trap					; _objc_msgSendv is not for the kernel
#else
; do profiling when enabled
	CALL_MCOUNT

	mflr		r0
	stw		r0,8(r1)		; save lr

	cmplwi		r5,32			; check parameter size against minimum
	ble+		LMsgSendvMinFrame	; is less than minimum, go use minimum
	mr		r12,r1			; remember current stack pointer
	sub		r11,r1,r5		; push parameter area
	rlwinm		r1,r11,0,0,27		; align stack pointer to 16 byte boundary
	stwu		r12,-32(r1)		; push aligned linkage area, set stack link 
	b		LMsgSendvHaveFrame

LMsgSendvMinFrame:
	stwu		r1,-64(r1)		; push aligned linkage and parameter areas, set stack link

LMsgSendvHaveFrame:
	; restore floating point register parameters from marg_list
	lfd		f13,96(r6)		; 
	lfd		f12,88(r6)		;
	lfd		f11,80(r6)		;
	lfd		f10,72(r6)		;
	lfd		f9,64(r6)		;
	lfd		f8,56(r6)		;
	lfd		f7,48(r6)		;
	lfd		f6,40(r6)		;
	lfd		f5,32(r6)		;
	lfd		f4,24(r6)		;
	lfd		f3,16(r6)		;
	lfd		f2,8(r6)		;
	lfd		f1,0(r6)		;

; load the register based arguments from the marg_list
; the first two parameters are already in r3 and r4, respectively
	subi		r0,r5,5			; make word count from byte count rounded up to multiple of 4...
	srwi.		r0,r0,2			; ... and subtracting for params already in r3 and r4
	beq		LMsgSendvSendIt		; branch if there are no parameters to load
	mtctr		r0			; counter = number of remaining words
	lwz		r5,32+(13*8)(r6)	; load 3rd parameter
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero
	addi		r11,r6,36+(13*8)	; switch to r11, because we are setting r6
	lwz		r6,0(r11)		; load 4th parameter
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz		r7,4(r11)		; load 5th parameter
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz		r8,8(r11)		; load 6th parameter
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz		r9,12(r11)		; load 7th parameter
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwzu		r10,16(r11)		; load 8th parameter, and update r11
	bdz		LMsgSendvSendIt		; decrement counter, branch if result is zero

; copy the stack based arguments from the marg_list
	addi		r12,r1,24+32-4		; target = address of stack based parameters
LMsgSendvArgLoop:
	lwzu		r0,4(r11)		; loop to copy remaining marg_list words to stack
	stwu		r0,4(r12)		;
	bdnz		LMsgSendvArgLoop	; decrement counter, branch if still non-zero

LMsgSendvSendIt:
	bl		_objc_msgSend		; objc_msgSend (self, selector, ...)

	lwz		r1,0(r1)		; restore stack pointer
	lwz		r0,8(r1)		; restore lr
	mtlr		r0			;
	blr					;
#endif

	END_ENTRY	_objc_msgSendv


/********************************************************************
 * struct_type	objc_msgSendv_stret(id		self,
 *				SEL		op,
 *				unsigned	arg_size,
 *				marg_list	arg_frame); 
 *
 * objc_msgSendv_stret is the struct-return form of msgSendv.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 * 
 * An equally correct way to prototype this routine is:
 *
 * void objc_msgSendv_stret(void	*structStorage,
 *			id		self,
 *			SEL		op,
 *			unsigned	arg_size,
 *			marg_list	arg_frame);
 *
 * which is useful in, for example, message forwarding where the
 * structure-return address needs to be passed in.
 *
 * The ABI for the two cases are identical.
 *
 * On entry:	r3 is the address in which the returned struct is put,
 *		r4 is the message receiver,
 *		r5 is the selector,
 *		r6 is the size of the marg_list, in bytes,
 *		r7 is the address of the marg_list
 ********************************************************************/

	ENTRY	_objc_msgSendv_stret

#if defined(KERNEL)
	trap					; _objc_msgSendv_stret is not for the kernel 
#else
; do profiling when enabled
	CALL_MCOUNT

	mflr		r0
	stw		r0,8(r1)		; (save return pc)

	cmplwi		r6,32			; check parameter size against minimum
	ble+		LMsgSendvStretMinFrame	; is less than minimum, go use minimum
	mr		r12,r1			; remember current stack pointer
	sub		r11,r1,r6		; push parameter area
	rlwinm		r1,r11,0,0,27		; align stack pointer to 16 byte boundary
	stwu		r12,-32(r1)		; push aligned linkage area, set stack link 
	b		LMsgSendvStretHaveFrame

LMsgSendvStretMinFrame:
	stwu		r1,-64(r1)		; push aligned linkage and parameter areas, set stack link

LMsgSendvStretHaveFrame:
; restore floating point register parameters from marg_list
	lfd		f13,96(r7)		; 
	lfd		f12,88(r7)		;
	lfd		f11,80(r7)		;
	lfd		f10,72(r7)		;
	lfd		f9,64(r7)		;
	lfd		f8,56(r7)		;
	lfd		f7,48(r7)		;
	lfd		f6,40(r7)		;
	lfd		f5,32(r7)		;
	lfd		f4,24(r7)		;
	lfd		f3,16(r7)		;
	lfd		f2,8(r7)		;
	lfd		f1,0(r7)		;

; load the register based arguments from the marg_list
; the structure return address and the first two parameters
; are already in r3, r4, and r5, respectively.
; NOTE: The callers r3 probably, but not necessarily, matches
; the r3 in the marg_list.  That is, the struct-return
; storage used by the caller could be an intermediate buffer
; that will end up being copied into the original
; struct-return buffer (pointed to by the marg_listed r3).
	subi		r0,r6,5			; make word count from byte count rounded up to multiple of 4...
	srwi.		r0,r0,2			; ... and subtracting for params already in r4 and r5
	beq		LMsgSendvStretSendIt	; branch if there are no parameters to load
	mtctr		r0			; counter = number of remaining words
	lwz		r6,36+(13*8)(r7)	; load 4th parameter
	bdz		LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	addi		r11,r7,40+(13*8)	; switch to r11, because we are setting r7
	lwz		r7,0(r11)		; load 5th parameter
	bdz		LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwz		r8,4(r11)		; load 6th parameter
	bdz		LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwz		r9,8(r11)		; load 7th parameter
	bdz		LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwzu		r10,12(r11)		; load 8th parameter, and update r11
	bdz		LMsgSendvStretSendIt	; decrement counter, branch if result is zero

; copy the stack based arguments from the marg_list
	addi		r12,r1,24+32-4		; target = address of stack based parameters
LMsgSendvStretArgLoop:
	lwzu		r0,4(r11)		; loop to copy remaining marg_list words to stack
	stwu		r0,4(r12)		;
	bdnz		LMsgSendvStretArgLoop	; decrement counter, branch if still non-zero

LMsgSendvStretSendIt:
	bl		_objc_msgSend_stret	; struct_type objc_msgSend_stret (self, selector, ...)

	lwz		r1,0(r1)		; restore stack pointer
	lwz		r0,8(r1)		; restore return pc
	mtlr		r0
	blr					; return
#endif

	END_ENTRY	_objc_msgSendv_stret


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; ****************  THE "FEW" API  ****************
;
; The "few args" apis; The compiler needs to be updated to generate calls to
; these functions, rather than to their counterparts, when the number of
; arguments to a method is < 6 (5 for struct returns).
;
; *************************************************
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

/********************************************************************
 * id		objc_msgSendFew(id	self,
 *				SEL	op,
 *					...);
 *
 * On entry:	r3 is the message receiver,
 *		r4 is the selector
 *		+ at most 3 args (ints or doubles)
 ********************************************************************/

	ENTRY	_objc_msgSendFew
; do profiling when enabled
	CALL_MCOUNT

; check whether receiver is nil
	cmplwi		r3,0			; receiver nil?
	beq		LMsgSendFewNilSelf	; if so, call handler or return nil

; receiver is non-nil: search the cache
	CacheLookup WORD_RETURN, MSG_SEND, LMsgSendFewCacheMiss, FEW_ARGS
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendFewCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SEND, FEW_ARGS
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; message sent to nil object call: optional handler and return nil
LMsgSendFewNilSelf:
	LOAD_STATIC_WORD r11, __objc_msgNil, EXTERNAL_SYMBOL
	cmplwi		r11,0			; handler nil?
	beqlr					; if no handler, return nil

	mflr		r0			; save return pc
	stw		r0,8(r1)		;
	subi		r1,r1,64		; allocate linkage area
	mtctr		r11			; 
	bctrl					; call handler
	addi		r1,r1,64		; deallocate linkage area
	lwz		r0,8(r1)		; restore return pc
	mtlr		r0			; 

	li		r3,0		; re-zero return value, in case handler changed it
	blr					; return to caller

LMsgSendFewExit:
	END_ENTRY	_objc_msgSendFew


/********************************************************************
 * struct_type	objc_msgSendFew_stret(id	self,
 *					SEL	op,
 *						...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	r3 is the address where the structure is returned,
 *		r4 is the message receiver,
 *		r5 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSendFew_stret
; do profiling when enabled
	CALL_MCOUNT

; check whether receiver is nil
	cmplwi		r4,0			; receiver nil?
	beq		LMsgSendFewStretNilSelf	; if so, call handler or just return

; receiver is non-nil: search the cache
	CacheLookup STRUCT_RETURN, MSG_SEND, LMsgSendFewStretCacheMiss, FEW_ARGS
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendFewStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SEND, FEW_ARGS
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; message sent to nil object call optional handler and return nil
LMsgSendFewStretNilSelf:
	LOAD_STATIC_WORD r11, __objc_msgNil, EXTERNAL_SYMBOL
	cmplwi		r11,0			; handler nil?
	beqlr					; if no handler, return

	mflr		r0			; save return pc
	stw		r0,8(r1)		;
	subi		r1,r1,64		; allocate linkage area
	mr		r3,r4			; move self to r3
	mr		r4,r5			; move SEL to r4
	mtctr		r11			; 
	bctrl					; call handler
	addi		r1,r1,64		; deallocate linkage area
	lwz		r0,8(r1)		; restore return pc
	mtlr		r0			; 

	blr					; return to caller

LMsgSendFewStretExit:
	END_ENTRY	_objc_msgSendFew_stret


/********************************************************************
 * id	objc_msgSendSuperFew(struct objc_super	*super,
 *				SEL			op,
 *							...);
 *
 * struct objc_super {
 *	id	receiver;
 *	Class	class;
 * };
 ********************************************************************/

	ENTRY	_objc_msgSendSuperFew
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	CacheLookup WORD_RETURN, MSG_SENDSUPER, LMsgSendSuperFewCacheMiss, FEW_ARGS
	lwz		r3,receiver(r3)		; receiver is the first arg
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperFewCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SENDSUPER, FEW_ARGS
	lwz		r3,receiver(r3)		; receiver is the first arg
	li		r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

LMsgSendSuperFewExit:
	END_ENTRY	_objc_msgSendSuperFew


/********************************************************************
 * struct_type	objc_msgSendSuperFew_stret(objc_super	*super,
 *						SEL		op,
 *								...);
 *
 * struct objc_super {
 *	id	receiver;
 *	Class	class;
 * };
 *
 *
 * objc_msgSendSuper_stret is the struct-return form of msgSendSuper.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry:	r3 is the address to which to copy the returned structure,
 *		r4 is the address of the objc_super structure,
 *		r5 is the selector
 ********************************************************************/

	ENTRY	_objc_msgSendSuperFew_stret
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	CacheLookup STRUCT_RETURN, MSG_SENDSUPER, LMsgSendSuperFewStretCacheMiss, FEW_ARGS
	lwz		r4,receiver(r4)		; receiver is the first arg
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperFewStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SENDSUPER, FEW_ARGS
	lwz		r4,receiver(r4)		; receiver is the first arg
	li		r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr					; goto *imp;

LMsgSendSuperFewStretExit:
	END_ENTRY	_objc_msgSendSuperFew_stret

