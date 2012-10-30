/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
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
 **  objc-msg-i386.s - i386 code to support objc messaging.
 **
 ********************************************************************
 ********************************************************************/

// The assembler syntax for an immediate value is the same as the
// syntax for a macro argument number (dollar sign followed by the
// digits).  Argument number wins in this ambiguity.  Until the
// assembler is fixed we have to find another way.
#define NO_MACRO_CONSTS
#ifdef NO_MACRO_CONSTS
	kTwo        = 2
	kEight      = 8
#endif

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
	.long   0

// _objc_entryPoints and _objc_exitPoints are used by objc
// to get the critical regions for which method caches 
// cannot be garbage collected.

.globl		_objc_entryPoints
_objc_entryPoints:
	.long	__cache_getImp
	.long	__cache_getMethod
	.long	_objc_msgSend
	.long	_objc_msgSend_stret
	.long	_objc_msgSendSuper
	.long	_objc_msgSendSuper_stret
	.long	0

.globl		_objc_exitPoints
_objc_exitPoints:
	.long	LGetImpExit
	.long	LGetMethodExit
	.long	LMsgSendExit
	.long	LMsgSendStretExit
	.long	LMsgSendSuperExit
	.long	LMsgSendSuperStretExit
	.long	0

/*
 * Handcrafted dyld stubs for each external call.
 * They should be converted into a local branch after linking. aB.
 */

/* asm_help.h version is not what we want */
#undef CALL_EXTERN

#if defined(__DYNAMIC__)

#define CALL_EXTERN(name)	call    L ## name ## $stub

#define LAZY_PIC_FUNCTION_STUB(name) \
.data                         ;\
.picsymbol_stub               ;\
L ## name ## $stub:           ;\
	.indirect_symbol name     ;\
	call    L0$ ## name       ;\
L0$ ## name:                  ;\
	popl    %eax              ;\
	movl    L ## name ## $lz-L0$ ## name(%eax),%edx ;\
	jmp     %edx              ;\
L ## name ## $stub_binder:    ;\
    lea     L ## name ## $lz-L0$ ## name(%eax),%eax ;\
    pushl   %eax              ;\
    jmp     dyld_stub_binding_helper ;\
.data                         ;\
.lazy_symbol_pointer          ;\
L ## name ## $lz:             ;\
	.indirect_symbol name     ;\
	.long L ## name ## $stub_binder

#else /* __DYNAMIC__ */

#define CALL_EXTERN(name)	call    name

#define LAZY_PIC_FUNCTION_STUB(name)

#endif /* __DYNAMIC__ */

// _class_lookupMethodAndLoadCache
LAZY_PIC_FUNCTION_STUB(__class_lookupMethodAndLoadCache)

// __objc_error
LAZY_PIC_FUNCTION_STUB(___objc_error) /* No stub needed */

#if defined(PROFILE)
// mcount
LAZY_PIC_FUNCTION_STUB(mcount)
#endif /* PROFILE */

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
	kFwdMsgSend      = 1
	kFwdMsgSendStret = 0


/********************************************************************
 *
 * Common offsets.
 *
 ********************************************************************/

	self            = 4
	super           = 4
	selector        = 8
	marg_size       = 12
	marg_list       = 16
	first_arg       = 12

	struct_addr     = 4

	self_stret      = 8
	super_stret     = 8
	selector_stret  = 12
	marg_size_stret = 16
	marg_list_stret = 20


/********************************************************************
 *
 * Structure definitions.
 *
 ********************************************************************/

// objc_super parameter to sendSuper
	receiver        = 0
	class           = 4

// Selected field offsets in class structure
	isa             = 0
	cache           = 32

// Method descriptor
	method_name     = 0
	method_imp      = 8

// Cache header
	mask            = 0
	occupied        = 4
	buckets         = 8		// variable length array

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
// LOAD_STATIC_WORD	targetReg, symbolName, LOCAL_SYMBOL | EXTERNAL_SYMBOL
//
// Load the value of the named static data word.
//
// Takes: targetReg       - the register, other than r0, to load
//        symbolName      - the name of the symbol
//        LOCAL_SYMBOL    - symbol name used as-is
//        EXTERNAL_SYMBOL - symbol name gets nonlazy treatment
//
// Eats: edx and targetReg
//////////////////////////////////////////////////////////////////////

