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
/********************************************************************
 *  objc-msg-ppc64.s - PowerPC code to support objc messaging.
 *  Based on objc-msg-ppc.s, copyright 1988-1996 NeXT Software, Inc.
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
; Substitute receiver for messages sent to nil (usually also nil)
; id _objc_nilReceiver
	.align 4
.private_extern __objc_nilReceiver
__objc_nilReceiver:
	.quad   0

; 8 bytes of zero, for floating-point zero return
L_zero:
	.space 8

; _objc_entryPoints and _objc_exitPoints are used by method dispatch
; caching code to figure out whether any threads are actively 
; in the cache for dispatching.  The labels surround the asm code
; that do cache lookups.  The tables are zero-terminated.
.private_extern _objc_entryPoints
_objc_entryPoints:
	.quad   __cache_getImp
	.quad   __cache_getMethod
	.quad   _objc_msgSend
	.quad   _objc_msgSend_stret
	.quad   _objc_msgSendSuper
	.quad   _objc_msgSendSuper_stret
	.quad   _objc_msgSend_rtp
	.quad   0

.private_extern _objc_exitPoints
_objc_exitPoints:
	.quad   LGetImpExit
	.quad   LGetMethodExit
	.quad   LMsgSendExit
	.quad   LMsgSendStretExit
	.quad   LMsgSendSuperExit
	.quad   LMsgSendSuperStretExit
	.quad   _objc_msgSend_rtp_exit
	.quad   0

/*
 * Handcrafted dyld stubs for each external call.
 * They should be converted into a local branch after linking. aB.
 */

/* asm_help.h version is not what we want */
#undef CALL_EXTERN

#define CALL_EXTERN(name)	bl      L ## name ## $stub

#define LAZY_PIC_FUNCTION_STUB(name) \
.data                         @\
.section __TEXT, __picsymbol_stub, symbol_stubs, pure_instructions, 32 @\
L ## name ## $stub:           @\
	.indirect_symbol name     @\
	mflr    r0                @\
	bcl     20,31,L0$ ## name @\
