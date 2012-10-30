/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
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
/*
  Implementation of the "objc runtime pages", an fixed area 
  in high memory that can be reached via an absolute branch.
*/

#import "objc-private.h"
#import <objc/message.h>


#if defined(__ppc__)

static size_t rtp_copy_code(unsigned* dest, unsigned* source, size_t max_insns);
static void rtp_set_up_objc_msgSend(uintptr_t address, size_t maxsize);
static void rtp_set_up_other(uintptr_t address, size_t maxsize, const char *name, void *gc_code, void *non_gc_code);

/**********************************************************************
* rtp_init
* Allocate and initialize the Objective-C runtime pages.
* Kills the process if something goes wrong.
**********************************************************************/
__private_extern__ void rtp_init(void)
{
    kern_return_t ret;
    vm_address_t objcRTPages = (vm_address_t)(kRTPagesHi - kRTPagesSize);

    if (PrintRTP) {
        _objc_inform("RTP: initializing rtp at [%p..%p)", 
                     (void *)objcRTPages, (void *)kRTPagesHi);
    }

    // unprotect the ObjC runtime pages for writing
    ret = vm_protect(mach_task_self(),
                     objcRTPages, kRTPagesSize,
                     FALSE, VM_PROT_READ | VM_PROT_WRITE);
                     
    if (ret != KERN_SUCCESS) {
        if (PrintRTP) {
            _objc_inform("RTP: warning: libSystem/kernel did not allocate Objective-C runtime pages; continuing anyway");
        }
        return;
    }
    
    // initialize code in ObjC runtime pages
    rtp_set_up_objc_msgSend(kRTAddress_objc_msgSend, kRTSize_objc_msgSend);
#ifdef NO_GC
    #define objc_assign_ivar_gc objc_assign_ivar_non_gc
    #define objc_assign_global_gc objc_assign_global_non_gc
    #define objc_assign_strongCast_gc objc_assign_strongCast_non_gc
#endif
    rtp_set_up_other(kRTAddress_objc_assign_ivar, kRTSize_objc_assign_ivar,
                    "objc_assign_ivar", objc_assign_ivar_gc, objc_assign_ivar_non_gc);
                    
    rtp_set_up_other(kRTAddress_objc_assign_global, kRTSize_objc_assign_global,
                    "objc_assign_global", objc_assign_global_gc, objc_assign_global_non_gc);
                    
    rtp_set_up_other(kRTAddress_objc_assign_strongCast, kRTSize_objc_assign_strongCast,
                    "objc_assign_strongCast", objc_assign_strongCast_gc, objc_assign_strongCast_non_gc);

    // initialize data in ObjC runtime pages
    memset((char *)kRTAddress_zero, 0, 16);
    strlcpy((char *)kIgnore, "<ignored selector>", OBJC_SIZE_T(19));

    // re-protect the ObjC runtime pages for execution
    ret = vm_protect(mach_task_self(),
                     objcRTPages, kRTPagesSize,
                     FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (ret != KERN_SUCCESS) {
        _objc_inform("RTP: Could not re-protect Objective-C runtime pages!");
    }
}


/**********************************************************************
* rtp_set_up_objc_msgSend
*
* Construct the objc runtime page version of objc_msgSend
* address is the entry point of the new implementation.
* maxsize is the number of bytes available for the new implementation.
**********************************************************************/
static void rtp_set_up_objc_msgSend(uintptr_t address, size_t maxsize) 
{
    // Location in the runtime pages of the new function.
    unsigned *buffer = (unsigned *)address;

    // Location of the original implementation.
    // objc_msgSend is simple enough to copy directly
    unsigned *code = (unsigned *)objc_msgSend;
    
    // If building an instrumented or profiled runtime, simply branch 
    // directly to the full implementation.
#if defined(OBJC_INSTRUMENTED) || defined(PROFILE)
    size_t written = objc_write_branch(buffer, code);
    sys_icache_invalidate(buffer, written*4);
    if (PrintRTP) {
        _objc_inform("RTP: instrumented or profiled libobjc - objc_msgSend "
                     "in RTP at %p is a %zu instruction branch", 
                     buffer, written);
    }
    return;
#endif

    if (PrintRTP) {
        _objc_inform("RTP: writing objc_msgSend at [%p..%p) ...", 
                     (void *)address, (void *)(address+maxsize));
    }

    // Copy instructions from function to runtime pages
    // i is the number of INSTRUCTIONS written so far
    size_t max_insns = maxsize / sizeof(unsigned);
    size_t i = rtp_copy_code(buffer, code, max_insns);
    if (i + objc_branch_size(buffer + i, code + i) > max_insns) {
        // objc_msgSend didn't fit in the alloted space.
        // Branch to ordinary objc_msgSend instead so the program won't crash.
        i = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, i*4);
        _objc_inform("RTP: objc_msgSend is too large to fit in the "
                     "runtime pages (%zu bytes available)", maxsize);
        return;
    }
    
    { 
        // Replace load of _objc_nilReceiver into r11
        // This assumes that the load of _objc_nilReceiver
        // immediately follows the LAST `mflr r0` in objc_msgSend, 
        // and that the original load sequence is six instructions long.

        // instructions used to load _objc_nilReceiver
        const unsigned op_mflr_r0    = 0x7c0802a6u;
        const unsigned op_nop     = 0x60000000u;
        
        // get address of _objc_nilReceiver, and its lo and hi halves
        uintptr_t address = (uintptr_t)&_objc_nilReceiver;
        uint16_t lo = address & 0xffff;
        uint16_t ha = ((address - (int16_t)lo) >> 16) & 0xffff;
#if defined(__ppc64__)
        uint16_t hi2 = (address >> 32) & 0xffff;
        uint16_t hi3 = (address >> 48) & 0xffff;
#endif

        // search for mflr instruction
        size_t j;
        for (j = i; j-- != 0; ) {
            if (buffer[j] == op_mflr_r0) {
                const unsigned op_lis_r11 = 0x3d600000u;
                const unsigned op_lwz_r11 = 0x816b0000u;
#if defined(__ppc__)
                // lis r11, ha
                // lwz r11, lo(r11)
                buffer[j + 0] = op_lis_r11 | ha;
                buffer[j + 1] = op_nop;
                buffer[j + 2] = op_nop;
                buffer[j + 3] = op_lwz_r11 | lo;
                buffer[j + 4] = op_nop;
                buffer[j + 5] = op_nop;
#elif defined(__ppc64__)
                const unsigned op_ori_r11 = 0x616b0000u;
                const unsigned op_oris_r11 = 0x656b0000u;
                const unsigned op_sldi_r11 = 0x796b07c6u;
                // lis  r11, hi3
                // ori  r11, r11, hi2
                // sldi r11, r11, 32
                // oris r11, r11, ha
                // lwz  r11, lo(r11)
                buffer[j + 0] = op_lis_r11  | hi3;
                buffer[j + 1] = op_ori_r11  | hi2;
                buffer[j + 2] = op_sldi_r11;
                buffer[j + 3] = op_oris_r11 | ha;
                buffer[j + 4] = op_lwz_r11  | lo;
                buffer[j + 5] = op_nop;
#endif
                break;
            }
        }
    }
    
    // branch to the cache miss code
    i += objc_write_branch(buffer + i, code + i);
    
    // flush the instruction cache
    sys_icache_invalidate(buffer, i*4);

    if (PrintRTP) {
        _objc_inform("RTP: wrote   objc_msgSend at [%p..%p)", 
                     (void *)address, (void *)(address + i*sizeof(unsigned)));
    }
}