// Values to specify whether the symbol is plain or nonlazy
LOCAL_SYMBOL	= 0
EXTERNAL_SYMBOL	= 1

.macro	LOAD_STATIC_WORD

#if defined(__DYNAMIC__)
	call	1f
1:	popl	%edx
.if $2 == EXTERNAL_SYMBOL
	movl	L$1-1b(%edx),$0
	movl	0($0),$0
.elseif $2 == LOCAL_SYMBOL
	movl	$1-1b(%edx),$0
.else
	!!! Unknown symbol type !!!
.endif
#else
	movl	$1,$0
#endif

.endmacro

//////////////////////////////////////////////////////////////////////
//
// LEA_STATIC_DATA	targetReg, symbolName, LOCAL_SYMBOL | EXTERNAL_SYMBOL
//
// Load the address of the named static data.
//
// Takes: targetReg       - the register, other than edx, to load
//        symbolName      - the name of the symbol
//        LOCAL_SYMBOL    - symbol is local to this module
//        EXTERNAL_SYMBOL - symbol is imported from another module
//
// Eats: edx and targetReg
//////////////////////////////////////////////////////////////////////

.macro	LEA_STATIC_DATA
#if defined(__DYNAMIC__)
	call	1f
1:	popl	%edx
.if $2 == EXTERNAL_SYMBOL
	movl	L$1-1b(%edx),$0
.elseif $2 == LOCAL_SYMBOL
	leal	$1-1b(%edx),$0
.else
	!!! Unknown symbol type !!!
.endif
#else
	leal	$1,$0
#endif

.endmacro

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
	.align	4, 0x90
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
// CALL_MCOUNTER	counterName
//
// Allocate and maintain a counter for the call site.
//
// Takes: counterName - name of counter.
//////////////////////////////////////////////////////////////////////

.macro CALL_MCOUNTER
#ifdef PROFILE
	pushl	%ebp
	movl	%esp,%ebp
	LOAD_STATIC_WORD %eax, $0, LOCAL_SYMBOL
	CALL_EXTERN(mcount)
	.data
	.align	2
$0:
	.long	0
	.text
	movl	%ebp,%esp
	popl	%ebp
#endif
.endmacro


/////////////////////////////////////////////////////////////////////
//
//
// CacheLookup	WORD_RETURN | STRUCT_RETURN, MSG_SEND | MSG_SENDSUPER | CACHE_GET, cacheMissLabel
//
// Locate the implementation for a selector in a class method cache.
//
// Takes: WORD_RETURN	(first parameter is at sp+4)
//        STRUCT_RETURN	(struct address is at sp+4, first parameter at sp+8)
//        MSG_SEND	(first parameter is receiver)
//        MSG_SENDSUPER	(first parameter is address of objc_super structure)
//        CACHE_GET	(first parameter is class; return method triplet)
//
//	  cacheMissLabel = label to branch to iff method is not cached
//
// On exit: (found) MSG_SEND and MSG_SENDSUPER: return imp in eax
//          (found) CACHE_GET: return method triplet in eax
//          (not found) jumps to cacheMissLabel
//	
/////////////////////////////////////////////////////////////////////


// Values to specify to method lookup macros whether the return type of
// the method is word or structure.
WORD_RETURN   = 0
STRUCT_RETURN = 1

// Values to specify to method lookup macros whether the first argument
// is an object/class reference or a 'objc_super' structure.
MSG_SEND      = 0	// first argument is receiver, search the isa
MSG_SENDSUPER = 1	// first argument is objc_super, search the class
CACHE_GET     = 2	// first argument is class, search that class

.macro	CacheLookup

// load variables and save caller registers.
// Overlapped to prevent AGI
.if $0 == WORD_RETURN			// Regular word return
.if $1 == MSG_SEND			// MSG_SEND
	movl	isa(%eax), %eax		//   class = self->isa
	movl	selector(%esp), %ecx	//   get selector
