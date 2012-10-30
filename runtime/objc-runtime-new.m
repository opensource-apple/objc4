/*
 * Copyright (c) 2005-2008 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-runtime-new.m
* Support for new-ABI classes and images.
**********************************************************************/

#if __OBJC2__

#include "objc-private.h"
#include "objc-runtime-new.h"
#include <objc/message.h>

#define newcls(cls) ((struct class_t *)cls)
#define newcat(cat) ((struct category_t *)cat)
#define newmethod(meth) ((struct method_t *)meth)
#define newivar(ivar) ((struct ivar_t *)ivar)
#define newcategory(cat) ((struct category_t *)cat)
#define newprotocol(p) ((struct protocol_t *)p)

#ifdef __LP64__
#define WORD_SHIFT 3UL
#define WORD_MASK 7UL
#else
#define WORD_SHIFT 2UL
#define WORD_MASK 3UL
#endif

static const char *getName(struct class_t *cls);
static uint32_t instanceSize(struct class_t *cls);
static BOOL isMetaClass(struct class_t *cls);
static struct class_t *getSuperclass(struct class_t *cls);
static void unload_class(class_t *cls, BOOL isMeta);
static class_t *setSuperclass(class_t *cls, class_t *newSuper);
static class_t *realizeClass(class_t *cls);
static void flushCaches(class_t *cls);
static void flushVtables(class_t *cls);
static method_t *getMethodNoSuper_nolock(struct class_t *cls, SEL sel);
static method_t *getMethod_nolock(class_t *cls, SEL sel);
static void changeInfo(class_t *cls, unsigned int set, unsigned int clear);
static IMP _method_getImplementation(method_t *m);


/***********************************************************************
* Lock management
* Every lock used anywhere must be managed here. 
* Locks not managed here may cause gdb deadlocks.
**********************************************************************/
__private_extern__ rwlock_t runtimeLock = {0};
__private_extern__ rwlock_t selLock = {0};
__private_extern__ mutex_t cacheUpdateLock = MUTEX_INITIALIZER;
__private_extern__ recursive_mutex_t loadMethodLock = RECURSIVE_MUTEX_INITIALIZER;
static int debugger_runtimeLock;
static int debugger_selLock;
static int debugger_cacheUpdateLock;
static int debugger_loadMethodLock;
#define RDONLY 1
#define RDWR 2

__private_extern__ void lock_init(void)
{
    rwlock_init(&selLock);
    rwlock_init(&runtimeLock);
    recursive_mutex_init(&loadMethodLock);
}


/***********************************************************************
* startDebuggerMode
* Attempt to acquire some locks for debugger mode.
* Returns 0 if debugger mode failed because too many locks are unavailable.
*
* Locks successfully acquired are held until endDebuggerMode().
* Locks not acquired are off-limits until endDebuggerMode(); any 
*   attempt to manipulate them will cause a trap.
* Locks not handled here may cause deadlocks in gdb.
**********************************************************************/
__private_extern__ int startDebuggerMode(void)
{
    int result = DEBUGGER_FULL;

    // runtimeLock is required (can't do much without it)
    if (rwlock_try_write(&runtimeLock)) {
        debugger_runtimeLock = RDWR;
    } else if (rwlock_try_read(&runtimeLock)) {
        debugger_runtimeLock = RDONLY;
        result = DEBUGGER_PARTIAL;
    } else {
        return DEBUGGER_OFF;
    }

    // cacheUpdateLock is required (must not fail a necessary cache flush)
    // must be AFTER runtimeLock to avoid lock inversion
    if (mutex_try_lock(&cacheUpdateLock)) {
        debugger_cacheUpdateLock = RDWR;
    } else {
        rwlock_unlock(&runtimeLock, debugger_runtimeLock);
        debugger_runtimeLock = 0;
        return DEBUGGER_OFF;
    }

    // selLock is optional
    if (rwlock_try_write(&selLock)) {
        debugger_selLock = RDWR;
    } else if (rwlock_try_read(&selLock)) {
        debugger_selLock = RDONLY;
        result = DEBUGGER_PARTIAL;
    } else {
        debugger_selLock = 0;
        result = DEBUGGER_PARTIAL;
    }

    // loadMethodLock is optional
    if (recursive_mutex_try_lock(&loadMethodLock)) {
        debugger_loadMethodLock = RDWR;
    } else {
        debugger_loadMethodLock = 0;
        result = DEBUGGER_PARTIAL;
    }

    return result;
}

/***********************************************************************
* endDebuggerMode
* Relinquish locks acquired in startDebuggerMode().
**********************************************************************/
__private_extern__ void endDebuggerMode(void)
{
    assert(debugger_runtimeLock != 0);

    rwlock_unlock(&runtimeLock, debugger_runtimeLock);
    debugger_runtimeLock = 0;

    rwlock_unlock(&selLock, debugger_selLock);
    debugger_selLock = 0;

    assert(debugger_cacheUpdateLock == RDWR);
    mutex_unlock(&cacheUpdateLock);
    debugger_cacheUpdateLock = 0;

    if (debugger_loadMethodLock) {
        recursive_mutex_unlock(&loadMethodLock);
        debugger_loadMethodLock = 0;
    }
}

/***********************************************************************
* isManagedDuringDebugger
* Returns YES if the given lock is handled specially during debugger 
* mode (i.e. debugger mode tries to acquire it).
**********************************************************************/
__private_extern__ BOOL isManagedDuringDebugger(void *lock)
{
    if (lock == &selLock) return YES;
    if (lock == &cacheUpdateLock) return YES;
    if (lock == &runtimeLock) return YES;
    if (lock == &loadMethodLock) return YES;
    return NO;
}

/***********************************************************************
* isLockedDuringDebugger
* Returns YES if the given mutex was acquired by debugger mode.
* Locking a managed mutex during debugger mode causes a trap unless 
*   this returns YES.
**********************************************************************/
__private_extern__ BOOL isLockedDuringDebugger(mutex_t *lock)
{
    assert(DebuggerMode);

    if (lock == &cacheUpdateLock) return YES;
    if (lock == (mutex_t *)&loadMethodLock) return YES;
    
    return NO;
}

/***********************************************************************
* isReadingDuringDebugger
* Returns YES if the given rwlock was read-locked by debugger mode.
* Read-locking a managed rwlock during debugger mode causes a trap unless
*   this returns YES.
**********************************************************************/
__private_extern__ BOOL isReadingDuringDebugger(rwlock_t *lock)
{
    assert(DebuggerMode);
    
    // read-lock is allowed even if debugger mode actually write-locked it
    if (debugger_runtimeLock  &&  lock == &runtimeLock) return YES;
    if (debugger_selLock  &&  lock == &selLock) return YES;

    return NO;
}

/***********************************************************************
* isWritingDuringDebugger
* Returns YES if the given rwlock was write-locked by debugger mode.
* Write-locking a managed rwlock during debugger mode causes a trap unless
*   this returns YES.
**********************************************************************/
__private_extern__ BOOL isWritingDuringDebugger(rwlock_t *lock)
{
    assert(DebuggerMode);
    
    if (debugger_runtimeLock == RDWR  &&  lock == &runtimeLock) return YES;
    if (debugger_selLock == RDWR  &&  lock == &selLock) return YES;

    return NO;
}


/***********************************************************************
* vtable dispatch
* 
* Every class gets a vtable pointer. The vtable is an array of IMPs.
* The selectors represented in the vtable are the same for all classes
*   (i.e. no class has a bigger or smaller vtable).
* Each vtable index has an associated trampoline which dispatches to 
*   the IMP at that index for the receiver class's vtable (after 
*   checking for NULL). Dispatch fixup uses these trampolines instead 
*   of objc_msgSend.
* Fragility: The vtable size and list of selectors is chosen at launch 
*   time. No compiler-generated code depends on any particular vtable 
*   configuration, or even the use of vtable dispatch at all.
* Memory size: If a class's vtable is identical to its superclass's 
*   (i.e. the class overrides none of the vtable selectors), then 
*   the class points directly to its superclass's vtable. This means 
*   selectors to be included in the vtable should be chosen so they are 
*   (1) frequently called, but (2) not too frequently overridden. In 
*   particular, -dealloc is a bad choice.
* Forwarding: If a class doesn't implement some vtable selector, that 
*   selector's IMP is set to objc_msgSend in that class's vtable.
* +initialize: Each class keeps the default vtable (which always 
*   redirects to objc_msgSend) until its +initialize is completed.
*   Otherwise, the first message to a class could be a vtable dispatch, 
*   and the vtable trampoline doesn't include +initialize checking.
* Changes: Categories, addMethod, and setImplementation all force vtable 
*   reconstruction for the class and all of its subclasses, if the 
*   vtable selectors are affected.
**********************************************************************/

#define X8(x) \
    x, x, x, x, x, x, x, x
#define X64(x) \
    X8(x), X8(x), X8(x), X8(x), X8(x), X8(x), X8(x), X8(x)
#define X128(x) \
    X64(x), X64(x)

#define vtableMax 128

IMP _objc_empty_vtable[vtableMax] = {
    X128(objc_msgSend)
};

#ifndef NO_VTABLE

// Trampoline descriptors for gdb.

objc_trampoline_header *gdb_objc_trampolines = NULL;

void gdb_objc_trampolines_changed(objc_trampoline_header *thdr) __attribute__((noinline));
void gdb_objc_trampolines_changed(objc_trampoline_header *thdr)
{
    rwlock_assert_writing(&runtimeLock);
    assert(thdr == gdb_objc_trampolines);

    if (PrintVtables) {
        _objc_inform("VTABLES: gdb_objc_trampolines_changed(%p)", thdr);
    }
}

// fixme workaround for rdar://6667753
static void appendTrampolines(objc_trampoline_header *thdr) __attribute__((noinline));

static void appendTrampolines(objc_trampoline_header *thdr)
{
    rwlock_assert_writing(&runtimeLock);
    assert(thdr->next == NULL);

    if (gdb_objc_trampolines != thdr->next) {
        thdr->next = gdb_objc_trampolines;
    }
    gdb_objc_trampolines = thdr;

    gdb_objc_trampolines_changed(thdr);
}

// Vtable management.

static size_t vtableStrlen;
static size_t vtableCount; 
static SEL *vtableSelectors;
static IMP *vtableTrampolines;
static const char * const defaultVtable[] = {
    "allocWithZone:", 
    "alloc", 
    "class", 
    "self", 
    "isKindOfClass:", 
    "respondsToSelector:", 
    "isFlipped", 
    "length", 
    "objectForKey:", 
    "count", 
    "objectAtIndex:", 
    "isEqualToString:", 
    "isEqual:", 
    "retain", 
    "release", 
    "autorelease", 
};
static const char * const defaultVtableGC[] = {
    "allocWithZone:", 
    "alloc", 
    "class", 
    "self", 
    "isKindOfClass:", 
    "respondsToSelector:", 
    "isFlipped", 
    "length", 
    "objectForKey:", 
    "count", 
    "objectAtIndex:", 
    "isEqualToString:", 
    "isEqual:", 
    "hash", 
    "addObject:", 
    "countByEnumeratingWithState:objects:count:", 
};

extern id objc_msgSend_vtable0(id, SEL, ...);
extern id objc_msgSend_vtable1(id, SEL, ...);
extern id objc_msgSend_vtable2(id, SEL, ...);
extern id objc_msgSend_vtable3(id, SEL, ...);
extern id objc_msgSend_vtable4(id, SEL, ...);
extern id objc_msgSend_vtable5(id, SEL, ...);
extern id objc_msgSend_vtable6(id, SEL, ...);
extern id objc_msgSend_vtable7(id, SEL, ...);
extern id objc_msgSend_vtable8(id, SEL, ...);
extern id objc_msgSend_vtable9(id, SEL, ...); 
extern id objc_msgSend_vtable10(id, SEL, ...);
extern id objc_msgSend_vtable11(id, SEL, ...);
extern id objc_msgSend_vtable12(id, SEL, ...);
extern id objc_msgSend_vtable13(id, SEL, ...);
extern id objc_msgSend_vtable14(id, SEL, ...);
extern id objc_msgSend_vtable15(id, SEL, ...);    

static IMP const defaultVtableTrampolines[] = {
    objc_msgSend_vtable0, 
    objc_msgSend_vtable1, 
    objc_msgSend_vtable2, 
    objc_msgSend_vtable3, 
    objc_msgSend_vtable4, 
    objc_msgSend_vtable5, 
    objc_msgSend_vtable6, 
    objc_msgSend_vtable7, 
    objc_msgSend_vtable8, 
    objc_msgSend_vtable9,  
    objc_msgSend_vtable10, 
    objc_msgSend_vtable11, 
    objc_msgSend_vtable12, 
    objc_msgSend_vtable13, 
    objc_msgSend_vtable14, 
    objc_msgSend_vtable15,
};
extern objc_trampoline_header defaultVtableTrampolineDescriptors;

static void check_vtable_size(void) __unused;
static void check_vtable_size(void)
{
    // Fail to compile if vtable sizes don't match.
    int c1[sizeof(defaultVtableTrampolines)-sizeof(defaultVtable)] __unused;
    int c2[sizeof(defaultVtable)-sizeof(defaultVtableTrampolines)] __unused;
    int c3[sizeof(defaultVtableTrampolines)-sizeof(defaultVtableGC)] __unused;
    int c4[sizeof(defaultVtableGC)-sizeof(defaultVtableTrampolines)] __unused;

    // Fail to compile if vtableMax is too small
    int c5[vtableMax - sizeof(defaultVtable)] __unused;
    int c6[vtableMax - sizeof(defaultVtableGC)] __unused;
}

/*
  x86_64 

  monomorphic (self rdi, sel* rsi, temp r10 and r11) {
      test %rdi, %rdi
      jeq  returnZero      // nil check
      movq 8(%rsi), %rsi   // load _cmd (fixme schedule)
      movq $xxxx, %r10
      cmp  0(%rdi), %r10   // isa check
      jeq  imp             // fixme long branches
        movq $yyyy, %r10
        cmp  0(%rdi), %r10 // fixme load rdi once for multiple isas
        jeq  imp2          // fixme long branches
      jmp  objc_msgSend    // fixme long branches
  }
  
*/
extern uint8_t vtable_prototype;
extern uint8_t vtable_ignored;
extern int vtable_prototype_size;
extern int vtable_prototype_index_offset;
static size_t makeVtableTrampoline(uint8_t *dst, size_t index)
{
    // copy boilerplate
    memcpy(dst, &vtable_prototype, vtable_prototype_size);
    
    // insert index
#if defined(__x86_64__)
    uint16_t *p = (uint16_t *)(dst + vtable_prototype_index_offset + 3);
    if (*p != 0x7fff) _objc_fatal("vtable_prototype busted");
    *p = index * 8;
#else
#   warning unknown architecture
#endif

    return vtable_prototype_size;
}


static void initVtables(void)
{
    if (DisableVtables) {
        if (PrintVtables) {
            _objc_inform("VTABLES: vtable dispatch disabled by OBJC_DISABLE_VTABLES");
        }
        vtableCount = 0;
        vtableSelectors = NULL;
        vtableTrampolines = NULL;
        return;
    }

    const char * const *names;
    size_t i;

    if (UseGC) {
        names = defaultVtableGC;
        vtableCount = sizeof(defaultVtableGC) / sizeof(defaultVtableGC[0]);
    } else {
        names = defaultVtable;
        vtableCount = sizeof(defaultVtable) / sizeof(defaultVtable[0]);
    }
    if (vtableCount > vtableMax) vtableCount = vtableMax;

    vtableSelectors = _malloc_internal(vtableCount * sizeof(SEL));
    vtableTrampolines = _malloc_internal(vtableCount * sizeof(IMP));

    // Built-in trampolines and their descriptors

    size_t defaultVtableTrampolineCount = 
        sizeof(defaultVtableTrampolines) / sizeof(defaultVtableTrampolines[0]);
#ifndef NDEBUG
    // debug: use generated code for 3/4 of the table
    defaultVtableTrampolineCount /= 4;
#endif

    for (i = 0; i < defaultVtableTrampolineCount && i < vtableCount; i++) {
        vtableSelectors[i] = sel_registerName(names[i]);
        vtableTrampolines[i] = defaultVtableTrampolines[i];
    }
    appendTrampolines(&defaultVtableTrampolineDescriptors);


    // Generated trampolines and their descriptors

    if (vtableCount > defaultVtableTrampolineCount) {
        // Memory for trampoline code
        size_t generatedCount = 
            vtableCount - defaultVtableTrampolineCount;

        const int align = 16;
        size_t codeSize = 
            round_page(sizeof(objc_trampoline_header) + align + 
                       generatedCount * (sizeof(objc_trampoline_descriptor) 
                                         + vtable_prototype_size + align));
        void *codeAddr = mmap(0, codeSize, PROT_READ|PROT_WRITE, 
                              MAP_PRIVATE|MAP_ANON, 
                              VM_MAKE_TAG(VM_MEMORY_OBJC_DISPATCHERS), 0);
        uint8_t *t = (uint8_t *)codeAddr;
        
        // Trampoline header
        objc_trampoline_header *thdr = (objc_trampoline_header *)t;
        thdr->headerSize = sizeof(objc_trampoline_header);
        thdr->descSize = sizeof(objc_trampoline_descriptor);
        thdr->descCount = (uint32_t)generatedCount;
        thdr->next = NULL;
        
        // Trampoline descriptors
        objc_trampoline_descriptor *tdesc = (objc_trampoline_descriptor *)(thdr+1);
        t = (uint8_t *)&tdesc[generatedCount];
        t += align - ((uintptr_t)t % align);
        
        // Dispatch code
        size_t tdi;
        for (i = defaultVtableTrampolineCount, tdi = 0; 
             i < vtableCount; 
             i++, tdi++) 
        {
            vtableSelectors[i] = sel_registerName(names[i]);
            if (vtableSelectors[i] == (SEL)kIgnore) {
                vtableTrampolines[i] = (IMP)&vtable_ignored;
                tdesc[tdi].offset = 0;
                tdesc[tdi].flags = 0;
            } else {
                vtableTrampolines[i] = (IMP)t;
                tdesc[tdi].offset = 
                    (uint32_t)((uintptr_t)t - (uintptr_t)&tdesc[tdi]);
                tdesc[tdi].flags = 
                    OBJC_TRAMPOLINE_MESSAGE|OBJC_TRAMPOLINE_VTABLE;
                
                t += makeVtableTrampoline(t, i);
                t += align - ((uintptr_t)t % align);
            }
        }

        appendTrampolines(thdr);
        sys_icache_invalidate(codeAddr, codeSize);
        mprotect(codeAddr, codeSize, PROT_READ|PROT_EXEC);
    }


    if (PrintVtables) {
        for (i = 0; i < vtableCount; i++) {
            _objc_inform("VTABLES: vtable[%zu] %p %s", 
                         i, vtableTrampolines[i], 
                         sel_getName(vtableSelectors[i]));
        }
    }

    if (PrintVtableImages) {
        _objc_inform("VTABLE IMAGES: '#' implemented by class");
        _objc_inform("VTABLE IMAGES: '-' inherited from superclass");
        _objc_inform("VTABLE IMAGES: ' ' not implemented");
        for (i = 0; i <= vtableCount; i++) {
            char spaces[vtableCount+1+1];
            size_t j;
            for (j = 0; j < i; j++) {
                spaces[j] = '|';
            }
            spaces[j] = '\0';
            _objc_inform("VTABLE IMAGES: %s%s", spaces, 
                         i<vtableCount ? sel_getName(vtableSelectors[i]) : "");
        }
    }

    if (PrintVtables  ||  PrintVtableImages) {
        vtableStrlen = 0;
        for (i = 0; i < vtableCount; i++) {
            vtableStrlen += strlen(sel_getName(vtableSelectors[i]));
        }
    }
}


