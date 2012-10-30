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
** 9605: Dan Schmidt (DSG&A)
**	Modified to clean up the calling conventions on all routines.
**	This allows gdb to back trace from and through these routines.
*/

#define isa		0
#define cache		32
#define mask		0
#define buckets		8
#define method_name	0
#define method_imp	8

;;
;; Objc_msgSend: Standard messenger
;; optimized for hppa: 20? clocks (best case) + 6 clocks / probe
;;

    .CODE
objc_msgSend
    .PROC
    .CALLINFO
    .ENTRY

    comib,=,n	0,%arg0,L$exitNull		; Return 0 if self == nil
    ldil	L'_objc_multithread_mask,%r20	; '
    ldw		R'_objc_multithread_mask(%r20),%r31	; '
    comib,=	0,%r31,L$lock			; lock if multithreaded
    ldw 	isa(0,%arg0),%r19		; <ds> class = self->isa;
L$continue
    ldw 	cache(0,%r19),%r20		; cache = class->cache
    ldw 	mask(0,%r20),%r21		; mask = cache->mask
    ldo 	buckets(%r20),%r20		; buckets = cache->buckets
    and 	%r21,%arg1,%r22			; index = selector & mask
L$loop
    ldwx,s	%r22(0,%r20),%r19		; method = cache->buckets[index]
    comib,=,n	0,%r19,L$cacheMiss		; if (method == NULL)
    ldw 	method_name(0,%r19),%r1		;
    addi	1,%r22,%r22			; ++index
    comb,<>	%r1,%arg1,L$loop		; if (name!=sel) continue loop
    and 	%r21,%r22,%r22			; <delay slot> index &=mask
    ldw 	method_imp(0,%r19),%r22		; Implementation into r22
    comib,=,n	0,%r31,L$unlock			; unlock if multithreaded
    b		$$dyncall			; goto *imp;
    nop

L$exitNull
    bv		0(%rp)				; return null
    copy	0,%ret0				; <delay slot> return val = 0

L$lock
    ldil	L'messageLock,%r1		; '
    ldo		R'messageLock(%r1),%r20		; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
L$spin
    ldcws	0(0,%r20),%r1			; try to lock it
    comib,=	0,%r1,L$spin			; if locked, try again
    nop						; <ds>
    b		L$continue			; rejoin mainline
    nop						; <ds>

L$unlock
    ldil	L'messageLock,%r1		; '
    ldo		R'messageLock(%r1),%r20		; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
    ldi		1,%r1				; get a one
    b		$$dyncall			;    goto *imp;
    .EXIT
    stw		%r1,0(0,%r20)			; <ds> clear lock

/*
** We have to save all the register based arguments (including floating
** point) before calling _class_lookupMethodAndLoadCache.  This is because
** we don't know what arguments were passed to us, and the arguments are
** not guaranteed to be saved across procedure calls (they're all caller-saved)
** We also have to save the return address (since we didn't save it on entry).
*/
L$cacheMiss
    .CALLINFO FRAME=80, CALLS, SAVE_RP, SAVE_SP, ENTRY_GR=3
    .ENTRY

    copy	%sp,%r19		; save sp in r19 to use store modify
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r19,%r3		; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker
    stw		%arg0,-36(0,%r3)	; save arg0 in fixed arg area
    stw		%arg1,-40(0,%r3)	; save arg1 in fixed arg area
    stw		%arg2,-44(0,%r3)	; save arg2 in fixed arg area
    stw		%arg3,-48(0,%r3)	; save arg3 in fixed arg area
    stw		%ret0,  4(0,%r3)	; save return struct ptr

    fstds,mb	%fr4,8(0,%r19)		; Save floating point args
    fstds,mb	%fr5,8(0,%r19)		; mb (modify before) is used
    fstds,mb	%fr6,8(0,%r19)
    fstds,mb	%fr7,8(0,%r19)

    .CALL
    bl		_class_lookupMethodAndLoadCache,2
    ldw		isa(0,%arg0),%arg0	; <delay slot> arg 0 = self->isa
    copy	%ret0,%r22		; move return value r22 for dyncall

    copy	%r3,%r19		; prev frame for fldds,mb
    fldds,mb	8(0,%r19),%fr4
    fldds,mb	8(0,%r19),%fr5
    fldds,mb	8(0,%r19),%fr6
    fldds,mb	8(0,%r19),%fr7

    ldw		   4(0,%r3),%ret0	; restore everything
    ldw		 -36(0,%r3),%arg0
    ldw		 -40(0,%r3),%arg1
    ldw		 -44(0,%r3),%arg2
    ldw		 -48(0,%r3),%arg3
    ldw		 -20(0,%r3),%rp		; restore return pointer
    ldwm	-128(0,%sp),%r3		; free stack, restore prev frame pointer

    ldil	L'_objc_multithread_mask,%r20		; '
    ldw		R'_objc_multithread_mask(%r20),%r20	; '
    comib,=	0,%r20,L$unlock		; unlock if multithreaded
    nop					; delay slot

    b		$$dyncall		; goto *imp (in r22);
    .EXIT
    nop
    .PROCEND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#define receiver	0