.elseif $1 == MSG_SENDSUPER		// MSG_SENDSUPER
	movl	super(%esp), %eax	//   get objc_super address
	movl	class(%eax), %eax	//   class = caller->class
	movl	selector(%esp), %ecx	//   get selector
.else					// CACHE_GET
	movl	selector(%esp), %ecx	//   get selector - class already in eax
.endif
.else					// Struct return
.if $1 == MSG_SEND			// MSG_SEND (stret)
	movl	isa(%eax), %eax		//   class = self->isa
	movl	(selector_stret)(%esp), %ecx	//   get selector
.elseif $1 == MSG_SENDSUPER		// MSG_SENDSUPER (stret)
	movl	super_stret(%esp), %eax	//   get objc_super address
	movl	class(%eax), %eax	//   class = caller->class
	movl	(selector_stret)(%esp), %ecx	//   get selector
.else					// CACHE_GET
	!! This should not happen.
.endif
.endif

	pushl	%edi			// save scratch register
	movl	cache(%eax), %eax	// cache = class->cache
	pushl	%esi			// save scratch register

#if defined(OBJC_INSTRUMENTED)
	pushl	%ebx			// save non-volatile register
	pushl	%eax			// save cache pointer
	xorl	%ebx, %ebx		// probeCount = 0
#endif
	leal	buckets(%eax), %edi	// buckets = &cache->buckets
	movl	mask(%eax), %esi		// mask = cache->mask
	movl	%ecx, %edx		// index = selector
#ifdef NO_MACRO_CONSTS
	shrl	$kTwo, %edx		// index = selector >> 2
#else
	shrl	$2, %edx		// index = selector >> 2
#endif

// search the receiver's cache
LMsgSendProbeCache_$0_$1_$2:
#if defined(OBJC_INSTRUMENTED)
	inc	%ebx			// probeCount += 1
#endif
	andl	%esi, %edx		// index &= mask
	movl	(%edi, %edx, 4), %eax	// method = buckets[index]

	testl	%eax, %eax		// check for end of bucket
	je	LMsgSendCacheMiss_$0_$1_$2	// go to cache miss code
	cmpl	method_name(%eax), %ecx	// check for method name match
	je	LMsgSendCacheHit_$0_$1_$2	// go handle cache hit
	inc	%edx			// bump index ...
	jmp	LMsgSendProbeCache_$0_$1_$2 // ... and loop

// not found in cache: restore state and go to callers handler
LMsgSendCacheMiss_$0_$1_$2:
#if defined(OBJC_INSTRUMENTED)
	popl	%edx			// retrieve cache pointer
	movl	mask(%edx), %esi		// mask = cache->mask
	testl	%esi, %esi		// a mask of zero is only for the...
	je	LMsgSendMissInstrumentDone_$0_$1_$2	// ... emptyCache, do not record anything

	// locate and update the CacheInstrumentation structure
	inc	%esi			// entryCount = mask + 1
#ifdef NO_MACRO_CONSTS
	shll	$kTwo, %esi		// tableSize = entryCount * sizeof(entry)
#else
	shll	$2, %esi			// tableSize = entryCount * sizeof(entry)
#endif
	addl	$buckets, %esi		// offset = buckets + tableSize
	addl	%edx, %esi		// cacheData = &cache->buckets[mask+1]

	movl	missCount(%esi), %edi	// 
	inc	%edi			// 
	movl	%edi, missCount(%esi)	// cacheData->missCount += 1
	movl	missProbes(%esi), %edi	// 
	addl	%ebx, %edi		// 
	movl	%edi, missProbes(%esi)	// cacheData->missProbes += probeCount
	movl	maxMissProbes(%esi), %edi// if (cacheData->maxMissProbes < probeCount)
	cmpl	%ebx, %edi		// 
	jge	LMsgSendMaxMissProbeOK_$0_$1_$2	// 
	movl	%ebx, maxMissProbes(%esi)// cacheData->maxMissProbes = probeCount
LMsgSendMaxMissProbeOK_$0_$1_$2:

	// update cache miss probe histogram
	cmpl	$CACHE_HISTOGRAM_SIZE, %ebx	// pin probeCount to max index
	jl	LMsgSendMissHistoIndexSet_$0_$1_$2
	movl	$(CACHE_HISTOGRAM_SIZE-1), %ebx