static int vtable_getIndex(SEL sel)
{
    int i;
    for (i = 0; i < vtableCount; i++) {
        if (vtableSelectors[i] == sel) return i;
    }
    return -1;
}

static BOOL vtable_containsSelector(SEL sel)
{
    return (vtable_getIndex(sel) < 0) ? NO : YES;
}

static void printVtableOverrides(class_t *cls, class_t *supercls)
{
    char overrideMap[vtableCount+1];
    int i;

    if (supercls) {
        size_t overridesBufferSize = vtableStrlen + 2*vtableCount + 1;
        char *overrides =
            _calloc_internal(overridesBufferSize, 1);
        for (i = 0; i < vtableCount; i++) {
            if (vtableSelectors[i] == (SEL)kIgnore) {
                overrideMap[i] = '-';
                continue;
            }
            if (getMethodNoSuper_nolock(cls, vtableSelectors[i])) {
                strlcat(overrides, sel_getName(vtableSelectors[i]), overridesBufferSize);
                strlcat(overrides, ", ", overridesBufferSize);
                overrideMap[i] = '#';
            } else if (getMethod_nolock(cls, vtableSelectors[i])) {
                overrideMap[i] = '-';
            } else {
                overrideMap[i] = ' ';
            }
        }
        if (PrintVtables) {
            _objc_inform("VTABLES: %s%s implements %s", 
                         getName(cls), isMetaClass(cls) ? "(meta)" : "", 
                         overrides);
        }
        _free_internal(overrides);
    }
    else {
        for (i = 0; i < vtableCount; i++) {
            overrideMap[i] = '#';
        }
    }

    if (PrintVtableImages) {
        overrideMap[vtableCount] = '\0';
        _objc_inform("VTABLE IMAGES: %s  %s%s", overrideMap, 
                     getName(cls), isMetaClass(cls) ? "(meta)" : "");
    }
}

/***********************************************************************
* updateVtable
* Rebuilds vtable for cls, using superclass's vtable if appropriate.
* Assumes superclass's vtable is up to date. 
* Does nothing to subclass vtables.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void updateVtable(class_t *cls, BOOL force)
{
    rwlock_assert_writing(&runtimeLock);

    // Keep default vtable until +initialize is complete. 
    // Default vtable redirects to objc_msgSend, which 
    // enforces +initialize locking.
    if (!force  &&  !_class_isInitialized((Class)cls)) {
        /*
        if (PrintVtables) {
            _objc_inform("VTABLES: KEEPING DEFAULT vtable for "
                         "uninitialized class %s%s",
                         getName(cls), isMetaClass(cls) ? "(meta)" : "");
        }
        */
        return;
    }

    // Decide whether this class can share its superclass's vtable.

    struct class_t *supercls = getSuperclass(cls);
    BOOL needVtable = NO;
    int i;
    if (!supercls) {
        // Root classes always need a vtable
        needVtable = YES;
    } 
    else if (cls->data->flags & RW_SPECIALIZED_VTABLE) {
        // Once you have your own vtable, you never go back
        needVtable = YES;
    } 
    else {
        for (i = 0; i < vtableCount; i++) {
            if (vtableSelectors[i] == (SEL)kIgnore) continue;
            method_t *m = getMethodNoSuper_nolock(cls, vtableSelectors[i]);
            // assume any local implementation differs from super's
            if (m) {
                needVtable = YES;
                break;
            }
        }
    }

    // Build a vtable for this class, or not.

    if (!needVtable) {
        if (PrintVtables) {
            _objc_inform("VTABLES: USING SUPERCLASS vtable for class %s%s",
                         getName(cls), isMetaClass(cls) ? "(meta)" : "");
        }
        cls->vtable = supercls->vtable;
    } 
    else {
        if (PrintVtables) {
            _objc_inform("VTABLES: %s vtable for class %s%s",
                         (cls->data->flags & RW_SPECIALIZED_VTABLE) ? 
                         "UPDATING SPECIALIZED" : "CREATING SPECIALIZED", 
                         getName(cls), isMetaClass(cls) ? "(meta)" : "");
        }
        if (PrintVtables  ||  PrintVtableImages) {
            printVtableOverrides(cls, supercls);
        }

        IMP *new_vtable = cls->vtable;
        IMP *super_vtable = supercls ? supercls->vtable : _objc_empty_vtable;
        // fixme use msgForward (instead of msgSend from empty vtable) ?

        if (cls->data->flags & RW_SPECIALIZED_VTABLE) {
            // update cls->vtable in place
            new_vtable = cls->vtable;
            assert(new_vtable != _objc_empty_vtable);
        } else {
            // make new vtable
            new_vtable = malloc(vtableCount * sizeof(IMP));
            changeInfo(cls, RW_SPECIALIZED_VTABLE, 0);
        }
        
        for (i = 0; i < vtableCount; i++) {
            if (vtableSelectors[i] == (SEL)kIgnore) {
                new_vtable[i] = (IMP)&vtable_ignored;
            } else {
                method_t *m = getMethodNoSuper_nolock(cls, vtableSelectors[i]);
                if (m) new_vtable[i] = _method_getImplementation(m);
                else new_vtable[i] = super_vtable[i];
            }
        }

        if (cls->vtable != new_vtable) {
            // don't let other threads see uninitialized parts of new_vtable
            OSMemoryBarrier();
            cls->vtable = new_vtable;
        }
    }
}

// ! NO_VTABLE
#else
// NO_VTABLE

static void initVtables(void)
{
    if (PrintVtables) {
        _objc_inform("VTABLES: no vtables on this architecture");
    }
}

static BOOL vtable_containsSelector(SEL sel)
{
    return NO;
}

static void updateVtable(class_t *cls, BOOL force)
{
}

// NO_VTABLE
#endif

typedef struct {
    category_t *cat;
    BOOL fromBundle;
} category_pair_t;

typedef struct {
    uint32_t count;
    category_pair_t list[0];  // variable-size
} category_list;

#define FOREACH_METHOD_LIST(_mlist, _cls, code)                         \
    do {                                                                \
        const method_list_t *_mlist;                                    \
        if (_cls->data->methods) {                                      \
            method_list_t **_mlistp;                                    \
            for (_mlistp = _cls->data->methods; *_mlistp; _mlistp++) {  \
                _mlist = *_mlistp;                                      \
                code                                                    \
            }                                                           \
        }                                                               \
    } while (0) 


// fixme don't chain property lists
typedef struct chained_property_list {
    struct chained_property_list *next;
    uint32_t count;
    struct objc_property list[0];  // variable-size
} chained_property_list;

/*
  Low two bits of mlist->entsize is used as the fixed-up marker.
  PREOPTIMIZED VERSION:
    Fixed-up method lists get entsize&3 == 3.
    dyld shared cache sets this for method lists it preoptimizes.
  UN-PREOPTIMIZED VERSION:
    Fixed-up method lists get entsize&3 == 1. 
    dyld shared cache uses 3, but those aren't trusted.
*/

static uint32_t fixed_up_method_list = 3;

__private_extern__ void
disableSelectorPreoptimization(void)
{
    fixed_up_method_list = 1;
}

static BOOL isMethodListFixedUp(const method_list_t *mlist)
{
    return (mlist->entsize_NEVER_USE & 3) == fixed_up_method_list;
}

static void setMethodListFixedUp(method_list_t *mlist)
{
    rwlock_assert_writing(&runtimeLock);
    assert(!isMethodListFixedUp(mlist));
    mlist->entsize_NEVER_USE = (mlist->entsize_NEVER_USE & ~3) | fixed_up_method_list;
}

/*
static size_t chained_property_list_size(const chained_property_list *plist)
{
    return sizeof(chained_property_list) + 
        plist->count * sizeof(struct objc_property);
}

static size_t protocol_list_size(const protocol_list_t *plist)
{
    return sizeof(protocol_list_t) + plist->count * sizeof(protocol_t *);
}
*/

// low bit used by dyld shared cache
static uint32_t method_list_entsize(const method_list_t *mlist)
{
    return mlist->entsize_NEVER_USE & ~(uint32_t)3;
}

static size_t method_list_size(const method_list_t *mlist)
{
    return sizeof(method_list_t) + (mlist->count-1)*method_list_entsize(mlist);
}

static method_t *method_list_nth(const method_list_t *mlist, uint32_t i)
{
    return (method_t *)(i*method_list_entsize(mlist) + (char *)&mlist->first);
}


static size_t ivar_list_size(const ivar_list_t *ilist)
{
    return sizeof(ivar_list_t) + (ilist->count-1) * ilist->entsize;
}

static ivar_t *ivar_list_nth(const ivar_list_t *ilist, uint32_t i)
{
    return (ivar_t *)(i*ilist->entsize + (char *)&ilist->first);
}


static method_list_t *cat_method_list(const category_t *cat, BOOL isMeta)
{
    if (!cat) return NULL;

    if (isMeta) return cat->classMethods;
    else return cat->instanceMethods;
}

static uint32_t cat_method_count(const category_t *cat, BOOL isMeta)
{
    method_list_t *cmlist = cat_method_list(cat, isMeta);
    return cmlist ? cmlist->count : 0;
}

static method_t *cat_method_nth(const category_t *cat, BOOL isMeta, uint32_t i)
{
    method_list_t *cmlist = cat_method_list(cat, isMeta);
    if (!cmlist) return NULL;
    
    return method_list_nth(cmlist, i);
}


// part of ivar_t, with non-deprecated alignment
typedef struct {
    uintptr_t *offset;
    const char *name;
    const char *type;
    uint32_t alignment;
} ivar_alignment_t;

static uint32_t ivar_alignment(const ivar_t *ivar)
{
    uint32_t alignment = ((ivar_alignment_t *)ivar)->alignment;
    if (alignment == (uint32_t)-1) alignment = (uint32_t)WORD_SHIFT;
    return 1<<alignment;
}


static void try_free(const void *p) 
{
    if (p && malloc_size(p)) free((void *)p);
}


/***********************************************************************
* make_ro_writeable
* Reallocates rw->ro if necessary to make it writeable.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static class_ro_t *make_ro_writeable(class_rw_t *rw)
{
    rwlock_assert_writing(&runtimeLock);

    if (rw->flags & RW_COPIED_RO) {
        // already writeable, do nothing
    } else {
        class_ro_t *ro = _memdup_internal(rw->ro, sizeof(*rw->ro));
        rw->ro = ro;
        rw->flags |= RW_COPIED_RO;
    }
    return (class_ro_t *)rw->ro;
}


/***********************************************************************
* unattachedCategories
* Returns the class => categories map of unattached categories.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static NXMapTable *unattachedCategories(void)
{
    rwlock_assert_writing(&runtimeLock);

    static NXMapTable *category_map = NULL;

    if (category_map) return category_map;

    // fixme initial map size
    category_map = NXCreateMapTableFromZone(NXPtrValueMapPrototype, 16, 
                                            _objc_internal_zone());

    return category_map;
}


/***********************************************************************
* addUnattachedCategoryForClass
* Records an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addUnattachedCategoryForClass(category_t *cat, class_t *cls, 
                                          header_info *catHeader)
{
    rwlock_assert_writing(&runtimeLock);

    BOOL catFromBundle = (catHeader->mhdr->filetype == MH_BUNDLE) ? YES: NO;

    // DO NOT use cat->cls! 
    // cls may be cat->cls->isa, or cat->cls may have been remapped.
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = NXMapGet(cats, cls);
    if (!list) {
        list = _calloc_internal(sizeof(*list) + sizeof(list->list[0]), 1);
    } else {
        list = _realloc_internal(list, sizeof(*list) + sizeof(list->list[0]) * (list->count + 1));
    }
    list->list[list->count++] = (category_pair_t){cat, catFromBundle};
    NXMapInsert(cats, cls, list);
}


/***********************************************************************
* removeUnattachedCategoryForClass
* Removes an unattached category.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeUnattachedCategoryForClass(category_t *cat, class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    // DO NOT use cat->cls! 
    // cls may be cat->cls->isa, or cat->cls may have been remapped.
    NXMapTable *cats = unattachedCategories();
    category_list *list;

    list = NXMapGet(cats, cls);
    if (!list) return;

    uint32_t i;
    for (i = 0; i < list->count; i++) {
        if (list->list[i].cat == cat) {
            // shift entries to preserve list order
            memmove(&list->list[i], &list->list[i+1], 
                    (list->count-i-1) * sizeof(list->list[i]));
            list->count--;
            return;
        }
    }
}


/***********************************************************************
* unattachedCategoriesForClass
* Returns the list of unattached categories for a class, and 
* deletes them from the list. 
* The result must be freed by the caller. 
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static category_list *unattachedCategoriesForClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    return NXMapRemove(unattachedCategories(), cls);
}


/***********************************************************************
* isRealized
* Returns YES if class cls has been realized.
* Locking: To prevent concurrent realization, hold runtimeLock.
**********************************************************************/
static BOOL isRealized(class_t *cls)
{
    return (cls->data->flags & RW_REALIZED) ? YES : NO;
}


/***********************************************************************
* isFuture
* Returns YES if class cls is an unrealized future class.
* Locking: To prevent concurrent realization, hold runtimeLock.
**********************************************************************/
static BOOL isFuture(class_t *cls)
{
    return (cls->data->flags & RW_FUTURE) ? YES : NO;
}


/***********************************************************************
* printReplacements
* Implementation of PrintReplacedMethods / OBJC_PRINT_REPLACED_METHODS.
* Warn about methods from cats that override other methods in cats or cls.
* Assumes no methods from cats have been added to cls yet.
**********************************************************************/
static void printReplacements(class_t *cls, category_list *cats)
{
    uint32_t c;
    BOOL isMeta = isMetaClass(cls);

    if (!cats) return;

    // Newest categories are LAST in cats
    // Later categories override earlier ones.
    for (c = 0; c < cats->count; c++) {
        category_t *cat = cats->list[c].cat;
        uint32_t cmCount = cat_method_count(cat, isMeta);
        uint32_t m;
        for (m = 0; m < cmCount; m++) {
            uint32_t c2, m2;
            method_t *meth2 = NULL;
            method_t *meth = cat_method_nth(cat, isMeta, m);
            SEL s = sel_registerName((const char *)meth->name);

            // Don't warn about GC-ignored selectors
            if (s == (SEL)kIgnore) continue;
            
            // Look for method in earlier categories
            for (c2 = 0; c2 < c; c2++) {
                category_t *cat2 = cats->list[c2].cat;
                uint32_t cm2Count = cat_method_count(cat2, isMeta);
                for (m2 = 0; m2 < cm2Count; m2++) {
                    meth2 = cat_method_nth(cat2, isMeta, m2);
                    SEL s2 = sel_registerName((const char *)meth2->name);
                    if (s == s2) goto whine;
                }
            }

            // Look for method in cls
            FOREACH_METHOD_LIST(mlist, cls, {
                for (m2 = 0; m2 < mlist->count; m2++) {
                    meth2 = method_list_nth(mlist, m2);
                    SEL s2 = sel_registerName((const char *)meth2->name);
                    if (s == s2) goto whine;
                }
            });

            // Didn't find any override.
            continue;

        whine:
            // Found an override.
            logReplacedMethod(getName(cls), s, isMetaClass(cls), cat->name, 
                              _method_getImplementation(meth2), 
                              _method_getImplementation(meth));
        }
    }
}