#define class		4

objc_msgSendSuper
    .PROC
    .CALLINFO
    .ENTRY

    ldil	L'_objc_multithread_mask,%r20		; '
    ldw		R'_objc_multithread_mask(%r20),%r31	; '
    comib,=	0,%r31,L$slock			; lock if multithreaded
    ldw		class(0,%arg0),%r19		; <ds> class = caller->class;
L$scontinue
    ldw		cache(0,%r19),%r20		; cache = class->cache
    ldw		mask(0,%r20),%r21		; mask = cache->mask
    ldo		buckets(%r20),%r20		; buckets = cache->buckets
    and		%r21,%arg1,%r22			; index = selector & mask;
L$LS1
    ldwx,s	%r22(0,%r20),%r19		; method = cache->buckets[index]
    comib,=,n	0,%r19,L$cacheMiss2		; if (method == NULL)
    ldw		method_name(0,%r19),%r1		; get method name
    addi	1,%r22,%r22			; ++index
    comb,<>	%r1, %arg1, L$LS1		; if (name!=sel) continue loop
    and		%r21,%r22,%r22			; <delay slot> index &=mask
    ldw		method_imp(0,%r19),%r22		; get method implementation
    comib,=	0,%r31,L$sunlock		; unlock if multithreaded
    ldw		receiver(0,%arg0),%arg0		; self = caller->receiver;
    b		$$dyncall			; goto *imp (in r22);
    nop

L$slock
    ldil	L'messageLock,%r1		; '
    ldo		R'messageLock(%r1),%r20		; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
L$sspin
    ldcws	0(0,%r20),%r1			; try to lock it
    comib,=	0,%r1,L$sspin			; if locked, try again
    nop						; <ds>
    b		L$scontinue			; rejoin mainline
    nop						; <ds>

L$sunlock
    ldil	L'messageLock,%r1		; '
    ldo		R'messageLock(%r1),%r20		; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
    ldi		1,%r1				; get a one
    b		$$dyncall			; goto *imp (in r22);
    .EXIT
    stw		%r1,0(0,%r20)			; <ds> clear lock