LMsgSendMissHistoIndexSet_$0_$1_$2:
	LEA_STATIC_DATA	%esi, _CacheMissHistogram, EXTERNAL_SYMBOL
#ifdef NO_MACRO_CONSTS
	shll	$kTwo, %ebx		// convert probeCount to histogram index
#else
	shll	$2, %ebx			// convert probeCount to histogram index
#endif
	addl	%ebx, %esi		// calculate &CacheMissHistogram[probeCount<<2]
	movl	0(%esi), %edi		// get current tally
	inc	%edi			// 
	movl	%edi, 0(%esi)		// tally += 1
LMsgSendMissInstrumentDone_$0_$1_$2:
	popl	%ebx			// restore non-volatile register
#endif

.if $0 == WORD_RETURN			// Regular word return
.if $1 == MSG_SEND			// MSG_SEND
	popl	%esi			//  restore callers register
	popl	%edi			//  restore callers register
	movl	self(%esp), %eax	//  get messaged object
	movl	isa(%eax), %eax		//  get objects class
.elseif $1 == MSG_SENDSUPER		// MSG_SENDSUPER
	// replace "super" arg with "receiver"
	movl	super+8(%esp), %edi	//  get super structure
	movl	receiver(%edi), %esi	//  get messaged object
	movl	%esi, super+8(%esp)	//  make it the first argument
	movl	class(%edi), %eax	//  get messaged class
	popl	%esi			//  restore callers register
	popl	%edi			//  restore callers register
.else					// CACHE_GET
	popl	%esi			//  restore callers register
	popl	%edi			//  restore callers register
.endif
.else					// Struct return
.if $1 == MSG_SEND			// MSG_SEND (stret)
	popl	%esi			//  restore callers register
	popl	%edi			//  restore callers register
	movl	self_stret(%esp), %eax	//  get messaged object
	movl	isa(%eax), %eax		//  get objects class
.elseif $1 == MSG_SENDSUPER		// MSG_SENDSUPER (stret)
	// replace "super" arg with "receiver"
	movl	super_stret+8(%esp), %edi//  get super structure
	movl	receiver(%edi), %esi	//  get messaged object
	movl	%esi, super_stret+8(%esp)//  make it the first argument
	movl	class(%edi), %eax	//  get messaged class
	popl	%esi			//  restore callers register
	popl	%edi			//  restore callers register
.else					// CACHE_GET
	!! This should not happen.
.endif
.endif

	jmp	$2			// go to callers handler

// eax points to matching cache entry
	.align	4, 0x90
LMsgSendCacheHit_$0_$1_$2:
#if defined(OBJC_INSTRUMENTED)
	popl	%edx			// retrieve cache pointer
	movl	mask(%edx), %esi		// mask = cache->mask
	testl	%esi, %esi		// a mask of zero is only for the...
	je	LMsgSendHitInstrumentDone_$0_$1_$2	// ... emptyCache, do not record anything

	// locate and update the CacheInstrumentation structure
	inc	%esi			// entryCount = mask + 1
#ifdef NO_MACRO_CONSTS
	shll	$kTwo, %esi		// tableSize = entryCount * sizeof(entry)
#else
	shll	$2, %esi			// tableSize = entryCount * sizeof(entry)
#endif
	addl	$buckets, %esi		// offset = buckets + tableSize
	addl	%edx, %esi		// cacheData = &cache->buckets[mask+1]

	movl	hitCount(%esi), %edi
	inc	%edi
	movl	%edi, hitCount(%esi)	// cacheData->hitCount += 1
	movl	hitProbes(%esi), %edi
	addl	%ebx, %edi
	movl	%edi, hitProbes(%esi)	// cacheData->hitProbes += probeCount
	movl	maxHitProbes(%esi), %edi// if (cacheData->maxHitProbes < probeCount)
	cmpl	%ebx, %edi
	jge	LMsgSendMaxHitProbeOK_$0_$1_$2
	movl	%ebx, maxHitProbes(%esi)// cacheData->maxHitProbes = probeCount
