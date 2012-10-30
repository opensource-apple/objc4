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
	occupied        = 4
	buckets         = 8		// variable length array

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


#if defined(OBJC_INSTRUMENTED)
// Cache instrumentation data, follows buckets
	hitCount        = 0
	hitProbes       = hitCount + 4
	maxHitProbes    = hitProbes + 4
	missCount       = maxHitProbes + 4
	missProbes      = missCount + 4
	maxMissProbes   = missProbes + 4
	flushCount      = maxMissProbes + 4
	flushedEntries  = flushCount + 4

// Buckets in CacheHitHistogram and CacheMissHistogram
	CACHE_HISTOGRAM_SIZE = 512
#endif


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

//////////////////////////////////////////////////////////////////////
//
// CALL_MCOUNTER
//
// Calls mcount() profiling routine. Must be called immediately on
// function entry, before any prologue executes.
//
//////////////////////////////////////////////////////////////////////

.macro CALL_MCOUNTER
#ifdef PROFILE
	// Current stack contents: ret
	pushq	%rbp
	movq	%rsp,%rbp
	// Current stack contents: ret, rbp
	call	mcount
	movq	%rbp,%rsp
	popq	%rbp
#endif
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
/*
 * old->ret 0   +208
 * 16 ->rbp -8  +200
 * 	a6  -16 +192
 * 	a5  -24 +184
 * 	a4  -32 +176
 * 	a3  -40 +168
 * 	a2  -48 +160
 * 	a1  -56 +152
 * 	rax -64 +144
 * 	r10 -72 +136
 * 	pad -80 +128
 * 	xmm7 -88 +112 
 * 	xmm6 -104 +96
 * 	xmm5 -120 +80
 * 	xmm4 -136 +64
 * 	xmm3 -152 +48
 * 	xmm2 -168 +32
 * 	xmm1 -184 +16
 * new->xmm0 -200 +0
 */
.macro SaveRegisters
.if $0 == 0
	movq	%a6, -16(%rsp)
	movq	%a5, -24(%rsp)
	movq	%a4, -32(%rsp)
.else
	// a4-a6 already saved by CacheLookup
.endif
	movq	%a3, -40(%rsp)
	movq	%a2, -48(%rsp)
	movq	%a1, -56(%rsp)
	movq	%rax, -64(%rsp)		// might be xmm parameter count
	movq	%r10, -72(%rsp)		// fixme needed?
	// movq	pad, -80(%rsp)
	
	subq	$$ 128+88, %rsp

	// stack is now 16-byte aligned
	movdqa	%xmm0, 0(%rsp)
	movdqa	%xmm1, 16(%rsp)
	movdqa	%xmm2, 32(%rsp)
	movdqa	%xmm3, 48(%rsp)
	movdqa	%xmm4, 64(%rsp)
	movdqa	%xmm5, 80(%rsp)
	movdqa	%xmm6, 96(%rsp)
	movdqa	%xmm7, 112(%rsp)
.endmacro

/////////////////////////////////////////////////////////////////////
//
// RestoreRegisters
//
// Pops a stack frame pushed by SaveRegisters
//
// On entry:
//	    %rsp is unchanged since SaveRegisters
//
// On exit: 
//	    stack = ret
//	
/////////////////////////////////////////////////////////////////////

.macro RestoreRegisters
	movdqa	0(%rsp), %xmm0
	movdqa	16(%rsp), %xmm1
	movdqa	32(%rsp), %xmm2
	movdqa	48(%rsp), %xmm3
	movdqa	64(%rsp), %xmm4
	movdqa	80(%rsp), %xmm5
	movdqa	96(%rsp), %xmm6
	movdqa	112(%rsp), %xmm7

	addq	$$ 128+88, %rsp

	movq	-16(%rsp), %a6
	movq	-24(%rsp), %a5
	movq	-32(%rsp), %a4
	movq	-40(%rsp), %a3
	movq	-48(%rsp), %a2
	movq	-56(%rsp), %a1
	movq	-64(%rsp), %rax
	movq	-72(%rsp), %r10
	// movq	-80(%rsp), pad
.endmacro


