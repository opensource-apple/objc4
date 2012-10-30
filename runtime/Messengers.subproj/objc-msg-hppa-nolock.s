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
#ifdef KERNEL
#define OBJC_LOCK_ROUTINE _simple_lock
#else
; _objc_entryPoints and _objc_exitPoints are used by moninitobjc() to setup
; objective-C messages for profiling.  The are made private_externs when in
; a shared library.
	.reference _moninitobjc
	.const
	.align 2
.globl _objc_entryPoints
_objc_entryPoints:
	.long _objc_msgSend
	.long _objc_msgSendSuper
	.long 0

.globl _objc_exitPoints
_objc_exitPoints:
	.long Lexit1
	.long Lexit5
	.long 0
	
#define OBJC_LOCK_ROUTINE _spin_lock
#endif /* KERNEL */

#define isa 0
#define cache 32
#define mask  0
#define buckets 8
#define method_name 0
#define method_imp 8


; optimized for hppa: 20? clocks (best case) + 6 clocks / probe

        .text
	.align 4
	.globl _objc_msgSend
	
_objc_msgSend:
        comib,<>,n  0,%r26,L0		; if (self) goto normalcase
	nop
        bv      0(%r2)                  ; else return null
        copy    0,%r28                  ; <delay slot> return val = 0
L0:     
        ldw      isa(0,%r26),%r19       ;     class = self->isa;
        ldw      cache(0,%r19),%r20     ;     cache = class->cache
        ldw      mask(0,%r20),%r21      ;     mask = cache->mask
        ldo      buckets(%r20),%r20     ;     buckets = cache->buckets
        and      %r21,%r25,%r22         ;     index = selector & mask;
L1:
        ldwx,s   %r22(0,%r20),%r19	;     method = cache->buckets[index];
        comib,=,n 0,%r19,LcacheMiss	;     if (method == NULL)
        ldw     method_name(0,%r19),%r1 ; 
        addi    1,%r22,%r22             ; ++index
        comb,<> %r1, %r25, L1		; if (name!=sel) continue loop
        and     %r21,%r22,%r22          ; <delay slot> index &=mask
        ldw     method_imp(0,%r19),%r19
Lexit1:
        bv,n     0(%r19)                ;    goto *imp;  (nullify delay)

#ifdef MONINIT
        .space 128                      ; /* area for moninitobjc to write */
#endif

LcacheMiss:
; We have to save all the register based arguments (including floating
; point) before calling _class_lookupMethodAndLoadCache.  This is because
; we do not know what arguments were passed to us, and the arguments are
; not guaranteed to be saved across procedure calls (they are all caller-saved)
; We also have to save the return address (since we did not save it on entry).


        copy    %r30,%r19
        ldo     128(%r30),%r30          ; Allocate space on stack
        stwm    %r2,4(0,%r19)           ; Save return pointer
        stwm    %r23,4(0,%r19)          ; Save old args
        stwm    %r24,4(0,%r19)          ;
        stwm    %r25,4(0,%r19)          ;
        stwm    %r26,4(0,%r19)          ;
#ifndef KERNEL
        fstds,mb  %fr4,4(0,%r19)        ; Save floating point args
        fstds,mb  %fr5,8(0,%r19)        ;    mb (modify before) is used instead
        fstds,mb  %fr6,8(0,%r19)        ;    of ma (as is implicit in above
        fstds,mb  %fr7,8(0,%r19)        ;    stores) with an initial value of 4
                                        ;    so that doubles are aligned
                                        ;    to 8 byte boundaries.
                                        ; Arg 1 (selector) is the same
#endif /* KERNEL */		

        stw     %r28,8(0,%r19)          ; save return struct ptr
        ldw      isa(0,%r26),%r26       ; arg 0 = self->isa
        CALL_EXTERN(__class_lookupMethodAndLoadCache)

        ldo     -128(%r30),%r30         ;   deallocate
        copy    %r30,%r19               ;
        ldwm    4(0,%r19),%r2           ; restore everything
        ldwm    4(0,%r19),%r23          ; 
        ldwm    4(0,%r19),%r24          ;
        ldwm    4(0,%r19),%r25          ;
        ldwm    4(0,%r19),%r26          ;