LMsgSendMaxHitProbeOK_$0_$1_$2:

	// update cache hit probe histogram
	cmpl	$CACHE_HISTOGRAM_SIZE, %ebx	// pin probeCount to max index
	jl	LMsgSendHitHistoIndexSet_$0_$1_$2
	movl	$(CACHE_HISTOGRAM_SIZE-1), %ebx
LMsgSendHitHistoIndexSet_$0_$1_$2:
	LEA_STATIC_DATA	%esi, _CacheHitHistogram, EXTERNAL_SYMBOL
#ifdef NO_MACRO_CONSTS
	shll	$kTwo, %ebx		// convert probeCount to histogram index
#else
	shll	$2, %ebx			// convert probeCount to histogram index
#endif
	addl	%ebx, %esi		// calculate &CacheHitHistogram[probeCount<<2]
	movl	0(%esi), %edi		// get current tally
	inc	%edi			// 
	movl	%edi, 0(%esi)		// tally += 1
LMsgSendHitInstrumentDone_$0_$1_$2:
	popl	%ebx			// restore non-volatile register
#endif

// load implementation address, restore state, and we're done
.if $1 == CACHE_GET
	// method triplet is already in eax
.else
	movl	method_imp(%eax), %eax	// imp = method->method_imp
.endif

.if $0 == WORD_RETURN			// Regular word return
.if $1 == MSG_SENDSUPER			// MSG_SENDSUPER
	// replace "super" arg with "self"
	movl	super+8(%esp), %edi
	movl	receiver(%edi), %esi
	movl	%esi, super+8(%esp)
.endif
.else					// Struct return
.if $1 == MSG_SENDSUPER			// MSG_SENDSUPER (stret)
	// replace "super" arg with "self"
	movl	super_stret+8(%esp), %edi
	movl	receiver(%edi), %esi
	movl	%esi, super_stret+8(%esp)
.endif
.endif

	// restore caller registers
	popl	%esi
	popl	%edi
.endmacro


/////////////////////////////////////////////////////////////////////
//
// MethodTableLookup WORD_RETURN | STRUCT_RETURN, MSG_SEND | MSG_SENDSUPER
//
// Takes: WORD_RETURN	(first parameter is at sp+4)
//	  STRUCT_RETURN	(struct address is at sp+4, first parameter at sp+8)
// 	  MSG_SEND	(first parameter is receiver)
//	  MSG_SENDSUPER	(first parameter is address of objc_super structure)
//
// On exit: Register parameters restored from CacheLookup
//	  imp in eax
//
/////////////////////////////////////////////////////////////////////

.macro MethodTableLookup

	// push args (class, selector)
	pushl	%ecx
	pushl	%eax
	CALL_EXTERN(__class_lookupMethodAndLoadCache)
#ifdef NO_MACRO_CONSTS
	addl	$kEight, %esp				// pop parameters
#else
	addl	$8, %esp					// pop parameters
#endif
.endmacro


/********************************************************************
 * Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp)
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

// load the class into eax
	movl	self(%esp), %eax

// do lookup
	CacheLookup WORD_RETURN, CACHE_GET, LGetMethodMiss

// cache hit, method triplet in %eax
	movl    first_arg(%esp), %ecx   // check for _objc_msgForward
	cmpl    method_imp(%eax), %ecx
	je      LGetMethodMiss          // if (imp==_objc_msgForward) return nil
	ret                             // else return method triplet address

LGetMethodMiss:
// cache miss, return nil
	xorl    %eax, %eax      // zero %eax
	ret

LGetMethodExit:
	END_ENTRY __cache_getMethod


/********************************************************************
 * IMP _cache_getImp(Class cls, SEL sel)
 *
 * If found, returns method implementation.
 * If not found, returns NULL.
 ********************************************************************/

	ENTRY __cache_getImp

// load the class into eax
	movl	self(%esp), %eax

// do lookup
	CacheLookup WORD_RETURN, CACHE_GET, LGetImpMiss

// cache hit, method triplet in %eax
	movl    method_imp(%eax), %eax  // return method imp
	ret

LGetImpMiss:
// cache miss, return nil
	xorl    %eax, %eax      // zero %eax
	ret