static BOOL isBundleClass(class_t *cls)
{
    return (cls->data->ro->flags & RO_FROM_BUNDLE) ? YES : NO;
}


static void
fixupMethodList(method_list_t *mlist, BOOL bundleCopy)
{
    assert(!isMethodListFixedUp(mlist));

    // fixme lock less in attachMethodLists ?
    sel_lock();

    uint32_t m;
    for (m = 0; m < mlist->count; m++) {
        method_t *meth = method_list_nth(mlist, m);
        SEL sel = sel_registerNameNoLock((const char *)meth->name, bundleCopy);
        meth->name = sel;

        if (sel == (SEL)kIgnore) {
            meth->imp = (IMP)&_objc_ignored_method;
        }
    }

    sel_unlock();

    setMethodListFixedUp(mlist);
}

static void 
attachMethodLists(class_t *cls, method_list_t **lists, int count, 
                  BOOL methodsFromBundle, BOOL *outVtablesAffected)
{
    rwlock_assert_writing(&runtimeLock);

    BOOL vtablesAffected = NO;
    size_t listsSize = count * sizeof(*lists);

    // Create or extend method list array
    // Leave `count` empty slots at the start of the array to be filled below.

    if (!cls->data->methods) {
        // no bonus method lists yet
        cls->data->methods = _calloc_internal(1 + count, sizeof(*lists));
    } else {
        size_t oldSize = malloc_size(cls->data->methods);
        cls->data->methods = 
            _realloc_internal(cls->data->methods, oldSize + listsSize);
        memmove(cls->data->methods + count, cls->data->methods, oldSize);
    }

    // Add method lists to array.
    // Reallocate un-fixed method lists.

    int i;
    for (i = 0; i < count; i++) {
        method_list_t *mlist = lists[i];
        if (!mlist) continue;

        // Fixup selectors if necessary
        if (!isMethodListFixedUp(mlist)) {
            mlist = _memdup_internal(mlist, method_list_size(mlist));
            fixupMethodList(mlist, methodsFromBundle);
        }

        // Scan for vtable updates
        if (outVtablesAffected  &&  !vtablesAffected) {
            uint32_t m;
            for (m = 0; m < mlist->count; m++) {
                SEL sel = method_list_nth(mlist, m)->name;
                if (vtable_containsSelector(sel)) vtablesAffected = YES;
            }
        }
        
        // Fill method list array
        cls->data->methods[i] = mlist;
    }

    if (outVtablesAffected) *outVtablesAffected = vtablesAffected;
}

static void 
attachCategoryMethods(class_t *cls, category_list *cats, 
                      BOOL *outVtablesAffected)
{
    if (!cats) return;
    if (PrintReplacedMethods) printReplacements(cls, cats);

    BOOL isMeta = isMetaClass(cls);
    method_list_t **mlists = _malloc_internal(cats->count * sizeof(*mlists));

    // Count backwards through cats to get newest categories first
    int mcount = 0;
    int i = cats->count;
    BOOL fromBundle = NO;
    while (i--) {
        method_list_t *mlist = cat_method_list(cats->list[i].cat, isMeta);
        if (mlist) {
            mlists[mcount++] = mlist;
            fromBundle |= cats->list[i].fromBundle;
        }
    }

    attachMethodLists(cls, mlists, mcount, fromBundle, outVtablesAffected);

    _free_internal(mlists);

}


static chained_property_list *
buildPropertyList(const struct objc_property_list *plist, category_list *cats, BOOL isMeta)
{
    // Do NOT use cat->cls! It may have been remapped.
    chained_property_list *newlist;
    uint32_t count = 0;
    uint32_t p, c;

    // Count properties in all lists.
    if (plist) count = plist->count;
    if (cats) {
        for (c = 0; c < cats->count; c++) {
            category_t *cat = cats->list[c].cat;
            /*
            if (isMeta  &&  cat->classProperties) {
                count += cat->classProperties->count;
            } 
            else*/
            if (!isMeta  &&  cat->instanceProperties) {
                count += cat->instanceProperties->count;
            }
        }
    }
    
    if (count == 0) return NULL;

    // Allocate new list. 
    newlist = _malloc_internal(sizeof(*newlist) + count * sizeof(struct objc_property));
    newlist->count = 0;
    newlist->next = NULL;

    // Copy properties; newest categories first, then ordinary properties
    if (cats) {
        c = cats->count;
        while (c--) {
            struct objc_property_list *cplist;
            category_t *cat = cats->list[c].cat;
            /*
            if (isMeta) {
                cplist = cat->classProperties;
                } else */
            {
                cplist = cat->instanceProperties;
            }
            if (cplist) {
                for (p = 0; p < cplist->count; p++) {
                    newlist->list[newlist->count++] = 
                        *property_list_nth(cplist, p);
                }
            }
        }
    }
    if (plist) {
        for (p = 0; p < plist->count; p++) {
            newlist->list[newlist->count++] = *property_list_nth(plist, p);
        }
    }

    assert(newlist->count == count);

    return newlist;
}


static protocol_list_t **
buildProtocolList(category_list *cats, struct protocol_list_t *base, 
                  struct protocol_list_t **protos)
{
    // Do NOT use cat->cls! It may have been remapped.
    struct protocol_list_t **p, **newp;
    struct protocol_list_t **newprotos;
    int count = 0;
    int i;

    // count protocol list in base
    if (base) count++;

    // count protocol lists in cats
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i].cat;
        if (cat->protocols) count++;
    }

    // no base or category protocols? return existing protocols unchanged
    if (count == 0) return protos;

    // count protocol lists in protos
    for (p = protos; p  &&  *p; p++) {
        count++;
    }

    if (count == 0) return NULL;
    
    newprotos = (struct protocol_list_t **)
        _malloc_internal((count+1) * sizeof(struct protocol_list_t *));
    newp = newprotos;

    if (base) {
        *newp++ = base;
    }

    for (p = protos; p  &&  *p; p++) {
        *newp++ = *p;
    }
    
    if (cats) for (i = 0; i < cats->count; i++) {
        category_t *cat = cats->list[i].cat;
        if (cat->protocols) {
            *newp++ = cat->protocols;
        }
    }

    *newp = NULL;

    return newprotos;
}


/***********************************************************************
* methodizeClass
* Fixes up cls's method list, protocol list, and property list.
* Attaches any outstanding categories.
* Builds vtable.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void methodizeClass(struct class_t *cls)
{
    category_list *cats;
    BOOL isMeta;

    rwlock_assert_writing(&runtimeLock);

    isMeta = isMetaClass(cls);

    // Methodizing for the first time
    if (PrintConnecting) {
        _objc_inform("CLASS: methodizing class '%s' %s", 
                     getName(cls), isMeta ? "(meta)" : "");
    }
    
    // Build method and protocol and property lists.
    // Include methods and protocols and properties from categories, if any
    // Do NOT use cat->cls! It may have been remapped.

    attachMethodLists(cls, (method_list_t **)&cls->data->ro->baseMethods, 1, 
                      isBundleClass(cls), NULL);

    cats = unattachedCategoriesForClass(cls);
    attachCategoryMethods(cls, cats, NULL);
    
    if (cats  ||  cls->data->ro->baseProperties) {
        cls->data->properties = 
            buildPropertyList(cls->data->ro->baseProperties, cats, isMeta);
    }
    
    if (cats  ||  cls->data->ro->baseProtocols) {
        cls->data->protocols = 
            buildProtocolList(cats, cls->data->ro->baseProtocols, NULL);
    }
    
    if (PrintConnecting) {
        uint32_t i;
        if (cats) {
            for (i = 0; i < cats->count; i++) {
                _objc_inform("CLASS: attached category %c%s(%s)", 
                             isMeta ? '+' : '-', 
                             getName(cls), cats->list[i].cat->name);
            }
        }
    }
    
    if (cats) _free_internal(cats);

    // No vtable until +initialize completes
    assert(cls->vtable == _objc_empty_vtable);
}


/***********************************************************************
* remethodizeClass
* Attach outstanding categories to an existing class.
* Fixes up cls's method list, protocol list, and property list.
* Updates method caches and vtables for cls and its subclasses.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void remethodizeClass(struct class_t *cls)
{
    category_list *cats;
    BOOL isMeta;

    rwlock_assert_writing(&runtimeLock);

    isMeta = isMetaClass(cls);

    // Re-methodizing: check for more categories
    if ((cats = unattachedCategoriesForClass(cls))) {
        chained_property_list *newproperties;
        struct protocol_list_t **newprotos;
        BOOL vtableAffected = NO;
        
        if (PrintConnecting) {
            _objc_inform("CLASS: attaching categories to class '%s' %s", 
                         getName(cls), isMeta ? "(meta)" : "");
        }
        
        // Update methods, properties, protocols
        
        attachCategoryMethods(cls, cats, &vtableAffected);
        
        newproperties = buildPropertyList(NULL, cats, isMeta);
        if (newproperties) {
            newproperties->next = cls->data->properties;
            cls->data->properties = newproperties;
        }
        
        newprotos = buildProtocolList(cats, NULL, cls->data->protocols);
        if (cls->data->protocols  &&  cls->data->protocols != newprotos) {
            _free_internal(cls->data->protocols);
        }
        cls->data->protocols = newprotos;
        
        _free_internal(cats);

        // Update method caches and vtables
        flushCaches(cls);
        if (vtableAffected) flushVtables(cls);
    }
}


/***********************************************************************
* changeInfo
* Atomically sets and clears some bits in cls's info field.
* set and clear must not overlap.
**********************************************************************/
static void changeInfo(class_t *cls, unsigned int set, unsigned int clear)
{
    uint32_t oldf, newf;

    assert(isFuture(cls)  ||  isRealized(cls));

    do {
        oldf = cls->data->flags;
        newf = (oldf | set) & ~clear;
    } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&cls->data->flags));
}


/***********************************************************************
* namedClasses
* Returns the classname => class map of all non-meta classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/

NXMapTable *gdb_objc_realized_classes;  // exported for debuggers in objc-gdb.h

static NXMapTable *namedClasses(void)
{
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(gdb_objc_realized_classes, 
                  NXCreateMapTableFromZone(NXStrValueMapPrototype, 1024, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v) );

    return gdb_objc_realized_classes;
}


/***********************************************************************
* addNamedClass
* Adds name => cls to the named non-meta class map.
* Warns about duplicate class names and keeps the old mapping.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addNamedClass(class_t *cls, const char *name)
{
    rwlock_assert_writing(&runtimeLock);
    class_t *old;
    if ((old = NXMapGet(namedClasses(), name))) {
        inform_duplicate(name, (Class)old, (Class)cls);
    } else {
        NXMapInsert(namedClasses(), name, cls);
    }
    assert(!(cls->data->flags & RO_META));

    // wrong: constructed classes are already realized when they get here
    // assert(!isRealized(cls));
}


/***********************************************************************
* removeNamedClass
* Removes cls from the name => cls map.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeNamedClass(class_t *cls, const char *name)
{
    rwlock_assert_writing(&runtimeLock);
    assert(!(cls->data->flags & RO_META));
    if (cls == NXMapGet(namedClasses(), name)) {
        NXMapRemove(namedClasses(), name);
    } else {
        // cls has a name collision with another class - don't remove the other
    }
}


/***********************************************************************
* realizedClasses
* Returns the class list for realized non-meta classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realizedClasses(void)
{
    static NXHashTable *class_hash = NULL;
    
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(class_hash, 
                  NXCreateHashTableFromZone(NXPtrPrototype, 1024, NULL, 
                                            _objc_internal_zone()), 
                  NXFreeHashTable(v));

    return class_hash;
}


/***********************************************************************
* realizedMetaclasses
* Returns the class list for realized metaclasses.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXHashTable *realizedMetaclasses(void)
{
    static NXHashTable *class_hash = NULL;
    
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(class_hash, 
                  NXCreateHashTableFromZone(NXPtrPrototype, 1024, NULL, 
                                            _objc_internal_zone()), 
                  NXFreeHashTable(v));

    return class_hash;
}


/***********************************************************************
* addRealizedClass
* Adds cls to the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addRealizedClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXHashInsert(realizedClasses(), cls);
    objc_addRegisteredClass((Class)cls);
    assert(!isMetaClass(cls));
    assert(!old);
}


/***********************************************************************
* removeRealizedClass
* Removes cls from the realized non-meta class hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeRealizedClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    if (isRealized(cls)) {
        assert(!isMetaClass(cls));
        NXHashRemove(realizedClasses(), cls);
        objc_removeRegisteredClass((Class)cls);
    }
}


/***********************************************************************
* addRealizedMetaclass
* Adds cls to the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addRealizedMetaclass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXHashInsert(realizedMetaclasses(), cls);
    assert(isMetaClass(cls));
    assert(!old);
}


/***********************************************************************
* removeRealizedMetaclass
* Removes cls from the realized metaclass hash.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeRealizedMetaclass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    if (isRealized(cls)) {
        assert(isMetaClass(cls));
        NXHashRemove(realizedMetaclasses(), cls);
    }
}


/***********************************************************************
* uninitializedClasses
* Returns the metaclass => class map for un-+initialized classes
* Replaces the 32-bit cls = objc_getName(metacls) during +initialize.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXMapTable *uninitializedClasses(void)
{
    static NXMapTable *class_map = NULL;
    
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(class_map, 
                  NXCreateMapTableFromZone(NXPtrValueMapPrototype, 1024, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v) );

    return class_map;
}


/***********************************************************************
* addUninitializedClass
* Adds metacls => cls to the un-+initialized class map
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addUninitializedClass(class_t *cls, class_t *metacls)
{
    rwlock_assert_writing(&runtimeLock);
    void *old;
    old = NXMapInsert(uninitializedClasses(), metacls, cls);
    assert(isRealized(metacls) ? isMetaClass(metacls) : metacls->data->flags & RO_META);
    assert(! (isRealized(cls) ? isMetaClass(cls) : cls->data->flags & RO_META));
    assert(!old);
}


static void removeUninitializedClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);
    NXMapRemove(uninitializedClasses(), cls->isa);
}


/***********************************************************************
* getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static class_t *getNonMetaClass(class_t *cls)
{
    rwlock_assert_locked(&runtimeLock);
    if (isMetaClass(cls)) {
        cls = NXMapGet(uninitializedClasses(), cls);
    }
    return cls;
}


/***********************************************************************
* _class_getNonMetaClass
* Return the ordinary class for this class or metaclass. 
* Used by +initialize. 
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Class _class_getNonMetaClass(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    rwlock_write(&runtimeLock);
    cls = getNonMetaClass(cls);
    realizeClass(cls);
    rwlock_unlock_write(&runtimeLock);
    
    return (Class)cls;
}



/***********************************************************************
* futureClasses
* Returns the classname => future class map for unrealized future classes.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static NXMapTable *futureClasses(void)
{
    rwlock_assert_writing(&runtimeLock);

    static NXMapTable *future_class_map = NULL;
    
    if (future_class_map) return future_class_map;

    // future_class_map is big enough to hold CF's classes and a few others
    future_class_map = NXCreateMapTableFromZone(NXStrValueMapPrototype, 32, 
                                                _objc_internal_zone());

    return future_class_map;
}


/***********************************************************************
* addFutureClass
* Installs cls as the class structure to use for the named class if it appears.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void addFutureClass(const char *name, class_t *cls)
{
    void *old;

    rwlock_assert_writing(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", cls, name);
    }

    cls->data = _calloc_internal(sizeof(*cls->data), 1);
    cls->data->flags = RO_FUTURE;

    old = NXMapKeyCopyingInsert(futureClasses(), name, cls);
    assert(!old);
}


/***********************************************************************
* removeFutureClass
* Removes the named class from the unrealized future class list, 
* because it has been realized.
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static void removeFutureClass(const char *name)
{
    rwlock_assert_writing(&runtimeLock);

    NXMapKeyFreeingRemove(futureClasses(), name);
}


/***********************************************************************
* remappedClasses
* Returns the oldClass => newClass map for realized future classes.
* Returns the oldClass => NULL map for ignored weak-linked classes.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static NXMapTable *remappedClasses(BOOL create)
{
    static NXMapTable *remapped_class_map = NULL;

    rwlock_assert_locked(&runtimeLock);

    if (remapped_class_map) return remapped_class_map;
    if (!create) return NULL;

    // remapped_class_map is big enough to hold CF's classes and a few others
    INIT_ONCE_PTR(remapped_class_map, 
                  NXCreateMapTableFromZone(NXPtrValueMapPrototype, 32, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v));

    return remapped_class_map;
}


/***********************************************************************
* noClassesRemapped
* Returns YES if no classes have been remapped
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static BOOL noClassesRemapped(void)
{
    rwlock_assert_locked(&runtimeLock);

    BOOL result = (remappedClasses(NO) == NULL);
    return result;
}


/***********************************************************************
* addRemappedClass
* newcls is a realized future class, replacing oldcls.
* OR newcls is NULL, replacing ignored weak-linked class oldcls.
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static void addRemappedClass(class_t *oldcls, class_t *newcls)
{
    rwlock_assert_writing(&runtimeLock);

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s", 
                     oldcls, newcls, getName(newcls));
    }

    void *old;
    old = NXMapInsert(remappedClasses(YES), oldcls, newcls);
    assert(!old);
}


/***********************************************************************
* remapClass
* Returns the live class pointer for cls, which may be pointing to 
* a class struct that has been reallocated.
* Returns NULL if cls is ignored because of weak linking.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static class_t *remapClass(class_t *cls)
{
    rwlock_assert_locked(&runtimeLock);

    class_t *c2;

    if (!cls) return NULL;

    if (NXMapMember(remappedClasses(YES), cls, (void**)&c2) == NX_MAPNOTAKEY) {
        return cls;
    } else {
        return c2;
    }
}


/***********************************************************************
* remapClassRef
* Fix up a class ref, in case the class referenced has been reallocated 
* or is an ignored weak-linked class.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static void remapClassRef(class_t **clsref)
{
    rwlock_assert_locked(&runtimeLock);

    class_t *newcls = remapClass(*clsref);    
    if (*clsref != newcls) *clsref = newcls;
}


/***********************************************************************
* addSubclass
* Adds subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void addSubclass(class_t *supercls, class_t *subcls)
{
    rwlock_assert_writing(&runtimeLock);

    if (supercls  &&  subcls) {
        assert(isRealized(supercls));
        assert(isRealized(subcls));
        subcls->data->nextSiblingClass = supercls->data->firstSubclass;
        supercls->data->firstSubclass = subcls;
    }
}


/***********************************************************************
* removeSubclass
* Removes subcls as a subclass of supercls.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void removeSubclass(class_t *supercls, class_t *subcls)
{
    rwlock_assert_writing(&runtimeLock);
    assert(getSuperclass(subcls) == supercls);

    class_t **cp;
    for (cp = &supercls->data->firstSubclass; 
         *cp  &&  *cp != subcls; 
         cp = &(*cp)->data->nextSiblingClass)
        ;
    assert(*cp == subcls);
    *cp = subcls->data->nextSiblingClass;
}



/***********************************************************************
* protocols
* Returns the protocol name => protocol map for protocols.
* Locking: runtimeLock must read- or write-locked by the caller
**********************************************************************/
static NXMapTable *protocols(void)
{
    static NXMapTable *protocol_map = NULL;
    
    rwlock_assert_locked(&runtimeLock);

    INIT_ONCE_PTR(protocol_map, 
                  NXCreateMapTableFromZone(NXStrValueMapPrototype, 16, 
                                           _objc_internal_zone()), 
                  NXFreeMapTable(v) );

    return protocol_map;
}


