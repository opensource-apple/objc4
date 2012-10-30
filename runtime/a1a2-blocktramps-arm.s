#if __arm__
	
#include <arm/arch.h>

.syntax unified

.text

	.private_extern __a1a2_tramphead
	.private_extern __a1a2_firsttramp
	.private_extern __a1a2_nexttramp
	.private_extern __a1a2_trampend

#ifdef _ARM_ARCH_7
	.thumb
	.thumb_func __a1a2_tramphead
	.thumb_func __a1a2_firsttramp
	.thumb_func __a1a2_nexttramp
	.thumb_func __a1a2_trampend
#else
	// don't use Thumb-1
	.arm
#endif
	
.align 12
__a1a2_tramphead:
	/*
	 r0 == self
	 r1 == pc of trampoline's first instruction + PC bias
	 lr == original return address
	 */

	// calculate the trampoline's index (512 entries, 8 bytes each)
#ifdef _ARM_ARCH_7
	// PC bias is only 4, no need to correct with 8-byte trampolines
	ubfx r1, r1, #3, #9
#else
	sub  r1, r1, #8               // correct PC bias
	lsl  r1, r1, #20
	lsr  r1, r1, #23
#endif

	// load block pointer from trampoline's data
	adr  r12, __a1a2_tramphead    // text page
	sub  r12, r12, #4096          // data page precedes text page
	ldr  r12, [r12, r1, LSL #3]   // load block pointer from data + index*8

	// shuffle parameters
	mov  r1, r0                   // _cmd = self
	mov  r0, r12                  // self = block pointer

	// tail call block->invoke
	ldr  pc, [r12, #12]
	// not reached

	// Make v6 and v7 match so they have the same number of TrampolineEntry
	// below. Debug asserts in objc-block-trampoline.m check this.
#ifdef _ARM_ARCH_7
	.space 16
#endif
	
.macro TrampolineEntry
	mov r1, pc
	b __a1a2_tramphead
	.align 3
.endmacro

.align 3
.private_extern __a1a2_firsttramp
__a1a2_firsttramp:
    TrampolineEntry

.private_extern __a1a2_nexttramp
__a1a2_nexttramp:
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry
TrampolineEntry

.private_extern __a1a2_trampend
__a1a2_trampend:

#endif