LGetImpExit:
	END_ENTRY __cache_getImp


/********************************************************************
 *
 * id objc_msgSend(id self, SEL	_cmd,...);
 *
 ********************************************************************/

	ENTRY	_objc_msgSend
	CALL_MCOUNTER	LP0

	movl	self(%esp), %eax

// check whether receiver is nil 
	testl	%eax, %eax
	je	LMsgSendNilSelf

// receiver is non-nil: search the cache
LMsgSendReceiverOk:
	CacheLookup WORD_RETURN, MSG_SEND, LMsgSendCacheMiss
	movl	$kFwdMsgSend, %edx	// flag word-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// cache miss: go search the method lists
LMsgSendCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SEND
	movl	$kFwdMsgSend, %edx	// flag word-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendNilSelf:
	call	1f			// load new receiver
1:	popl	%edx
	movl	__objc_nilReceiver-1b(%edx),%eax
	testl	%eax, %eax		// return nil if no new receiver
	je	LMsgSendDone
	movl	%eax, self(%esp)	// send to new receiver
	jmp	LMsgSendReceiverOk
LMsgSendDone:
	ret

// guaranteed non-nil entry point (disabled for now)
// .globl _objc_msgSendNonNil
// _objc_msgSendNonNil:
// 	movl	self(%esp), %eax
// 	jmp     LMsgSendReceiverOk

LMsgSendExit:
	END_ENTRY	_objc_msgSend

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
	CALL_MCOUNTER LP1

	movl	super(%esp), %eax

// receiver is non-nil: search the cache
	CacheLookup WORD_RETURN, MSG_SENDSUPER, LMsgSendSuperCacheMiss
	movl	$kFwdMsgSend, %edx	// flag word-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// cache miss: go search the method lists
LMsgSendSuperCacheMiss:
	MethodTableLookup WORD_RETURN, MSG_SENDSUPER
	movl	$kFwdMsgSend, %edx	// flag word-return for _objc_msgForward
	jmp	*%eax			// goto *imp

LMsgSendSuperExit:
	END_ENTRY	_objc_msgSendSuper

/********************************************************************
 * id objc_msgSendv(id self, SEL _cmd, unsigned size, marg_list frame);
 *
 * On entry:
 *		(sp+4)  is the message receiver,
 *		(sp+8)	is the selector,
 *		(sp+12) is the size of the marg_list, in bytes,
 *		(sp+16) is the address of the marg_list
 *
 ********************************************************************/

	ENTRY	_objc_msgSendv

#if defined(KERNEL)
	trap				// _objc_msgSendv is not for the kernel
#else
	pushl	%ebp
	movl	%esp, %ebp
	movl	(marg_list+4)(%ebp), %edx
	addl	$8, %edx			// skip self & selector
	movl	(marg_size+4)(%ebp), %ecx
	subl	$5, %ecx			// skip self & selector
	shrl	$2, %ecx
	jle	LMsgSendvArgsOK
LMsgSendvArgLoop:
	decl	%ecx
	movl	0(%edx, %ecx, 4), %eax
	pushl	%eax
	jg	LMsgSendvArgLoop

LMsgSendvArgsOK:
	movl	(selector+4)(%ebp), %ecx
	pushl	%ecx
	movl	(self+4)(%ebp),%ecx
	pushl	%ecx
	call	_objc_msgSend
	movl	%ebp,%esp
	popl	%ebp

	ret
#endif
	END_ENTRY	_objc_msgSendv


/********************************************************************
 *
 * void	objc_msgSend_stret(void *st_addr	, id self, SEL _cmd, ...);
 *
 *
 * objc_msgSend_stret is the struct-return form of msgSend.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 *
 * On entry:	(sp+4)is the address where the structure is returned,
 *		(sp+8) is the message receiver,
 *		(sp+12) is the selector
 ********************************************************************/

	ENTRY	_objc_msgSend_stret
	CALL_MCOUNTER	LP2

	movl	self_stret(%esp), %eax

// check whether receiver is nil 
	testl	%eax, %eax
	je	LMsgSendStretNilSelf