/***********************************************************************
* remapProtocol
* Returns the live protocol pointer for proto, which may be pointing to 
* a protocol struct that has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static protocol_t *remapProtocol(protocol_ref_t proto)
{
    rwlock_assert_locked(&runtimeLock);

    protocol_t *newproto = NXMapGet(protocols(), ((protocol_t *)proto)->name);
    return newproto ? newproto : (protocol_t *)proto;
}


/***********************************************************************
* remapProtocolRef
* Fix up a protocol ref, in case the protocol referenced has been reallocated.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static void remapProtocolRef(protocol_t **protoref)
{
    rwlock_assert_locked(&runtimeLock);

    protocol_t *newproto = remapProtocol((protocol_ref_t)*protoref);
    if (*protoref != newproto) *protoref = newproto;
}


/***********************************************************************
* moveIvars
* Slides a class's ivars to accommodate the given superclass size.
* Also slides ivar and weak GC layouts if provided.
* Ivars are NOT compacted to compensate for a superclass that shrunk.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void moveIvars(class_ro_t *ro, uint32_t superSize, 
                      layout_bitmap *ivarBitmap, layout_bitmap *weakBitmap)
{
    rwlock_assert_writing(&runtimeLock);

    uint32_t diff;
    uint32_t i;

    assert(superSize > ro->instanceStart);
    diff = superSize - ro->instanceStart;

    if (ro->ivars) {
        // Find maximum alignment in this class's ivars
        uint32_t maxAlignment = 1;
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            uint32_t alignment = ivar_alignment(ivar);
            if (alignment > maxAlignment) maxAlignment = alignment;
        }

        // Compute a slide value that preserves that alignment
        uint32_t alignMask = maxAlignment - 1;
        if (diff & alignMask) diff = (diff + alignMask) & ~alignMask;

        // Slide all of this class's ivars en masse
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            uint32_t oldOffset = (uint32_t)*ivar->offset;
            uint32_t newOffset = oldOffset + diff;
            *ivar->offset = newOffset;

            if (PrintIvars) {
                _objc_inform("IVARS:    offset %u -> %u for %s (size %u, align %u)", 
                             oldOffset, newOffset, ivar->name, 
                             ivar->size, ivar_alignment(ivar));
            }
        }

        // Slide GC layouts
        uint32_t oldOffset = ro->instanceStart;
        uint32_t newOffset = ro->instanceStart + diff;

        if (ivarBitmap) {
            layout_bitmap_slide(ivarBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
        if (weakBitmap) {
            layout_bitmap_slide(weakBitmap, 
                                oldOffset >> WORD_SHIFT, 
                                newOffset >> WORD_SHIFT);
        }
    }

    *(uint32_t *)&ro->instanceStart += diff;
    *(uint32_t *)&ro->instanceSize += diff;

    if (!ro->ivars) {
        // No ivars slid, but superclass changed size. 
        // Expand bitmap in preparation for layout_bitmap_splat().
        if (ivarBitmap) layout_bitmap_grow(ivarBitmap, ro->instanceSize >> WORD_SHIFT);
        if (weakBitmap) layout_bitmap_grow(weakBitmap, ro->instanceSize >> WORD_SHIFT);
    }
}


/***********************************************************************
* getIvar
* Look up an ivar by name.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
static ivar_t *getIvar(class_t *cls, const char *name)
{
    rwlock_assert_locked(&runtimeLock);

    const ivar_list_t *ivars;
    assert(isRealized(cls));
    if ((ivars = cls->data->ro->ivars)) {
        uint32_t i;
        for (i = 0; i < ivars->count; i++) {
            struct ivar_t *ivar = ivar_list_nth(ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            // ivar->name may be NULL for anonymous bitfields etc.
            if (ivar->name  &&  0 == strcmp(name, ivar->name)) {
                return ivar;
            }
        }
    }

    return NULL;
}


/***********************************************************************
* realizeClass
* Performs first-time initialization on class cls, 
* including allocating its read-write data.
* Returns the real class structure for the class. 
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static class_t *realizeClass(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    const class_ro_t *ro;
    class_rw_t *rw;
    class_t *supercls;
    class_t *metacls;
    BOOL isMeta;

    if (!cls) return NULL;
    if (isRealized(cls)) return cls;
    assert(cls == remapClass(cls));

    ro = (const class_ro_t *)cls->data;
    if (ro->flags & RO_FUTURE) {
        // This was a future class. rw data is already allocated.
        rw = cls->data;
        ro = cls->data->ro;
        changeInfo(cls, RW_REALIZED, RW_FUTURE);
    } else {
        // Normal class. Allocate writeable class data.
        rw = _calloc_internal(sizeof(class_rw_t), 1);
        rw->ro = ro;
        rw->flags = RW_REALIZED;
        cls->data = rw;
    }

    isMeta = (ro->flags & RO_META) ? YES : NO;

    rw->version = isMeta ? 7 : 0;  // old runtime went up to 6

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' %s %p %p", 
                     ro->name, isMeta ? "(meta)" : "", cls, ro);
    }

    // Realize superclass and metaclass, if they aren't already.
    // This needs to be done after RW_REALIZED is set above, for root classes.
    supercls = realizeClass(remapClass(cls->superclass));
    metacls = realizeClass(remapClass(cls->isa));

    // Check for remapped superclass
    // fixme doesn't handle remapped metaclass
    assert(metacls == cls->isa);
    if (supercls != cls->superclass) {
        cls->superclass = supercls;
    }

    /* debug: print them all
    if (ro->ivars) {
        uint32_t i;
        for (i = 0; i < ro->ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ro->ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield

            _objc_inform("IVARS: %s.%s (offset %u, size %u, align %u)", 
                         ro->name, ivar->name, 
                         *ivar->offset, ivar->size, ivar_alignment(ivar));
        }
    }
    */


    if (supercls) {
        // Non-fragile ivars - reconcile this class with its superclass
        layout_bitmap ivarBitmap;
        layout_bitmap weakBitmap;
        BOOL layoutsChanged = NO;

        if (UseGC) {
            // fixme can optimize for "class has no new ivars", etc
            // WARNING: gcc c++ sets instanceStart/Size=0 for classes with  
            //   no local ivars, but does provide a layout bitmap. 
            //   Handle that case specially so layout_bitmap_create doesn't die
            //   The other ivar sliding code below still works fine, and 
            //   the final result is a good class.
            if (ro->instanceStart == 0  &&  ro->instanceSize == 0) {
                // We can't use ro->ivarLayout because we don't know
                // how long it is. Force a new layout to be created.
                if (PrintIvars) {
                    _objc_inform("IVARS: instanceStart/Size==0 for class %s; "
                                 "disregarding ivar layout", ro->name);
                }
                ivarBitmap = 
                    layout_bitmap_create(NULL, 
                                         supercls->data->ro->instanceSize, 
                                         supercls->data->ro->instanceSize, NO);
                weakBitmap = 
                    layout_bitmap_create(NULL, 
                                         supercls->data->ro->instanceSize, 
                                         supercls->data->ro->instanceSize, YES);
                layoutsChanged = YES;
            } else {
                ivarBitmap = 
                    layout_bitmap_create(ro->ivarLayout, 
                                         ro->instanceSize, 
                                         ro->instanceSize, NO);
                weakBitmap = 
                    layout_bitmap_create(ro->weakIvarLayout, 
                                         ro->instanceSize,
                                         ro->instanceSize, YES);
            }
        }

        if (ro->instanceStart < supercls->data->ro->instanceSize) {
            // Superclass has changed size. This class's ivars must move.
            // Also slide layout bits in parallel.
            // This code is incapable of compacting the subclass to 
            //   compensate for a superclass that shrunk, so don't do that.
            if (PrintIvars) {
                _objc_inform("IVARS: sliding ivars for class %s "
                             "(superclass was %u bytes, now %u)", 
                             ro->name, ro->instanceStart, 
                             supercls->data->ro->instanceSize);
            }
            class_ro_t *ro_w = make_ro_writeable(rw);
            ro = rw->ro;
            moveIvars(ro_w, supercls->data->ro->instanceSize, 
                      UseGC ? &ivarBitmap : NULL, UseGC ? &weakBitmap : NULL);
            gdb_objc_class_changed((Class)cls, OBJC_CLASS_IVARS_CHANGED, ro->name);
            layoutsChanged = YES;
        } 
        
        if (UseGC) {
            // Check superclass's layout against this class's layout.
            // This needs to be done even if the superclass is not bigger.
            layout_bitmap superBitmap = 
                layout_bitmap_create(supercls->data->ro->ivarLayout, 
                                     supercls->data->ro->instanceSize, 
                                     supercls->data->ro->instanceSize, NO);
            layoutsChanged |= layout_bitmap_splat(ivarBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);

            superBitmap = 
                layout_bitmap_create(supercls->data->ro->weakIvarLayout, 
                                     supercls->data->ro->instanceSize, 
                                     supercls->data->ro->instanceSize, YES);
            layoutsChanged |= layout_bitmap_splat(weakBitmap, superBitmap, 
                                                  ro->instanceStart);
            layout_bitmap_free(superBitmap);

            if (layoutsChanged) {
                // Rebuild layout strings. 
                if (PrintIvars) {
                    _objc_inform("IVARS: gc layout changed for class %s",
                                 ro->name);
                }
                class_ro_t *ro_w = make_ro_writeable(rw);
                ro = rw->ro;
                ro_w->ivarLayout = layout_string_create(ivarBitmap);
                ro_w->weakIvarLayout = layout_string_create(weakBitmap);
            }

            layout_bitmap_free(ivarBitmap);
            layout_bitmap_free(weakBitmap);
        }
    }

    // Connect this class to its superclass's subclass lists
    if (supercls) {
        addSubclass(supercls, cls);
    }

    // Attach categories
    methodizeClass(cls);

    if (!isMeta) {
        addRealizedClass(cls);
    } else {
        addRealizedMetaclass(cls);
    }

    return cls;
}


/***********************************************************************
* getClass
* Looks up a class by name. The class MIGHT NOT be realized.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
static class_t *getClass(const char *name)
{
    rwlock_assert_locked(&runtimeLock);

    return (class_t *)NXMapGet(namedClasses(), name);
}


/***********************************************************************
* missingWeakSuperclass
* Return YES if some superclass of cls was weak-linked and is missing.
**********************************************************************/
static BOOL 
missingWeakSuperclass(class_t *cls)
{
    assert(!isRealized(cls));

    if (!cls->superclass) {
        // superclass NULL. This is normal for root classes only.
        return (!(cls->data->flags & RO_ROOT));
    } else {
        // superclass not NULL. Check if a higher superclass is missing.
        class_t *supercls = remapClass(cls->superclass);
        if (!supercls) return YES;
        if (isRealized(supercls)) return NO;
        return missingWeakSuperclass(supercls);
    }
}


/***********************************************************************
* realizeAllClassesInImage
* Non-lazily realizes all unrealized classes in the given image.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClassesInImage(header_info *hi)
{
    rwlock_assert_writing(&runtimeLock);

    size_t count, i;
    class_t **classlist;

    if (hi->allClassesRealized) return;

    classlist = _getObjc2ClassList(hi, &count);

    for (i = 0; i < count; i++) {
        realizeClass(remapClass(classlist[i]));
    }

    hi->allClassesRealized = YES;
}


/***********************************************************************
* realizeAllClasses
* Non-lazily realizes all unrealized classes in all known images.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void realizeAllClasses(void)
{
    rwlock_assert_writing(&runtimeLock);

    header_info *hi;
    for (hi = FirstHeader; hi; hi = hi->next) {
        realizeAllClassesInImage(hi);
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ Class _objc_allocateFutureClass(const char *name)
{
    rwlock_write(&runtimeLock);

    struct class_t *cls;
    NXMapTable *future_class_map = futureClasses();

    if ((cls = NXMapGet(future_class_map, name))) {
        // Already have a future class for this name.
        rwlock_unlock_write(&runtimeLock);
        return (Class)cls;
    }

    cls = (class_t *)_calloc_class(sizeof(*cls));
    addFutureClass(name, cls);

    rwlock_unlock_write(&runtimeLock);
    return (Class)cls;
}


/***********************************************************************
* 
**********************************************************************/
void objc_setFutureClass(Class cls, const char *name)
{
    // fixme hack do nothing - NSCFString handled specially elsewhere
}


#define FOREACH_REALIZED_SUBCLASS(_c, _cls, code)                       \
    do {                                                                \
        rwlock_assert_writing(&runtimeLock);                                \
        class_t *_top = _cls;                                           \
        class_t *_c = _top;                                             \
        if (_c) {                                                       \
            while (1) {                                                 \
                code                                                    \
                if (_c->data->firstSubclass) {                          \
                    _c = _c->data->firstSubclass;                       \
                } else {                                                \
                    while (!_c->data->nextSiblingClass  &&  _c != _top) { \
                        _c = getSuperclass(_c);                         \
                    }                                                   \
                    if (_c == _top) break;                              \
                    _c = _c->data->nextSiblingClass;                    \
                }                                                       \
            }                                                           \
        } else {                                                        \
            /* nil means all realized classes */                        \
            NXHashTable *_classes = realizedClasses();                  \
            NXHashTable *_metaclasses = realizedMetaclasses();          \
            NXHashState _state;                                         \
            _state = NXInitHashState(_classes);                         \
            while (NXNextHashState(_classes, &_state, (void**)&_c))    \
            {                                                           \
                code                                                    \
            }                                                           \
            _state = NXInitHashState(_metaclasses);                     \
            while (NXNextHashState(_metaclasses, &_state, (void**)&_c)) \
            {                                                           \
                code                                                    \
            }                                                           \
        }                                                               \
    } while (0)


/***********************************************************************
* flushVtables
* Rebuilds vtables for cls and its realized subclasses. 
* If cls is Nil, all realized classes and metaclasses are touched.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void flushVtables(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    if (PrintVtables  &&  !cls) {
        _objc_inform("VTABLES: ### EXPENSIVE ### global vtable flush!");
    }

    FOREACH_REALIZED_SUBCLASS(c, cls, {
        updateVtable(c, NO);
    });
}


/***********************************************************************
* flushCaches
* Flushes caches for cls and its realized subclasses.
* Does not update vtables.
* If cls is Nil, all realized and metaclasses classes are touched.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static void flushCaches(class_t *cls)
{
    rwlock_assert_writing(&runtimeLock);

    FOREACH_REALIZED_SUBCLASS(c, cls, {
        flush_cache((Class)c);
    });
}


/***********************************************************************
* flush_caches
* Flushes caches and rebuilds vtables for cls, its subclasses, 
* and optionally its metaclass.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ void flush_caches(Class cls_gen, BOOL flush_meta)
{
    class_t *cls = newcls(cls_gen);
    rwlock_write(&runtimeLock);
    // fixme optimize vtable flushing? (only needed for vtable'd selectors)
    flushCaches(cls);
    flushVtables(cls);
    // don't flush root class's metaclass twice (it's a subclass of the root)
    if (flush_meta  &&  getSuperclass(cls)) {
        flushCaches(cls->isa);
        flushVtables(cls->isa);
    }
    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock
**********************************************************************/
__private_extern__ const char *
map_images(enum dyld_image_states state, uint32_t infoCount,
           const struct dyld_image_info infoList[])
{
    const char *err;

    rwlock_write(&runtimeLock);
    err = map_images_nolock(state, infoCount, infoList);
    rwlock_unlock_write(&runtimeLock);
    return err;
}


