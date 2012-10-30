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

#ifdef __ppc__

/********************************************************************
 *
 *  objc-msg-ppc.s - PowerPC code to support objc messaging.
 *
 *  Copyright 1988-1996 NeXT Software, Inc.
 *
 *  December 2002 Andy Belk (abelk at apple.com)
 *    Use r2 in the messenger - no longer need r10.
 *    Removed "few args" variants (no longer worth it, especially since gcc3 still
 *    doesn't generate code for them).
 *    Add NonNil entry points to objc_msgSend and objc_msgSend_stret.
 *    Align objc_msgSend et al on cache lines.
 *    Replace CALL_EXTERN references (which caused excess mflr/mtlr usage) with
 *    dyld-stub-compatible versions: shorter and become local branches within a dylib.
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
 
#undef  OBJC_ASM
#define OBJC_ASM
#include "objc-rtp.h"

/********************************************************************
 * Data used by the ObjC runtime.
 *
 ********************************************************************/

	.data
; Substitute receiver for messages sent to nil (usually also nil)
; id _objc_nilReceiver
	.align 4
.private_extern __objc_nilReceiver
__objc_nilReceiver:
	.long   0

; _objc_entryPoints and _objc_exitPoints are used by method dispatch
; caching code to figure out whether any threads are actively 
; in the cache for dispatching.  The labels surround the asm code
; that do cache lookups.  The tables are zero-terminated.
.private_extern _objc_entryPoints
_objc_entryPoints:
	.long   __cache_getImp
	.long   __cache_getMethod
	.long   _objc_msgSend
	.long   _objc_msgSend_stret
	.long   _objc_msgSendSuper
	.long   _objc_msgSendSuper_stret
	.long   _objc_msgSend_rtp
	.long   0

.private_extern _objc_exitPoints
_objc_exitPoints:
	.long   LGetImpExit
	.long   LGetMethodExit
	.long   LMsgSendExit
	.long   LMsgSendStretExit
	.long   LMsgSendSuperExit
	.long   LMsgSendSuperStretExit
	.long   _objc_msgSend_rtp_exit
	.long   0

/*
 * Handcrafted dyld stubs for each external call.
 * They should be converted into a local branch after linking. aB.
 */

/* asm_help.h version is not what we want */
#undef CALL_EXTERN

#if defined(__DYNAMIC__)

#define CALL_EXTERN(name)	bl      L ## name ## $stub

#define LAZY_PIC_FUNCTION_STUB(name) \
.data                         @\
.picsymbol_stub               @\
L ## name ## $stub:           @\
	.indirect_symbol name     @\
	mflr    r0                @\
	bcl     20,31,L0$ ## name @\