// receiver is non-nil: search the cache
LMsgSendStretReceiverOk:
	CacheLookup STRUCT_RETURN, MSG_SEND, LMsgSendStretCacheMiss
	movl	$kFwdMsgSendStret, %edx	// flag struct-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// cache miss: go search the method lists
LMsgSendStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SEND
	movl	$kFwdMsgSendStret, %edx	// flag struct-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// message sent to nil: redirect to nil receiver, if any
LMsgSendStretNilSelf:
	call	1f			// load new receiver
1:	popl	%edx
	movl	__objc_nilReceiver-1b(%edx),%eax
	testl	%eax, %eax		// return nil if no new receiver
	je	LMsgSendStretDone
	movl	%eax, self_stret(%esp)	// send to new receiver
	jmp	LMsgSendStretReceiverOk
LMsgSendStretDone:
	ret	$4			// pop struct return address (#2995932)

// guaranteed non-nil entry point (disabled for now)
// .globl _objc_msgSendNonNil_stret
// _objc_msgSendNonNil_stret:
// 	CALL_MCOUNTER	LP3
// 	movl	self_stret(%esp), %eax
// 	jmp     LMsgSendStretReceiverOk

LMsgSendStretExit:
	END_ENTRY	_objc_msgSend_stret

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
 * On entry:	(sp+4)is the address where the structure is returned,
 *		(sp+8) is the address of the objc_super structure,
 *		(sp+12) is the selector
 *
 ********************************************************************/

	ENTRY	_objc_msgSendSuper_stret
	CALL_MCOUNTER LP4

	movl	super_stret(%esp), %eax

// receiver is non-nil: search the cache
	CacheLookup STRUCT_RETURN, MSG_SENDSUPER, LMsgSendSuperStretCacheMiss
	movl	$kFwdMsgSendStret, %edx	// flag struct-return for _objc_msgForward
	jmp	*%eax			// goto *imp

// cache miss: go search the method lists
LMsgSendSuperStretCacheMiss:
	MethodTableLookup STRUCT_RETURN, MSG_SENDSUPER
	movl	$kFwdMsgSendStret, %edx	// flag struct-return for _objc_msgForward
	jmp	*%eax			// goto *imp

LMsgSendSuperStretExit:
	END_ENTRY	_objc_msgSendSuper_stret


/********************************************************************
 * id objc_msgSendv_stret(void *st_addr, id self, SEL _cmd, unsigned size, marg_list frame);
 *
 * objc_msgSendv_stret is the struct-return form of msgSendv.
 * The ABI calls for (sp+4) to be used as the address of the structure
 * being returned, with the parameters in the succeeding locations.
 * 
 * On entry:	(sp+4)  is the address in which the returned struct is put,
 *		(sp+8)  is the message receiver,
 *		(sp+12) is the selector,
 *		(sp+16) is the size of the marg_list, in bytes,
 *		(sp+20) is the address of the marg_list
 *
 ********************************************************************/

	ENTRY	_objc_msgSendv_stret

#if defined(KERNEL)
	trap				// _objc_msgSendv_stret is not for the kernel
#else
	pushl	%ebp
	movl	%esp, %ebp
	movl	(marg_list_stret+4)(%ebp), %edx
	addl	$8, %edx			// skip self & selector
	movl	(marg_size_stret+4)(%ebp), %ecx
	subl	$5, %ecx			// skip self & selector
	shrl	$2, %ecx
	jle	LMsgSendvStretArgsOK
LMsgSendvStretArgLoop:
	decl	%ecx
	movl	0(%edx, %ecx, 4), %eax
	pushl	%eax
	jg	LMsgSendvStretArgLoop

LMsgSendvStretArgsOK:
	movl	(selector_stret+4)(%ebp), %ecx
	pushl	%ecx
	movl	(self_stret+4)(%ebp),%ecx
	pushl	%ecx
	movl	(struct_addr+4)(%ebp),%ecx
	pushl	%ecx
	call	_objc_msgSend_stret
	movl	%ebp,%esp
	popl	%ebp

	ret
#endif
	END_ENTRY	_objc_msgSendv_stret


/********************************************************************
 *
 * id _objc_msgForward(id self, SEL _cmd,...);
 *
 ********************************************************************/