/***********************************************************************
* load_images
* Process +load in the given images which are being mapped in by dyld.
* Calls ABI-agnostic code after taking ABI-specific locks.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
__private_extern__ const char *
load_images(enum dyld_image_states state, uint32_t infoCount,
            const struct dyld_image_info infoList[])
{
    BOOL found;

    recursive_mutex_lock(&loadMethodLock);

    // Discover load methods
    rwlock_write(&runtimeLock);
    found = load_images_nolock(state, infoCount, infoList);
    rwlock_unlock_write(&runtimeLock);

    // Call +load methods (without runtimeLock - re-entrant)
    if (found) {
        call_load_methods();
    }

    recursive_mutex_unlock(&loadMethodLock);

    return NULL;
}


/***********************************************************************
* unmap_image
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
*
* Locking: write-locks runtimeLock and loadMethodLock
**********************************************************************/
__private_extern__ void 
unmap_image(const struct mach_header *mh, intptr_t vmaddr_slide)
{
    recursive_mutex_lock(&loadMethodLock);
    rwlock_write(&runtimeLock);

    unmap_image_nolock(mh, vmaddr_slide);

    rwlock_unlock_write(&runtimeLock);
    recursive_mutex_unlock(&loadMethodLock);
}


/***********************************************************************
* _read_images
* Perform initial processing of the headers in the linked 
* list beginning with headerList. 
*
* Called by: map_images_nolock
*
* Locking: runtimeLock acquired by map_images
**********************************************************************/
__private_extern__ void _read_images(header_info **hList, uint32_t hCount)
{
    header_info *hi;
    uint32_t hIndex;
    size_t count;
    size_t i;
    class_t **resolvedFutureClasses = NULL;
    size_t resolvedFutureClassCount = 0;
    static BOOL doneOnce;

    rwlock_assert_writing(&runtimeLock);

    if (!doneOnce) {
        initVtables();
        doneOnce = YES;
    }

#define EACH_HEADER \
    hIndex = 0; \
    hIndex < hCount && (hi = hList[hIndex]);    \
    hIndex++

    // Complain about images that contain old-ABI data
    // fixme new-ABI compiler still emits some bits into __OBJC segment
    for (EACH_HEADER) {
        size_t count;
        if (_getObjcSelectorRefs(hi, &count) || _getObjcModules(hi, &count)) {
            _objc_inform("found old-ABI metadata in image %s !", 
                         hi->os.dl_info.dli_fname);
        }
    }

    // fixme hack
    static BOOL hackedNSCFString = NO;
    if (!hackedNSCFString) {
        // Insert future class __CFConstantStringClassReference == NSCFString
        void *dlh = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
        if (dlh) {
            void *addr = dlsym(dlh, "__CFConstantStringClassReference");
            if (addr) {
                addFutureClass("NSCFString", (class_t *)addr);
                hackedNSCFString = YES;
            }
            dlclose(dlh);
        }
    }

    // Discover classes. Fix up unresolved future classes. Mark bundle classes.
    NXMapTable *future_class_map = futureClasses();
    for (EACH_HEADER) {
        class_t **classlist = _getObjc2ClassList(hi, &count);
        for (i = 0; i < count; i++) {
            const char *name = getName(classlist[i]);
            
            if (missingWeakSuperclass(classlist[i])) {
                // No superclass (probably weak-linked). 
                // Disavow any knowledge of this subclass.
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING class '%s' with "
                                 "missing weak-linked superclass", name);
                }
                addRemappedClass(classlist[i], NULL);
                classlist[i]->superclass = NULL;
                classlist[i] = NULL;
                continue;
            }

            if (NXCountMapTable(future_class_map) > 0) {
                class_t *newCls = NXMapGet(future_class_map, name);
                if (newCls) {
                    // Copy class_t to future class's struct.
                    // Preserve future's rw data block.
                    class_rw_t *rw = newCls->data;
                    memcpy(newCls, classlist[i], sizeof(class_t));
                    rw->ro = (class_ro_t *)newCls->data;
                    newCls->data = rw;

                    removeFutureClass(name);
                    addRemappedClass(classlist[i], newCls);
                    classlist[i] = newCls;
                    // Non-lazily realize the class below.
                    resolvedFutureClasses = (class_t **)
                        _realloc_internal(resolvedFutureClasses, 
                                          (resolvedFutureClassCount+1) 
                                          * sizeof(class_t *));
                    resolvedFutureClasses[resolvedFutureClassCount++] = newCls;
                }
            }
            addNamedClass(classlist[i], name);
            addUninitializedClass(classlist[i], classlist[i]->isa);
            if (hi->mhdr->filetype == MH_BUNDLE) {
                classlist[i]->data->flags |= RO_FROM_BUNDLE;
                classlist[i]->isa->data->flags |= RO_FROM_BUNDLE;
            }
        }
    }

    // Fix up remapped classes
    // classlist is up to date, but classrefs may not be
    
    if (!noClassesRemapped()) {
        for (EACH_HEADER) {
            class_t **classrefs = _getObjc2ClassRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
            // fixme why doesn't test future1 catch the absence of this?
            classrefs = _getObjc2SuperRefs(hi, &count);
            for (i = 0; i < count; i++) {
                remapClassRef(&classrefs[i]);
            }
        }
    }


    // Fix up @selector references
    sel_lock();
    for (EACH_HEADER) {
        if (PrintPreopt) {
            if (sel_preoptimizationValid(hi)) {
                _objc_inform("PREOPTIMIZATION: honoring preoptimized selectors in %s", 
                             _nameForHeader(hi->mhdr));
            }
            else if (_objcHeaderOptimizedByDyld(hi)) {
                _objc_inform("PREOPTIMIZATION: IGNORING preoptimized selectors in %s", 
                             _nameForHeader(hi->mhdr));
            }
        }
        
        if (sel_preoptimizationValid(hi)) continue;

        SEL *sels = _getObjc2SelectorRefs(hi, &count);
        BOOL isBundle = hi->mhdr->filetype == MH_BUNDLE;
        for (i = 0; i < count; i++) {
            sels[i] = sel_registerNameNoLock((const char *)sels[i], isBundle);
        }
    }
    sel_unlock();

    // Discover protocols. Fix up protocol refs.
    NXMapTable *protocol_map = protocols();
    for (EACH_HEADER) {
        extern struct class_t OBJC_CLASS_$_Protocol;
        Class cls = (Class)&OBJC_CLASS_$_Protocol;
        assert(cls);
        protocol_t **protocols = _getObjc2ProtocolList(hi, &count);
        // fixme duplicate protocol from bundle
        for (i = 0; i < count; i++) {
            if (!NXMapGet(protocol_map, protocols[i]->name)) {
                protocols[i]->isa = cls;
                NXMapKeyCopyingInsert(protocol_map, 
                                      protocols[i]->name, protocols[i]);
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s",
                                 protocols[i], protocols[i]->name);
                }
            } else {
                if (PrintProtocols) {
                    _objc_inform("PROTOCOLS: protocol at %p is %s (duplicate)",
                                 protocols[i], protocols[i]->name);
                }
            }
        }
    }
    for (EACH_HEADER) {
        protocol_t **protocols;
        protocols = _getObjc2ProtocolRefs(hi, &count);
        for (i = 0; i < count; i++) {
            remapProtocolRef(&protocols[i]);
        }
    }

    // Realize non-lazy classes (for +load methods and static instances)
    for (EACH_HEADER) {
        class_t **classlist = 
            _getObjc2NonlazyClassList(hi, &count);
        for (i = 0; i < count; i++) {
            realizeClass(remapClass(classlist[i]));
        }
    }    

    // Realize newly-resolved future classes, in case CF manipulates them
    if (resolvedFutureClasses) {
        for (i = 0; i < resolvedFutureClassCount; i++) {
            realizeClass(resolvedFutureClasses[i]);
        }
        _free_internal(resolvedFutureClasses);
    }    

    // Discover categories. 
    for (EACH_HEADER) {
        category_t **catlist = 
            _getObjc2CategoryList(hi, &count);
        for (i = 0; i < count; i++) {
            category_t *cat = catlist[i];
            // Do NOT use cat->cls! It may have been remapped.
            class_t *cls = remapClass(cat->cls);

            if (!cls) {
                // Category's target class is missing (probably weak-linked).
                // Disavow any knowledge of this category.
                catlist[i] = NULL;
                if (PrintConnecting) {
                    _objc_inform("CLASS: IGNORING category \?\?\?(%s) %p with "
                                 "missing weak-linked target class", 
                                 cat->name, cat);
                }
                continue;
            }

            // Process this category. 
            // First, register the category with its target class. 
            // Then, rebuild the class's method lists (etc) if 
            // the class is realized. 
            BOOL classExists = NO;
            if (cat->instanceMethods ||  cat->protocols  
                ||  cat->instanceProperties) 
            {
                addUnattachedCategoryForClass(cat, cls, hi);
                if (isRealized(cls)) {
                    remethodizeClass(cls);
                    classExists = YES;
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category -%s(%s) %s", 
                                 getName(cls), cat->name, 
                                 classExists ? "on existing class" : "");
                }
            }

            if (cat->classMethods  ||  cat->protocols  
                /* ||  cat->classProperties */) 
            {
                addUnattachedCategoryForClass(cat, cls->isa, hi);
                if (isRealized(cls->isa)) {
                    remethodizeClass(cls->isa);
                }
                if (PrintConnecting) {
                    _objc_inform("CLASS: found category +%s(%s)", 
                                 getName(cls), cat->name);
                }
            }
        }
    }

    // Category discovery MUST BE LAST to avoid potential races 
    // when other threads call the new category code before 
    // this thread finishes its fixups.

    // +load handled by prepare_load_methods()

#undef EACH_HEADER
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed 
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
static void schedule_class_load(class_t *cls)
{
    if (!cls) return;
    assert(isRealized(cls));  // _read_images should realize

    if (cls->data->flags & RW_LOADED) return;

    // Ensure superclass-first ordering
    schedule_class_load(getSuperclass(cls));

    add_class_to_loadable_list((Class)cls);
    changeInfo(cls, RW_LOADED, 0); 
}

__private_extern__ void prepare_load_methods(header_info *hi)
{
    size_t count, i;

    rwlock_assert_writing(&runtimeLock);

    class_t **classlist = 
        _getObjc2NonlazyClassList(hi, &count);
    for (i = 0; i < count; i++) {
        schedule_class_load(remapClass(classlist[i]));
    }

    category_t **categorylist = _getObjc2NonlazyCategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = categorylist[i];
        // Do NOT use cat->cls! It may have been remapped.
        class_t *cls = remapClass(cat->cls);
        if (!cls) continue;  // category for ignored weak-linked class
        realizeClass(cls);
        assert(isRealized(cls->isa));
        add_category_to_loadable_list((Category)cat);
    }
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
* Locking: write-lock and loadMethodLock acquired by unmap_image
**********************************************************************/
__private_extern__ void _unload_image(header_info *hi)
{
    size_t count, i;

    recursive_mutex_assert_locked(&loadMethodLock);
    rwlock_assert_writing(&runtimeLock);

    // Unload unattached categories and categories waiting for +load.

    category_t **catlist = _getObjc2CategoryList(hi, &count);
    for (i = 0; i < count; i++) {
        category_t *cat = catlist[i];
        if (!cat) continue;  // category for ignored weak-linked class
        class_t *cls = remapClass(cat->cls);
        assert(cls);  // shouldn't have live category for dead class

        // fixme for MH_DYLIB cat's class may have been unloaded already

        // unattached list
        removeUnattachedCategoryForClass(cat, cls);

        // +load queue
        remove_category_from_loadable_list((Category)cat);
    }

    // Unload classes.

    class_t **classlist = _getObjc2ClassList(hi, &count);
    for (i = 0; i < count; i++) {
        class_t *cls = classlist[i];
        // fixme remapped classes?
        // fixme ignored weak-linked classes
        if (cls) {
            remove_class_from_loadable_list((Class)cls);
            unload_class(cls->isa, YES);
            unload_class(cls, NO);
        }
    }
    
    // Clean up protocols.
#warning fixme protocol unload

    // fixme DebugUnload
}


/***********************************************************************
* method_getDescription
* Returns a pointer to this method's objc_method_description.
* Locking: none
**********************************************************************/
struct objc_method_description *
method_getDescription(Method m)
{
    if (!m) return NULL;
    return (struct objc_method_description *)newmethod(m);
}


/***********************************************************************
* method_getImplementation
* Returns this method's IMP.
* Locking: none
**********************************************************************/
static IMP 
_method_getImplementation(method_t *m)
{
    if (!m) return NULL;
    return m->imp;
}

IMP 
method_getImplementation(Method m)
{
    return _method_getImplementation(newmethod(m));
}


/***********************************************************************
* method_getName
* Returns this method's selector.
* The method must not be NULL.
* The method must already have been fixed-up.
* Locking: none
**********************************************************************/
SEL 
method_getName(Method m_gen)
{
    struct method_t *m = newmethod(m_gen);
    if (!m) return NULL;

    assert((SEL)m->name == sel_registerName((char *)m->name));
    return (SEL)m->name;
}


/***********************************************************************
* method_getTypeEncoding
* Returns this method's old-style type encoding string.
* The method must not be NULL.
* Locking: none
**********************************************************************/
const char *
method_getTypeEncoding(Method m)
{
    if (!m) return NULL;
    return newmethod(m)->types;
}


/***********************************************************************
* method_setImplementation
* Sets this method's implementation to imp.
* The previous implementation is returned.
**********************************************************************/
static IMP 
_method_setImplementation(class_t *cls, method_t *m, IMP imp)
{
    rwlock_assert_writing(&runtimeLock);

    if (!m) return NULL;
    if (!imp) return NULL;

    if (m->name == (SEL)kIgnore) {
        // Ignored methods stay ignored
        return m->imp;
    }

    IMP old = _method_getImplementation(m);
    m->imp = imp;

    // No cache flushing needed - cache contains Methods not IMPs.

    if (vtable_containsSelector(newmethod(m)->name)) {
        // Will be slow if cls is NULL (i.e. unknown)
        // fixme build list of classes whose Methods are known externally?
        flushVtables(cls);
    }

    // fixme update monomorphism if necessary

    return old;
}

IMP 
method_setImplementation(Method m, IMP imp)
{
    // Don't know the class - will be slow if vtables are affected
    // fixme build list of classes whose Methods are known externally?
    IMP result;
    rwlock_write(&runtimeLock);
    result = _method_setImplementation(Nil, newmethod(m), imp);
    rwlock_unlock_write(&runtimeLock);
    return result;
}


void method_exchangeImplementations(Method m1_gen, Method m2_gen)
{
    method_t *m1 = newmethod(m1_gen);
    method_t *m2 = newmethod(m2_gen);
    if (!m1  ||  !m2) return;

    rwlock_write(&runtimeLock);

    if (m1->name == (SEL)kIgnore  ||  m2->name == (SEL)kIgnore) {
        // Ignored methods stay ignored. Now they're both ignored.
        m1->imp = (IMP)&_objc_ignored_method;
        m2->imp = (IMP)&_objc_ignored_method;
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    IMP m1_imp = m1->imp;
    m1->imp = m2->imp;
    m2->imp = m1_imp;

    if (vtable_containsSelector(m1->name)  ||  
        vtable_containsSelector(m2->name)) 
    {
        // Don't know the class - will be slow if vtables are affected
        // fixme build list of classes whose Methods are known externally?
        flushVtables(NULL);
    }

    // fixme update monomorphism if necessary

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* ivar_getOffset
* fixme
* Locking: none
**********************************************************************/
ptrdiff_t
ivar_getOffset(Ivar ivar)
{
    if (!ivar) return 0;
    return *newivar(ivar)->offset;
}


/***********************************************************************
* ivar_getName
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getName(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->name;
}


/***********************************************************************
* ivar_getTypeEncoding
* fixme
* Locking: none
**********************************************************************/
const char *
ivar_getTypeEncoding(Ivar ivar)
{
    if (!ivar) return NULL;
    return newivar(ivar)->type;
}


/***********************************************************************
* _protocol_getMethod_nolock
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static Method 
_protocol_getMethod_nolock(protocol_t *proto, SEL sel, 
                           BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    rwlock_assert_writing(&runtimeLock);

    uint32_t i;
    if (!proto  ||  !sel) return NULL;

    method_list_t **mlistp = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlistp = &proto->instanceMethods;
        } else {
            mlistp = &proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlistp = &proto->optionalInstanceMethods;
        } else {
            mlistp = &proto->optionalClassMethods;
        }
    }

    if (*mlistp) {
        method_list_t *mlist = *mlistp;
        if (!isMethodListFixedUp(mlist)) {
            mlist = _memdup_internal(mlist, method_list_size(mlist));
            fixupMethodList(mlist, YES/*always copy for simplicity*/);
            *mlistp = mlist;
        }
        for (i = 0; i < mlist->count; i++) {
            method_t *m = method_list_nth(mlist, i);
            if (sel == m->name) return (Method)m;
        }
    }

    if (proto->protocols) {
        Method m;
        for (i = 0; i < proto->protocols->count; i++) {
            protocol_t *realProto = remapProtocol(proto->protocols->list[i]);
            m = _protocol_getMethod_nolock(realProto, sel, 
                                           isRequiredMethod, isInstanceMethod);
            if (m) return m;
        }
    }

    return NULL;
}


