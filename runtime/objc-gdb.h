/*
 * Copyright (c) 2008 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_GDB_H
#define _OBJC_GDB_H

/* 
 * WARNING  DANGER  HAZARD  BEWARE  EEK
 * 
 * Everything in this file is for debugger and developer tool use only.
 * These will change in arbitrary OS updates and in unpredictable ways.
 * When your program breaks, you get to keep both pieces.
 */

#ifdef __APPLE_API_PRIVATE

#include <stdint.h>
#include <objc/hashtable.h>
#include <objc/maptable.h>


/***********************************************************************
* Trampoline descriptors for gdb.
**********************************************************************/

typedef struct {
    uint32_t offset;  // 0 = unused, else code = (uintptr_t)desc + desc->offset
    uint32_t flags;
} objc_trampoline_descriptor;
#define OBJC_TRAMPOLINE_MESSAGE (1<<0)   // trampoline acts like objc_msgSend
#define OBJC_TRAMPOLINE_STRET   (1<<1)   // trampoline is struct-returning
#define OBJC_TRAMPOLINE_VTABLE  (1<<2)   // trampoline is vtable dispatcher

typedef struct objc_trampoline_header {
    uint16_t headerSize;  // sizeof(objc_trampoline_header)
    uint16_t descSize;    // sizeof(objc_trampoline_descriptor)
    uint32_t descCount;   // number of descriptors following this header
    struct objc_trampoline_header *next;
} objc_trampoline_header;

extern objc_trampoline_header *gdb_objc_trampolines;

extern void gdb_objc_trampolines_changed(objc_trampoline_header *thdr);
// Notify gdb that gdb_objc_trampolines has changed.
// thdr itself includes the new descriptors; thdr->next is not new.


/***********************************************************************
* Debugger mode.
**********************************************************************/

// Start debugger mode. 
// Returns non-zero if debugger mode was successfully started.
// In debugger mode, you can try to use the runtime without deadlocking 
// on other threads. All other threads must be stopped during debugger mode. 
// OBJC_DEBUGMODE_FULL requires more locks so later operations are less 
// likely to fail.
#define OBJC_DEBUGMODE_FULL (1<<0)
extern int gdb_objc_startDebuggerMode(uint32_t flags);

// Stop debugger mode. Do not call if startDebuggerMode returned zero.
extern void gdb_objc_endDebuggerMode(void);

// Failure hook when debugger mode tries something that would block.
// Set a breakpoint here to handle it before the runtime causes a trap.
// Debugger mode is still active; call endDebuggerMode to end it.
extern void gdb_objc_debuggerModeFailure(void);


/***********************************************************************
* Class lists for heap.
**********************************************************************/

#if __OBJC2__

// Maps class name to Class, for in-use classes only. NXStrValueMapPrototype.
extern NXMapTable *gdb_objc_realized_classes;

#else

// Hashes Classes, for all known classes. Custom prototype.
extern NXHashTable *_objc_debug_class_hash;

#endif

/***********************************************************************
 * Garbage Collector heap dump
**********************************************************************/

/* Dump GC heap; if supplied the name is returned in filenamebuffer.  Returns YES on success. */
OBJC_GC_EXPORT BOOL objc_dumpHeap(char *filenamebuffer, unsigned long length);

#define OBJC_HEAP_DUMP_FILENAME_FORMAT "/tmp/objc-gc-heap-dump-%d-%d"


#endif
#endif