L0$ ## name:                  @\
	mflr    r11               @\
	addis   r11,r11,ha16(L ## name ## $lazy_ptr-L0$ ## name) @\
	mtlr    r0                @\
	lwz     r12,lo16(L ## name ## $lazy_ptr-L0$ ## name)(r11) @\
	mtctr   r12               @\
	addi    r11,r11,lo16(L ## name ## $lazy_ptr-L0$ ## name) @\
	bctr                      @\
.data                         @\
.lazy_symbol_pointer          @\
L ## name ## $lazy_ptr:       @\
	.indirect_symbol name     @\
	.long dyld_stub_binding_helper

#else /* __DYNAMIC__ */

#define CALL_EXTERN(name)	bl      name

#define LAZY_PIC_FUNCTION_STUB(name)

#endif /* __DYNAMIC__ */

; _class_lookupMethodAndLoadCache
LAZY_PIC_FUNCTION_STUB(__class_lookupMethodAndLoadCache)

; __objc_error
LAZY_PIC_FUNCTION_STUB(___objc_error) /* No stub needed */

#if defined(PROFILE)
; mcount
LAZY_PIC_FUNCTION_STUB(mcount)
#endif /* PROFILE */


/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

; objc_super parameter to sendSuper
#define RECEIVER         0
#define CLASS            4

; Selected field offsets in class structure
#define ISA              0
#define CACHE            32

; Method descriptor
#define METHOD_NAME      0
#define METHOD_IMP       8

; Cache header
#define MASK             0
#define OCCUPIED         4
#define BUCKETS          8	// variable length array

#if defined(OBJC_INSTRUMENTED)
; Cache instrumentation data, follows buckets
#define hitCount         0
#define hitProbes        hitCount + 4
#define maxHitProbes     hitProbes + 4
#define missCount        maxHitProbes + 4
#define missProbes       missCount + 4
#define maxMissProbes    missProbes + 4
#define flushCount       maxMissProbes + 4
#define flushedEntries   flushCount + 4
#endif

/********************************************************************
 *
 * Constants.
 *
 ********************************************************************/

// In case the implementation is _objc_msgForward_internal, indicate to it
// whether the method was invoked as a word-return or struct-return.
// The li instruction costs nothing because it fits into spare
// processor cycles. We choose to make the MsgSend indicator non-zero
// as r11 is already guaranteed non-zero for a cache hit (no li needed).

#define kFwdMsgSend          1
#define kFwdMsgSendStret     0


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
#define LOCAL_SYMBOL     0
#define EXTERNAL_SYMBOL  1

.macro LOAD_STATIC_WORD

#if defined(__DYNAMIC__)
	mflr    r0
	bcl     20,31,1f	; 31 is cr7[so]
1:	mflr    $0
	mtlr    r0
.if $2 == EXTERNAL_SYMBOL
	addis   $0,$0,ha16(L$1-1b)
	lwz     $0,lo16(L$1-1b)($0)
	lwz     $0,0($0)
.elseif $2 == LOCAL_SYMBOL
	addis   $0,$0,ha16($1-1b)
	lwz     $0,lo16($1-1b)($0)
.else
	!!! Unknown symbol type !!!
.endif
#else
	lis     $0,ha16($1)
	lwz     $0,lo16($1)($0)
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

.macro LEA_STATIC_DATA
#if defined(__DYNAMIC__)
	mflr    r0
	bcl     20,31,1f	; 31 is cr7[so]
1:	mflr    $0
	mtlr    r0
.if $2 == EXTERNAL_SYMBOL
	addis   $0,$0,ha16(L$1-1b)
	lwz     $0,lo16(L$1-1b)($0)
.elseif $2 == LOCAL_SYMBOL
	addis   $0,$0,ha16($1-1b)
	addi    $0,$0,lo16($1-1b)
.else
	!!! Unknown symbol type !!!
.endif
#else
	lis     $0,hi16($1)
	ori     $0,$0,lo16($1)
#endif

.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; ENTRY		functionName
;
; Assembly directives to begin an exported function.
; We align on cache boundaries for these few functions.
;
; Takes: functionName - name of the exported function
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro ENTRY
	.text
	.align    5
	.globl    $0
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
	LEA_STATIC_DATA $0, $1, EXTERNAL_SYMBOL
	b       .+16			; jump into loop at the reserving check
	lwz     r0,0($0)		; check with fast, less intrusive lwz versus lwarx
	cmplwi  r0,0			; lock held?
	bne     .-8				; if so, spin until it appears unlocked
	lwarx   r0,0,$0			; get lock value, acquire memory reservation 
	cmplwi  r0,0			; lock held?
	bne     .-20			; if locked, go spin waiting for unlock
	li      r0,1			; get value that means locked
	stwcx.  r0,0,$0			; store it iff reservation still holds
	bne-    .-20			; if reservation was lost, go re-reserve
	isync   				; discard effects of prefetched instructions 
.endmacro

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; PUNLOCK	scratchReg, lockName
;
; Release named spinlock.
;
; Takes: scratchReg - a register, other than r0, that can be mangled
;        lockName   - the name of a static, aligned, 32-bit lock word
;
; Eats: r0 and scratchReg
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro PUNLOCK
	sync    				; force out changes before unlocking
	LEA_STATIC_DATA	$0, $1, EXTERNAL_SYMBOL
	li      r0,0			; get value meaning "unlocked"
	stw     r0,0($0)		; unlock the lock
.endmacro


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; CacheLookup selectorRegister, cacheMissLabel
;
; Locate the implementation for a selector in a class method cache.
;
; Takes: 
;	 $0 = register containing selector (r4 or r5 ONLY);
;	 cacheMissLabel = label to branch to iff method is not cached
;	 r12 = class whose cache is to be searched
;
; On exit: (found) method triplet in r2, imp in r12, r11 is non-zero
;          (not found) jumps to cacheMissLabel
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.macro CacheLookup

#if defined(OBJC_INSTRUMENTED)
	; when instrumented, we use r6 and r7
	stw     r6,36(r1)		; save r6 for use as cache pointer
	stw     r7,40(r1)		; save r7 for use as probe count
	li      r7,0			; no probes so far!
#endif

	lwz     r2,CACHE(r12)		; cache = class->cache
	stw     r9,48(r1)		; save r9

#if defined(OBJC_INSTRUMENTED)
	mr      r6,r2			; save cache pointer
#endif

	lwz     r11,MASK(r2)		; mask = cache->mask
	addi    r0,r2,BUCKETS		; buckets = cache->buckets
	slwi    r11,r11,2		; r11 = mask << 2 
	and     r9,$0,r11		; bytes = sel & (mask<<2)

#if defined(OBJC_INSTRUMENTED)
	b       LLoop_$0_$1

LMiss_$0_$1:
	; r6 = cache, r7 = probeCount
	lwz     r9,MASK(r6)		; entryCount = mask + 1
	addi    r9,r9,1			;
	slwi    r9,r9,2			; tableSize = entryCount * sizeof(entry)
	addi    r9,r9,BUCKETS		; offset = buckets + tableSize
	add     r11,r6,r9		; cacheData = &cache->buckets[mask+1]
	lwz     r9,missCount(r11)	; cacheData->missCount += 1
	addi    r9,r9,1			; 
	stw     r9,missCount(r11)	; 
	lwz     r9,missProbes(r11)	; cacheData->missProbes += probeCount
	add     r9,r9,r7		; 
	stw     r9,missProbes(r11)	; 
	lwz     r9,maxMissProbes(r11)	; if (probeCount > cacheData->maxMissProbes)
	cmplw   r7,r9			; maxMissProbes = probeCount
	ble     .+8			; 
	stw     r7,maxMissProbes(r11)	;

	lwz     r6,36(r1)		; restore r6
	lwz     r7,40(r1)		; restore r7

	b       $1			; goto cacheMissLabel
#endif

; search the cache
LLoop_$0_$1:
#if defined(OBJC_INSTRUMENTED)
	addi    r7,r7,1			; probeCount += 1
#endif

	lwzx    r2,r9,r0		; method = buckets[bytes/4]
	addi    r9,r9,4			; bytes += 4
	cmplwi  r2,0			; if (method == NULL)
#if defined(OBJC_INSTRUMENTED)
	beq-    LMiss_$0_$1
#else
	beq-    $1			; goto cacheMissLabel
#endif

	lwz     r12,METHOD_NAME(r2)	; name  = method->method_name
	and     r9,r9,r11		; bytes &= (mask<<2)
	cmplw   r12,$0			; if (name != selector)
	bne-    LLoop_$0_$1		; goto loop

; cache hit, r2 == method triplet address
; Return triplet in r2 and imp in r12
	lwz     r12,METHOD_IMP(r2)	; imp = method->method_imp

#if defined(OBJC_INSTRUMENTED)
	; r6 = cache, r7 = probeCount
	lwz     r9,MASK(r6)		; entryCount = mask + 1
	addi    r9,r9,1			;
	slwi    r9,r9,2			; tableSize = entryCount * sizeof(entry)
	addi    r9,r9,BUCKETS		; offset = buckets + tableSize
	add     r11,r6,r9		; cacheData = &cache->buckets[mask+1]
	lwz     r9,hitCount(r11)	; cache->hitCount += 1
	addi    r9,r9,1			; 
	stw     r9,hitCount(r11)	; 
	lwz     r9,hitProbes(r11)	; cache->hitProbes += probeCount
	add     r9,r9,r7		; 
	stw     r9,hitProbes(r11)	; 
	lwz     r9,maxHitProbes(r11)	; if (probeCount > cache->maxMissProbes)
	cmplw   r7,r9			;maxMissProbes = probeCount
	ble     .+8			; 
	stw     r7,maxHitProbes(r11)	; 

	lwz     r6,36(r1)		; restore r6
	lwz     r7,40(r1)		; restore r7
#endif

	lwz     r9,48(r1)		; restore r9

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
; MethodTableLookup WORD_RETURN | STRUCT_RETURN, MSG_SEND | MSG_SENDSUPER
;
; Takes: WORD_RETURN    (r3 is first parameter)
;        STRUCT_RETURN  (r3 is structure return address, r4 is first parameter)
;        MSG_SEND       (first parameter is receiver)
;        MSG_SENDSUPER  (first parameter is address of objc_super structure)
;
; Eats: r0, r2, r11, r12
; On exit: restores r9 saved by CacheLookup
;          imp in ctr
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Values to specify to method lookup macros whether the return type of
; the method is an integer or structure.
#define WORD_RETURN   0
#define STRUCT_RETURN 1

; Values to specify to method lookup macros whether the return type of
; the method is an integer or structure.
#define MSG_SEND      0
#define MSG_SENDSUPER 1

.macro MethodTableLookup
	mflr    r0              ; save lr
	stw     r0,   8(r1)     ;

	stw     r3,  24(r1)     ; save arguments
	stw     r4,  28(r1)     ; 
	stw     r5,  32(r1)     ;
	stw     r6,  36(r1)     ;
	stw     r7,  40(r1)     ;
	stw     r8,  44(r1)     ;
	; r9 was saved by CacheLookup
	stw     r10, 52(r1)     ;

#if !defined(KERNEL)
; Save the FP parameter registers.
; We do not spill vector argument registers. This is 
; harmless because vector parameters are unsupported.
	stfd    f1, -104(r1)	;
	stfd    f2,  -96(r1)	;
	stfd    f3,  -88(r1)	;
	stfd    f4,  -80(r1)	;
	stfd    f5,  -72(r1)	;
	stfd    f6,  -64(r1)	;
	stfd    f7,  -56(r1)	;
	stfd    f8,  -48(r1)	;
	stfd    f9,  -40(r1)	;
	stfd    f10, -32(r1)	;
	stfd    f11, -24(r1)	;
	stfd    f12, -16(r1)	;
	stfd    f13,  -8(r1)	;

	stwu    r1,-56-(13*8)(r1)	; grow the stack. Must be 16-byte-aligned.
#else
	stwu    r1,-64(r1)     ; grow the stack. Must be 16-byte-aligned.
#endif

; Pass parameters to __class_lookupMethodAndLoadCache.  First parameter is
; the class pointer.  Second parameter is the selector.  Where they come
; from depends on who called us.  In the int return case, the selector is
; already in r4.
.if $0 == WORD_RETURN		; WORD_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	lwz     r3,ISA(r3)		; class = receiver->isa
.else							; MSG_SENDSUPER
	lwz     r3,CLASS(r3)	; class = super->class
.endif

.else						; STRUCT_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	lwz     r3,ISA(r4)		; class = receiver->isa
.else							; MSG_SENDSUPER
	lwz     r3,CLASS(r4)	; class = super->class
.endif
	mr      r4,r5			; selector = selector 
.endif

	; We code the call inline rather than using the CALL_EXTERN macro because
	; that leads to a lot of extra unnecessary and inefficient instructions.
	CALL_EXTERN(__class_lookupMethodAndLoadCache)

	mr      r12,r3			; copy implementation to r12
	mtctr   r3				; copy imp to ctr
	lwz     r1,0(r1)		; restore the stack pointer
	lwz     r0,8(r1)		;
	mtlr    r0				; restore return pc

#if !defined(KERNEL)

; Restore FP parameter registers
	lfd     f1, -104(r1)	;
	lfd     f2,  -96(r1)	;
	lfd     f3,  -88(r1)	;
	lfd     f4,  -80(r1)	;
	lfd     f5,  -72(r1)	;
	lfd     f6,  -64(r1)	;
	lfd     f7,  -56(r1)	;
	lfd     f8,  -48(r1)	;
	lfd     f9,  -40(r1)	;
	lfd     f10, -32(r1)	;
	lfd     f11, -24(r1)	;
	lfd     f12, -16(r1)	;
	lfd     f13, -8(r1)		;

	lwz     r3,  24(r1)		; restore parameter registers
	lwz     r4,  28(r1)		;
	lwz     r5,  32(r1)		;
	lwz     r6,  36(r1)		;
	lwz     r7,  40(r1)		;
	lwz     r8,  44(r1)		;
	lwz     r9,  48(r1)		; r9 was saved by CacheLookup
	lwz     r10, 52(r1)		;

#endif /* !KERNEL */

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

	.macro CALL_MCOUNT
#if defined(PROFILE)
	mflr    r0				; save return pc
	stw     r0,8(r1)		;

	stwu    r1,-208(r1)		; push aligned areas, set stack link

	stw     r3, 56(r1)		; save all volatile registers
	stw     r4, 60(r1)		; 
	stw     r5, 64(r1)		;
	stw     r6, 68(r1)		; 
	stw     r7, 72(r1)		;
	stw     r8, 76(r1)		;
	stw     r9, 80(r1)		;
	stw     r10,84(r1)		;
	stw     r11,88(r1)		; save r11 and r12, too
	stw     r12,92(r1)		;

	stfd    f1, 96(r1)		;
	stfd    f2, 104(r1)		;
	stfd    f3, 112(r1)		;
	stfd    f4, 120(r1)		;
	stfd    f5, 128(r1)		;
	stfd    f6, 136(r1)		;
	stfd    f7, 144(r1)		;
	stfd    f8, 152(r1)		;
	stfd    f9, 160(r1)		;
	stfd    f10,168(r1)		;
	stfd    f11,176(r1)		;
	stfd    f12,184(r1)		;
	stfd    f13,192(r1)		;

	mr      r3, r0			; pass our callers address

	CALL_EXTERN(mcount)

	lwz     r3, 56(r1)		; restore all volatile registers
	lwz     r4, 60(r1)		; 
	lwz     r5, 64(r1)		;
	lwz     r6, 68(r1)		; 
	lwz     r7, 72(r1)		;
	lwz     r8, 76(r1)		;
	lwz     r9, 80(r1)		;
	lwz     r10,84(r1)		;
	lwz     r11,88(r1)		; restore r11 and r12, too
	lwz     r12,92(r1)		;

	lfd     f1, 96(r1)		;
	lfd     f2, 104(r1)		;
	lfd     f3, 112(r1)		;
	lfd     f4, 120(r1)		;
	lfd     f5, 128(r1)		;
	lfd     f6, 136(r1)		;
	lfd     f7, 144(r1)		;
	lfd     f8, 152(r1)		;
	lfd     f9, 160(r1)		;
	lfd     f10,168(r1)		;
	lfd     f11,176(r1)		;
	lfd     f12,184(r1)		;
	lfd     f13,192(r1)		;

	lwz     r1,0(r1)		; restore the stack pointer
	lwz     r0,8(r1)		;
	mtlr	r0				; restore return pc
#endif
	.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp)
 *
 * On entry:    r3 = class whose cache is to be searched
 *              r4 = selector to search for
 *              r5 = _objc_msgForward IMP
 *
 * If found, returns method triplet pointer.
 * If not found, returns NULL.
 *
 * NOTE: _cache_getMethod never returns any cache entry whose implementation
 * is _objc_msgForward. It returns (Method)1 instead. This prevents thread-
 * safety and memory management bugs in _class_lookupMethodAndLoadCache. 
 * See _class_lookupMethodAndLoadCache for details.
 *
 * _objc_msgForward is passed as a parameter because it's more efficient
 * to do the (PIC) lookup once in the caller than repeatedly here.
 ********************************************************************/

    .private_extern __cache_getMethod
    ENTRY __cache_getMethod
; do profiling if enabled
    CALL_MCOUNT

; do lookup
    mr     r12,r3	; move class to r12 for CacheLookup
    CacheLookup r4, LGetMethodMiss

; cache hit, method triplet in r2 and imp in r12
    cmplw   r12, r5                 ; check for _objc_msgForward
    mr      r3, r2                  ; optimistically get the return value
    bnelr                           ; Not _objc_msgForward, return the triplet address
    li      r3, 1                   ; Is _objc_msgForward, return (Method)1
    blr
	
LGetMethodMiss:
    li      r3, 0                   ; cache miss or _objc_msgForward, return nil
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

    .private_extern __cache_getImp
    ENTRY __cache_getImp
; do profiling if enabled
    CALL_MCOUNT

; do lookup
    mr     r12,r3	; move class to r12 for CacheLookup
    CacheLookup r4, LGetImpMiss

; cache hit, method triplet in r2 and imp in r12
    mr      r3, r12    ; return method imp address
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
 * On entry: r3 is the message receiver,
 *           r4 is the selector
 ********************************************************************/

; WARNING - This code may be copied as is to the Objective-C runtime pages.
;           The code is copied by rtp_set_up_objc_msgSend() from the 
;           beginning to the blr marker just prior to the cache miss code.  
;           Do not add callouts, global variable accesses, or rearrange
;           the code without updating rtp_set_up_objc_msgSend. 

; Absolute symbols bounding the runtime page version of objc_msgSend.
_objc_msgSend_rtp = 0xfffeff00
_objc_msgSend_rtp_exit = 0xfffeff00+0x100

	ENTRY _objc_msgSend_fixup_rtp
	lwz	r4, 4(r4)		; load _cmd from message_ref
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_fixup_rtp
	
	ENTRY _objc_msgSend
; check whether receiver is nil or selector is to be ignored
	cmplwi  r3,0            ; receiver nil?
	xoris   r11,r4,((kIgnore>>16) & 0xffff) ; clear hi if equal to ignored
	cmplwi  cr1,r11,(kIgnore & 0xffff)      ; selector is to be ignored?
	beq-    LMsgSendNilSelf ; if nil receiver, call handler or return nil
	lwz     r12,ISA(r3)     ; class = receiver->isa
	beqlr-  cr1             ; if ignored selector, return self immediately

; guaranteed non-nil entry point (disabled for now)
; .globl _objc_msgSendNonNil
; _objc_msgSendNonNil:

; do profiling when enabled
	CALL_MCOUNT

; receiver is non-nil: search the cache
LMsgSendReceiverOk:
	; class is already in r12
	CacheLookup r4, LMsgSendCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	; r11 guaranteed non-zero on exit from CacheLookup with a hit
	// li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr						; goto *imp;

; WARNING - The first six instructions of LMsgSendNilSelf are
;       rewritten when objc_msgSend is copied to the runtime pages.
;       These instructions must be maintained AS IS unless the code in
;       rtp_set_up_objc_msgSend is also updated.
;       * `mflr r0` must not be changed (not even to use a different register)
;       * the load of _objc_nilReceiver value must remain six insns long
;       * the value of _objc_nilReceiver must continue to be loaded into r11

; message sent to nil: redirect to nil receiver, if any
LMsgSendNilSelf:
	; DO NOT CHANGE THE NEXT SIX INSTRUCTIONS - see note above
	mflr    r0			; save return address
	bcl     20,31,1f		; 31 is cr7[so]
1:	mflr    r11
	addis   r11,r11,ha16(__objc_nilReceiver-1b)
	lwz     r11,lo16(__objc_nilReceiver-1b)(r11)
	mtlr    r0			; restore return address
	; DO NOT CHANGE THE PREVIOUS SIX INSTRUCTIONS - see note above

	cmplwi  r11,0			; return nil if no new receiver
	beq	LMsgSendReturnZero

	mr	r3,r11			; send to new receiver
	lwz	r12,ISA(r11)		; class = receiver->isa
	b	LMsgSendReceiverOk

LMsgSendReturnZero:
	li	r3, 0
	li	r4, 0
	lis	r12, ha16(kRTAddress_zero)
	lfd	f1, lo16(kRTAddress_zero)(r12)
	lfd	f2, lo16(kRTAddress_zero)(r12)
	
; WARNING - This blr marks the end of the copy to the ObjC runtime pages and
;           also marks the beginning of the cache miss code.  Do not move
;           around without checking the ObjC runtime pages initialization code.
	blr

; cache miss: go search the method lists
LMsgSendCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SEND
	li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr					; goto *imp;

LMsgSendExit:
	END_ENTRY _objc_msgSend

/********************************************************************
 *
 * double objc_msgSend_fpret(id self, SEL op, ...);
 *
 ********************************************************************/

	ENTRY _objc_msgSend_fpret
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_fpret

/********************************************************************
 * struct_type	objc_msgSend_stret(id	self,
 *				SEL	op,
 *					...);
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for r3 to be used as the address of the structure
 * being returned, with the parameters in the succeeding registers.
 *
 * On entry: r3 is the address where the structure is returned,
 *           r4 is the message receiver,
 *           r5 is the selector
 ********************************************************************/

	ENTRY _objc_msgSend_stret_fixup_rtp
	lwz	r5, 4(r5)		; load _cmd from message_ref
	b	_objc_msgSend_stret
	END_ENTRY _objc_msgSend_stret_fixup_rtp
	
	ENTRY _objc_msgSend_stret
; check whether receiver is nil
	cmplwi  r4,0			; receiver nil?
	beq     LMsgSendStretNilSelf	; if so, call handler or just return

; guaranteed non-nil entry point (disabled for now)
; .globl _objc_msgSendNonNil_stret
; _objc_msgSendNonNil_stret:

; do profiling when enabled
	CALL_MCOUNT

; receiver is non-nil: search the cache
LMsgSendStretReceiverOk:
	lwz     r12, ISA(r4)		; class = receiver->isa
	CacheLookup r5, LMsgSendStretCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

; cache miss: go search the method lists
LMsgSendStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SEND
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

; message sent to nil: redirect to nil receiver, if any
LMsgSendStretNilSelf:
	mflr    r0			; load new receiver
	bcl     20,31,1f		; 31 is cr7[so]
1:	mflr    r11
	addis   r11,r11,ha16(__objc_nilReceiver-1b)
	lwz     r11,lo16(__objc_nilReceiver-1b)(r11)
	mtlr    r0

	cmplwi  r11,0			; return if no new receiver
	beqlr

	mr	r4,r11			; send to new receiver
	b	LMsgSendStretReceiverOk

LMsgSendStretExit:
	END_ENTRY _objc_msgSend_stret


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

	ENTRY _objc_msgSendSuper2_fixup_rtp
	; objc_super->class is superclass of the class to search
	lwz	r11, CLASS(r3)
	lwz	r4, 4(r4)		; load _cmd from message_ref
	lwz	r11, 4(r11)		; r11 = cls->super_class
	stw	r11, CLASS(r3)
	b	_objc_msgSendSuper
	END_ENTRY _objc_msgSendSuper2_fixup_rtp
	
	ENTRY _objc_msgSendSuper
; do profiling when enabled
	CALL_MCOUNT

; check whether selector is to be ignored
	xoris	r11,r4,((kIgnore>>16) & 0xffff) ; clear hi if to be ignored
	cmplwi	r11,(kIgnore & 0xffff)          ; selector is to be ignored?
	lwz     r12,CLASS(r3)			;     class = super->class
	beq-	LMsgSendSuperIgnored            ; if ignored, return self

; search the cache
	; class is already in r12
	CacheLookup r4, LMsgSendSuperCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	lwz     r3,RECEIVER(r3)		; receiver is the first arg
	; r11 guaranteed non-zero after cache hit
	; li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr    				; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SENDSUPER
	lwz     r3,RECEIVER(r3)		; receiver is the first arg
	li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr    				; goto *imp;

; ignored selector: return self
LMsgSendSuperIgnored:
	lwz	r3,RECEIVER(r3)
	blr

LMsgSendSuperExit:
	END_ENTRY _objc_msgSendSuper


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

	ENTRY _objc_msgSendSuper2_stret_fixup_rtp
	; objc_super->class is superclass of the class to search
	lwz	r11, CLASS(r4)
	lwz	r5, 4(r5)		; load _cmd from message_ref
	lwz	r11, 4(r11)		; r11 = cls->super_class
	stw	r11, CLASS(r4)
	b	_objc_msgSendSuper_stret
	END_ENTRY _objc_msgSendSuper2_stret_fixup_rtp

	ENTRY _objc_msgSendSuper_stret
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	lwz     r12,CLASS(r4)			; class = super->class
	CacheLookup r5, LMsgSendSuperStretCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	lwz     r4,RECEIVER(r4)		; receiver is the first arg
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SENDSUPER
	lwz     r4,RECEIVER(r4)		; receiver is the first arg
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

LMsgSendSuperStretExit:
	END_ENTRY _objc_msgSendSuper_stret


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
 *	intptr_t	linkageArea[6];
 *	intptr_t	registerArgs[8];
 *	intptr_t	stackArgs[variable];
 * };
 *
 ********************************************************************/

; _FwdSel is @selector(forward::), set up in map_images().
; ALWAYS dereference _FwdSel to get to "forward::" !!
	.data
	.align 2
	.private_extern _FwdSel
_FwdSel: .long 0

	.cstring
	.align 2
LUnkSelStr: .ascii "Does not recognize selector %s\0"

	.data
	.align 2
	.private_extern __objc_forward_handler
__objc_forward_handler:	.long 0

	.data
	.align 2
	.private_extern __objc_forward_stret_handler
__objc_forward_stret_handler:	.long 0
	

	ENTRY __objc_msgForward
	// Non-stret version
	li	r11,kFwdMsgSend
	b	__objc_msgForward_internal
	END_ENTRY _objc_msgForward

	ENTRY __objc_msgForward_stret
	// Struct-return version
	li	r11,kFwdMsgSendStret
	b	__objc_msgForward_internal
	END_ENTRY _objc_msgForward_stret

	
	ENTRY __objc_msgForward_internal
	// Method cache version

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band register %r11 is zero for stret, nonzero otherwise

; do profiling when enabled
	CALL_MCOUNT

	; Check return type (stret or not)
	cmplwi	r11,kFwdMsgSendStret
	beq	LMsgForwardStretSel

	; Non-stret return
	; Call user handler, if any
	LOAD_STATIC_WORD r12, __objc_forward_handler, LOCAL_SYMBOL
	cmplwi	r12, 0
	mtctr	r12
	bnectr			; call _objc_forward_handler if not NULL
	; No user handler
	mr	r11, r3		; r11 = receiver
	mr	r12, r4		; r12 = SEL
	b	LMsgForwardSelCmp

LMsgForwardStretSel:	
	; Stret return
	; Call user handler, if any
	LOAD_STATIC_WORD r12, __objc_forward_stret_handler, LOCAL_SYMBOL
	cmplwi	r12, 0
	mtctr	r12
	bnectr			; call _objc_forward_stret_handler if not NULL
	; No user handler
	mr	r11, r4		; r11 = receiver
	mr	r12, r5		; r12 = SEL

LMsgForwardSelCmp:
	; r11 is the receiver
	; r12 is the selector
	
	; Die if forwarding "forward::"
	LOAD_STATIC_WORD r2, _FwdSel, LOCAL_SYMBOL
	cmplw   r2, r12
	beq     LMsgForwardError

	; Save registers to margs
	; Link register
	mflr    r0
	stw     r0,  8(r1)

	; GPR parameters
	stw     r3, 24(r1)
	stw     r4, 28(r1)
	stw     r5, 32(r1)
	stw     r6, 36(r1)
	stw     r7, 40(r1)
	stw     r8, 44(r1)
	stw     r9, 48(r1)
	stw     r10,52(r1)

	; FP parameters
	stfd    f1, -104(r1)
	stfd    f2,  -96(r1)
	stfd    f3,  -88(r1)
	stfd    f4,  -80(r1)
	stfd    f5,  -72(r1)
	stfd    f6,  -64(r1)
	stfd    f7,  -56(r1)
	stfd    f8,  -48(r1)
	stfd    f9,  -40(r1)
	stfd    f10, -32(r1)
	stfd    f11, -24(r1)
	stfd    f12, -16(r1)
	stfd    f13,  -8(r1)

	; Call [receiver forward:sel :margs]
	mr	r3, r11			; receiver
	mr	r4, r2			; forward::
	mr      r5, r12			; sel
	subi    r6,r1,13*8		; &margs (on stack)

	stwu    r1,-56-(13*8)(r1)	; push stack frame
	bl      _objc_msgSend		; [self forward:sel :objc_sendv_margs]
	addi    r1,r1,56+13*8		; pop stack frame

	lwz     r0,8(r1)		; restore lr
	mtlr    r0			;
	blr     			;

LMsgForwardError:
	; Call __objc_error(receiver, "unknown selector %s", "forward::")
	mr	r3, r11
	LEA_STATIC_DATA r4, LUnkSelStr, LOCAL_SYMBOL
	mr      r5, r2
	CALL_EXTERN(___objc_error)	; never returns
	trap

	END_ENTRY __objc_msgForward_internal


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

	ENTRY _objc_msgSendv

#if !defined(KERNEL)
; do profiling when enabled
	CALL_MCOUNT

	mflr    r0
	stw     r0,8(r1)		; save lr

	cmplwi  r5,32			; check parameter size against minimum
	ble+    LMsgSendvMinFrame	; is less than minimum, go use minimum
	mr      r12,r1			; remember current stack pointer
	sub     r11,r1,r5		; push parameter area
	rlwinm  r1,r11,0,0,27		; align stack pointer to 16 byte boundary
	stwu    r12,-32(r1)		; push aligned linkage area, set stack link 
	b       LMsgSendvHaveFrame

LMsgSendvMinFrame:
	stwu    r1,-64(r1)		; push aligned linkage and parameter areas, set stack link

LMsgSendvHaveFrame:
	; restore floating point register parameters from marg_list
	lfd     f1,  0(r6)		;
	lfd     f2,  8(r6)		;
	lfd     f3, 16(r6)		;
	lfd     f4, 24(r6)		;
	lfd     f5, 32(r6)		;
	lfd     f6, 40(r6)		;
	lfd     f7, 48(r6)		;
	lfd     f8, 56(r6)		;
	lfd     f9, 64(r6)		;
	lfd     f10,72(r6)		;
	lfd     f11,80(r6)		;
	lfd     f12,88(r6)		;
	lfd     f13,96(r6)		; 

; load the register based arguments from the marg_list
; the first two parameters are already in r3 and r4, respectively
	subi    r0,r5,(2*4)-3			; make word count from byte count rounded up to multiple of 4...
	srwi.   r0,r0,2			; ... and subtracting for params already in r3 and r4
	beq     LMsgSendvSendIt		; branch if there are no parameters to load
	mtctr   r0			; counter = number of remaining words
	lwz     r5,32+(13*8)(r6)	; load 3rd parameter
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero
	addi    r11,r6,36+(13*8)	; switch to r11, because we are setting r6
	lwz     r6,0(r11)		; load 4th parameter
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz     r7,4(r11)		; load 5th parameter
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz     r8,8(r11)		; load 6th parameter
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwz     r9,12(r11)		; load 7th parameter
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero
	lwzu    r10,16(r11)		; load 8th parameter, and update r11
	bdz     LMsgSendvSendIt		; decrement counter, branch if result is zero

; copy the stack based arguments from the marg_list
	addi    r12,r1,24+32-4		; target = address of stack based parameters
LMsgSendvArgLoop:
	lwzu    r0,4(r11)		; loop to copy remaining marg_list words to stack
	stwu    r0,4(r12)		;
	bdnz    LMsgSendvArgLoop	; decrement counter, branch if still non-zero

LMsgSendvSendIt:
	bl      _objc_msgSend		; objc_msgSend (self, selector, ...)

	lwz     r1,0(r1)		; restore stack pointer
	lwz     r0,8(r1)		; restore lr
	mtlr    r0				;
	blr     				;
#else
	trap    				; _objc_msgSendv is not for the kernel
#endif

	END_ENTRY _objc_msgSendv

/********************************************************************
 * double objc_msgSendv_fpret(id self, SEL op, unsigned arg_size, 
 *                            marg_list arg_frame);
 ********************************************************************/

	ENTRY _objc_msgSendv_fpret
	b _objc_msgSendv
	END_ENTRY _objc_msgSendv_fpret

/********************************************************************
 * void objc_msgSendv_stret(void	*structStorage,
 *			id		self,
 *			SEL		op,
 *			unsigned	arg_size,
 *			marg_list	arg_frame);
 *
 * objc_msgSendv_stret is the struct-return form of msgSendv.
 * This function does not use the struct-return ABI; instead, the
 * structure return address is passed as a normal parameter.
 * The two are functionally identical on ppc, but not on other architectures.
 *
 * On entry:	r3 is the address in which the returned struct is put,
 *		r4 is the message receiver,
 *		r5 is the selector,
 *		r6 is the size of the marg_list, in bytes,
 *		r7 is the address of the marg_list
 ********************************************************************/

	ENTRY _objc_msgSendv_stret

#if !defined(KERNEL)
; do profiling when enabled
	CALL_MCOUNT

	mflr    r0
	stw     r0,8(r1)		; (save return pc)

	cmplwi  r6,32			; check parameter size against minimum
	ble+    LMsgSendvStretMinFrame	; is less than minimum, go use minimum
	mr      r12,r1			; remember current stack pointer
	sub     r11,r1,r6		; push parameter area
	rlwinm  r1,r11,0,0,27	; align stack pointer to 16 byte boundary
	stwu    r12,-32(r1)		; push aligned linkage area, set stack link 
	b       LMsgSendvStretHaveFrame

LMsgSendvStretMinFrame:
	stwu    r1,-64(r1)		; push aligned linkage and parameter areas, set stack link

LMsgSendvStretHaveFrame:
; restore floating point register parameters from marg_list
	lfd     f1,0(r7)		;
	lfd     f2,8(r7)		;
	lfd     f3,16(r7)		;
	lfd     f4,24(r7)		;
	lfd     f5,32(r7)		;
	lfd     f6,40(r7)		;
	lfd     f7,48(r7)		;
	lfd     f8,56(r7)		;
	lfd     f9,64(r7)		;
	lfd     f10,72(r7)		;
	lfd     f11,80(r7)		;
	lfd     f12,88(r7)		;
	lfd     f13,96(r7)		; 

; load the register based arguments from the marg_list
; the structure return address and the first two parameters
; are already in r3, r4, and r5, respectively.
; NOTE: The callers r3 probably, but not necessarily, matches
; the r3 in the marg_list.  That is, the struct-return
; storage used by the caller could be an intermediate buffer
; that will end up being copied into the original
; struct-return buffer (pointed to by the marg_listed r3).
	subi    r0,r6,(3*4)-3		; make word count from byte count rounded up to multiple of 4...
	srwi.   r0,r0,2			; ... and subtracting for params already in r3 and r4 and r5
	beq     LMsgSendvStretSendIt	; branch if there are no parameters to load
	mtctr   r0					; counter = number of remaining words
	lwz     r6,36+(13*8)(r7)	; load 4th parameter
	bdz     LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	addi    r11,r7,40+(13*8)	; switch to r11, because we are setting r7
	lwz     r7,0(r11)			; load 5th parameter
	bdz     LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwz     r8,4(r11)			; load 6th parameter
	bdz     LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwz     r9,8(r11)			; load 7th parameter
	bdz     LMsgSendvStretSendIt	; decrement counter, branch if result is zero
	lwzu    r10,12(r11)			; load 8th parameter, and update r11
	bdz     LMsgSendvStretSendIt	; decrement counter, branch if result is zero

; copy the stack based arguments from the marg_list
	addi    r12,r1,24+32-4		; target = address of stack based parameters
LMsgSendvStretArgLoop:
	lwzu    r0,4(r11)			; loop to copy remaining marg_list words to stack
	stwu    r0,4(r12)			;
	bdnz    LMsgSendvStretArgLoop	; decrement counter, branch if still non-zero

LMsgSendvStretSendIt:
	bl      _objc_msgSend_stret	; struct_type objc_msgSend_stret (self, selector, ...)

	lwz     r1,0(r1)		; restore stack pointer
	lwz     r0,8(r1)		; restore return pc
	mtlr    r0
	blr     				; return
#else /* KERNEL */
	trap    				; _objc_msgSendv_stret is not for the kernel
#endif /* !KERNEL */

	END_ENTRY _objc_msgSendv_stret


	ENTRY _method_invoke
	
	lwz	r12, METHOD_IMP(r4)
	lwz	r4, METHOD_NAME(r4)
	mtctr	r12
	bctr
	
	END_ENTRY _method_invoke


	ENTRY _method_invoke_stret
	
	lwz	r12, METHOD_IMP(r5)
	lwz	r5, METHOD_NAME(r5)
	mtctr	r12
	bctr
	
	END_ENTRY _method_invoke_stret

#endif