/***********************************************************************
* _protocol_getMethod
* fixme
* Locking: write-locks runtimeLock
**********************************************************************/
__private_extern__ Method 
_protocol_getMethod(Protocol *p, SEL sel, BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    rwlock_write(&runtimeLock);
    Method result = _protocol_getMethod_nolock(newprotocol(p), sel, 
                                               isRequiredMethod,
                                               isInstanceMethod);
    rwlock_unlock_write(&runtimeLock);
    return result;
}


/***********************************************************************
* protocol_getName
* Returns the name of the given protocol.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
const char *
protocol_getName(Protocol *proto)
{
    return newprotocol(proto)->name;
}


/***********************************************************************
* protocol_getInstanceMethodDescription
* Returns the description of a named instance method.
* Locking: runtimeLock must not be held by the caller
**********************************************************************/
struct objc_method_description 
protocol_getMethodDescription(Protocol *p, SEL aSel, 
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    Method m = 
        _protocol_getMethod(p, aSel, isRequiredMethod, isInstanceMethod);
    if (m) return *method_getDescription(m);
    else return (struct objc_method_description){NULL, NULL};
}


/***********************************************************************
* _protocol_conformsToProtocol_nolock
* Returns YES if self conforms to other.
* Locking: runtimeLock must be held by the caller.
**********************************************************************/
static BOOL _protocol_conformsToProtocol_nolock(protocol_t *self, protocol_t *other)
{
    if (!self  ||  !other) {
        return NO;
    }

    if (0 == strcmp(self->name, other->name)) {
        return YES;
    }

    if (self->protocols) {
        int i;
        for (i = 0; i < self->protocols->count; i++) {
            protocol_t *proto = remapProtocol(self->protocols->list[i]);
            if (0 == strcmp(other->name, proto->name)) {
                return YES;
            }
            if (_protocol_conformsToProtocol_nolock(proto, other)) {
                return YES;
            }
        }
    }

    return NO;
}


/***********************************************************************
* protocol_conformsToProtocol
* Returns YES if self conforms to other.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_conformsToProtocol(Protocol *self, Protocol *other)
{
    BOOL result;
    rwlock_read(&runtimeLock);
    result = _protocol_conformsToProtocol_nolock(newprotocol(self), 
                                                 newprotocol(other));
    rwlock_unlock_read(&runtimeLock);
    return result;
}


/***********************************************************************
* protocol_isEqual
* Return YES if two protocols are equal (i.e. conform to each other)
* Locking: acquires runtimeLock
**********************************************************************/
BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES;
    if (!self  ||  !other) return NO;

    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns descriptions of a protocol's methods.