L0$ ## name:                  @\
	mflr    r11               @\
	addis   r11,r11,ha16(L ## name ## $lazy_ptr-L0$ ## name) @\
	mtlr    r0                @\
	ldu     r12,lo16(L ## name ## $lazy_ptr-L0$ ## name)(r11) @\
	mtctr   r12               @\
	bctr                      @\
.data                         @\
.lazy_symbol_pointer          @\
L ## name ## $lazy_ptr:       @\
	.indirect_symbol name     @\
	.quad dyld_stub_binding_helper

; _class_lookupMethodAndLoadCache
LAZY_PIC_FUNCTION_STUB(__class_lookupMethodAndLoadCache)

#if __OBJC2__
; _objc_fixupMessageRef	
LAZY_PIC_FUNCTION_STUB(__objc_fixupMessageRef)
#endif

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
#define CLASS            8

; Selected field offsets in class structure
#define ISA              0
#if __OBJC2__
#  define CACHE          16
#else
#  define CACHE          64
#endif

; Method descriptor
#define METHOD_NAME      0
#define METHOD_IMP       16

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

// In case the implementation is _objc_msgForward, indicate to it
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

	mflr    r0
	bcl     20,31,1f	; 31 is cr7[so]
1:	mflr    $0
	mtlr    r0
.if $2 == EXTERNAL_SYMBOL
	addis   $0,$0,ha16(L$1-1b)
	ld      $0,lo16(L$1-1b)($0)
	ld      $0,0($0)
.elseif $2 == LOCAL_SYMBOL
	addis   $0,$0,ha16($1-1b)
	ld      $0,lo16($1-1b)($0)
.else
	!!! Unknown symbol type !!!
.endif

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
	mflr    r0
	bcl     20,31,1f	; 31 is cr7[so]
1:	mflr    $0
	mtlr    r0
.if $2 == EXTERNAL_SYMBOL
	addis   $0,$0,ha16(L$1-1b)
	ld      $0,lo16(L$1-1b)($0)
.elseif $2 == LOCAL_SYMBOL
	addis   $0,$0,ha16($1-1b)
	addi    $0,$0,lo16($1-1b)
.else
	!!! Unknown symbol type !!!
.endif

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
; FixupMessageRef receiver, super, ref
;
; Look up a method and fix up a message ref.
;
; Takes: 
;	 receiver = receiver register
;	 super = register address of objc_super2 struct or NULL
;	 ref = message ref register
;	 These arguments must use the REGx macros. Some combinations
;	   are disallowed. 
;
; On exit: 
;	 *ref is fixed up
;	 r12 is imp to call
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	; $0 = receiver register
	; $1 = register address of objc_super2 struct, or NULL
	; $2 = message ref register
	; Returns imp in r12 and ctr.
	; 3,2,4  4,2,5  2,3,4    2,4,5
	; 5<4    3<4    4<3,5<4  
#define REG2 2
#define REG3 3
#define REG4 4
#define REG5 5


.macro MR_REG3
.if $0 == REG2
	mr      r3, r2
.elseif $0 == REG3
	; mr      r3, r3
.elseif $0 == REG4
	mr      r3, r4
.elseif $0 == REG5
	mr      r3, r5
.else
	error unknown register
.endif
.endmacro

.macro MR_REG4
.if $0 == REG2
	mr      r4, r2
.elseif $0 == REG3
	mr      r4, r3
.elseif $0 == REG4
	; mr      r4, r4
.elseif $0 == REG5
	mr      r4, r5
.else
	error unknown register
.endif
.endmacro

.macro MR_REG5
.if $0 == REG2
	mr      r5, r2
.elseif $0 == REG3
	mr      r5, r3
.elseif $0 == REG4
	mr      r5, r4
.elseif $0 == REG5
	; mr      r5, r5
.else
	error unknown register
.endif
.endmacro

#if __OBJC2__
.macro FixupMessageRef
	; Save lr
	mflr    r0
	std     r0,  16(r1)

	; Save parameter registers
	std     r3,  48(r1)
	std     r4,  56(r1)
	std     r5,  64(r1)
	std     r6,  72(r1)
	std     r7,  80(r1)
	std     r8,  88(r1) 
	std     r9,  96(r1)
	std     r10, 104(r1)

	; Save fp parameter registers
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

	; Push stack frame
	stdu    r1,-120-(13*8)(r1)	; must be 16-byte aligned

.if REG5 != $1  &  REG5 != $0  &  REG4 != $0
	MR_REG5 $2
	MR_REG4 $1
	MR_REG3 $0
.elseif REG3 != $1  &  REG3 != $2  &  REG4 != $2
	MR_REG3 $0
	MR_REG4 $1
	MR_REG5 $2
.else
	error register collision
.endif

	CALL_EXTERN(__objc_fixupMessageRef)

	; Save returned IMP in r12 and ctr
	mtctr   r3
	mr      r12, r3

	; Pop stack frame
	ld      r1,0(r1)

	; Restore lr
	ld      r0,16(r1)
	mtlr    r0

	; Restore fp parameter registers
	lfd     f1, -104(r1)
	lfd     f2,  -96(r1)
	lfd     f3,  -88(r1)
	lfd     f4,  -80(r1)
	lfd     f5,  -72(r1)
	lfd     f6,  -64(r1)
	lfd     f7,  -56(r1)
	lfd     f8,  -48(r1)
	lfd     f9,  -40(r1)
	lfd     f10, -32(r1)
	lfd     f11, -24(r1)
	lfd     f12, -16(r1)
	lfd     f13, -8(r1)

	; Restore parameter registers
	ld     r3,  48(r1)
	ld     r4,  56(r1)
	ld     r5,  64(r1)
	ld     r6,  72(r1)
	ld     r7,  80(r1)
	ld     r8,  88(r1)
	ld     r9,  96(r1)
	ld     r10, 104(r1)

.endmacro
#endif


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
	std     r6,72(r1)		; save r6 for use as cache pointer
	std     r7,80(r1)		; save r7 for use as probe count
	li      r7,0			; no probes so far!
#endif

	ld      r2,CACHE(r12)		; cache = class->cache
	std     r9,96(r1)		; save r9

#if defined(OBJC_INSTRUMENTED)
	mr      r6,r2			; save cache pointer
#endif

	lwz     r11,MASK(r2)		; mask = cache->mask
	addi    r0,r2,BUCKETS		; buckets = cache->buckets
	sldi    r11,r11,3		; r11 = mask << 3 
	and     r9,$0,r11		; bytes = sel & (mask<<3)

#if defined(OBJC_INSTRUMENTED)
	b       LLoop_$0_$1

LMiss_$0_$1:
	; r6 = cache, r7 = probeCount
	lwz     r9,MASK(r6)		; entryCount = mask + 1
	addi    r9,r9,1			;
	sldi    r9,r9,2			; tableSize = entryCount * sizeof(entry)
	addi    r9,r9,BUCKETS		; offset = buckets + tableSize
	add     r11,r6,r9		; cacheData = &cache->buckets[mask+1]
	ld      r9,missCount(r11)	; cacheData->missCount += 1
	addi    r9,r9,1			; 
	std     r9,missCount(r11)	; 
	ld      r9,missProbes(r11)	; cacheData->missProbes += probeCount
	add     r9,r9,r7		; 
	std     r9,missProbes(r11)	; 
	ld      r9,maxMissProbes(r11)	; if (probeCount > cacheData->maxMissProbes)
	cmpld   r7,r9			; maxMissProbes = probeCount
	ble     .+8			; 
	std     r7,maxMissProbes(r11)	;

	ld      r6,72(r1)		; restore r6
	ld      r7,80(r1)		; restore r7

	b       $1			; goto cacheMissLabel
#endif
	
; search the cache
LLoop_$0_$1:
#if defined(OBJC_INSTRUMENTED)
	addi    r7,r7,1			; probeCount += 1
#endif

	ldx     r2,r9,r0		; method = buckets[bytes/8]
	addi    r9,r9,8			; bytes += 8
	cmpldi  r2,0			; if (method == NULL)
#if defined(OBJC_INSTRUMENTED)
	beq-    LMiss_$0_$1
#else
	beq-    $1			; goto cacheMissLabel
#endif

	ld      r12,METHOD_NAME(r2)	; name  = method->method_name
	and     r9,r9,r11		; bytes &= (mask<<3)
	cmpld   r12,$0			; if (name != selector)
	bne-    LLoop_$0_$1		; goto loop

; cache hit, r2 == method triplet address
; Return triplet in r2 and imp in r12
	ld      r12,METHOD_IMP(r2)	; imp = method->method_imp

#if defined(OBJC_INSTRUMENTED)
	; r6 = cache, r7 = probeCount
	lwz     r9,MASK(r6)		; entryCount = mask + 1
	addi    r9,r9,1			;
	sldi    r9,r9,2			; tableSize = entryCount * sizeof(entry)
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

	ld      r6,72(r1)		; restore r6
	ld      r7,80(r1)		; restore r7
#endif

	ld      r9,96(r1)		; restore r9

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
	std     r0,  16(r1)     ;

	std     r3,  48(r1)     ; save arguments
	std     r4,  56(r1)     ; 
	std     r5,  64(r1)     ;
	std     r6,  72(r1)     ;
	std     r7,  80(r1)     ;
	std     r8,  88(r1)     ;
	; r9 was saved by CacheLookup
	std     r10, 104(r1)    ;

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

	stdu    r1,-120-(13*8)(r1)	; grow the stack. Must be 16-byte-aligned.

; Pass parameters to __class_lookupMethodAndLoadCache.  First parameter is
; the class pointer.  Second parameter is the selector.  Where they come
; from depends on who called us.  In the int return case, the selector is
; already in r4.
.if $0 == WORD_RETURN		; WORD_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	ld      r3,ISA(r3)		; class = receiver->isa
.else							; MSG_SENDSUPER
	ld      r3,CLASS(r3)	; class = super->class
.endif

.else						; STRUCT_RETURN
.if $1 == MSG_SEND				; MSG_SEND
	ld      r3,ISA(r4)		; class = receiver->isa
.else							; MSG_SENDSUPER
	ld      r3,CLASS(r4)	; class = super->class
.endif
	mr      r4,r5			; selector = selector 
.endif

	; We code the call inline rather than using the CALL_EXTERN macro because
	; that leads to a lot of extra unnecessary and inefficient instructions.
	CALL_EXTERN(__class_lookupMethodAndLoadCache)

	mr      r12,r3			; copy implementation to r12
	mtctr   r3				; copy imp to ctr
	ld      r1,0(r1)		; restore the stack pointer
	ld      r0,16(r1)		;
	mtlr    r0				; restore return pc

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

	ld      r3,  48(r1)		; restore parameter registers
	ld      r4,  56(r1)		;
	ld      r5,  64(r1)		;
	ld      r6,  72(r1)		;
	ld      r7,  80(r1)		;
	ld      r8,  88(r1)		;
	ld      r9,  96(r1)		; r9 was saved by CacheLookup
	ld      r10, 104(r1)		;

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
	std     r0, 16(r1)		;

	stdu    r1,-304(r1)		; push aligned areas, set stack link

	std     r3, 112(r1)		; save all volatile registers
	std     r4, 120(r1)		; 
	std     r5, 128(r1)		;
	std     r6, 136(r1)		; 
	std     r7, 144(r1)		;
	std     r8, 152(r1)		;
	std     r9, 160(r1)		;
	std     r10,168(r1)		;
	std     r11,176(r1)		; save r11 and r12, too
	std     r12,184(r1)		;

	stfd    f1, 192(r1)		;
	stfd    f2, 200(r1)		;
	stfd    f3, 208(r1)		;
	stfd    f4, 216(r1)		;
	stfd    f5, 224(r1)		;
	stfd    f6, 232(r1)		;
	stfd    f7, 240(r1)		;
	stfd    f8, 248(r1)		;
	stfd    f9, 256(r1)		;
	stfd    f10,264(r1)		;
	stfd    f11,272(r1)		;
	stfd    f12,280(r1)		;
	stfd    f13,288(r1)		;

	mr      r3, r0			; pass our callers address

	CALL_EXTERN(mcount)

	ld      r3, 112(r1)		; restore all volatile registers
	ld      r4, 120(r1)		; 
	ld      r5, 128(r1)		;
	ld      r6, 136(r1)		; 
	ld      r7, 144(r1)		;
	ld      r8, 152(r1)		;
	ld      r9, 160(r1)		;
	ld      r10,168(r1)		;
	ld      r11,176(r1)		; restore r11 and r12, too
	ld      r12,184(r1)		;

	lfd     f1, 192(r1)		;
	lfd     f2, 200(r1)		;
	lfd     f3, 208(r1)		;
	lfd     f4, 216(r1)		;
	lfd     f5, 224(r1)		;
	lfd     f6, 232(r1)		;
	lfd     f7, 240(r1)		;
	lfd     f8, 248(r1)		;
	lfd     f9, 256(r1)		;
	lfd     f10,264(r1)		;
	lfd     f11,272(r1)		;
	lfd     f12,280(r1)		;
	lfd     f13,288(r1)		;

	ld      r1, 0(r1)		; restore the stack pointer
	ld      r0, 16(r1)		;
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
 * is _objc_msgForward. It returns NULL instead. This prevents thread-
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
    mr      r12,r3	; move class to r12 for CacheLookup
    CacheLookup r4, LGetMethodMiss

; cache hit, method triplet in r2 and imp in r12
    cmpld   r12, r5                 ; check for _objc_msgForward
    mr      r3, r2                  ; optimistically get the return value
    bnelr                           ; Not _objc_msgForward, return the triplet address

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
_objc_msgSend_rtp = 0xfffffffffffeff00
_objc_msgSend_rtp_exit = 0xfffffffffffeff00+0x100
	
	ENTRY _objc_msgSend
; check whether receiver is nil or selector is to be ignored
	cmpldi  r3,0            ; receiver nil?
	  not     r11, r4
	  xoris   r11, r11, ((~kIgnore >> 16) & 0xffff)
	beq-    LMsgSendNilSelf ; if nil receiver, call handler or return nil
	ld      r12,ISA(r3)     ; class = receiver->isa
	  cmpldi  r11, (~kIgnore & 0xffff)
	  beqlr-		; if ignored selector, return self immediately

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
	ld      r11,lo16(__objc_nilReceiver-1b)(r11)
	mtlr    r0			; restore return address
	; DO NOT CHANGE THE PREVIOUS SIX INSTRUCTIONS - see note above

	cmpldi  r11,0			; return nil if no new receiver
	beq	LMsgSendReturnZero

	mr	r3,r11			; send to new receiver
	ld 	r12,ISA(r11)		; class = receiver->isa
	b	LMsgSendReceiverOk

LMsgSendReturnZero:
	li	r3, 0
	li	r4, 0
	; fixme this breaks RTP
	LEA_STATIC_DATA r11, L_zero, LOCAL_SYMBOL
	lfd	f1, 0(r11)
	lfd	f2, 0(r11)

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


#if __OBJC2__
	ENTRY _objc_msgSend_fixup
	
	cmpldi	r3, 0
	li	r2, 0
	beq-	LMsgSendFixupNilSelf	

	; r3 = receiver
	; r2 = 0 (not msgSend_super)
	; r4 = address of message ref
	FixupMessageRef REG3, REG2, REG4

	; imp is in r12 and ctr
	; Load _cmd from the message_ref
	ld	r4, 8(r4)
	; Be ready for objc_msgForward
	li	r11, kFwdMsgSend
	bctr

LMsgSendFixupNilSelf:
	li	r3, 0
	li	r4, 0
	LEA_STATIC_DATA r11, L_zero, LOCAL_SYMBOL
	lfd	f1, 0(r11)
	lfd	f2, 0(r11)
	blr
	
	END_ENTRY _objc_msgSend_fixup


	ENTRY _objc_msgSend_fixedup
	; Load _cmd from the message_ref
	ld	r4, 8(r4)
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_fixedup
#endif


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

	ENTRY _objc_msgSend_stret
; check whether receiver is nil
	cmpldi  r4,0			; receiver nil?
	beq     LMsgSendStretNilSelf	; if so, call handler or just return

; guaranteed non-nil entry point (disabled for now)
; .globl _objc_msgSendNonNil_stret
; _objc_msgSendNonNil_stret:

; do profiling when enabled
	CALL_MCOUNT

; receiver is non-nil: search the cache
LMsgSendStretReceiverOk:
	ld      r12, ISA(r4)		; class = receiver->isa
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
	ld      r11,lo16(__objc_nilReceiver-1b)(r11)
	mtlr    r0

	cmpldi  r11,0			; return nil if no new receiver
	beqlr

	mr	r4,r11			; send to new receiver
	b	LMsgSendStretReceiverOk

LMsgSendStretExit:
	END_ENTRY _objc_msgSend_stret


#if __OBJC2__
	ENTRY _objc_msgSend_stret_fixup
	
	cmpldi	r4, 0
	li	r2, 0
	beqlr-	; return if nil receiver

	; r4 = receiver
	; r2 = 0 (not msgSend_super)
	; r5 = address of message ref
	FixupMessageRef REG4, REG2, REG5

	; imp is in r12 and ctr
	; Load _cmd from the message_ref
	ld	r5, 8(r5)
	; Be ready for objc_msgForward
	li	r11, kFwdMsgSendStret
	bctr
	
	END_ENTRY _objc_msgSend_stret_fixup


	ENTRY _objc_msgSend_stret_fixedup
	; Load _cmd from the message_ref
	ld	r5, 8(r5)
	b	_objc_msgSend_stret
	END_ENTRY _objc_msgSend_stret_fixedup
#endif


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


	ENTRY _objc_msgSendSuper
; do profiling when enabled
	CALL_MCOUNT

; check whether selector is to be ignored
	not     r11, r4
	xoris   r11, r11, ((~kIgnore >> 16) & 0xffff)
	  ld      r12,CLASS(r3)			;     class = super->class
	cmpldi  r11, (~kIgnore & 0xffff)
	beqlr-		; if ignored selector, return self immediately

; search the cache
	; class is already in r12
	CacheLookup r4, LMsgSendSuperCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	ld      r3,RECEIVER(r3)		; receiver is the first arg
	; r11 guaranteed non-zero after cache hit
	; li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr    				; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SENDSUPER
	ld      r3,RECEIVER(r3)		; receiver is the first arg
	li      r11,kFwdMsgSend		; indicate word-return to _objc_msgForward
	bctr    				; goto *imp;

; ignored selector: return self
LMsgSendSuperIgnored:
	ld 	r3,RECEIVER(r3)
	blr

LMsgSendSuperExit:
	END_ENTRY _objc_msgSendSuper


#if __OBJC2__
	ENTRY _objc_msgSendSuper2_fixup

	ld	r2, RECEIVER(r3)

	; r2 = receiver
	; r3 = address of objc_super2 
	; r4 = address of message ref
	FixupMessageRef REG2, REG3, REG4

	; imp is in r12 and ctr
	; Load _cmd from the message_ref
	ld	r4, 8(r4)
	; Load receiver from objc_super2
	ld	r3, RECEIVER(r3)
	bctr
	
	END_ENTRY _objc_msgSendSuper2_fixup

	
	ENTRY _objc_msgSendSuper2_fixedup
	; objc_super->class is superclass of the class to search
	ld	r11, CLASS(r3)		; cls = objc_super->class
	ld	r4, 8(r4)		; load _cmd from message_ref
	ld	r11, 8(r11)		; cls = cls->superclass
	std	r11, CLASS(r3)		; objc_super->class = cls
	; objc_super->class is now the class to search
	b	_objc_msgSendSuper
	END_ENTRY _objc_msgSendSuper2_fixedup
#endif


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

	ENTRY _objc_msgSendSuper_stret
; do profiling when enabled
	CALL_MCOUNT

; search the cache
	ld      r12,CLASS(r4)			; class = super->class
	CacheLookup r5, LMsgSendSuperStretCacheMiss
	; CacheLookup placed imp in r12
	mtctr   r12
	ld      r4,RECEIVER(r4)		; receiver is the first arg
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

; cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SENDSUPER
	ld      r4,RECEIVER(r4)		; receiver is the first arg
	li      r11,kFwdMsgSendStret	; indicate struct-return to _objc_msgForward
	bctr    				; goto *imp;

LMsgSendSuperStretExit:
	END_ENTRY _objc_msgSendSuper_stret


#if __OBJC2__
	ENTRY _objc_msgSendSuper2_stret_fixup

	ld	r2, RECEIVER(r4)
	
	; r2 = receiver
	; r4 = address of objc_super2
	; r5 = address of message ref
	FixupMessageRef REG2, REG4, REG5

	; imp is in r12 and ctr
	; Load _cmd from the message_ref
	ld	r5, 8(r5)
	; Load receiver from objc_super2
	ld	r4, RECEIVER(r4)
	bctr

	END_ENTRY _objc_msgSendSuper2_stret_fixup


	ENTRY _objc_msgSendSuper2_stret_fixedup
	; objc_super->class is superclass of the class to search
	ld	r11, CLASS(r4)		; cls = objc_super->class
	ld	r5, 8(r5)		; load _cmd from message_ref
	ld	r11, 8(r11)		; cls = cls->superclass
	std	r11, CLASS(r4)		; objc_super->class = cls
	; objc_super->class is now the class to search
	b	_objc_msgSendSuper_stret
	END_ENTRY _objc_msgSendSuper2_stret_fixedup
#endif


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

	ENTRY __objc_msgForward
; do profiling when enabled
	CALL_MCOUNT

	; Check return type (stret or not)
	cmpldi	r11, kFwdMsgSendStret
	beq	LMsgForwardStretSel

	; Non-stret return
	; Call user handler, if any
	LOAD_STATIC_WORD r12, __objc_forward_handler, LOCAL_SYMBOL
	cmpldi	r12, 0
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
	cmpldi	r12, 0
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
	cmpld	r2, r12
	beq	LMsgForwardError

	; Save registers to margs
	; Link register
	mflr    r0
	std     r0, 16(r1)

	; GPR parameters
	std     r3, 48(r1)
	std     r4, 56(r1)
	std     r5, 64(r1)
	std     r6, 72(r1)
	std     r7, 80(r1)
	std     r8, 88(r1)
	std     r9, 96(r1)
	std     r10,104(r1)

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
	mr	r5, r12			; sel
	subi    r6,r1,13*8		; &margs (on stack)

	stdu    r1,-120-(13*8)(r1)	; push stack frame
	bl      _objc_msgSend		; [self forward:sel :objc_sendv_margs]
	addi    r1,r1,120+13*8		; pop stack frame

	ld      r0,16(r1)		; restore lr
	mtlr    r0			;
	blr     			;


LMsgForwardError:
	; Call __objc_error(receiver, "unknown selector %s", "forward::")
	mr	r3, r11
	LEA_STATIC_DATA r4, LUnkSelStr, LOCAL_SYMBOL
	mr      r5, r2
	CALL_EXTERN(___objc_error)	; never returns
	trap

	END_ENTRY __objc_msgForward


	ENTRY _method_invoke
	
	ld	r12, METHOD_IMP(r4)
	ld	r4, METHOD_NAME(r4)
	mtctr	r12
	bctr
	
	END_ENTRY _method_invoke


	ENTRY _method_invoke_stret
	
	ld	r12, METHOD_IMP(r5)
	ld	r5, METHOD_NAME(r5)
	mtctr	r12
	bctr
	
	END_ENTRY _method_invoke_stret