// Location LFwdStr contains the string "forward::"
// Location LFwdSel contains a pointer to LFwdStr, that can be changed
// to point to another forward:: string for selector uniquing
// purposes.  ALWAYS dereference LFwdSel to get to "forward::" !!
	.objc_meth_var_names
	.align	2
LFwdStr:.ascii	"forward::\0"

	.objc_message_refs
	.align	2
LFwdSel:.long	LFwdStr

	.cstring
	.align	2
LUnkSelStr:    .ascii	"Does not recognize selector %s\0"

	ENTRY	__objc_msgForward

#if defined(KERNEL)
	trap				// _objc_msgForward is not for the kernel
#else
	cmpl	$kFwdMsgSendStret, %edx	// check secret flag for word vs struct return
	je	LForwardStretVersion	// jump to struct return version...

	// non-stret version ...
	pushl   %ebp
	movl    %esp,%ebp
	movl	(selector+4)(%esp), %eax
#if defined(__DYNAMIC__)
	call	L__objc_msgForward$pic_base
L__objc_msgForward$pic_base:
	popl	%edx
	leal	LFwdSel-L__objc_msgForward$pic_base(%edx),%ecx
	cmpl	%ecx, %eax
#else
	cmpl	LFwdSel, %eax
#endif
	je	LMsgForwardError

	leal	(self+4)(%esp), %ecx
	pushl	%ecx
	pushl	%eax
#if defined(__DYNAMIC__)
	movl	LFwdSel-L__objc_msgForward$pic_base(%edx),%ecx
#else
	movl	LFwdSel,%ecx
#endif
	pushl	%ecx
	pushl	(self+16)(%esp)
	call	_objc_msgSend
	movl    %ebp,%esp
	popl    %ebp
	ret

// call error handler with unrecognized selector message
	.align	4, 0x90
LMsgForwardError:
#if defined(__DYNAMIC__)
	leal	LFwdSel-L__objc_msgForward$pic_base(%edx),%eax
	pushl 	%eax
	leal	LUnkSelStr-L__objc_msgForward$pic_base(%edx),%eax
	pushl 	%eax
#else
	pushl	$LFwdSel
	pushl	$LUnkSelStr
#endif
	pushl	(self+12)(%esp)
	CALL_EXTERN(___objc_error)	// volatile, will not return

// ***** Stret version of function below
// ***** offsets have been changed (by adding a word to make room for the 
// ***** structure, and labels have been changed to be unique.

LForwardStretVersion:
	pushl   %ebp
	movl    %esp,%ebp
	movl	(selector_stret+4)(%esp), %eax

#if defined(__DYNAMIC__)
	call	L__objc_msgForwardStret$pic_base
L__objc_msgForwardStret$pic_base:
	popl	%edx
	leal	LFwdSel-L__objc_msgForwardStret$pic_base(%edx),%ecx
	cmpl	%ecx, %eax
#else
	cmpl	LFwdSel, %eax
#endif
	je	LMsgForwardStretError

	leal	(self_stret+4)(%esp), %ecx
	pushl	%ecx
	pushl	%eax
#if defined(__DYNAMIC__)
	movl	LFwdSel-L__objc_msgForwardStret$pic_base(%edx),%ecx
#else
	movl	LFwdSel,%ecx
#endif
	pushl	%ecx
	pushl	(self_stret+16)(%esp)
	call	_objc_msgSend
	movl    %ebp,%esp
	popl    %ebp
	ret	$4			// pop struct return address (#2995932)

// call error handler with unrecognized selector message
	.align	4, 0x90
LMsgForwardStretError:
#if defined(__DYNAMIC__)
	leal	LFwdSel-L__objc_msgForwardStret$pic_base(%edx),%eax
	pushl 	%eax
	leal	LUnkSelStr-L__objc_msgForwardStret$pic_base(%edx),%eax
	pushl 	%eax
#else
	pushl	$LFwdSel
	pushl	$LUnkSelStr
#endif
	pushl	(self_stret+12)(%esp)
	CALL_EXTERN(___objc_error)	// volatile, will not return

#endif /* defined (KERNEL) */
	END_ENTRY	__objc_msgForward