* Locking: acquires runtimeLock
**********************************************************************/
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p, 
                                   BOOL isRequiredMethod,BOOL isInstanceMethod,
                                   unsigned int *outCount)
{
    struct protocol_t *proto = newprotocol(p);
    struct objc_method_description *result = NULL;
    unsigned int count = 0;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    method_list_t *mlist = NULL;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlist = proto->instanceMethods;
        } else {
            mlist = proto->classMethods;
        }
    } else {
        if (isInstanceMethod) {
            mlist = proto->optionalInstanceMethods;
        } else {
            mlist = proto->optionalClassMethods;
        }
    }

    if (mlist) {
        unsigned int i;
        count = mlist->count;
        result = calloc(count + 1, sizeof(struct objc_method_description));
        for (i = 0; i < count; i++) {
            method_t *m = method_list_nth(mlist, i);
            result[i].name = sel_registerName((const char *)m->name);
            result[i].types = (char *)m->types;
        }
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* protocol_getProperty
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
static Property 
_protocol_getProperty_nolock(protocol_t *proto, const char *name, 
                             BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    if (!isRequiredProperty  ||  !isInstanceProperty) {
        // Only required instance properties are currently supported
        return NULL;
    }

    struct objc_property_list *plist;
    if ((plist = proto->instanceProperties)) {
        uint32_t i;
        for (i = 0; i < plist->count; i++) {
            Property prop = property_list_nth(plist, i);
            if (0 == strcmp(name, prop->name)) {
                return prop;
            }
        }
    }

    if (proto->protocols) {
        uintptr_t i;
        for (i = 0; i < proto->protocols->count; i++) {
            protocol_t *p = remapProtocol(proto->protocols->list[i]);
            Property prop = 
                _protocol_getProperty_nolock(p, name, 
                                             isRequiredProperty, 
                                             isInstanceProperty);
            if (prop) return prop;
        }
    }

    return NULL;
}

Property protocol_getProperty(Protocol *p, const char *name, 
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    Property result;

    if (!p  ||  !name) return NULL;

    rwlock_read(&runtimeLock);
    result = _protocol_getProperty_nolock(newprotocol(p), name, 
                                          isRequiredProperty, 
                                          isInstanceProperty);
    rwlock_unlock_read(&runtimeLock);
    
    return result;
}


/***********************************************************************
* protocol_copyPropertyList
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Property *protocol_copyPropertyList(Protocol *proto, unsigned int *outCount)
{
    Property *result = NULL;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    struct objc_property_list *plist = newprotocol(proto)->instanceProperties;
    result = copyPropertyList(plist, outCount);

    rwlock_unlock_read(&runtimeLock);

    return result;
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols. 
* Does not copy those protocol's incorporated protocols in turn.
* Locking: acquires runtimeLock
**********************************************************************/
Protocol **protocol_copyProtocolList(Protocol *p, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = NULL;
    protocol_t *proto = newprotocol(p);
    
    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    if (proto->protocols) {
        count = (unsigned int)proto->protocols->count;
    }
    if (count > 0) {
        result = malloc((count+1) * sizeof(Protocol *));

        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)remapProtocol(proto->protocols->list[i]);
        }
        result[i] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getClassList
* Returns pointers to all classes.
* This requires all classes be realized, which is regretfully non-lazy.
* Locking: acquires runtimeLock
**********************************************************************/
int 
objc_getClassList(Class *buffer, int bufferLen) 
{
    rwlock_write(&runtimeLock);

    realizeAllClasses();

    int count;
    class_t *cls;
    NXHashState state;
    NXHashTable *classes = realizedClasses();
    int allCount = NXCountHashTable(classes);

    if (!buffer) {
        rwlock_unlock_write(&runtimeLock);
        return allCount;
    }

    count = 0;
    state = NXInitHashState(classes);
    while (count < bufferLen  &&  
           NXNextHashState(classes, &state, (void **)&cls))
    {
        buffer[count++] = (Class)cls;
    }

    rwlock_unlock_write(&runtimeLock);

    return allCount;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol **
objc_copyProtocolList(unsigned int *outCount) 
{
    rwlock_read(&runtimeLock);

    int count, i;
    Protocol *proto;
    const char *name;
    NXMapState state;
    NXMapTable *protocol_map = protocols();
    Protocol **result;

    count = NXCountMapTable(protocol_map);
    if (count == 0) {
        rwlock_unlock_read(&runtimeLock);
        if (outCount) *outCount = 0;
        return NULL;
    }

    result = calloc(1 + count, sizeof(Protocol *));

    i = 0;
    state = NXInitMapState(protocol_map);
    while (NXNextMapState(protocol_map, &state, 
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }
    
    result[i++] = NULL;
    assert(i == count+1);

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or return NULL
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol *objc_getProtocol(const char *name)
{
    rwlock_read(&runtimeLock); 
    Protocol *result = (Protocol *)NXMapGet(protocols(), name);
    rwlock_unlock_read(&runtimeLock);
    return result;
}


/***********************************************************************
* class_copyMethodList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Method *
class_copyMethodList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    unsigned int count = 0;
    Method *result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);
    
    assert(isRealized(cls));

    FOREACH_METHOD_LIST(mlist, cls, {
        count += mlist->count;
    });

    if (count > 0) {
        unsigned int m;
        result = malloc((count + 1) * sizeof(Method));
        
        m = 0;
        FOREACH_METHOD_LIST(mlist, cls, {
            unsigned int i;
            for (i = 0; i < mlist->count; i++) {
                Method aMethod = (Method)method_list_nth(mlist, i);
                if (method_getName(aMethod) == (SEL)kIgnore) {
                    count--;
                    continue;
                }
                result[m++] = aMethod;
            }
        });
        result[m] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyIvarList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Ivar *
class_copyIvarList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    const ivar_list_t *ivars;
    Ivar *result = NULL;
    unsigned int count = 0;
    unsigned int i;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));
    
    if ((ivars = cls->data->ro->ivars)  &&  ivars->count) {
        result = malloc((ivars->count+1) * sizeof(Ivar));
        
        for (i = 0; i < ivars->count; i++) {
            ivar_t *ivar = ivar_list_nth(ivars, i);
            if (!ivar->offset) continue;  // anonymous bitfield
            result[count++] = (Ivar)ivar;
        }
        result[count] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);
    
    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* class_copyPropertyList. Returns a heap block containing the 
* properties declared in the class, or NULL if the class 
* declares no properties. Caller must free the block.
* Does not copy any superclass's properties.
* Locking: read-locks runtimeLock
**********************************************************************/
Property *
class_copyPropertyList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    chained_property_list *plist;
    unsigned int count = 0;
    Property *result = NULL;

    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));

    for (plist = cls->data->properties; plist; plist = plist->next) {
        count += plist->count;
    }

    if (count > 0) {
        unsigned int p;
        result = malloc((count + 1) * sizeof(Property));
        
        p = 0;
        for (plist = cls->data->properties; plist; plist = plist->next) {
            unsigned int i;
            for (i = 0; i < plist->count; i++) {
                result[p++] = (Property)&plist->list[i];
            }
        }
        result[p] = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* _class_getLoadMethod
* fixme
* Called only from add_class_to_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller.
**********************************************************************/
__private_extern__ IMP 
_class_getLoadMethod(Class cls_gen)
{
    rwlock_assert_locked(&runtimeLock);

    struct class_t *cls = newcls(cls_gen);
    const method_list_t *mlist;
    int i;

    assert(isRealized(cls));
    assert(isRealized(cls->isa));
    assert(!isMetaClass(cls));
    assert(isMetaClass(cls->isa));

    mlist = cls->isa->data->ro->baseMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* _category_getName
* Returns a category's name.
* Locking: none
**********************************************************************/
__private_extern__ const char *
_category_getName(Category cat)
{
    return newcategory(cat)->name;
}


/***********************************************************************
* _category_getClassName
* Returns a category's class's name
* Called only from add_category_to_loadable_list and 
* remove_category_from_loadable_list.
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
__private_extern__ const char *
_category_getClassName(Category cat)
{
    rwlock_assert_locked(&runtimeLock);
    // cat->cls may have been remapped
    return getName(remapClass(newcategory(cat)->cls));
}


/***********************************************************************
* _category_getClass
* Returns a category's class
* Called only by call_category_loads.
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ Class 
_category_getClass(Category cat)
{
    rwlock_read(&runtimeLock);
    // cat->cls may have been remapped
    struct class_t *result = remapClass(newcategory(cat)->cls);
    assert(isRealized(result));  // ok for call_category_loads' usage
    rwlock_unlock_read(&runtimeLock);
    return (Class)result;
}


/***********************************************************************
* _category_getLoadMethod
* fixme
* Called only from add_category_to_loadable_list
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
__private_extern__ IMP 
_category_getLoadMethod(Category cat)
{
    rwlock_assert_locked(&runtimeLock);

    const method_list_t *mlist;
    int i;

    mlist = newcategory(cat)->classMethods;
    if (mlist) for (i = 0; i < mlist->count; i++) {
        method_t *m = method_list_nth(mlist, i);
        if (0 == strcmp((const char *)m->name, "load")) {
            return m->imp;
        }
    }

    return NULL;
}


/***********************************************************************
* class_copyProtocolList
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Protocol **
class_copyProtocolList(Class cls_gen, unsigned int *outCount)
{
    struct class_t *cls = newcls(cls_gen);
    Protocol **r;
    struct protocol_list_t **p;
    unsigned int count = 0;
    unsigned int i;
    Protocol **result = NULL;
    
    if (!cls) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));
    
    for (p = cls->data->protocols; p  &&  *p; p++) {
        count += (uint32_t)(*p)->count;
    }

    if (count) {
        result = malloc((count+1) * sizeof(Protocol *));
        r = result;
        for (p = cls->data->protocols; p  &&  *p; p++) {
            for (i = 0; i < (*p)->count; i++) {
                *r++ = (Protocol *)remapProtocol((*p)->list[i]);
            }
        }
        *r++ = NULL;
    }

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* _objc_copyClassNamesForImage
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ const char **
_objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount)
{
    size_t count, i, shift;
    class_t **classlist;
    const char **names;
    
    rwlock_read(&runtimeLock);
    
    classlist = _getObjc2ClassList(hi, &count);
    names = malloc((count+1) * sizeof(const char *));
    
    shift = 0;
    for (i = 0; i < count; i++) {
        class_t *cls = remapClass(classlist[i]);
        if (cls) {
            names[i-shift] = getName(classlist[i]);
        } else {
            shift++;  // ignored weak-linked class
        }
    }
    count -= shift;
    names[count] = NULL;

    rwlock_unlock_read(&runtimeLock);

    if (outCount) *outCount = (unsigned int)count;
    return names;
}


/***********************************************************************
* _class_getCache
* fixme
* Locking: none
**********************************************************************/
__private_extern__ Cache 
_class_getCache(Class cls)
{
    return newcls(cls)->cache;
}


/***********************************************************************
* _class_getInstanceSize
* fixme
* Locking: none
**********************************************************************/
__private_extern__ size_t 
_class_getInstanceSize(Class cls)
{
    if (!cls) return 0;
    return instanceSize(newcls(cls));
}

static uint32_t
instanceSize(struct class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    // fixme rdar://5244378
    return (uint32_t)((cls->data->ro->instanceSize + WORD_MASK) & ~WORD_MASK);
}


/***********************************************************************
* class_getVersion
* fixme
* Locking: none
**********************************************************************/
int 
class_getVersion(Class cls)
{
    if (!cls) return 0;
    assert(isRealized(newcls(cls)));
    return newcls(cls)->data->version;
}


/***********************************************************************
* _class_setCache
* fixme
* Locking: none
**********************************************************************/
__private_extern__ void 
_class_setCache(Class cls, Cache cache)
{
    newcls(cls)->cache = cache;
}


/***********************************************************************
* class_setVersion
* fixme
* Locking: none
**********************************************************************/
void 
class_setVersion(Class cls, int version)
{
    if (!cls) return;
    assert(isRealized(newcls(cls)));
    newcls(cls)->data->version = version;
}


/***********************************************************************
* _class_getName
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ const char *_class_getName(Class cls)
{
    if (!cls) return "nil";
    // fixme hack rwlock_write(&runtimeLock);
    const char *name = getName(newcls(cls));
    // rwlock_unlock_write(&runtimeLock);
    return name;
}


/***********************************************************************
* getName
* fixme
* Locking: runtimeLock must be held by the caller
**********************************************************************/
static const char *
getName(struct class_t *cls)
{
    // fixme hack rwlock_assert_writing(&runtimeLock);
    assert(cls);

    if (isRealized(cls)) {
        return cls->data->ro->name;
    } else {
        return ((const struct class_ro_t *)cls->data)->name;
    }
}


/***********************************************************************
* getMethodNoSuper_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static method_t *
getMethodNoSuper_nolock(struct class_t *cls, SEL sel)
{
    rwlock_assert_locked(&runtimeLock);

    uint32_t i;

    assert(isRealized(cls));
    // fixme nil cls? 
    // fixme NULL sel?

    FOREACH_METHOD_LIST(mlist, cls, {
        for (i = 0; i < mlist->count; i++) {
            method_t *m = method_list_nth(mlist, i);
            if (m->name == sel) return m;
        }
    });

    return NULL;
}


/***********************************************************************
* _class_getMethodNoSuper
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ Method 
_class_getMethodNoSuper(Class cls, SEL sel)
{
    rwlock_read(&runtimeLock);
    Method result = (Method)getMethodNoSuper_nolock(newcls(cls), sel);
    rwlock_unlock_read(&runtimeLock);
    return result;
}

/***********************************************************************
* _class_getMethodNoSuper
* For use inside lockForMethodLookup() only.
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ Method 
_class_getMethodNoSuper_nolock(Class cls, SEL sel)
{
    return (Method)getMethodNoSuper_nolock(newcls(cls), sel);
}


/***********************************************************************
* getMethod_nolock
* fixme
* Locking: runtimeLock must be read- or write-locked by the caller
**********************************************************************/
static method_t *
getMethod_nolock(class_t *cls, SEL sel)
{
    method_t *m = NULL;

    rwlock_assert_locked(&runtimeLock);

    // fixme nil cls?
    // fixme NULL sel?

    assert(isRealized(cls));

    while (cls  &&  ((m = getMethodNoSuper_nolock(cls, sel))) == NULL) {
        cls = getSuperclass(cls);
    }

    return m;
}


/***********************************************************************
* _class_getMethod
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ Method _class_getMethod(Class cls, SEL sel)
{
    Method m;
    rwlock_read(&runtimeLock);
    m = (Method)getMethod_nolock(newcls(cls), sel);
    rwlock_unlock_read(&runtimeLock);
    return m;
}


/***********************************************************************
* ABI-specific lookUpMethod helpers.
* Locking: read- and write-locks runtimeLock.
**********************************************************************/
__private_extern__ void lockForMethodLookup(void)
{
    rwlock_read(&runtimeLock);
}
__private_extern__ void unlockForMethodLookup(void)
{
    rwlock_unlock_read(&runtimeLock);
}

__private_extern__ IMP prepareForMethodLookup(Class cls, SEL sel, BOOL init)
{
    rwlock_assert_unlocked(&runtimeLock);

    if (!isRealized(newcls(cls))) {
        rwlock_write(&runtimeLock);
        realizeClass(newcls(cls));
        rwlock_unlock_write(&runtimeLock);
    }

    if (init  &&  !_class_isInitialized(cls)) {
        _class_initialize (cls);
        // If sel == initialize, _class_initialize will send +initialize and 
        // then the messenger will send +initialize again after this 
        // procedure finishes. Of course, if this is not being called 
        // from the messenger then it won't happen. 2778172
    }

    return NULL;
}


/***********************************************************************
* class_getProperty
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
Property class_getProperty(Class cls_gen, const char *name)
{
    Property result = NULL;
    chained_property_list *plist;
    struct class_t *cls = newcls(cls_gen);

    if (!cls  ||  !name) return NULL;

    rwlock_read(&runtimeLock);

    assert(isRealized(cls));

    for ( ; cls; cls = getSuperclass(cls)) {
        for (plist = cls->data->properties; plist; plist = plist->next) {
            uint32_t i;
            for (i = 0; i < plist->count; i++) {
                if (0 == strcmp(name, plist->list[i].name)) {
                    result = &plist->list[i];
                    goto done;
                }
            }
        }
    }

 done:
    rwlock_unlock_read(&runtimeLock);

    return result;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL _class_isMetaClass(Class cls)
{
    if (!cls) return NO;
    return isMetaClass(newcls(cls));
}

static BOOL 
isMetaClass(struct class_t *cls)
{
    assert(cls);
    assert(isRealized(cls));
    return (cls->data->ro->flags & RO_META) ? YES : NO;
}


__private_extern__ Class _class_getMeta(Class cls)
{
    assert(cls);
    if (isMetaClass(newcls(cls))) return cls;
    else return ((id)cls)->isa;
}

Class gdb_class_getClass(Class cls)
{
    const char *className = strdup(getName(newcls(cls)));
    if(!className) return Nil;
    Class rCls = look_up_class(className, NO, NO);
    free((char*)className);
    return rCls;
}

BOOL gdb_objc_isRuntimeLocked()
{
    if (rwlock_try_write(&runtimeLock)) {
        rwlock_unlock_write(&runtimeLock);
    } else
        return YES;
    
    if (mutex_try_lock(&cacheUpdateLock)) {
        mutex_unlock(&cacheUpdateLock);
    } else 
        return YES;
    
    return NO;
}

/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_isInitializing(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data->flags & RW_INITIALIZING) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_isInitialized(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    return (cls->data->flags & RW_INITIALIZED) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void 
_class_setInitializing(Class cls_gen)
{
    struct class_t *cls = newcls(_class_getMeta(cls_gen));
    changeInfo(cls, RW_INITIALIZING, 0);
}


/***********************************************************************
* Locking: write-locks runtimeLock
**********************************************************************/
__private_extern__ void 
_class_setInitialized(Class cls_gen)
{

    struct class_t *metacls;
    struct class_t *cls;

    rwlock_write(&runtimeLock);
    metacls = newcls(_class_getMeta(cls_gen));
    cls = getNonMetaClass(metacls);

    // Update vtables (initially postponed pending +initialize completion)
    // Do cls first because root metacls is a subclass of root cls
    updateVtable(cls, YES);
    updateVtable(metacls, YES);

    rwlock_unlock_write(&runtimeLock);

    changeInfo(metacls, RW_INITIALIZED, RW_INITIALIZING);
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_shouldGrowCache(Class cls)
{
    return YES; // fixme good or bad for memory use?
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void 
_class_setGrowCache(Class cls, BOOL grow)
{
    // fixme good or bad for memory use?
}


/***********************************************************************
* _class_isLoadable
* fixme
* Locking: none
**********************************************************************/
__private_extern__ BOOL 
_class_isLoadable(Class cls)
{
    assert(isRealized(newcls(cls)));
    return YES;  // any class registered for +load is definitely loadable
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL 
_class_hasCxxStructorsNoSuper(Class cls)
{
    assert(isRealized(newcls(cls)));
    return (newcls(cls)->data->ro->flags & RO_HAS_CXX_STRUCTORS) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ BOOL
_class_shouldFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    return (newcls(cls)->data->flags & RW_FINALIZE_ON_MAIN_THREAD) ? YES : NO;
}


/***********************************************************************
* Locking: fixme
**********************************************************************/
__private_extern__ void
_class_setFinalizeOnMainThread(Class cls)
{
    assert(isRealized(newcls(cls)));
    changeInfo(newcls(cls), RW_FINALIZE_ON_MAIN_THREAD, 0);
}


/***********************************************************************
* _class_instancesHaveAssociatedObjects
* May manipulate unrealized future classes in the CF-bridged case.
**********************************************************************/
__private_extern__ BOOL
_class_instancesHaveAssociatedObjects(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    assert(isFuture(cls)  ||  isRealized(cls));
    return (cls->data->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS) ? YES : NO;
}


/***********************************************************************
* _class_assertInstancesHaveAssociatedObjects
* May manipulate unrealized future classes in the CF-bridged case.
**********************************************************************/
__private_extern__ void
_class_assertInstancesHaveAssociatedObjects(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    assert(isFuture(cls)  ||  isRealized(cls));
    changeInfo(cls, RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS, 0);
}


/***********************************************************************
* Locking: none
* fixme assert realized to get superclass remapping?
**********************************************************************/
__private_extern__ Class 
_class_getSuperclass(Class cls)
{
    return (Class)getSuperclass(newcls(cls));
}

static struct class_t *
getSuperclass(struct class_t *cls)
{
    if (!cls) return NULL;
    return cls->superclass;
}


/***********************************************************************
* class_getIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const char *
class_getIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return (const char *)cls->data->ro->ivarLayout;
    else return NULL;
}


/***********************************************************************
* class_getWeakIvarLayout
* Called by the garbage collector. 
* The class must be NULL or already realized. 
* Locking: none
**********************************************************************/
const char *
class_getWeakIvarLayout(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    if (cls) return (const char *)cls->data->ro->weakIvarLayout;
    else return NULL;
}


/***********************************************************************
* class_setIvarLayout
* Changes the class's GC scan layout.
* NULL layout means no unscanned ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setIvarLayout(Class cls_gen, const char *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    rwlock_write(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set ivar layout for already-registered "
                     "class '%s'", getName(cls));
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    try_free(ro_w->ivarLayout);
    ro_w->ivarLayout = (unsigned char *)_strdup_internal(layout);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* class_setWeakIvarLayout
* Changes the class's GC weak layout.
* NULL layout means no weak ivars
* The class must be under construction.
* fixme: sanity-check layout vs instance size?
* fixme: sanity-check layout vs superclass?
* Locking: acquires runtimeLock
**********************************************************************/
void
class_setWeakIvarLayout(Class cls_gen, const char *layout)
{
    class_t *cls = newcls(cls_gen);
    if (!cls) return;

    rwlock_write(&runtimeLock);
    
    // Can only change layout of in-construction classes.
    // note: if modifications to post-construction classes were 
    //   allowed, there would be a race below (us vs. concurrent GC scan)
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        _objc_inform("*** Can't set weak ivar layout for already-registered "
                     "class '%s'", getName(cls));
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    try_free(ro_w->weakIvarLayout);
    ro_w->weakIvarLayout = (unsigned char *)_strdup_internal(layout);

    rwlock_unlock_write(&runtimeLock);
}


/***********************************************************************
* _class_getVariable
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
__private_extern__ Ivar 
_class_getVariable(Class cls, const char *name)
{
    rwlock_read(&runtimeLock);

    for ( ; cls != Nil; cls = class_getSuperclass(cls)) {
        struct ivar_t *ivar = getIvar(newcls(cls), name);
        if (ivar) {
            rwlock_unlock_read(&runtimeLock);
            return (Ivar)ivar;
        }
    }

    rwlock_unlock_read(&runtimeLock);

    return NULL;
}


/***********************************************************************
* class_conformsToProtocol
* fixme
* Locking: read-locks runtimeLock
**********************************************************************/
BOOL class_conformsToProtocol(Class cls_gen, Protocol *proto)
{
    Protocol **protocols;
    unsigned int count, i;
    BOOL result = NO;
    
    if (!cls_gen) return NO;
    if (!proto) return NO;

    // fixme null cls?

    protocols = class_copyProtocolList(cls_gen, &count);

    for (i = 0; i < count; i++) {
        if (protocols[i] == proto  ||  
            protocol_conformsToProtocol(protocols[i], proto)) 
        {
            result = YES;
            break;
        }
    }

    if (protocols) free(protocols);

    return result;
}


/***********************************************************************
* class_addMethod
* fixme
* Locking: write-locks runtimeLock
**********************************************************************/
static IMP 
_class_addMethod(Class cls_gen, SEL name, IMP imp, 
                 const char *types, BOOL replace)
{
    struct class_t *cls = newcls(cls_gen);
    IMP result = NULL;

    if (!types) types = "";

    rwlock_write(&runtimeLock);

    assert(isRealized(cls));

    method_t *m;
    if ((m = getMethodNoSuper_nolock(cls, name))) {
        // already exists
        if (!replace) {
            result = _method_getImplementation(m);
        } else {
            result = _method_setImplementation(cls, m, imp);
        }
    } else {
        // fixme optimize
        method_list_t *newlist;
        newlist = _calloc_internal(sizeof(*newlist), 1);
        newlist->entsize_NEVER_USE = (uint32_t)sizeof(method_t) | fixed_up_method_list;
        newlist->count = 1;
        newlist->first.name = name;
        newlist->first.types = strdup(types);
        if (name != (SEL)kIgnore) {
            newlist->first.imp = imp;
        } else {
            newlist->first.imp = (IMP)&_objc_ignored_method;
        }

        BOOL vtablesAffected;
        attachMethodLists(cls, &newlist, 1, NO, &vtablesAffected);
        flushCaches(cls);
        if (vtablesAffected) flushVtables(cls);

        result = NULL;
    }

    rwlock_unlock_write(&runtimeLock);

    return result;
}


BOOL 
class_addMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NO;

    IMP old = _class_addMethod(cls, name, imp, types, NO);
    return old ? NO : YES;
}


IMP 
class_replaceMethod(Class cls, SEL name, IMP imp, const char *types)
{
    if (!cls) return NULL;

    return _class_addMethod(cls, name, imp, types, YES);
}


/***********************************************************************
* class_addIvar
* Adds an ivar to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL 
class_addIvar(Class cls_gen, const char *name, size_t size, 
              uint8_t alignment, const char *type)
{
    struct class_t *cls = newcls(cls_gen);

    if (!cls) return NO;

    if (!type) type = "";
    if (name  &&  0 == strcmp(name, "")) name = NULL;

    rwlock_write(&runtimeLock);

    assert(isRealized(cls));

    // No class variables
    if (isMetaClass(cls)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    // Can only add ivars to in-construction classes.
    if (!(cls->data->flags & RW_CONSTRUCTING)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    // Check for existing ivar with this name, unless it's anonymous.
    // Check for too-big ivar.
    // fixme check for superclass ivar too?
    if ((name  &&  getIvar(cls, name))  ||  size > UINT32_MAX) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }

    class_ro_t *ro_w = make_ro_writeable(cls->data);

    // fixme allocate less memory here
    
    ivar_list_t *oldlist, *newlist;
    if ((oldlist = (ivar_list_t *)cls->data->ro->ivars)) {
        size_t oldsize = ivar_list_size(oldlist);
        newlist = _calloc_internal(oldsize + oldlist->entsize, 1);
        memcpy(newlist, oldlist, oldsize);
        _free_internal(oldlist);
    } else {
        newlist = _calloc_internal(sizeof(ivar_list_t), 1);
        newlist->entsize = (uint32_t)sizeof(ivar_t);
    }

    uint32_t offset = instanceSize(cls);
    uint32_t alignMask = (1<<alignment)-1;
    offset = (offset + alignMask) & ~alignMask;

    ivar_t *ivar = ivar_list_nth(newlist, newlist->count++);
    ivar->offset = _malloc_internal(sizeof(*ivar->offset));
    *ivar->offset = offset;
    ivar->name = name ? _strdup_internal(name) : NULL;
    ivar->type = _strdup_internal(type);
    ivar->alignment = alignment;
    ivar->size = (uint32_t)size;

    ro_w->ivars = newlist;
    ro_w->instanceSize = (uint32_t)(offset + size);

    // Ivar layout updated in registerClass.

    rwlock_unlock_write(&runtimeLock);

    return YES;
}


/***********************************************************************
* class_addProtocol
* Adds a protocol to a class.
* Locking: acquires runtimeLock
**********************************************************************/
BOOL class_addProtocol(Class cls_gen, Protocol *protocol_gen)
{
    class_t *cls = newcls(cls_gen);
    protocol_t *protocol = newprotocol(protocol_gen);
    protocol_list_t *plist;
    protocol_list_t **plistp;

    if (!cls) return NO;
    if (class_conformsToProtocol(cls_gen, protocol_gen)) return NO;

    rwlock_write(&runtimeLock);

    assert(isRealized(cls));
    
    // fixme optimize
    plist = _malloc_internal(sizeof(protocol_list_t) + sizeof(protocol_t *));
    plist->count = 1;
    plist->list[0] = (protocol_ref_t)protocol;
    
    unsigned int count = 0;
    for (plistp = cls->data->protocols; plistp && *plistp; plistp++) {
        count++;
    }

    cls->data->protocols = 
        _realloc_internal(cls->data->protocols, 
                          (count+2) * sizeof(protocol_list_t *));
    cls->data->protocols[count] = plist;
    cls->data->protocols[count+1] = NULL;

    // fixme metaclass?

    rwlock_unlock_write(&runtimeLock);

    return YES;
}


/***********************************************************************
* look_up_class
* Look up a class by name, and realize it.
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ id 
look_up_class(const char *name, 
              BOOL includeUnconnected __attribute__((unused)), 
              BOOL includeClassHandler __attribute__((unused)))
{
    if (!name) return nil;

    rwlock_read(&runtimeLock);
    class_t *result = getClass(name);
    BOOL unrealized = result  &&  !isRealized(result);
    rwlock_unlock_read(&runtimeLock);
    if (unrealized) {
        rwlock_write(&runtimeLock);
        realizeClass(result);
        rwlock_unlock_write(&runtimeLock);
    }
    return (id)result;
}


/***********************************************************************
* objc_duplicateClass
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class 
objc_duplicateClass(Class original_gen, const char *name, 
                    size_t extraBytes)
{
    struct class_t *original = newcls(original_gen);
    struct class_t *duplicate;

    rwlock_write(&runtimeLock);

    assert(isRealized(original));
    assert(!isMetaClass(original));

    duplicate = (struct class_t *)
        _calloc_class(instanceSize(original->isa) + extraBytes);
    if (instanceSize(original->isa) < sizeof(class_t)) {
        _objc_inform("busted! %s\n", original->data->ro->name);
    }


    duplicate->isa = original->isa;
    duplicate->superclass = original->superclass;
    duplicate->cache = (Cache)&_objc_empty_cache;
    duplicate->vtable = _objc_empty_vtable;

    duplicate->data = _calloc_internal(sizeof(*original->data), 1);
    duplicate->data->flags = (original->data->flags | RW_COPIED_RO) & ~RW_SPECIALIZED_VTABLE;
    duplicate->data->version = original->data->version;
    duplicate->data->firstSubclass = NULL;
    duplicate->data->nextSiblingClass = NULL;

    duplicate->data->ro = 
        _memdup_internal(original->data->ro, sizeof(*original->data->ro));
    *(char **)&duplicate->data->ro->name = _strdup_internal(name);
    
    if (original->data->methods) {
        duplicate->data->methods = 
            _memdup_internal(original->data->methods, 
                             malloc_size(original->data->methods));
        method_list_t **mlistp = duplicate->data->methods;
        for (mlistp = duplicate->data->methods; *mlistp; mlistp++) {
            *mlistp = _memdup_internal(*mlistp, method_list_size(*mlistp));
        }
    }

    // fixme dies when categories are added to the base
    duplicate->data->properties = original->data->properties;
    duplicate->data->protocols = original->data->protocols;

    if (duplicate->superclass) {
        addSubclass(duplicate->superclass, duplicate);
    }

    // Don't methodize class - construction above is correct

    addNamedClass(duplicate, duplicate->data->ro->name);
    addRealizedClass(duplicate);
    // no: duplicate->isa == original->isa
    // addRealizedMetaclass(duplicate->isa);

    if (PrintConnecting) {
        _objc_inform("CLASS: realizing class '%s' (duplicate of %s) %p %p", 
                     name, original->data->ro->name, 
                     duplicate, duplicate->data->ro);
    }

    rwlock_unlock_write(&runtimeLock);

    return (Class)duplicate;
}

/***********************************************************************
* objc_initializeClassPair
* Locking: runtimeLock must be write-locked by the caller
**********************************************************************/
static void objc_initializeClassPair_internal(Class superclass_gen, const char *name, Class cls_gen, Class meta_gen)
{
    rwlock_assert_writing(&runtimeLock);

    class_t *superclass = newcls(superclass_gen);
    class_t *cls = newcls(cls_gen);
    class_t *meta = newcls(meta_gen);
    class_ro_t *cls_ro_w, *meta_ro_w;
    
    cls->data = _calloc_internal(sizeof(class_rw_t), 1);
    meta->data = _calloc_internal(sizeof(class_rw_t), 1);
    cls_ro_w = _calloc_internal(sizeof(class_ro_t), 1);
    meta_ro_w = _calloc_internal(sizeof(class_ro_t), 1);
    cls->data->ro = cls_ro_w;
    meta->data->ro = meta_ro_w;

    // Set basic info
    cls->cache = (Cache)&_objc_empty_cache;
    meta->cache = (Cache)&_objc_empty_cache;
    cls->vtable = _objc_empty_vtable;
    meta->vtable = _objc_empty_vtable;

    cls->data->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    meta->data->flags = RW_CONSTRUCTING | RW_COPIED_RO | RW_REALIZED;
    cls->data->version = 0;
    meta->data->version = 7;

    cls_ro_w->flags = 0;
    meta_ro_w->flags = RO_META;
    if (!superclass) {
        cls_ro_w->flags |= RO_ROOT;
        meta_ro_w->flags |= RO_ROOT;
    }
    if (superclass) {
        cls_ro_w->instanceStart = instanceSize(superclass);
        meta_ro_w->instanceStart = instanceSize(superclass->isa);
        cls_ro_w->instanceSize = cls_ro_w->instanceStart;
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    } else {
        cls_ro_w->instanceStart = 0;
        meta_ro_w->instanceStart = (uint32_t)sizeof(class_t);
        cls_ro_w->instanceSize = (uint32_t)sizeof(id);  // just an isa
        meta_ro_w->instanceSize = meta_ro_w->instanceStart;
    }

    cls_ro_w->name = _strdup_internal(name);
    meta_ro_w->name = _strdup_internal(name);

    // Connect to superclasses and metaclasses
    cls->isa = meta;
    if (superclass) {
        meta->isa = superclass->isa->isa;
        cls->superclass = superclass;
        meta->superclass = superclass->isa;
        addSubclass(superclass, cls);
        addSubclass(superclass->isa, meta);
    } else {
        meta->isa = meta;
        cls->superclass = Nil;
        meta->superclass = cls;
        addSubclass(cls, meta);
    }
}

/***********************************************************************
* objc_initializeClassPair
**********************************************************************/
Class objc_initializeClassPair(Class superclass_gen, const char *name, Class cls_gen, Class meta_gen)
{
    class_t *superclass = newcls(superclass_gen);

    rwlock_write(&runtimeLock);
    
    //
    // Common superclass integrity checks with objc_allocateClassPair
    //
    if (getClass(name)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }
    // fixme reserve class against simmultaneous allocation

    if (superclass) assert(isRealized(superclass));

    if (superclass  &&  superclass->data->flags & RW_CONSTRUCTING) {
        // Can't make subclass of an in-construction class
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }


    // just initialize what was supplied
    objc_initializeClassPair_internal(superclass_gen, name, cls_gen, meta_gen);

    rwlock_unlock_write(&runtimeLock);
    return cls_gen;
}

/***********************************************************************
* objc_allocateClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
Class objc_allocateClassPair(Class superclass_gen, const char *name, 
                             size_t extraBytes)
{
    class_t *superclass = newcls(superclass_gen);
    Class cls, meta;

    rwlock_write(&runtimeLock);

    //
    // Common superclass integrity checks with objc_initializeClassPair
    //
    if (getClass(name)) {
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }
    // fixme reserve class against simmultaneous allocation

    if (superclass) assert(isRealized(superclass));

    if (superclass  &&  superclass->data->flags & RW_CONSTRUCTING) {
        // Can't make subclass of an in-construction class
        rwlock_unlock_write(&runtimeLock);
        return NO;
    }



    // Allocate new classes.
    if (superclass) {
        cls = _calloc_class(instanceSize(superclass->isa) + extraBytes);
        meta = _calloc_class(instanceSize(superclass->isa->isa) + extraBytes);
    } else {
        cls = _calloc_class(sizeof(class_t) + extraBytes);
        meta = _calloc_class(sizeof(class_t) + extraBytes);
    }
    

    objc_initializeClassPair_internal(superclass_gen, name, cls, meta);

    rwlock_unlock_write(&runtimeLock);

    return (Class)cls;
}


/***********************************************************************
* objc_registerClassPair
* fixme
* Locking: acquires runtimeLock
**********************************************************************/
void objc_registerClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);
    
    rwlock_write(&runtimeLock);

    if ((cls->data->flags & RW_CONSTRUCTED)  ||  
        (cls->isa->data->flags & RW_CONSTRUCTED)) 
    {
        _objc_inform("objc_registerClassPair: class '%s' was already "
                     "registered!", cls->data->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (!(cls->data->flags & RW_CONSTRUCTING)  ||  
        !(cls->isa->data->flags & RW_CONSTRUCTING))
    {
        _objc_inform("objc_registerClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    // Build ivar layouts
    if (UseGC) {
        struct class_t *supercls = getSuperclass(cls);
        class_ro_t *ro_w = (class_ro_t *)cls->data->ro;

        if (ro_w->ivarLayout) {
            // Class builder already called class_setIvarLayout.
        }
        else if (!supercls) {
            // Root class. Scan conservatively (should be isa ivar only).
            // ivar_layout is already NULL.
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layouts.
            ro_w->ivarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->ivarLayout);
        }
        else {
            // Has local ivars. Build layouts based on superclass.
            layout_bitmap bitmap = 
                layout_bitmap_create(supercls->data->ro->ivarLayout, 
                                     instanceSize(supercls), 
                                     instanceSize(cls), NO);
            uint32_t i;
            for (i = 0; i < ro_w->ivars->count; i++) {
                ivar_t *ivar = ivar_list_nth(ro_w->ivars, i);
                if (!ivar->offset) continue;  // anonymous bitfield

                layout_bitmap_set_ivar(bitmap, ivar->type, *ivar->offset);
            }
            ro_w->ivarLayout = layout_string_create(bitmap);
            layout_bitmap_free(bitmap);
        }

        if (ro_w->weakIvarLayout) {
            // Class builder already called class_setWeakIvarLayout.
        }
        else if (!supercls) {
            // Root class. No weak ivars (should be isa ivar only).
            // weak_ivar_layout is already NULL.
        }
        else if (ro_w->ivars == NULL) {
            // No local ivars. Use superclass's layout.
            ro_w->weakIvarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->weakIvarLayout);
        }
        else {
            // Has local ivars. Build layout based on superclass.
            // No way to add weak ivars yet.
            ro_w->weakIvarLayout = (unsigned char *)
                _strdup_internal((char *)supercls->data->ro->weakIvarLayout);
        }
    }

    // Clear "under construction" bit, set "done constructing" bit
    cls->data->flags &= ~RW_CONSTRUCTING;
    cls->isa->data->flags &= ~RW_CONSTRUCTING;
    cls->data->flags |= RW_CONSTRUCTED;
    cls->isa->data->flags |= RW_CONSTRUCTED;

    // Add to realized and uninitialized classes
    addNamedClass(cls, cls->data->ro->name);
    addRealizedClass(cls);
    addRealizedMetaclass(cls->isa);
    addUninitializedClass(cls, cls->isa);

    rwlock_unlock_write(&runtimeLock);
}


static void unload_class(class_t *cls, BOOL isMeta)
{
    // Detach class from various lists

    // categories not yet attached to this class
    category_list *cats;
    cats = unattachedCategoriesForClass(cls);
    if (cats) free(cats);

    // class tables and +load queue
    if (!isMeta) {
        removeNamedClass(cls, getName(cls));
        removeRealizedClass(cls);
        removeUninitializedClass(cls);
    } else {
        removeRealizedMetaclass(cls);
    }

    // superclass's subclass list
    if (isRealized(cls)) {
        class_t *supercls = getSuperclass(cls);
        if (supercls) removeSubclass(supercls, cls);
    }


    // Dispose the class's own data structures

    if (isRealized(cls)) {
        uint32_t i;

        // Dereferences the cache contents; do this before freeing methods
        if (cls->cache != (Cache)&_objc_empty_cache) _cache_free(cls->cache);
        
        if (cls->data->methods) {
            method_list_t **mlistp;
            for (mlistp = cls->data->methods; *mlistp; mlistp++) {
                for (i = 0; i < (**mlistp).count; i++) {
                    method_t *m = method_list_nth(*mlistp, i);
                    try_free(m->types);
                }
                try_free(*mlistp);
            }
            try_free(cls->data->methods);
        }
        
        const ivar_list_t *ilist = cls->data->ro->ivars;
        if (ilist) {
            for (i = 0; i < ilist->count; i++) {
                const ivar_t *ivar = ivar_list_nth(ilist, i);
                try_free(ivar->offset);
                try_free(ivar->name);
                try_free(ivar->type);
            }
            try_free(ilist);
        }

        protocol_list_t **plistp = cls->data->protocols;
        for (plistp = cls->data->protocols; plistp && *plistp; plistp++) {
            try_free(*plistp);
        }
        try_free(cls->data->protocols);
        
        // fixme:
        // properties
        
        if (cls->vtable != _objc_empty_vtable  &&  
            cls->data->flags & RW_SPECIALIZED_VTABLE) try_free(cls->vtable);
        try_free(cls->data->ro->ivarLayout);
        try_free(cls->data->ro->weakIvarLayout);
        try_free(cls->data->ro->name);
        try_free(cls->data->ro);
        try_free(cls->data);
        try_free(cls);
    }
}

void objc_disposeClassPair(Class cls_gen)
{
    class_t *cls = newcls(cls_gen);

    rwlock_write(&runtimeLock);

    if (!(cls->data->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))  ||  
        !(cls->isa->data->flags & (RW_CONSTRUCTED|RW_CONSTRUCTING))) 
    {
        // class not allocated with objc_allocateClassPair
        // disposing still-unregistered class is OK!
        _objc_inform("objc_disposeClassPair: class '%s' was not "
                     "allocated with objc_allocateClassPair!", 
                     cls->data->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    if (isMetaClass(cls)) {
        _objc_inform("objc_disposeClassPair: class '%s' is a metaclass, "
                     "not a class!", cls->data->ro->name);
        rwlock_unlock_write(&runtimeLock);
        return;
    }

    // Shouldn't have any live subclasses.
    if (cls->data->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data->ro->name, 
                     getName(cls->data->firstSubclass));
    }
    if (cls->isa->data->firstSubclass) {
        _objc_inform("objc_disposeClassPair: class '%s' still has subclasses, "
                     "including '%s'!", cls->data->ro->name, 
                     getName(cls->isa->data->firstSubclass));
    }

    // don't remove_class_from_loadable_list() 
    // - it's not there and we don't have the lock
    unload_class(cls->isa, YES);
    unload_class(cls, NO);

    rwlock_unlock_write(&runtimeLock);
}



/***********************************************************************
* class_createInstanceFromZone
* fixme
* Locking: none
**********************************************************************/
id
class_createInstanceFromZone(Class cls, size_t extraBytes, void *zone)
{
    if (cls) assert(isRealized(newcls(cls)));
    return _internal_class_createInstanceFromZone(cls, extraBytes, zone);
}


/***********************************************************************
* class_createInstance
* fixme
* Locking: none
**********************************************************************/
id 
class_createInstance(Class cls, size_t extraBytes)
{
    return class_createInstanceFromZone(cls, extraBytes, NULL);
}


/***********************************************************************
* object_copyFromZone
* fixme
* Locking: none
**********************************************************************/
id 
object_copyFromZone(id oldObj, size_t extraBytes, void *zone)
{
    id obj;
    size_t size;

    if (!oldObj) return nil;

    size = _class_getInstanceSize(oldObj->isa) + extraBytes;
#if !defined(NO_GC)
    if (UseGC) {
        obj = (id) auto_zone_allocate_object(gc_zone, size, 
                                             AUTO_OBJECT_SCANNED, 0, 1);
    } else
#endif
    if (zone) {
        obj = malloc_zone_calloc(zone, size, 1);
    } else {
        obj = (id) calloc(1, size);
    }
    if (!obj) return nil;

    // fixme this doesn't handle C++ ivars correctly (#4619414)
    objc_memmove_collectable(obj, oldObj, size);

#if !defined(NO_GC)
    if (UseGC) gc_fixup_weakreferences(obj, oldObj);
#endif

    return obj;
}


/***********************************************************************
* object_copy
* fixme
* Locking: none
**********************************************************************/
id 
object_copy(id oldObj, size_t extraBytes)
{
    return object_copyFromZone(oldObj, extraBytes, malloc_default_zone());
}


/***********************************************************************
* object_dispose
* fixme
* Locking: none
**********************************************************************/
id 
object_dispose(id obj)
{
    return _internal_object_dispose(obj);
}


/***********************************************************************
* _objc_getFreedObjectClass
* fixme
* Locking: none
**********************************************************************/
Class _objc_getFreedObjectClass (void)
{
    return nil;
}

#ifndef NO_FIXUP

extern id objc_msgSend_fixup(id, SEL, ...);
extern id objc_msgSend_fixedup(id, SEL, ...);
extern id objc_msgSendSuper2_fixup(id, SEL, ...);
extern id objc_msgSendSuper2_fixedup(id, SEL, ...);
extern id objc_msgSend_stret_fixup(id, SEL, ...);
extern id objc_msgSend_stret_fixedup(id, SEL, ...);
extern id objc_msgSendSuper2_stret_fixup(id, SEL, ...);
extern id objc_msgSendSuper2_stret_fixedup(id, SEL, ...);
#if defined(__i386__)  ||  defined(__x86_64__)
extern id objc_msgSend_fpret_fixup(id, SEL, ...);
extern id objc_msgSend_fpret_fixedup(id, SEL, ...);
#endif
#if defined(__x86_64__)
extern id objc_msgSend_fp2ret_fixup(id, SEL, ...);
extern id objc_msgSend_fp2ret_fixedup(id, SEL, ...);
#endif

/***********************************************************************
* _objc_fixupMessageRef
* Fixes up message ref *msg. 
* obj is the receiver. supr is NULL for non-super messages
* Locking: acquires runtimeLock
**********************************************************************/
__private_extern__ IMP 
_objc_fixupMessageRef(id obj, struct objc_super2 *supr, message_ref *msg)
{
    IMP imp;
    class_t *isa;

    rwlock_assert_unlocked(&runtimeLock);

    if (!supr) {
        // normal message - search obj->isa for the method implementation
        isa = (class_t *)obj->isa;
        
        if (!isRealized(isa)) {
            // obj is a class object, isa is its metaclass
            class_t *cls;
            rwlock_write(&runtimeLock);
            cls = realizeClass((class_t *)obj);
            rwlock_unlock_write(&runtimeLock);
                
            // shouldn't have instances of unrealized classes!
            assert(isMetaClass(isa));
            // shouldn't be relocating classes here!
            assert(cls == (class_t *)obj);
        }
    }
    else {
        // this is objc_msgSend_super, and supr->current_class->superclass
        // is the class to search for the method implementation
        assert(isRealized((class_t *)supr->current_class));
        isa = getSuperclass((class_t *)supr->current_class);
    }

    msg->sel = sel_registerName((const char *)msg->sel);
    
#ifndef NO_VTABLE
    int vtableIndex;
    if (msg->imp == (IMP)&objc_msgSend_fixup  &&  
        (vtableIndex = vtable_getIndex(msg->sel)) >= 0) 
    {
        // vtable dispatch
        msg->imp = vtableTrampolines[vtableIndex];
        imp = isa->vtable[vtableIndex];
    }
    else 
#endif
    {
        // ordinary dispatch
        imp = lookUpMethod((Class)isa, msg->sel, YES/*initialize*/, YES/*cache*/);
        
        if (msg->imp == (IMP)&objc_msgSend_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSendSuper2_fixup) { 
            msg->imp = (IMP)&objc_msgSendSuper2_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSend_stret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_stret_fixedup;
        } 
        else if (msg->imp == (IMP)&objc_msgSendSuper2_stret_fixup) { 
            msg->imp = (IMP)&objc_msgSendSuper2_stret_fixedup;
        } 
#if defined(__i386__)  ||  defined(__x86_64__)
        else if (msg->imp == (IMP)&objc_msgSend_fpret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fpret_fixedup;
        } 
#endif
#if defined(__x86_64__)
        else if (msg->imp == (IMP)&objc_msgSend_fp2ret_fixup) { 
            msg->imp = (IMP)&objc_msgSend_fp2ret_fixedup;
        } 
#endif
        else {
            // The ref may already have been fixed up, either by another thread
            // or by +initialize via lookUpMethod above.
        }
    }

    return imp;
}

// ! NO_FIXUP
#endif


#warning fixme delete after #4586306
Class class_poseAs(Class imposter, Class original)
{
    _objc_fatal("Don't call class_poseAs.");
}


// ProKit SPI
static class_t *setSuperclass(class_t *cls, class_t *newSuper)
{
    class_t *oldSuper;

    rwlock_assert_writing(&runtimeLock);

    oldSuper = cls->superclass;
    removeSubclass(oldSuper, cls);
    removeSubclass(oldSuper->isa, cls->isa);

    cls->superclass = newSuper;
    cls->isa->superclass = newSuper->isa;
    addSubclass(newSuper, cls);
    addSubclass(newSuper->isa, cls->isa);

    flushCaches(cls);
    flushCaches(cls->isa);
    flushVtables(cls);
    flushVtables(cls->isa);

    return oldSuper;
}


Class class_setSuperclass(Class cls_gen, Class newSuper_gen)
{
    class_t *cls = newcls(cls_gen);
    class_t *newSuper = newcls(newSuper_gen);
    class_t *oldSuper;

    rwlock_write(&runtimeLock);
    oldSuper = setSuperclass(cls, newSuper);
    rwlock_unlock_write(&runtimeLock);

    return (Class)oldSuper;
}

#endif
