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
#ifndef KERNEL
| _objc_entryPoints and _objc_exitPoints are used by moninitobjc() to setup
| objective-C messages for profiling.  The are made private_externs when in
| a shared library.
	.reference _moninitobjc
	.const
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

	self = 4
	selector = 8
	cache = 32
	buckets = 8
	method_imp = 8

| optimized for 68040: 27 clocks (best case) + 16 clocks / probe

	.text
	.align 1
	.globl _objc_msgSend
_objc_msgSend:
	movel sp@(self),d0		| (1)
	movel d0,a0			| (1)
	andl __objc_multithread_mask,d0	| (1) if (_objc_multithread_mask == 0)
	jne L1				| (2)   goto lock;
	tstl a0				|     if (self != nil)
	jne L11				|	continue with objc_msgSend
        movel __objc_msgNil,a0		| (?) load nil object handler
        tstl a0				| (?) If NULL just return and dont do anything
        jeq L10				| (?)
        jbsr a0@			| (?) call __objc_msgNil;
	clrl d0				| (1) zero d0, just in case nil handler changed them
	movel d0,a0			| (1) zero a0, just in case nil handler changed them
L10:	rts				|
L1:	movel a0@,a0			| (1) class = self->isa;
	movel a1,sp@-			| (2) (save a1)
	movel a0@(cache),a1		| (1) cache = class->cache;
	movel sp@(selector+4),d1	| (1) index = selector;
L2:	andl a1@,d1			| (1) index &= cache->mask;
	movel a1@(buckets,d1:l:4),d0	| (4) method = cache->buckets[index];
	movel d0,a0			| (1) if (method == NULL)
	jne L3				| (2)   goto cache_miss;
	jra L5				|
L3:	movel sp@(selector+4),d0	| (1)
	cmpl a0@,d0			| (1) if (method_name == selector)
	jeq L4				| (2)   goto cache_hit;
	addql #1,d1			|     index++
	jra L2				|     goto loop;
L4:	movel a0@(method_imp),a0	| (1) imp = method->method_imp;
	movel sp@+,a1			| (1) (restore a1)
Lexit1:	jmp a0@				| (3) goto *imp;
	.space 22			| /* area for moninitobjc to write */
L5:	movel sp@(self+4),a0		|     cache_miss:
	movel sp@(selector+4),sp@-	|     imp =
	movel a0@,sp@-			|     _class_lookupMethodAndLoadCache
	CALL_EXTERN(__class_lookupMethodAndLoadCache)	|     (class, selector);
	addql #8,sp			|
	movel d0,a0			|
	movel sp@+,a1			|     (restore a1)
Lexit2:	jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */



| locking version of objc_msgSend:

L11:	clrb _messageLock+1		|     (workaround 040 bug)
	tas _messageLock		|     mutex_lock (messageLock);
	jpl L24				|
	jra L11				|
L24:	movel a0@,a0			|     class = self->isa;
	movel a1,sp@-			|     (save a1)
	movel a0@(cache),a1		|     cache = class->cache;
	movel sp@(selector+4),d1	|     index = selector;
L12:	andl a1@,d1			|     index &= cache->mask;
	movel a1@(buckets,d1:l:4),d0	|     method = cache->buckets[index];
	movel d0,a0			|     if (method == NULL)
	jne L13				|	goto cache_miss;
	jra L15				|
L13:	movel sp@(selector+4),d0	|    
	cmpl a0@,d0			|     if (method_name == selector)
	jeq L14				|	goto cache_hit;
	addql #1,d1			|     index++
	jra L12				|     goto loop;
L14:	movel a0@(method_imp),a0	|     imp = method->method_imp;
	movel sp@+,a1			|     (restore a1)
	clrb _messageLock		|     mutex_unlock (messageLock);
Lexit3: jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */
L15:	movel sp@(self+4),a0		|     cache_miss:
	movel sp@(selector+4),sp@-	|     imp =
	movel a0@,sp@-			|     _class_lookupMethodAndLoadCache
	CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)	|     (class, selector);
	addql #8,sp			|
	movel d0,a0			|
	movel sp@+,a1			|     (restore a1)
	clrb _messageLock		|     mutex_unlock (messageLock);
Lexit4:	jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */



	caller = 4

| optimized for 68040: 31 clocks (best case) + 16 clocks / probe

	.align 1
	.globl _objc_msgSendSuper
_objc_msgSendSuper:
	tstl __objc_multithread_mask	| (1) if (_objc_multithread_mask == 0)
	jne L20				| (2)   goto lock;
	jra L21				|
L20:	movel sp@(caller),a0		| (1)
	movel a2,sp@-			| (2) (save a2)
	movel a0@+,sp@(self+4)		| (2) self = caller->receiver;
	movel a0@,a2			| (1) class = caller->class;
	movel a1,sp@-			| (2) (save a1)
	movel a2@(cache),a1		| (1) cache = class->cache;
	movel sp@(selector+8),d1	| (1) index = selector;