L$cacheMiss2
    .CALLINFO FRAME=80, CALLS, SAVE_RP, SAVE_SP, ENTRY_GR=3
    .ENTRY

    copy	%sp,%r19		; save sp in r19 to use store modify
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r19,%r3		; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker
    stw		%arg0,-36(0,%r3)	; save arg0 in fixed arg area
    stw		%arg1,-40(0,%r3)	; save arg1 in fixed arg area
    stw		%arg2,-44(0,%r3)	; save arg2 in fixed arg area
    stw		%arg3,-48(0,%r3)	; save arg3 in fixed arg area
    stw		%ret0,  4(0,%r3)	; save return struct ptr

    fstds,mb	%fr4,8(0,%r19)		; Save floating point args
    fstds,mb	%fr5,8(0,%r19)		; mb (modify before) is used
    fstds,mb	%fr6,8(0,%r19)
    fstds,mb	%fr7,8(0,%r19)

    .CALL
    bl		_class_lookupMethodAndLoadCache,2
    ldw		class(0,%arg0),%arg0	; <delay slot> arg0 = caller->class;
    copy	%ret0,%r22		; move return value r22 for dyncall

    copy	%r3,%r19		; prev frame for fldds,mb
    fldds,mb	8(0,%r19),%fr4
    fldds,mb	8(0,%r19),%fr5
    fldds,mb	8(0,%r19),%fr6
    fldds,mb	8(0,%r19),%fr7

    ldw		   4(0,%r3),%ret0	; restore everything
    ldw		 -36(0,%r3),%arg0
    ldw		 -40(0,%r3),%arg1
    ldw		 -44(0,%r3),%arg2
    ldw		 -48(0,%r3),%arg3
    ldw		 -20(0,%r3),%rp		; restore return pointer
    ldwm	-128(0,%sp),%r3		; free stack, restore prev frame pointer

    ldil	L'_objc_multithread_mask,%r20		; '
    ldw		R'_objc_multithread_mask(%r20),%r20	; '
    comib,=	0,%r20,L$unlock			; unlock if multithreaded
    ldw         receiver(0,%arg0),%arg0		; self = caller->receiver;

    b		$$dyncall			; goto *imp (in r22);
    .EXIT
    nop
    .PROCEND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .EXPORT OBJC_METH_VAR_NAME_FORWARD,DATA
    .SPACE $PRIVATE$
    .SUBSPA $DATA$
OBJC_METH_VAR_NAME_FORWARD:
    .STRING "forward::\0"

    .SUBSPA $$OBJC_MESSAGE_REFS$$,QUAD=1,ALIGN=4,ACCESS=31
forwardstr
    .word OBJC_METH_VAR_NAME_FORWARD

    .DATA
;   .cstring
;   .align 1
errstr
    .string "Does not recognize selector %s\0"

    .CODE

;
; NOTE: Because the stack grows from low mem to high mem on this machine
; and the args go the other way, the marg_list pointer is 4 above the first arg
; and subsequent arguments are at NEGATIVE offsets from the marg_list.
; This means that marg_getValue() and related macros will have to be adjusted
; appropriately.
;
_objc_msgForward
    .PROC
    .CALLINFO FRAME=80, CALLS, SAVE_RP, SAVE_SP, ENTRY_GR=3
    .ENTRY

    copy	%sp,%r19		; save sp
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r19,%r3		; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker
    stw		%arg3,-48(0,%r3)	; save args in fixed arg area
    stw		%arg2,-44(0,%r3)	; 
    stw		%arg1,-40(0,%r3)	; _cmd selector (arg1)
    stw		%arg0,-36(0,%r3)	; self

    addil       L'forwardstr-$global$,%dp	; '
    ldo         R'forwardstr-$global$(%r1),%r20	; '
    ldw         0(0,%r20),%r20			; get forward::
    combt,=,n	%r20,%arg1,L$error		; if (sel==@selector(forward::))

    ; Set up call as [self forward:sel :marg_list]
    copy   	%arg1,%arg2			; original selector in arg2
    copy   	%r20,%arg1			; forward:: as arg1 (_cmd)

    .CALL ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
    bl     	objc_msgSend,2			; call forward::
    ldo   	-32(%r3),%arg3			; <delay slot> copy original sel

    ldw		-20(0,%r3),%rp		; restore RP
    bv		0(%rp)			; return to caller
    ldwm	-128(0,%sp),%r3		; free stack, restore prev frame pointer

L$error
    addil  	L'errstr-$global$,%dp		; '
    ldo    	R'errstr-$global$(%r1),%arg1	; '
    .CALL ARGW0=GR,ARGW1=GR
    bl     	__objc_error,%rp		; __objc_error never returns,
    .EXIT
    copy   	%r20,%arg2			; so no need to clean up.
    .PROCEND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Algorithm is as follows:
; . Calculate how much stack size is needed for any arguments not in the
;   general registers and allocate space on stack.
; . Restore general argument regs from the bottom of the marg_list.
; . Restore fp argument regs from the same area.
;   The first two args in the marg list are always old obj and struct
;   return address - since old selector (_cmd) is not needed, struct
;   return (which might be needed) is stashed in place of _cmd.
; . Call the new method.

objc_msgSendv
    .PROC
    .CALLINFO FRAME=80, CALLS, SAVE_RP, SAVE_SP, ENTRY_GR=3
    .ENTRY

    copy	%sp,%r19		; save sp
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r19,%r3		; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker

    ldo    	95(%arg2),%r19		; Calculate frame size, rounded
    depi   	0,31,6,%r19		; up to 64 byte boundary...
    add    	%r19,%sp,%sp		; Allocate frame area (no locals)

    copy   	%arg2,%r20		; r20 now holds arg size
    ldo    	-16(%arg3),%r21		; r21 now holds marg_list+16
    ldws   	0(0,%r21),%arg3		; Get old general register args 2-3
    ldws   	4(0,%r21),%arg2		; (self and sel not needed)
    fldds  	0(0,%r21),%fr7		; Mirror to fp regs
    fldws   	4(0,%r21),%fr6		; ditto

    ldo    	-52(%sp),%r22		; newly allocated stack area.
    ldo    	-8(%r20),%r20		; Size -= 8
    comibf,<,n	0,%r20,L$L36
L$L35
    ldws,mb	-4(0,%r21),%r19		; while(size>0)
    addibf,<=	-4,%r20,L$L35		;  { *(dest--) = *(src--); size-=4; }
    stws,ma	%r19,-4(0,%r22)		; <delay slot>

    .CALL ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
L$L36
    bl     	objc_msgSend,2		; Call method
    nop

    ldw		-20(0,%r3),%rp		; restore RP
    ldo		128(%r3),%sp		; restore SP (free variable space)
    bv		0(%rp)			; return to caller
    .EXIT
    ldwm	-128(0,%sp),%r3		; restore frame pointer & free stack
    .PROCEND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;
;; Lock routines
;;
;;

;;
;; Lock routine
;;
_objc_private_lock
    .PROC
    .CALLINFO FRAME=0,NO_CALLS
    .ENTRY
    addi	0xf,%arg0,%arg0		; add 15
    depi	0,31,4,%arg0		; clear low byte to align on 16
L_lockspin:
    ldcws	0(0,%arg0),%r1		; try to lock it
    comib,=	0,%r1,L_lockspin	; if had 0, try again
    nop					; <ds>
    .EXIT
    bv,n	0(%rp)			; return
    .PROCEND
;;
;; Unlock routine
;;
_objc_private_unlock
    .PROC
    .CALLINFO FRAME=0,NO_CALLS
    .ENTRY
    addi	0xf,%arg0,%arg0		; add 15
    depi	0,31,4,%arg0		; clear low byte to align on 16
    ldi		1,%r1			; get a one
    bv		0(%rp)			; return
    .EXIT
    stw		%r1,0(0,%arg0)		; <ds> clear lock
    .PROCEND

;
;
; Imports and Exports
;
;

    .IMPORT $global$,DATA
    .IMPORT $$dyncall,MILLICODE
    .IMPORT _objc_multithread_mask,DATA
    .IMPORT messageLock,DATA
    .IMPORT _class_lookupMethodAndLoadCache,CODE
    .IMPORT __objc_error,CODE

    .EXPORT objc_msgSend,        ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
    .EXPORT objc_msgSendv,       ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
    .EXPORT objc_msgSendSuper,   ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
    .EXPORT _objc_msgForward,    ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
    .EXPORT _objc_private_lock,  ENTRY,PRIV_LEV=3,ARGW0=GR
    .EXPORT _objc_private_unlock,ENTRY,PRIV_LEV=3,ARGW0=GR