/////////////////////////////////////////////////////////////////////
//
//
// CacheLookup	selectorRegister, cacheMissLabel, name
//
// Locate the implementation for a selector in a class method cache.
//
// Takes: 
//	  $0 = register containing selector (%a1 or %a2 ONLY)
//	  cacheMissLabel = label to branch to iff method is not cached
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

	movq	cache(%r11), %a4	// cache = class->cache

#if defined(OBJC_INSTRUMENTED)
	pushl	%ebx			// save non-volatile register
	pushl	%eax			// save cache pointer
	xorl	%ebx, %ebx		// probeCount = 0
#endif

	leaq	buckets(%a4), %a5	// buckets = &cache->buckets
	movl	mask(%a4), %a6d
	shlq	$$3, %a6		// %a6 = cache->mask << 3
	mov	$0, %a4			// bytes = sel
	andq	%a6, %a4		// bytes &= (mask << 3)
	
// search the receiver's cache
// r11 = method (soon)
// a4 = bytes
// a5 = buckets
// a6 = mask << 3
// $0 = sel
LMsgSendProbeCache_$1:
#if defined(OBJC_INSTRUMENTED)
	addl	$$1, %ebx			// probeCount += 1
#endif
	movq	(%a5, %a4, 1), %r11		// method = buckets[bytes/8]
	testq	%r11, %r11			// if (method == NULL)
#if defined(OBJC_INSTRUMENTED)
	je	LMsgSendCacheMiss_$1
#else
	je	$1				//   goto cacheMissLabel
#endif

	addq	$$8, %a4			// bytes += 8
	andq	%a6, %a4			// bytes &= (mask << 3)
	cmpq	method_name(%r11), $0		// if (method_name != sel)
	jne	LMsgSendProbeCache_$1	//   goto loop

	// cache hit, r11 = method triplet
#if defined(OBJC_INSTRUMENTED)
	jmp	LMsgSendInstrumentCacheHit_$1
LMsgSendCacheHit2_$1:
#endif

	// restore saved registers
	movq	-32(%rsp), %a4
	movq	-24(%rsp), %a5
	movq	-16(%rsp), %a6

	// Done. Only instrumentation follows.
	
#if defined(OBJC_INSTRUMENTED)
	jmp	LMsgSendCacheDone_$1

LMsgSendInstrumentCacheHit_$1:
	popl	%edx			// retrieve cache pointer
	movl	mask(%edx), %esi		// mask = cache->mask
	testl	%esi, %esi		// a mask of zero is only for the...
	je	LMsgSendHitInstrumentDone_$1	// ... emptyCache, do not record anything

	// locate and update the CacheInstrumentation structure
	addl	$$1, %esi			// entryCount = mask + 1
	shll	$$2, %esi		// tableSize = entryCount * sizeof(entry)
	addl	$buckets, %esi		// offset = buckets + tableSize
	addl	%edx, %esi		// cacheData = &cache->buckets[mask+1]

	movl	hitCount(%esi), %edi
	addl	$$1, %edi
	movl	%edi, hitCount(%esi)	// cacheData->hitCount += 1
	movl	hitProbes(%esi), %edi
	addl	%ebx, %edi
	movl	%edi, hitProbes(%esi)	// cacheData->hitProbes += probeCount
	movl	maxHitProbes(%esi), %edi// if (cacheData->maxHitProbes < probeCount)
	cmpl	%ebx, %edi
	jge	LMsgSendMaxHitProbeOK_$1
	movl	%ebx, maxHitProbes(%esi)// cacheData->maxHitProbes = probeCount
LMsgSendMaxHitProbeOK_$1:

	// update cache hit probe histogram
	cmpl	$CACHE_HISTOGRAM_SIZE, %ebx	// pin probeCount to max index
	jl	LMsgSendHitHistoIndexSet_$1
	movl	$(CACHE_HISTOGRAM_SIZE-1), %ebx
LMsgSendHitHistoIndexSet_$1:
	LEA_STATIC_DATA	%esi, _CacheHitHistogram, EXTERNAL_SYMBOL
	shll	$$2, %ebx		// convert probeCount to histogram index
	addl	%ebx, %esi		// calculate &CacheHitHistogram[probeCount<<2]
	movl	0(%esi), %edi		// get current tally
	addl	$$1, %edi			// 
	movl	%edi, 0(%esi)		// tally += 1
