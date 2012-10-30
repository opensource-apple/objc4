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

#import "objc-private.h"
#import <objc/message.h>


#if defined(__i386__)


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


PRIVATE_EXTERN void rtp_init(void)
{
    // At load time, the page on which the objc_assign_* routines live is not
    // marked as executable. We fix that here, regardless of the GC choice.
#if SUPPORT_GC
    if (UseGC)
    {
        rtp_swap_imp((unsigned*)objc_assign_ivar,
            objc_assign_ivar_gc, "objc_assign_ivar");
        rtp_swap_imp((unsigned*)objc_assign_global,
            objc_assign_global_gc, "objc_assign_global");
        rtp_swap_imp((unsigned*)objc_assign_threadlocal,
            objc_assign_threadlocal_gc, "objc_assign_threadlocal");
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


PRIVATE_EXTERN void rtp_init(void)
{
    if (PrintRTP) {
        _objc_inform("RTP: no rtp implementation for this platform");
    }
}


#endif

