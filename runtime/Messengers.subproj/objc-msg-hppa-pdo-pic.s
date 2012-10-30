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
** June 16, 1999 - Laurent Ramontianu
**    A PIC/sanitized version of the standard hppa-pdo messenger
**    for use with shared libraries.
*/

    .SPACE $PRIVATE$
    .SUBSPA $DATA$,QUAD=1,ALIGN=8,ACCESS=31
    .SUBSPA $BSS$,QUAD=1,ALIGN=8,ACCESS=31,ZERO,SORT=82
    .SUBSPA $$OBJC_MESSAGE_REFS$$,QUAD=1,ALIGN=4,ACCESS=31
    .SPACE $TEXT$
    .SUBSPA $LIT$,QUAD=0,ALIGN=8,ACCESS=44
    .SUBSPA $CODE$,QUAD=0,ALIGN=8,ACCESS=44,CODE_ONLY

    .IMPORT _objc_msgSend_v,DATA
    .IMPORT _objc_multithread_mask,DATA
    .IMPORT messageLock,DATA
    .IMPORT $$dyncall,MILLICODE
    .IMPORT _class_lookupMethodAndLoadCache,CODE
    .IMPORT __objc_error,CODE


#define isa		0
#define cache		32
#define mask		0
#define buckets		8
#define method_name	0
#define method_imp	8

;;
;; objc_msgSend: Standard messenger
;;

    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT objc_msgSend,CODE
    .EXPORT objc_msgSend,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
objc_msgSend
    .PROC
    .CALLINFO
    .ENTRY

    comib,=	0,%arg0,L$exitNull		; Return 0 if self == nil
    nop

    addil	LT'_objc_multithread_mask,%r19		; '
    ldw		RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    comib,=	0,%r1,L$lock			; lock if multithreaded
    nop

L$continue
    ldw 	isa(0,%arg0),%r20		; class = self->isa;
    ldw 	cache(0,%r20),%r20		; cache = class->cache
    ldw 	mask(0,%r20),%r21		; mask = cache->mask
    ldo 	buckets(%r20),%r20		; buckets = cache->buckets
    and 	%r21,%arg1,%r22			; index = selector & mask

L$loop
    ldwx,s	%r22(0,%r20),%r1		; method= cache->buckets[index]
    comib,=	0,%r1,L$cacheMiss		; if (method == NULL)
    nop

    ldw 	method_name(0,%r1),%r1		;
    comb,=	%r1,%arg1,L$finishOff		; if (name=sel) break loop
    nop

    addi	1,%r22,%r22			; ++index
    and 	%r22,%r21,%r22			; index &= mask
    b		L$loop				; continue loop
    nop

L$finishOff
    ldwx,s	%r22(0,%r20),%r1		; method= cache->buckets[index]
    ldw 	method_imp(0,%r1),%r22		; implementation into r22

    addil	LT'_objc_multithread_mask,%r19		; '
    ldw		RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    comib,=	0,%r1,L$unlock			; unlock if multithreaded
    nop

    b		__next_dynjmp			; goto *imp
    nop

L$exitNull
    bv		0(%rp)				; return null
    copy	0,%ret0				; <delay slot> return val = 0

L$lock
    addil	LT'messageLock,%r19		; '
    ldw		RT'messageLock(%r1),%r20	; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
L$spin
    ldcws	0(0,%r20),%r1			; try to lock it
    comib,=	0,%r1,L$spin			; if locked, try again
    nop

    b		L$continue			; rejoin mainline
    nop						; <ds>

L$unlock
    addil	LT'messageLock,%r19		; '
    ldw		RT'messageLock(%r1),%r20	; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
    ldi		1,%r1				; get a one
    stw		%r1,0(0,%r20)			; clear lock

    b		__next_dynjmp			; goto *imp
    .EXIT
    nop