LMsgSendHitInstrumentDone_$1:
	popl	%ebx			// restore non-volatile register
	jmp	LMsgSendCacheHit2_$1


LMsgSendCacheMiss_$1:
	popl	%edx			// retrieve cache pointer
	movl	mask(%edx), %esi		// mask = cache->mask
	testl	%esi, %esi		// a mask of zero is only for the...
	je	LMsgSendMissInstrumentDone_$1	// ... emptyCache, do not record anything

	// locate and update the CacheInstrumentation structure
	addl	$$1, %esi			// entryCount = mask + 1
	shll	$$2, %esi		// tableSize = entryCount * sizeof(entry)
	addl	$buckets, %esi		// offset = buckets + tableSize
	addl	%edx, %esi		// cacheData = &cache->buckets[mask+1]

	movl	missCount(%esi), %edi	// 
	addl	$$1, %edi			// 
	movl	%edi, missCount(%esi)	// cacheData->missCount += 1
	movl	missProbes(%esi), %edi	// 
	addl	%ebx, %edi		// 
	movl	%edi, missProbes(%esi)	// cacheData->missProbes += probeCount
	movl	maxMissProbes(%esi), %edi// if (cacheData->maxMissProbes < probeCount)
	cmpl	%ebx, %edi		// 
	jge	LMsgSendMaxMissProbeOK_$1	// 
	movl	%ebx, maxMissProbes(%esi)// cacheData->maxMissProbes = probeCount
LMsgSendMaxMissProbeOK_$1:

	// update cache miss probe histogram
	cmpl	$CACHE_HISTOGRAM_SIZE, %ebx	// pin probeCount to max index
	jl	LMsgSendMissHistoIndexSet_$1
	movl	$(CACHE_HISTOGRAM_SIZE-1), %ebx
LMsgSendMissHistoIndexSet_$1:
	LEA_STATIC_DATA	%esi, _CacheMissHistogram, EXTERNAL_SYMBOL
	shll	$$2, %ebx		// convert probeCount to histogram index
	addl	%ebx, %esi		// calculate &CacheMissHistogram[probeCount<<2]
	movl	0(%esi), %edi		// get current tally
	addl	$$1, %edi			// 
	movl	%edi, 0(%esi)		// tally += 1
LMsgSendMissInstrumentDone_$1:
	popl	%ebx			// restore non-volatile register
	jmp	$0

LMsgSendCacheDone_$1:	
#endif

	
.endmacro


/////////////////////////////////////////////////////////////////////
//
// MethodTableLookup classRegister, selectorRegister
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

	SaveRegisters 1

	// _class_lookupMethodAndLoadCache(class, selector)
	movq	$0, %a1
	movq	$1, %a2
	call	__class_lookupMethodAndLoadCache

	// IMP is now in %rax
	movq	%rax, %r11

	RestoreRegisters

.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp)
 *
 * On entry:	a1 = class whose cache is to be searched
 *		a2 = selector to search for
 *		a3 = _objc_msgForward IMP
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
        
	ENTRY __cache_getMethod

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup %a2, LGetMethodMiss

// cache hit, method triplet in %r11
	cmpq    method_imp(%r11), %a3	// if (imp == _objc_msgForward)
	je      LGetMethodMiss          //     return nil
	movq	%r11, %rax		// return method triplet address
	ret

LGetMethodMiss:
// cache miss, return nil
	xorq    %rax, %rax      // erase %rax
	ret

LGetMethodExit:
	END_ENTRY __cache_getMethod


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

// do lookup
	movq	%a1, %r11		// move class to r11 for CacheLookup
	CacheLookup %a2, LGetImpMiss

// cache hit, method triplet in %r11
	movq	method_imp(%r11), %rax	// return method imp address
	ret

LGetImpMiss:
// cache miss, return nil
	xorq    %rax, %rax      // erase %rax
	ret

LGetImpExit:
	END_ENTRY __cache_getImp


/********************************************************************
 *
 * id objc_msgSend(id self, SEL	_cmd,...);
 *
 ********************************************************************/
	
	ENTRY	_objc_msgSend
	CALL_MCOUNTER

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendReturnSelf	// ignore and return self

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, LMsgSendCacheMiss
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LMsgSendCacheMiss:
	MethodTableLookup isa(%a1), %a2
	// MethodTableLookup placed IMP in r11
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
	END_ENTRY	_objc_msgSend