#ifndef KERNEL
        fldds,mb  4(0,%r19),%fr4        ; see comment above about alignment
        fldds,mb  8(0,%r19),%fr5        ;
        fldds,mb  8(0,%r19),%fr6        ;
        fldds,mb  8(0,%r19),%fr7        ;
#endif /* KERNEL */		
        ldw     8(0,%r19),%r20          ; get ret structure ptr

        copy    %r28,%r19
        copy    %r20,%r28               ; restore ret structure ptr
Lexit2:
        bv,n    0(%r19)                 ;  goto *imp   (nullify delay)

#ifdef MONINIT
        .space 128                      ; /* area for moninitobjc to write */
#endif





#define receiver 0
#define class 4

        .globl _objc_msgSendSuper
_objc_msgSendSuper:
        ldw      class(0,%r26),%r19     ;     class = caller->class;
        ldw      cache(0,%r19),%r20     ;     cache = class->cache
        ldw      mask(0,%r20),%r21      ;     mask = cache->mask
        ldo      buckets(%r20),%r20     ;     buckets = cache->buckets
        and      %r21,%r25,%r22         ;     index = selector & mask;
LS1:					;
        ldwx,s   %r22(0,%r20),%r19      ;     method = cache->buckets[index];
        comib,=,n 0,%r19,LS2           ;     if (method == NULL)
        ldw     method_name(0,%r19),%r1; 
        addi    1,%r22,%r22             ; ++index
        comb,<> %r1, %r25, LS1          ; if (name!=sel) continue loop
        and     %r21,%r22,%r22          ; <delay slot> index &=mask
        ldw     method_imp(0,%r19),%r19
        ldw     receiver(0,%r26),%r26   ;     self = caller->receiver;
Lexit5:  
        bv,n     0(%r19)                ;    goto *imp;  (nullify delay)
#ifdef MONINIT
        .space 128                      ; /* area for moninitobjc to write */
#endif

                                        ;
LS2:					;
        copy    %r30,%r19
        ldo     128(%r30),%r30          ; Allocate space on stack
        stwm    %r2,4(0,%r19)           ; Save return pointer
        stwm    %r23,4(0,%r19)          ; Save old args
        stwm    %r24,4(0,%r19)          ;
        stwm    %r25,4(0,%r19)          ;
        stwm    %r26,4(0,%r19)          ;
#ifndef KERNEL		
        fstds,mb  %fr4,4(0,%r19)        ; Save floating point args
        fstds,mb  %fr5,8(0,%r19)        ;    mb (modify before) is used instead
        fstds,mb  %fr6,8(0,%r19)        ;    of ma (as is implicit in above
        fstds,mb  %fr7,8(0,%r19)        ;    stores) with an initial value of 4
                                        ;    so that doubles are aligned
                                        ;    to 8 byte boundaries.
                                        ; Arg 1 (selector) is the same
#endif /* KERNEL */										
        stw     %r28,8(0,%r19)          ; save return struct ptr
        ldw      class(0,%r26),%r26     ; arg 0 = caller->class;
        CALL_EXTERN_AGAIN(__class_lookupMethodAndLoadCache)

        ldo     -128(%r30),%r30         ;   deallocate
        copy    %r30,%r19               ;
        ldwm    4(0,%r19),%r2           ; restore everything
        ldwm    4(0,%r19),%r23          ; 
        ldwm    4(0,%r19),%r24          ;
        ldwm    4(0,%r19),%r25          ;
        ldwm    4(0,%r19),%r26          ;
#ifndef KERNEL				
        fldds,mb  4(0,%r19),%fr4        ; see comment above about alignment
        fldds,mb  8(0,%r19),%fr5        ;
        fldds,mb  8(0,%r19),%fr6        ;
        fldds,mb  8(0,%r19),%fr7        ;