/*
** We have to save all the register based arguments (including floating
** point) before calling _class_lookupMethodAndLoadCache.  This is because
** we don't know what arguments were passed to us, and the arguments are
** not guaranteed to be saved across procedure calls (they're all caller-saved)
** We also have to save the return address (since we didn't save it on entry).
*/
L$cacheMiss
    .CALLINFO FRAME=128,CALLS,SAVE_RP,SAVE_SP,ENTRY_GR=3
    .ENTRY

    copy	%sp,%r1			; save sp in r1 to use store modify
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r1,%r3			; establish new frame pointer

    stw		%rp,-20(0,%r3)		; save rp in frame marker
    stw		%sp,-4(0,%r3)		; save sp in frame marker

    stw		%arg0,-36(0,%r3)	; save arg0 in fixed arg area
    stw		%arg1,-40(0,%r3)	; save arg1 in fixed arg area
    stw		%arg2,-44(0,%r3)	; save arg2 in fixed arg area
    stw		%arg3,-48(0,%r3)	; save arg3 in fixed arg area
    stw		%ret0,4(0,%r3)		; save return struct ptr
    stw		%ret1,8(0,%r3)		; save return struct ptr

    fstds,mb	%fr4,8(0,%r1)		; Save floating point args
    fstds,mb	%fr5,8(0,%r1)		; mb (modify before) is used
    fstds,mb	%fr6,8(0,%r1)
    fstds,mb	%fr7,8(0,%r1)

    .CALL ARGW0=GR,ARGW1=GR
    bl		_class_lookupMethodAndLoadCache,2
    ldw		isa(0,%arg0),%arg0	; <delay slot> arg 0 = self->isa

    copy	%ret0,%r22		; move return value r22 for dynjmp

    copy	%r3,%r1			; prev frame for fldds,mb
    fldds,mb	8(0,%r1),%fr4
    fldds,mb	8(0,%r1),%fr5
    fldds,mb	8(0,%r1),%fr6
    fldds,mb	8(0,%r1),%fr7

    ldw		4(0,%r3),%ret0		; restore everything
    ldw		8(0,%r3),%ret1		; restore everything
    ldw		-36(0,%r3),%arg0
    ldw		-40(0,%r3),%arg1
    ldw		-44(0,%r3),%arg2
    ldw		-48(0,%r3),%arg3

    ldw		-20(0,%r3),%rp		; restore return pointer
    ldwm	-128(0,%sp),%r3		; free stack,restore prev frame pointer

    addil       LT'_objc_multithread_mask,%r19		; '
    ldw         RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    comib,=	0,%r1,L$unlock		; unlock if multithreaded
    nop

    b		__next_dynjmp		; goto *imp
    .EXIT
    nop
    .PROCEND


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#define receiver	0
#define class		4

    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT objc_msgSendSuper,CODE
    .EXPORT objc_msgSendSuper,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
objc_msgSendSuper
    .PROC
    .CALLINFO
    .ENTRY

    addil	LT'_objc_multithread_mask,%r19		; '
    ldw		RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    comib,=	0,%r1,L$slock			; lock if multithreaded
    nop

L$scontinue
    ldw		class(0,%arg0),%r20		; class = caller->class;
    ldw		cache(0,%r20),%r20		; cache = class->cache
    ldw		mask(0,%r20),%r21		; mask = cache->mask
    ldo		buckets(%r20),%r20		; buckets = cache->buckets
    and		%r21,%arg1,%r22			; index = selector & mask;

L$sloop
    ldwx,s	%r22(0,%r20),%r1		; method= cache->buckets[index]
    comib,=	0,%r1,L$scacheMiss		; if (method == NULL)
    nop

    ldw		method_name(0,%r1),%r1		;
    comb,=	%r1,%arg1,L$sfinishOff		; if (name=sel) break loop
    nop

    addi	1,%r22,%r22			; ++index
    and 	%r22,%r21,%r22			; index &= mask
    b		L$sloop				; continue loop
    nop

L$sfinishOff
    ldwx,s	%r22(0,%r20),%r1		; method= cache->buckets[index]
    ldw		method_imp(0,%r1),%r22		; implementation into r22

    addil	LT'_objc_multithread_mask,%r19		; '
    ldw		RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    ldw		receiver(0,%arg0),%arg0		; self = caller->receiver;
    comib,=	0,%r1,L$sunlock			; unlock if multithreaded
    nop

    b		__next_dynjmp			; goto *imp
    nop

L$slock
    addil	LT'messageLock,%r19		; '
    ldw		RT'messageLock(%r1),%r20	; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
L$sspin
    ldcws	0(0,%r20),%r1			; try to lock it
    comib,=	0,%r1,L$sspin			; if locked, try again
    nop

    b		L$scontinue			; rejoin mainline
    nop						; <ds>

L$sunlock
    addil	LT'messageLock,%r19		; '
    ldw		RT'messageLock(%r1),%r20	; '
    addi	0xf,%r20,%r20			; add 15
    depi	0,31,4,%r20			; clear low byte to align on 16
    ldi		1,%r1				; get a one
    stw		%r1,0(0,%r20)			; clear lock

    b		__next_dynjmp			; goto *imp
    .EXIT
    nop