#if __OBJC2__
	ENTRY _objc_msgSend_fixup

	testq	%a1, %a1
	je	LMsgSendFixupNilSelf

	SaveRegisters 0
	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	jmp 	*%r11

LMsgSendFixupNilSelf:
	// message sent to nil - return 0
	movq	$0, %rax
	movq	$0, %rdx
	xorps	%xmm0, %xmm0
	xorps	%xmm1, %xmm1
	ret
	
	END_ENTRY _objc_msgSend_fixup


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
	CALL_MCOUNTER

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendSuperReturnSelf

// search the cache (objc_super in %a1)
	movq	class(%a1), %r11	// class = objc_super->class
	CacheLookup %a2, LMsgSendSuperCacheMiss
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	movq	receiver(%a1), %a1	// load real receiver
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	MethodTableLookup class(%a1), %a2
	// MethodTableLookup placed IMP in r11
	movq	receiver(%a1), %a1	// load real receiver
	jmp	*%r11			// goto *imp

LMsgSendSuperReturnSelf:
	movq    receiver(%a1), %rax
	ret
	
LMsgSendSuperExit:
	END_ENTRY	_objc_msgSendSuper

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_fixup

	SaveRegisters 0
	// a1 = address of objc_super2
	// a2 = address of message ref
	movq	%a2, %a3
	movq	%a1, %a2
	movq	receiver(%a1), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
	// Load receiver from objc_super2
	movq	receiver(%a1), %a1
	jmp 	*%r11
	
	END_ENTRY _objc_msgSendSuper2_fixup


	ENTRY _objc_msgSendSuper2_fixedup
	// objc_super->class is superclass of class to search
	movq	class(%a1), %r11	// cls = objc_super->class
	movq	8(%a2), %a2		// load _cmd from message_ref
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a1)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper
	END_ENTRY _objc_msgSendSuper2_fixedup
#endif


/********************************************************************
 *
 * double objc_msgSend_fpret(id self, SEL _cmd,...);
 * Used for `long double` return only. `float` and `double` use objc_msgSend.
 *
 ********************************************************************/

	ENTRY	_objc_msgSend_fpret
	CALL_MCOUNTER

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendFpretReturnZero

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendFpretNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendFpretReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, LMsgSendFpretCacheMiss
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LMsgSendFpretCacheMiss:
	MethodTableLookup isa(%a1), %a2
	// MethodTableLookup placed IMP in r11
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
	END_ENTRY	_objc_msgSend_fpret
	
#if __OBJC2__
	ENTRY _objc_msgSend_fpret_fixup

	testq	%a1, %a1
	je	LMsgSendFpretFixupNilSelf

	SaveRegisters 0
	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
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
	
	END_ENTRY _objc_msgSend_fpret_fixup


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
	CALL_MCOUNTER

// check whether selector is ignored
	cmpq    $ kIgnore, %a2
	je      LMsgSendFp2retReturnZero

// check whether receiver is nil 
	testq	%a1, %a1
	je	LMsgSendFp2retNilSelf

// receiver (in %a1) is non-nil: search the cache
LMsgSendFp2retReceiverOk:
	movq	isa(%a1), %r11		// class = self->isa
	CacheLookup %a2, LMsgSendFp2retCacheMiss
	// CacheLookup placed method in r11
	movq	method_imp(%r11), %r11
	jmp	*%r11			// goto *imp

// cache miss: go search the method lists
LMsgSendFp2retCacheMiss:
	MethodTableLookup isa(%a1), %a2
	// MethodTableLookup placed IMP in r11
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
	END_ENTRY	_objc_msgSend_fp2ret

#if __OBJC2__
	ENTRY _objc_msgSend_fp2ret_fixup

	testq	%a1, %a1
	je	LMsgSendFp2retFixupNilSelf

	SaveRegisters 0
	// a1 = receiver
	// a2 = address of message ref
	movq	%a2, %a3
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a2), %a2
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
	
	END_ENTRY _objc_msgSend_fp2ret_fixup


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
	CALL_MCOUNTER

// check whether receiver is nil 
	testq	%a2, %a2
	je	LMsgSendStretNilSelf