/**********************************************************************
* rtp_set_up_other
*
* construct the objc runtime page version of the supplied code
* address is the entry point of the new implementation.
* maxsize is the number of bytes available for the new implementation.
* name is the c string name of the routine being set up.
* gc_code is the code to use if collecting is enabled (assumed to be large and requiring a branch.)
* non_gc_code is the code to use if collecting is not enabled (assumed to be small enough to copy.)
**********************************************************************/
static void rtp_set_up_other(uintptr_t address, size_t maxsize, const char *name, void *gc_code, void *non_gc_code) {
    // location in the runtime pages of this function
    unsigned *buffer = (unsigned *)address;
    
    // Location of the original implementation.
    unsigned *code = (unsigned *)(objc_collecting_enabled() ? gc_code : non_gc_code);
    
    if (objc_collecting_enabled()) {
        size_t written = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, written*4);
        if (PrintRTP) {
            _objc_inform("RTP: %s in RTP at %p is a %zu instruction branch", 
                         name, buffer, written);
        }
        return;
    }

    if (PrintRTP) {
        _objc_inform("RTP: writing %s at [%p..%p) ...", 
                     name, (void *)address, (void *)(address + maxsize));
    }

    // Copy instructions from function to runtime pages
    // i is the number of INSTRUCTIONS written so far
    size_t max_insns = maxsize / sizeof(unsigned);
    size_t i = rtp_copy_code(buffer, code, max_insns);
    if (i > max_insns) {
        // code didn't fit in the alloted space.
        // Branch to ordinary objc_assign_ivar instead so the program won't crash.
        i = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, i*4);
        _objc_inform("RTP: %s is too large to fit in the "
                     "runtime pages (%zu bytes available)", name, maxsize);
        return;
    }
    
    // flush the instruction cache
    sys_icache_invalidate(buffer, i*4);

    if (PrintRTP) {
        _objc_inform("RTP: wrote %s at [%p..%p)", 
                     name, (void *)address, 
                     (void *)(address + i * sizeof(unsigned)));
    }
}