L$scacheMiss
    .CALLINFO FRAME=128,CALLS,SAVE_RP,SAVE_SP,ENTRY_GR=3
    .ENTRY

    copy	%sp,%r1			; save sp in r1 to use store modify
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r1,%r3			; establish new frame pointer

    stw		%rp,-20(0,%r3)		; save rp in frame marker
    stw		%sp,-4(0,%r3)		; save sp in frame marker

    stw		%arg0,-36(0,%r3)	; save arg0 in fixed arg area
    stw		%arg1,-40(0,%r3)	; save arg1 in fixed arg area
    stw		%arg2,-44(0,%r3)	; save arg2 in fixed arg area
    stw		%arg3,-48(0,%r3)	; save arg3 in fixed arg area
    stw		%ret0,4(0,%r3)		; save return struct ptr
    stw		%ret1,8(0,%r3)		; save return struct ptr

    fstds,mb	%fr4,8(0,%r1)		; Save floating point args
    fstds,mb	%fr5,8(0,%r1)		; mb (modify before) is used
    fstds,mb	%fr6,8(0,%r1)
    fstds,mb	%fr7,8(0,%r1)

    .CALL ARGW0=GR,ARGW1=GR
    bl		_class_lookupMethodAndLoadCache,2
    ldw		class(0,%arg0),%arg0	; <delay slot> arg0 = caller->class

    copy	%ret0,%r22		; move return value to r22 for dynjmp

    copy	%r3,%r1			; prev frame for fldds,mb
    fldds,mb	8(0,%r1),%fr4
    fldds,mb	8(0,%r1),%fr5
    fldds,mb	8(0,%r1),%fr6
    fldds,mb	8(0,%r1),%fr7

    ldw		4(0,%r3),%ret0		; restore everything
    ldw		8(0,%r3),%ret1		; restore everything
    ldw		-36(0,%r3),%arg0
    ldw		-40(0,%r3),%arg1
    ldw		-44(0,%r3),%arg2
    ldw		-48(0,%r3),%arg3

    ldw		-20(0,%r3),%rp		; restore return pointer
    ldwm	-128(0,%sp),%r3		; free stack, restore prev frame pointer

    addil	LT'_objc_multithread_mask,%r19		; '
    ldw		RT'_objc_multithread_mask(%r1),%r1	; '
    ldw		0(0,%r1),%r1
    ldw		receiver(0,%arg0),%arg0	; self = caller->receiver;
    comib,=	0,%r1,L$sunlock		; unlock if multithreaded
    nop

    b		__next_dynjmp		; goto *imp
    .EXIT
    nop
    .PROCEND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .SPACE $PRIVATE$
    .SUBSPA $DATA$
    .align 4
    .EXPORT OBJC_METH_VAR_NAME_FORWARD,DATA

OBJC_METH_VAR_NAME_FORWARD:
    .STRING "forward::\0"

    .SPACE $PRIVATE$
    .SUBSPA $$OBJC_MESSAGE_REFS$$
    .align 4
forwardstr
    .word OBJC_METH_VAR_NAME_FORWARD

    .SPACE $PRIVATE$
    .SUBSPA $DATA$
;   .cstring
;   .align 1
errstr
    .string "Does not recognize selector %s\0"

;
; NOTE: Because the stack grows from low mem to high mem on this machine
; and the args go the other way, the marg_list pointer is 4 above the first arg
; and subsequent arguments are at NEGATIVE offsets from the marg_list.
; This means that marg_getValue() and related macros will have to be adjusted
; appropriately.
;
    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT _objc_msgForward,CODE
    .EXPORT _objc_msgForward,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