#endif /* KERNEL */										
        ldw     8(0,%r19),%r20          ; get ret structure ptr
        ldw      receiver(0,%r26),%r26  ;     self = caller->receiver;
        copy    %r28,%r19
        copy    %r20,%r28
Lexit6:  bv,n    0(%r19)                 ;  goto *imp   (nullify delay)

#ifdef MONINIT
        .space 128                      ; /* area for moninitobjc to write */
#endif

        
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
.align 1
;
; NOTE: Because the stack grows from low mem to high mem on this machine
; and the args go the other way, the marg_list pointer is to the first argument
; and subsequent arguments are at NEGATIVE offsets from the marg_list.
; This means that marg_getValue() and related macros will have to be adjusted
; appropriately.
;
	.globl __objc_msgForward
__objc_msgForward:
        stw     %r2,-20(0,%r30)         ; save rp
        ldo     64(%r30),%r30           ; create frame area (no locals needed)
        ldil    L`L31,%r1
        ldo     R`L31(%r1),%r19
        ldw     0(0,%r19),%r19
        combt,=,n %r19, %r25,L34	; if (sel==@selector(forward::))
        ldo     -112(%r30),%r20         ; ptr to arg3 homing area
        stwm    %r23,4(0,%r20)          ; Mirror registers onto stack
        stwm    %r24,4(0,%r20)          ;
        stwm    %r25,4(0,%r20)          ;
        stwm    %r26,4(0,%r20)          ;
        
        copy    %r25,%r24
        copy    %r19,%r25               ; [self forward:sel :marg_list]

        bl      _objc_msgSend,%r2
        copy    %r20,%r23               ; <delay slot> copy original sel

        ldo     -64(%r30),%r30		; deallocate
        ldw     -20(0,%r30),%r2		; restore rp
        bv,n    0(%r2)			; return
L34:
        ldil    L`L32,%r1
        ldo     R`L32(%r1),%r25
        copy    %r19,%r24                ; no need to clean up.
        BRANCH_EXTERN(__objc_error)


; Algorithm is as follows:
; . Calculate how much stack size is needed for any arguments not in the
;   general registers and allocate space on stack.
; . Restore general argument regs from the bottom of the marg_list.
; . Restore fp argument regs from the same area.
;   (The first two args in the marg list are always old obj and old SEL.)
; . Call the new method.
	.globl _objc_msgSendv
_objc_msgSendv:
                                        ; objc_msgSendv(self, sel, size, margs)
        stw     %r2,-20(0,%r30)         ; Save rp
        stw     %r4,-36(0,%r30)         ; Save callee-saved r4 
        copy    %r30,%r4                ; Save old sp vale
        ldo     95(%r24),%r19           ; Calculate frame size, rounded
        depi    0,31,6,%r19             ; up to 64 byte boundary...

        add     %r19,%r30,%r30          ; Allocate frame area (no locals)
        copy    %r24,%r20               ; r20 now holds arg size
        ldo     -16(%r23),%r21          ; r21 now holds marg_list+16
        ldws    0(0,%r21),%r23          ; Get old general register args (dont
        ldws    4(0,%r21),%r24          ; need first two: always self & SEL)
#ifndef KERNEL		
        fldds,mb   0(0,%r21),%fr7          ; Mirror to fp regs
        fldws   4(0,%r21),%fr6          ; 
#endif /* KERNEL */		

        ldo     -52(%r30),%r22          ; newly allocated stack area.
        ldo     -8(%r20),%r20           ; Size -= 8
        comibf,<,n 0,%r20,L36
L35:    ldws,mb -4(0,%r21),%r19         ; while(size>0)
        addibf,<= -4,%r20,L35		;  { *(dest--) = *(src--); size-=4; }
        stws,ma %r19,-4(0,%r22)         ; <delay slot>
L36:    bl      _objc_msgSend,%r2
        nop
        copy    %r4,%r30                ; deallocate
        ldw     -36(0,%r30), %r4
        ldw     -20(0,%r30), %r2
Lexit9:
        bv,n    0(%r2)