/**********************************************************************
* rtp_copy_code
*
* Copy blr-terminated PPC instructions from source to dest.
* If a blr is reached then that blr is copied, and the return value is 
*   the number of instructions copied ( <= max_insns )
* If no blr is reached then exactly max_insns instructions are copied, 
*   and the return value is max_insns+1.
**********************************************************************/
static size_t rtp_copy_code(unsigned* dest, unsigned* source, size_t max_insns)
{
    const unsigned op_blr = 0x4e800020u;
    size_t i;
    
    // copy instructions until blr is found
    for (i = 0; i < max_insns; i++) {
        dest[i] = source[i];
        if (source[i] == op_blr) break;
    }
    
    // return number of instructions copied
    // OR max_insns+1 if no blr was found
    return i + 1;
}


#elif defined(__i386__)


/**********************************************************************
* rtp_swap_imp
*
* Swap a function's current implementation with a new one.
* The routine at 'address' is assumed to be at least as large as the
*   jump instruction required to reach the new implementation.
**********************************************************************/
static void rtp_swap_imp(unsigned *address, void *code, const char *name)
{
    if (vm_protect(mach_task_self(), (vm_address_t)address, 1,
        FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
        _objc_fatal("Could not get write access to %s.", name);
    else
    {
        objc_write_branch(address, (unsigned*)code);

        if (vm_protect(mach_task_self(), (vm_address_t)address, 1,
            FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS)
            _objc_fatal("Could not reprotect %s.", name);
    }
}


__private_extern__ void rtp_init(void)
{
    // At load time, the page on which the objc_assign_* routines live is not
    // marked as executable. We fix that here, regardless of the GC choice.
#ifndef NO_GC
    if (UseGC)
    {
        rtp_swap_imp((unsigned*)objc_assign_ivar,
            objc_assign_ivar_gc, "objc_assign_ivar");
        rtp_swap_imp((unsigned*)objc_assign_global,
            objc_assign_global_gc, "objc_assign_global");
        rtp_swap_imp((unsigned*)objc_assign_strongCast,
            objc_assign_strongCast_gc, "objc_assign_strongCast");
    }
    else
#endif
    {   // Not GC, just make the page executable.
        if (vm_protect(mach_task_self(), (vm_address_t)objc_assign_ivar, 1,
            FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS)
            _objc_fatal("Could not reprotect objc_assign_*.");
    }
}


#else


__private_extern__ void rtp_init(void)
{
    if (PrintRTP) {
        _objc_inform("RTP: no rtp implementation for this platform");
    }
}


#endif