L6:	andl a1@,d1			| (1) index &= cache->mask;
	movel a1@(buckets,d1:l:4),d0	| (4) method = cache->buckets[index];
	movel d0,a0			| (1) if (method == NULL)
	jne L7				| (2)   goto cache_miss;
	jra L9				|
L7:	movel sp@(selector+8),d0	| (1)
	cmpl a0@,d0			| (1) if (method_name == selector)
	jeq L8				| (2)   goto cache_hit;
	addql #1,d1			|     index++
	jra L6				|     goto loop;
L8:	movel a0@(method_imp),a0	| (1) imp = method->method_imp;
	movel sp@+,a1			| (1) (restore a1)
	movel sp@+,a2			| (1) (restore a2)
Lexit5:	jmp a0@				| (3) goto *imp;
	.space 22			| /* area for moninitobjc to write */
L9:	movel sp@(selector+8),sp@-	|     imp =
	movel a2,sp@-			|     _class_lookupMethodAndLoadCache
	CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)	|     (class, selector);
	addql #8,sp			|
	movel d0,a0			|
	movel sp@+,a1			|     (restore a1)
	movel sp@+,a2			|     (restore a2)
Lexit6:	jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */



| locking version of objc_msgSendSuper:

L21:	clrb _messageLock+1		|     (workaround 040 bug)
	tas _messageLock		|     mutex_lock (messageLock);
	jpl L27				|
	jra L21				|
L27:	movel sp@(caller),a0		|    
	movel a2,sp@-			|     (save a2)
	movel a0@+,sp@(self+4)		|     self = caller->receiver;
	movel a0@,a2			|     class = caller->class;
	movel a1,sp@-			|     (save a1)
	movel a2@(cache),a1		|     cache = class->cache;
	movel sp@(selector+8),d1	|     index = selector;
L16:	andl a1@,d1			|     index &= cache->mask;
	movel a1@(buckets,d1:l:4),d0	|     method = cache->buckets[index];
	movel d0,a0			|     if (method == NULL)
	jne L17				|	goto cache_miss;
	jra L19				|
L17:	movel sp@(selector+8),d0	|    
	cmpl a0@,d0			|     if (method_name == selector)
	jeq L18				|	goto cache_hit;
	addql #1,d1			|     index++
	jra L16				|     goto loop;
L18:	movel a0@(method_imp),a0	|     imp = method->method_imp;
	movel sp@+,a1			|     (restore a1)
	movel sp@+,a2			|     (restore a2)
	clrb _messageLock		|     mutex_unlock (messageLock);
Lexit7:	jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */
L19:	movel sp@(selector+8),sp@-	|     imp =
	movel a2,sp@-			|     _class_lookupMethodAndLoadCache
	CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)	|     (class, selector);
	addql #8,sp			|
	movel d0,a0			|
	movel sp@+,a1			|     (restore a1)
	movel sp@+,a2			|     (restore a2)
	clrb _messageLock		|     mutex_unlock (messageLock);
Lexit8:	jmp a0@				|     goto *imp;
	.space 22			| /* area for moninitobjc to write */


	.objc_meth_var_names
	.align 1
L30:	.ascii "forward::\0"

	.objc_message_refs
	.align 2
L31:	.long L30

	.cstring
	.align 1
L32:	.ascii "Does not recognize selector %s\0"

	.text
	.align 1
	.globl __objc_msgForward
__objc_msgForward:
	linkw a6,#0x0			|  set up frame pointer
	movel sp@(selector+4),d0	|  +n accounts for sp pushes
	cmpl L31,d0			|  if (sel == @selector (forward::))
	bne L33				|  
	pea L30				|  __objc_error (self,
	pea L32				|                _errDoesntRecognize
	movel sp@(self+12),sp@-		|                "forward::");
	BRANCH_EXTERN(___objc_error)		|  
L33:    pea sp@(self+4)			|  return [self forward: sel : &self];
	movel d0,sp@-			|  
	movel L31,sp@-			|  
	movel sp@(self+16),sp@-		|  
	bsr _objc_msgSend		|  
	unlk a6				|  clear frame pointer
	rts				|  


	size = 12
	args = 16

	.text
	.align 1
	.globl _objc_msgSendv
_objc_msgSendv:
	linkw a6,#0			|  
	movel a6@(size+4),d0		|  
	addql #3,d0			|  size = round_up (size, 4);
	andl #0xfffffffc,d0		|  
	movel a6@(args+4),a0		|  
	addl d0,a0			|  arg_ptr = &args[size];
	subql #8,d0			|  size -= 8;
	ble L35				|  while (size > 0)
L34:	movel a0@-,sp@-			|    *--sp = *--arg_ptr;
	subql #4,d0			|    size -= 4;
	bgt L34				|  
L35:	movel a6@(selector+4),sp@-	|  
	movel a6@(self+4),sp@-		|  objc_msgSend (self, selector, ...);
	bsr _objc_msgSend		|  
	unlk a6				|  (deallocate variable storage)
	rts				|  