// receiver (in %a2) is non-nil: search the cache
LMsgSendStretReceiverOk:
	movq	isa(%a2), %r11			//   class = self->isa
	CacheLookup %a3, LMsgSendStretCacheMiss
	// CacheLookup placed method in %r11
	movq	method_imp(%r11), %r11
LMsgSendStretCallImp:
	cmpq	%r11, L_objc_msgForward(%rip)	// if imp == _objc_msgForward
	je	__objc_msgForward_stret		//   call struct-returning fwd
	jmp	*%r11				// else goto *imp

// cache miss: go search the method lists
LMsgSendStretCacheMiss:
	MethodTableLookup isa(%a2), %a3
	// MethodTableLookup placed IMP in r11
	jmp	LMsgSendStretCallImp

// message sent to nil: redirect to nil receiver, if any
LMsgSendStretNilSelf:
	movq	__objc_nilReceiver(%rip), %a2
	testq	%a2, %a2			// if (receiver != nil)
	jne	LMsgSendStretReceiverOk		//   send to new receiver
	ret					// else just return

LMsgSendStretExit:
	END_ENTRY	_objc_msgSend_stret

#if __OBJC2__
	ENTRY _objc_msgSend_stret_fixup

	testq	%a2, %a2
	je	LMsgSendStretFixupNilSelf

	SaveRegisters 0
	// a2 = receiver
	// a3 = address of message ref
	movq	%a2, %a1
	movq	$0, %a2
	// __objc_fixupMessageRef(receiver, 0, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	cmpq	%r11, L_objc_msgForward(%rip)	// if imp == _objc_msgForward
	je	__objc_msgForward_stret		//   call struct-returning fwd
	jmp	*%r11				// else goto *imp

LMsgSendStretFixupNilSelf:
	ret
	
	END_ENTRY _objc_msgSend_stret_fixup


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
	CALL_MCOUNTER

// search the cache (objc_super in %a2)
	movq	class(%a2), %r11		// class = objc_super->class
	CacheLookup %a3, LMsgSendSuperStretCacheMiss
	// CacheLookup placed method in %r11
	movq	method_imp(%r11), %r11
LMsgSendSuperStretCallImp:
	movq	receiver(%a2), %a2		// load real receiver
	cmpq	%r11, L_objc_msgForward(%rip)	// if imp == _objc_msgForward
	je	__objc_msgForward_stret		//   call struct-returning fwd
	jmp	*%r11				// else goto *imp

// cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	MethodTableLookup class(%a2), %a3
	// MethodTableLookup placed IMP in r11
	jmp	LMsgSendSuperStretCallImp

LMsgSendSuperStretExit:
	END_ENTRY	_objc_msgSendSuper_stret

#if __OBJC2__
	ENTRY _objc_msgSendSuper2_stret_fixup

	SaveRegisters 0
	// a2 = address of objc_super2
	// a3 = address of message ref
	movq	receiver(%a2), %a1
	// __objc_fixupMessageRef(receiver, objc_super, ref)
	call	__objc_fixupMessageRef
	movq	%rax, %r11
	RestoreRegisters

	// imp is in r11
	// Load _cmd from the message_ref
	movq	8(%a3), %a3
	// Load receiver from objc_super2
	movq	receiver(%a2), %a2
	cmpq	%r11, L_objc_msgForward(%rip)	// if imp == _objc_msgForward
	je	__objc_msgForward_stret		//   call struct-returning fwd
	jmp	*%r11				// else goto *imp
	
	END_ENTRY _objc_msgSendSuper2_stret_fixup

	
	ENTRY _objc_msgSendSuper2_stret_fixedup
	// objc_super->class is superclass of class to search
	movq	class(%a2), %r11	// cls = objc_super->class
	movq	8(%a3), %a3		// load _cmd from message_ref
	movq	8(%r11), %r11		// cls = cls->superclass
	movq	%r11, class(%a2)
	// objc_super->class is now the class to search
	jmp	_objc_msgSendSuper_stret
	END_ENTRY _objc_msgSendSuper2_stret_fixedup
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

	// GrP fixme don't know how to cmpq reg, _objc_msgForward
L_objc_msgForward:	.quad __objc_msgForward

	ENTRY	__objc_msgForward

	// Non-struct return only!

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
