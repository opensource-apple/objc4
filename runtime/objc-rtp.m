/*
 * Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 2004 Apple Computer, Inc.  All Rights Reserved.
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
  objc-rtp.m
  Copyright 2004, Apple Computer, Inc.
  Author: Jim Laskey
  
  Implementation of the "objc runtime pages", an fixed area 
  in high memory that can be reached via an absolute branch.
*/

#import "objc-rtp.h"
#import "objc-private.h"
#import "objc-auto.h"

#import <stdint.h>
#import <mach/mach.h>


// Local prototypes

static void rtp_set_up_objc_msgSend(uintptr_t address, size_t maxsize);
static void rtp_set_up_other(uintptr_t address, size_t maxsize, const char *name, void *gc_code, void *non_gc_code);

#if defined(__ppc__)
// from Libc, but no prototype yet (#3850825)
extern void sys_icache_invalidate(const void * newcode, size_t len);

static size_t rtp_copy_code(unsigned* dest, unsigned* source, size_t max_insns);
#endif


#if !defined(__ppc__)

__private_extern__ void rtp_init(void)
{
    if (PrintRTP) {
        _objc_inform("RTP: no rtp implementation for this platform");
    }
}

#else

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
                     objcRTPages, kRTPagesHi);
    }

    // unprotect the ObjC runtime pages for writing
    ret = vm_protect(mach_task_self(),
                     objcRTPages, kRTPagesSize,
                     FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
                     
    if (ret != KERN_SUCCESS) {
        if (PrintRTP) {
            _objc_inform("RTP: warning: libSystem/kernel did not allocate Objective-C runtime pages; continuing anyway");
        }
        return;
    }
    
    // initialize code in ObjC runtime pages
    rtp_set_up_objc_msgSend(kRTAddress_objc_msgSend, kRTSize_objc_msgSend);
    
    rtp_set_up_other(kRTAddress_objc_assign_ivar, kRTSize_objc_assign_ivar,
                    "objc_assign_ivar", objc_assign_ivar_gc, objc_assign_ivar_non_gc);
                    
    rtp_set_up_other(kRTAddress_objc_assign_global, kRTSize_objc_assign_global,
                    "objc_assign_global", objc_assign_global_gc, objc_assign_global_non_gc);
                    
    rtp_set_up_other(kRTAddress_objc_assign_strongCast, kRTSize_objc_assign_strongCast,
                    "objc_assign_strongCast", objc_assign_strongCast_gc, objc_assign_strongCast_non_gc);

    // initialize data in ObjC runtime pages
    memset((char *)kRTAddress_zero, 0, 16);
    strcpy((char *)kIgnore, "<ignored selector>");

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
#if defined(__ppc__)
    // Location in the runtime pages of the new function.
    unsigned *buffer = (unsigned *)address;

    // Location of the original implementation.
    // objc_msgSend is simple enough to copy directly
    unsigned *code = (unsigned *)objc_msgSend;
    
    // If building an instrumented or profiled runtime, simply branch 
    // directly to the full implementation.
#if defined(OBJC_INSTRUMENTED) || defined(PROFILE)
    unsigned written = objc_write_branch(buffer, code);
    sys_icache_invalidate(buffer, written*4);
    if (PrintRTP) {
        _objc_inform("RTP: instrumented or profiled libobjc - objc_msgSend "
                     "in RTP at %p is a %d instruction branch", 
                     buffer, written);
    }
    return;
#endif

    // If function interposing is enabled, call the full implementation 
    // via a dyld-recognizable stub.
    if (AllowInterposing) {
        extern void objc_msgSend_stub(void);
        unsigned written = objc_write_branch(buffer, objc_msgSend_stub);
        sys_icache_invalidate(buffer, written*4);
        if (PrintRTP) {
            _objc_inform("RTP: interposing enabled - objc_msgSend "
                         "in RTP at %p is a %d instruction branch", 
                         buffer, written);
        }
        return;
    }

    if (PrintRTP) {
        _objc_inform("RTP: writing objc_msgSend at [%p..%p) ...", 
                     address, address+maxsize);
    }

    // Copy instructions from function to runtime pages
    // i is the number of INSTRUCTIONS written so far
    size_t max_insns = maxsize / sizeof(unsigned);
    size_t i = rtp_copy_code(buffer, code, max_insns);
    if (i > max_insns) {
        // objc_msgSend didn't fit in the alloted space.
        // Branch to ordinary objc_msgSend instead so the program won't crash.
        i = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, i*4);
        _objc_inform("RTP: objc_msgSend is too large to fit in the "
                     "runtime pages (%d bytes available)", maxsize);
        return;
    }
    
    { 
        // Replace load of _objc_nilReceiver.
        // This assumes that the load of _objc_nilReceiver
        // immediately follows the LAST `mflr r0` in objc_msgSend, 
        // and that the original load sequence is six instructions long.
        
        // instructions used to load _objc_nilReceiver
        const unsigned op_mflr_r0    = 0x7c0802a6u;
        const unsigned op_lis_r11 = 0x3d600000u;
        const unsigned op_lwz_r11 = 0x816b0000u;
        const unsigned op_nop     = 0x60000000u;
        
        // get address of _objc_nilReceiver, and its lo and hi halves
        unsigned address = (unsigned)&_objc_nilReceiver;
        signed lo = (signed short)address;
        signed ha = (address - lo) >> 16;
        
        // search for mflr instruction
        int j;
        for (j = i; j-- != 0; ) {
            if (buffer[j] == op_mflr_r0) {
                // replace with lis lwz nop nop sequence
                buffer[j + 0] = op_lis_r11 | (ha & 0xffff);
                buffer[j + 1] = op_nop;
                buffer[j + 2] = op_nop;
                buffer[j + 3] = op_lwz_r11 | (lo & 0xffff);
                buffer[j + 4] = op_nop;
                buffer[j + 5] = op_nop;
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
                     address, address + i*sizeof(unsigned));
    }

#elif defined(__i386__)
    #warning needs implementation
#else
    #error unknown architecture
#endif   
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
#if defined(__ppc__)
    // location in the runtime pages of this function
    unsigned *buffer = (unsigned *)address;
    
    // Location of the original implementation.
    unsigned *code = (unsigned *)(objc_collecting_enabled() ? gc_code : non_gc_code);
    
    if (objc_collecting_enabled()) {
        unsigned written = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, written*4);
        if (PrintRTP) {
            _objc_inform("RTP: %s in RTP at %p is a %d instruction branch", 
                         name, buffer, written);
        }
        return;
    }

    if (PrintRTP) {
        _objc_inform("RTP: writing %s at [%p..%p) ...", 
                     name, address, address + maxsize);
    }

    // Copy instructions from function to runtime pages
    // i is the number of INSTRUCTIONS written so far
    unsigned max_insns = maxsize / sizeof(unsigned);
    unsigned i = rtp_copy_code(buffer, code, max_insns);
    if (i > max_insns) {
        // code didn't fit in the alloted space.
        // Branch to ordinary objc_assign_ivar instead so the program won't crash.
        i = objc_write_branch(buffer, code);
        sys_icache_invalidate(buffer, i*4);
        _objc_inform("RTP: %s is too large to fit in the "
                     "runtime pages (%d bytes available)", name, maxsize);
        return;
    }
    
    // flush the instruction cache
    sys_icache_invalidate(buffer, i*4);

    if (PrintRTP) {
        _objc_inform("RTP: wrote %s at [%p..%p)", 
                     name, address, address + i * sizeof(unsigned));
    }

#elif defined(__i386__)
    #warning needs implementation
#else // defined(architecture)
    #error unknown architecture
#endif // defined(architecture)
}


#if defined(__ppc__)

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

// defined(__ppc__)
#endif

// defined(__ppc__)  ||  defined(__i386__)
#endif