_objc_msgForward
    .PROC
    .CALLINFO FRAME=128,CALLS,SAVE_RP,SAVE_SP,ENTRY_GR=3
    .ENTRY

    copy	%sp,%r1			; save sp
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r1,%r3			; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker
    stw		%arg3,-48(0,%r3)	; save args in fixed arg area
    stw		%arg2,-44(0,%r3)	; ...
    stw		%arg1,-40(0,%r3)	; _cmd selector (arg1)
    stw		%arg0,-36(0,%r3)	; self

    addil	LT'forwardstr,%r19		; '
    ldw		RT'forwardstr(%r1),%r20		; '
    ldw         0(0,%r20),%r20		; get forward::
    combt,=	%r20,%arg1,L$error	; if (sel==@selector(forward::))
    nop

    ; Set up call as [self forward:sel :marg_list]
    copy   	%arg1,%arg2		; original selector in arg2
    copy   	%r20,%arg1		; forward:: as arg1 (_cmd)
    ldo   	-32(%r3),%arg3		; copy original sel

    addil	LT'_objc_msgSend_v,%r19		; '
    ldw		RT'_objc_msgSend_v(%r1),%r1	; '
    ldw		0(0,%r1),%r22
    .CALL ARGW0=GR
    bl		$$dyncall,%r31
    copy	%r31,%r2

    ldw		-20(0,%r3),%rp		; restore RP
    bv		0(%rp)			; return to caller
    ldwm	-128(0,%sp),%r3		; free stack, restore prev frame pointer

L$error
    addil	LT'errstr,%r19		; '
    ldw		RT'errstr(%r1),%arg1	; '
    .CALL ARGW0=GR,ARGW1=GR
    bl     	__objc_error,%rp	; __objc_error never returns,
    .EXIT
    copy   	%r20,%arg2		; so no need to clean up.
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

    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT objc_msgSendv,CODE
    .EXPORT objc_msgSendv,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
objc_msgSendv
    .PROC
    .CALLINFO FRAME=128,CALLS,SAVE_RP,SAVE_SP,ENTRY_GR=3
    .ENTRY

    copy	%sp,%r1			; save sp
    stwm	%r3,128(0,%sp)		; save frame pointer & allocate stack
    copy	%r1,%r3			; establish new frame pointer

    stw		%rp,  -20(0,%r3)	; save rp in frame marker
    stw		%sp,   -4(0,%r3)	; save sp in frame marker

    ldo    	95(%arg2),%r1		; Calculate frame size, rounded
    depi   	0,31,6,%r1		; up to 64 byte boundary...
    add    	%r1,%sp,%sp		; Allocate frame area (no locals)

    copy   	%arg2,%r20		; r20 now holds arg size
    ldo    	-16(%arg3),%r21		; r21 now holds marg_list+16
    ldws   	0(0,%r21),%arg3		; Get old general register args 2-3
    ldws   	4(0,%r21),%arg2		; (self and sel not needed)
    fldds  	0(0,%r21),%fr7		; Mirror to fp regs
    fldws   	4(0,%r21),%fr6		; ditto

    ldo    	-52(%sp),%r22		; newly allocated stack area.
    ldo    	-8(%r20),%r20		; Size -= 8
    comibf,<	0,%r20,L$L36
    nop
L$L35
    ldws,mb	-4(0,%r21),%r1		; while(size>0)
    addibf,<=	-4,%r20,L$L35		;  { *(dest--) = *(src--); size-=4; }
    stws,ma	%r1,-4(0,%r22)		; <delay slot>

L$L36
    addil	LT'_objc_msgSend_v,%r19		; '
    ldw		RT'_objc_msgSend_v(%r1),%r1	; '
    ldw		0(0,%r1),%r22
    .CALL ARGW0=GR
    bl		$$dyncall,%r31
    copy	%r31,%r2

    ldw		-20(0,%r3),%rp		; restore RP
    ldo		128(%r3),%sp		; restore SP (free variable space)

    ldwm	-128(0,%sp),%r3		; restore frame pointer & free stack
    bv		0(%rp)			; return to caller
    .EXIT
    nop
    .PROCEND


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;
;; lock/unlock routines
;;
;;

;;
;; Lock routine
;;
    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT _objc_private_lock,CODE
    .EXPORT _objc_private_lock,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
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
    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT _objc_private_unlock,CODE
    .EXPORT _objc_private_unlock,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
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

;;
;; __next_dynjmp routine
;;
    .SPACE $TEXT$
    .SUBSPA $CODE$
    .align 4
    .EXPORT __next_dynjmp,CODE
    .EXPORT __next_dynjmp,ENTRY,PRIV_LEV=3,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
__next_dynjmp
    .PROC
    .CALLINFO FRAME=0,NO_CALLS
    .ENTRY
    bb,>=,n %r22,0x1e,L$jumpExternal
    depi 0,31,2,%r22
    ldws 4(%sr0,%r22),%r19
    ldws 0(%sr0,%r22),%r22
L$jumpExternal
    ldsid (%sr0,%r22),%r1
    mtsp %r1,%sr0
    be 0(%sr0,%r22)
    .EXIT
    nop
    .PROCEND

