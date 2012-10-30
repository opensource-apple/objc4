/*
 * Copyright (c) 2002-2007 Apple Inc. All rights reserved.
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

// ZEROCOST_SWITCH
#if !__LP64__  ||  !OBJC_ZEROCOST_EXCEPTIONS

/***********************************************************************
* 32-bit implementation
**********************************************************************/

#include <stdlib.h>

#import "objc-exception.h"
#import "objc-private.h"

static objc_exception_functions_t xtab;

// forward declaration
static void set_default_handlers();


/*
 * Exported functions
 */

// get table; version tells how many
void objc_exception_get_functions(objc_exception_functions_t *table) {
    // only version 0 supported at this point
    if (table && table->version == 0)
        *table = xtab;
}

// set table
void objc_exception_set_functions(objc_exception_functions_t *table) {
    // only version 0 supported at this point
    if (table && table->version == 0)
        xtab = *table;
}

/*
 * The following functions are
 * synthesized by the compiler upon encountering language constructs
 */
 
void objc_exception_throw(id exception) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.throw_exc(exception);
    _objc_fatal("objc_exception_throw failed");
}

void objc_exception_try_enter(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.try_enter(localExceptionData);
}


void objc_exception_try_exit(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    xtab.try_exit(localExceptionData);
}


id objc_exception_extract(void *localExceptionData) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    return xtab.extract(localExceptionData);
}


int objc_exception_match(Class exceptionClass, id exception) {
    if (!xtab.throw_exc) {
        set_default_handlers();
    }
    return xtab.match(exceptionClass, exception);
}


// quick and dirty exception handling code
// default implementation - mostly a toy for use outside/before Foundation
// provides its implementation
// Perhaps the default implementation should just complain loudly and quit



#import <pthread.h>
#import <setjmp.h>

extern void _objc_inform(const char *fmt, ...);

typedef struct { jmp_buf buf; void *pointers[4]; } LocalData_t;

typedef struct _threadChain {
    LocalData_t *topHandler;
    void *perThreadID;
    struct _threadChain *next;
}
    ThreadChainLink_t;

static ThreadChainLink_t ThreadChainLink;

static ThreadChainLink_t *getChainLink() {
    // follow links until thread_self() found (someday) XXX
    pthread_t self = pthread_self();
    ThreadChainLink_t *walker = &ThreadChainLink;
    while (walker->perThreadID != (void *)self) {
        if (walker->next != NULL) {
            walker = walker->next;
            continue;
        }
        // create a new one
        // XXX not thread safe (!)
        // XXX Also, we don't register to deallocate on thread death
        walker->next = (ThreadChainLink_t *)malloc(sizeof(ThreadChainLink_t));
        walker = walker->next;
        walker->next = NULL;
        walker->topHandler = NULL;
        walker->perThreadID = self;
    }
    return walker;
}

static void default_try_enter(void *localExceptionData) {
    ThreadChainLink_t *chainLink = getChainLink();
    ((LocalData_t *)localExceptionData)->pointers[1] = chainLink->topHandler;
    chainLink->topHandler = localExceptionData;
    if (PrintExceptions) _objc_inform("EXCEPTIONS: entered try block %p\n", chainLink->topHandler);
}

static void default_throw(id value) {
    ThreadChainLink_t *chainLink = getChainLink();
    if (value == nil) {
        if (PrintExceptions) _objc_inform("EXCEPTIONS: objc_exception_throw with nil value\n");
        return;
    }
    if (chainLink == NULL) {
        if (PrintExceptions) _objc_inform("EXCEPTIONS: No handler in place!\n");
        return;
    }
    if (PrintExceptions) _objc_inform("EXCEPTIONS: exception thrown, going to handler block %p\n", chainLink->topHandler);
    LocalData_t *led = chainLink->topHandler;
    chainLink->topHandler = led->pointers[1];	// pop top handler
    led->pointers[0] = value;			// store exception that is thrown
    _longjmp(led->buf, 1);
}
    
static void default_try_exit(void *led) {
    ThreadChainLink_t *chainLink = getChainLink();
    if (!chainLink || led != chainLink->topHandler) {
        if (PrintExceptions) _objc_inform("EXCEPTIONS: *** mismatched try block exit handlers\n");
        return;
    }
    if (PrintExceptions) _objc_inform("EXCEPTIONS: removing try block handler %p\n", chainLink->topHandler);
    chainLink->topHandler = chainLink->topHandler->pointers[1];	// pop top handler
}

static id default_extract(void *localExceptionData) {
    LocalData_t *led = (LocalData_t *)localExceptionData;
    return (id)led->pointers[0];
}

static int default_match(Class exceptionClass, id exception) {
    //return [exception isKindOfClass:exceptionClass];
    Class cls;
    for (cls = exception->isa; nil != cls; cls = _class_getSuperclass(cls)) 
	if (cls == exceptionClass) return 1;
    return 0;
}

static void set_default_handlers() {
    objc_exception_functions_t default_functions = {
        0, default_throw, default_try_enter, default_try_exit, default_extract, default_match };

    // should this always print?
    if (PrintExceptions) _objc_inform("EXCEPTIONS: *** Setting default (non-Foundation) exception mechanism\n");
    objc_exception_set_functions(&default_functions);
}


__private_extern__ void exception_init(void)
{
    // nothing to do
}

__private_extern__ void _destroyAltHandlerList(struct alt_handler_list *list)
{
    // nothing to do
}


// !__LP64__
#else
// __LP64__

/***********************************************************************
* 64-bit implementation.
**********************************************************************/

#include <objc/objc-exception.h>
#include "objc-private.h"


// unwind library types and functions
// Mostly adapted from Itanium C++ ABI: Exception Handling
//   http://www.codesourcery.com/cxx-abi/abi-eh.html

struct _Unwind_Exception;
struct _Unwind_Context;

typedef int _Unwind_Action;
static const _Unwind_Action _UA_SEARCH_PHASE = 1;
static const _Unwind_Action _UA_CLEANUP_PHASE = 2;
static const _Unwind_Action _UA_HANDLER_FRAME = 4;
static const _Unwind_Action _UA_FORCE_UNWIND = 8;

typedef enum {
    _URC_NO_REASON = 0,
    _URC_FOREIGN_EXCEPTION_CAUGHT = 1,
    _URC_FATAL_PHASE2_ERROR = 2,
    _URC_FATAL_PHASE1_ERROR = 3,
    _URC_NORMAL_STOP = 4,
    _URC_END_OF_STACK = 5,
    _URC_HANDLER_FOUND = 6,
    _URC_INSTALL_CONTEXT = 7,
    _URC_CONTINUE_UNWIND = 8
} _Unwind_Reason_Code;


typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn)(struct _Unwind_Context *, void *);

struct dwarf_eh_bases
{
    uintptr_t tbase;
    uintptr_t dbase;
    uintptr_t func;
};

extern uintptr_t _Unwind_GetIP (struct _Unwind_Context *);
extern uintptr_t _Unwind_GetCFA (struct _Unwind_Context *);
extern uintptr_t _Unwind_GetLanguageSpecificData(struct _Unwind_Context *);
extern const void * _Unwind_Find_FDE (void *, struct dwarf_eh_bases *);
extern _Unwind_Reason_Code _Unwind_Backtrace (_Unwind_Trace_Fn, void *);


// C++ runtime types and functions
// Mostly adapted from Itanium C++ ABI: Exception Handling
//   http://www.codesourcery.com/cxx-abi/abi-eh.html

typedef void (*terminate_handler) ();

// mangled std::set_terminate()
extern terminate_handler _ZSt13set_terminatePFvvE(terminate_handler);
extern void *__cxa_allocate_exception(size_t thrown_size);
extern void __cxa_throw(void *exc, void *typeinfo, void (*destructor)(void *)) __attribute__((noreturn));
extern void *__cxa_begin_catch(void *exc);
extern void __cxa_end_catch(void);
extern void __cxa_rethrow(void);
extern void *__cxa_current_exception_type(void);

extern _Unwind_Reason_Code 
__gxx_personality_v0(int version,
                     _Unwind_Action actions,
                     uint64_t exceptionClass,
                     struct _Unwind_Exception *exceptionObject,
                     struct _Unwind_Context *context);


// objc's internal exception types and data

extern const void *objc_ehtype_vtable[];

struct objc_typeinfo {
    // Position of vtable and name fields must match C++ typeinfo object
    const void **vtable;  // always objc_ehtype_vtable
    const char *name;     // c++ typeinfo string

    Class cls;
};

struct objc_exception {
    id obj;
    struct objc_typeinfo tinfo;
};


static void _objc_exception_noop(void) { } 
static char _objc_exception_false(void) { return 0; } 
static char _objc_exception_true(void) { return 1; } 
static char _objc_exception_do_catch(struct objc_typeinfo *catch_tinfo, 
                                     struct objc_typeinfo *throw_tinfo, 
                                     void **throw_obj_p, 
                                     unsigned outer);

const void *objc_ehtype_vtable[] = {
    NULL,  // typeinfo's vtable? - fixme 
    NULL,  // typeinfo's typeinfo - fixme
    _objc_exception_noop,      // in-place destructor?
    _objc_exception_noop,      // destructor?
    _objc_exception_true,      // __is_pointer_p
    _objc_exception_false,     // __is_function_p
    _objc_exception_do_catch,  // __do_catch
    _objc_exception_false,     // __do_upcast
};

struct objc_typeinfo OBJC_EHTYPE_id = {
    objc_ehtype_vtable+2, 
    "id", 
    NULL
};



/***********************************************************************
* Foundation customization
**********************************************************************/

/***********************************************************************
* _objc_default_exception_preprocessor
* Default exception preprocessor. Expected to be overridden by Foundation.
**********************************************************************/
static id _objc_default_exception_preprocessor(id exception)
{
    return exception;
}
static objc_exception_preprocessor exception_preprocessor = _objc_default_exception_preprocessor;


/***********************************************************************
* _objc_default_exception_matcher
* Default exception matcher. Expected to be overridden by Foundation.
**********************************************************************/
static int _objc_default_exception_matcher(Class catch_cls, id exception)
{
    Class cls;
    for (cls = exception->isa;
         cls != NULL; 
         cls = class_getSuperclass(cls))
    {
        if (cls == catch_cls) return 1;
    }

    return 0;
}
static objc_exception_matcher exception_matcher = _objc_default_exception_matcher;


/***********************************************************************
* _objc_default_uncaught_exception_handler
* Default uncaught exception handler. Expected to be overridden by Foundation.
**********************************************************************/
static void _objc_default_uncaught_exception_handler(id exception)
{
}
static objc_uncaught_exception_handler uncaught_handler = _objc_default_uncaught_exception_handler;


/***********************************************************************
* objc_setExceptionPreprocessor
* Set a handler for preprocessing Objective-C exceptions. 
* Returns the previous handler. 
**********************************************************************/
objc_exception_preprocessor
objc_setExceptionPreprocessor(objc_exception_preprocessor fn)
{
    objc_exception_preprocessor result = exception_preprocessor;
    exception_preprocessor = fn;
    return result;
}


/***********************************************************************
* objc_setExceptionMatcher
* Set a handler for matching Objective-C exceptions. 
* Returns the previous handler. 
**********************************************************************/
objc_exception_matcher
objc_setExceptionMatcher(objc_exception_matcher fn)
{
    objc_exception_matcher result = exception_matcher;
    exception_matcher = fn;
    return result;
}


/***********************************************************************
* objc_setUncaughtExceptionHandler
* Set a handler for uncaught Objective-C exceptions. 
* Returns the previous handler. 
**********************************************************************/
objc_uncaught_exception_handler 
objc_setUncaughtExceptionHandler(objc_uncaught_exception_handler fn)
{
    objc_uncaught_exception_handler result = uncaught_handler;
    uncaught_handler = fn;
    return result;
}


/***********************************************************************
* Exception personality
**********************************************************************/

static void call_alt_handlers(struct _Unwind_Context *ctx);

_Unwind_Reason_Code 
__objc_personality_v0(int version,
                      _Unwind_Action actions,
                      uint64_t exceptionClass,
                      struct _Unwind_Exception *exceptionObject,
                      struct _Unwind_Context *context)
{
    BOOL unwinding = ((actions & _UA_CLEANUP_PHASE)  ||  
                      (actions & _UA_FORCE_UNWIND));

    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: %s through frame [ip=%p sp=%p] "
                     "for exception %p", 
                     unwinding ? "unwinding" : "searching", 
                     (void*)(_Unwind_GetIP(context)-1),
                     (void*)_Unwind_GetCFA(context), exceptionObject);
    }

    // If we're executing the unwind, call this frame's alt handlers, if any.
    if (unwinding) {
        call_alt_handlers(context);
    }

    // Let C++ handle the unwind itself.
    return __gxx_personality_v0(version, actions, exceptionClass, 
                                exceptionObject, context);
}


/***********************************************************************
* Compiler ABI
**********************************************************************/

static void _objc_exception_destructor(void *exc_gen) {
    struct objc_exception *exc = (struct objc_exception *)exc_gen;
    if (UseGC  &&  auto_zone_is_valid_pointer(gc_zone, exc->obj)) {
        // retained by objc_exception_throw
        auto_zone_release(gc_zone, exc->obj);
    }
}


void objc_exception_throw(id obj)
{
    struct objc_exception *exc = 
        __cxa_allocate_exception(sizeof(struct objc_exception));

    exc->obj = (*exception_preprocessor)(obj);
    if (UseGC  &&  auto_zone_is_valid_pointer(gc_zone, obj)) {
        // exc is non-scanned memory. Retain the object for the duration.
        auto_zone_retain(gc_zone, obj);
    }

    exc->tinfo.vtable = objc_ehtype_vtable;
    exc->tinfo.name = object_getClassName(obj);
    exc->tinfo.cls = obj ? obj->isa : Nil;

    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: throwing %p (object %p, a %s)", 
                     exc, obj, object_getClassName(obj));
    }

    __cxa_throw(exc, &exc->tinfo, &_objc_exception_destructor);
}


void objc_exception_rethrow(void)
{
    // exception_preprocessor doesn't get another bite of the apple
    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: rethrowing current exception");
    }
    __cxa_rethrow();
}


id objc_begin_catch(void *exc_gen)
{
    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: handling exception %p at %p", 
                     exc_gen, __builtin_return_address(0));
    }
    // NOT actually an id in the catch(...) case!
    return (id)__cxa_begin_catch(exc_gen);
}


void objc_end_catch(void)
{
    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: finishing handler");
    }
    __cxa_end_catch();
}


static char _objc_exception_do_catch(struct objc_typeinfo *catch_tinfo, 
                                     struct objc_typeinfo *throw_tinfo, 
                                     void **throw_obj_p, 
                                     unsigned outer)
{
    id exception;

    if (throw_tinfo->vtable != objc_ehtype_vtable) {
        // Only objc types can be caught here.
        return 0;
    }

    // `catch (id)` always catches objc types.
    if (catch_tinfo == &OBJC_EHTYPE_id) {
        if (PrintExceptions) _objc_inform("EXCEPTIONS: catch(id)");
        return 1;
    }

    exception = *(id *)throw_obj_p;
    // fixme remapped catch_tinfo->cls
    if ((*exception_matcher)(catch_tinfo->cls, exception)) {
        if (PrintExceptions) _objc_inform("EXCEPTIONS: catch(%s)", 
                                          class_getName(catch_tinfo->cls));
        return 1;
    }

    return 0;
}


/***********************************************************************
* _objc_terminate
* Custom std::terminate handler.
*
* The uncaught exception callback is implemented as a std::terminate handler. 
* 1. Check if there's an active exception
* 2. If so, check if it's an Objective-C exception
* 3. If so, call our registered callback with the object.
* 4. Finally, call the previous terminate handler.
**********************************************************************/
static terminate_handler old_terminate = NULL;
static void _objc_terminate(void)
{
    if (PrintExceptions) {
        _objc_inform("EXCEPTIONS: terminating");
    }

    if (! __cxa_current_exception_type()) {
        // No current exception.
        (*old_terminate)();
    }
    else {
        // There is a current exception. Check if it's an objc exception.
        @try {
            __cxa_rethrow();
        } @catch (id e) {
            // It's an objc object. Call Foundation's handler, if any.
            (*uncaught_handler)(e);
            (*old_terminate)();
        } @catch (...) {
            // It's not an objc object. Continue to C++ terminate.
            (*old_terminate)();
        }
    }
}


/***********************************************************************
* alt handler support
**********************************************************************/


// Dwarf eh data encodings
#define DW_EH_PE_omit      0xff  // no data follows

#define DW_EH_PE_absptr    0x00
#define DW_EH_PE_uleb128   0x01
#define DW_EH_PE_udata2    0x02
#define DW_EH_PE_udata4    0x03
#define DW_EH_PE_udata8    0x04
#define DW_EH_PE_sleb128   0x09
#define DW_EH_PE_sdata2    0x0A
#define DW_EH_PE_sdata4    0x0B
#define DW_EH_PE_sdata8    0x0C

#define DW_EH_PE_pcrel     0x10
#define DW_EH_PE_textrel   0x20
#define DW_EH_PE_datarel   0x30
#define DW_EH_PE_funcrel   0x40
#define DW_EH_PE_aligned   0x50  // fixme

#define DW_EH_PE_indirect  0x80  // gcc extension


/***********************************************************************
* read_uleb
* Read a LEB-encoded unsigned integer from the address stored in *pp.
* Increments *pp past the bytes read.
* Adapted from DWARF Debugging Information Format 1.1, appendix 4
**********************************************************************/
static uintptr_t read_uleb(uintptr_t *pp)
{
    uintptr_t result = 0;
    uintptr_t shift = 0;
    unsigned char byte;
    do {
        byte = *(const unsigned char *)(*pp)++;
        result |= (byte & 0x7f) << shift;
        shift += 7;
    } while (byte & 0x80);
    return result;
}


/***********************************************************************
* read_sleb
* Read a LEB-encoded signed integer from the address stored in *pp.
* Increments *pp past the bytes read.
* Adapted from DWARF Debugging Information Format 1.1, appendix 4
**********************************************************************/
static intptr_t read_sleb(uintptr_t *pp)
{
    uintptr_t result = 0;
    uintptr_t shift = 0;
    unsigned char byte;
    do {
        byte = *(const unsigned char *)(*pp)++;
        result |= (byte & 0x7f) << shift;
        shift += 7;
    } while (byte & 0x80);
    if ((shift < 8*sizeof(intptr_t))  &&  (byte & 0x40)) {
        result |= ((intptr_t)-1) << shift;
    }
    return result;
}


/***********************************************************************
* get_cie
* Returns the address of the CIE for the given FDE.
**********************************************************************/
static uintptr_t get_cie(uintptr_t fde) {
    uintptr_t deltap = fde + sizeof(int32_t);
    int32_t delta = *(int32_t *)deltap;
    return deltap - delta;
}


/***********************************************************************
* get_cie_augmentation
* Returns the augmentation string for the given CIE.
**********************************************************************/
static const char *get_cie_augmentation(uintptr_t cie) {
    return (const char *)(cie + 2*sizeof(int32_t) + 1);
}


/***********************************************************************
* read_address
* Reads an encoded address from the address stored in *pp.
* Increments *pp past the bytes read.
* The data is interpreted according to the given dwarf encoding 
* and base addresses.
**********************************************************************/
static uintptr_t read_address(uintptr_t *pp, 
                              struct dwarf_eh_bases *bases, 
                              unsigned char encoding)
{
    uintptr_t result = 0;
    uintptr_t oldp = *pp;

    // fixme need DW_EH_PE_aligned?

#define READ(type) \
    result = *(type *)(*pp); \
    *pp += sizeof(type);

    if (encoding == DW_EH_PE_omit) return 0;

    switch (encoding & 0x0f) {
    case DW_EH_PE_absptr:
        READ(uintptr_t);
        break;
    case DW_EH_PE_uleb128:
        result = read_uleb(pp);
        break;
    case DW_EH_PE_udata2:
        READ(uint16_t);
        break;
    case DW_EH_PE_udata4:
        READ(uint32_t);
        break;
#if __LP64__
    case DW_EH_PE_udata8:
        READ(uint64_t);
        break;
#endif
    case DW_EH_PE_sleb128:
        result = read_sleb(pp);
        break;
    case DW_EH_PE_sdata2:
        READ(int16_t);
        break;
    case DW_EH_PE_sdata4:
        READ(int32_t);
        break;
#if __LP64__
    case DW_EH_PE_sdata8:
        READ(int64_t);
        break;
#endif
    default:
        _objc_inform("unknown DWARF EH encoding 0x%x at %p", 
                     encoding, (void *)*pp);
        break;
    }

#undef READ

    if (result) {
        switch (encoding & 0x70) {
        case DW_EH_PE_pcrel:
            // fixme correct?
            result += (uintptr_t)oldp;
            break;
        case DW_EH_PE_textrel:
            result += bases->tbase;
            break;
        case DW_EH_PE_datarel:
            result += bases->dbase;
            break;
        case DW_EH_PE_funcrel:
            result += bases->func;
            break;
        case DW_EH_PE_aligned:
            _objc_inform("unknown DWARF EH encoding 0x%x at %p", 
                         encoding, (void *)*pp);
            break;
        default:
            // no adjustment
            break;
        }

        if (encoding & DW_EH_PE_indirect) {
            result = *(uintptr_t *)result;
        }
    }

    return (uintptr_t)result;
}


/***********************************************************************
* frame_finder
* Determines whether the frame represented by ctx is 
* (1) an Objective-C or Objective-C++ frame, and 
* (2) has any catch handlers.
**********************************************************************/
struct frame_range {
    uintptr_t ip_start;
    uintptr_t ip_end;
    uintptr_t cfa;
};

static _Unwind_Reason_Code frame_finder(struct _Unwind_Context *ctx, void *arg)
{
    uintptr_t ip_start;
    uintptr_t ip_end;

    uintptr_t lsda = _Unwind_GetLanguageSpecificData(ctx);
    if (!lsda) return _URC_NO_REASON; 

    uintptr_t ip = _Unwind_GetIP(ctx) - 1;

    struct dwarf_eh_bases bases;
    uintptr_t fde = (uintptr_t)_Unwind_Find_FDE((void *)ip, &bases);
    if (!fde) return _URC_NO_REASON;

    uintptr_t cie = get_cie(fde);
    const char *aug = get_cie_augmentation(cie);
    uintptr_t augdata = (uintptr_t)(aug + strlen(aug) + 1);
    read_uleb(&augdata); // code alignment factor
    read_sleb(&augdata); // data alignment factor
    augdata++; // RA register

    // 'z' must be first, if present
    if (*aug == 'z') {
        aug++;
        read_uleb(&augdata);  // augmentation length
    }

    uintptr_t personality = 0;
    char ch;
    while ((ch = *aug++)) {
        if (ch == 'L') {
            // LSDA encoding
            augdata++;  
        } else if (ch == 'R') {
            // pointer encoding
            augdata++;
        } else if (ch == 'P') {
            // personality function
            unsigned char enc = *(const unsigned char *)augdata++;
            personality = read_address(&augdata, &bases, enc);
        } else {
            // unknown augmentation - ignore the rest
            break;
        }
    }
                                                
    // No personality means no handlers in this frame
    if (!personality) return _URC_NO_REASON;

    // Only the objc personality will honor our attached handlers.
    if (personality != (uintptr_t)__objc_personality_v0) return _URC_NO_REASON;

    // We have the LSDA and the right personality. 
    // Scan the LSDA for handlers matching this IP

    unsigned char LPStart_enc = *(const unsigned char *)lsda++;
    if (LPStart_enc != DW_EH_PE_omit) {
        read_address(&lsda, &bases, LPStart_enc); // LPStart
    }

    unsigned char TType_enc = *(const unsigned char *)lsda++;
    if (TType_enc != DW_EH_PE_omit) {
        read_uleb(&lsda);  // TType
    }

    unsigned char call_site_enc = *(const unsigned char *)lsda++;
    uintptr_t length = read_uleb(&lsda);
    uintptr_t call_site_table = lsda;
    uintptr_t call_site_table_end = call_site_table + length;
    uintptr_t action_record_table = call_site_table_end;

    uintptr_t action_record = 0;
    uintptr_t p = call_site_table;

    while (p < call_site_table_end) {
        uintptr_t start = read_address(&p, &bases, call_site_enc);
        uintptr_t len = read_address(&p, &bases, call_site_enc);
        uintptr_t pad = read_address(&p, &bases, call_site_enc);
        uintptr_t action = read_uleb(&p);

        if (ip < bases.func + start) {
            // no more source ranges
            return _URC_NO_REASON;
        } 
        else if (ip < bases.func + start + len) {
            // found the range
            if (!pad) return _URC_NO_REASON;  // ...but it has no landing pad
            // found the landing pad
            ip_start = bases.func + start;
            ip_end = bases.func + start + len;
            action_record = action ? action_record_table + action - 1 : 0;
            break;
        }        
    }
    
    if (!action_record) return _URC_NO_REASON;  // no catch handlers

    // has handlers, destructors, and/or throws specifications
    // Use this frame if it has any handlers
    int has_handler = 0;
    p = action_record;
    intptr_t offset;
    do {
        intptr_t filter = read_sleb(&p);
        uintptr_t temp = p;
        offset = read_sleb(&temp);
        p += offset;
        
        if (filter < 0) {
            // throws specification - ignore
        } else if (filter == 0) {
            // destructor - ignore
        } else /* filter >= 0 */ {
            // catch handler - use this frame
            has_handler = 1;
            break;
        }
    } while (offset);
    
    if (!has_handler) return _URC_NO_REASON;  // no catch handlers - ignore

    struct frame_range *result = (struct frame_range *)arg;
    result->ip_start = ip_start;
    result->ip_end = ip_end;
    result->cfa = _Unwind_GetCFA(ctx);

    return _URC_HANDLER_FOUND;
}


// This data structure assumes the number of 
// active alt handlers per frame is small.
struct alt_handler_data {
    uintptr_t ip_start;
    uintptr_t ip_end;
    uintptr_t cfa;
    objc_exception_handler fn;
    void *context;
};

struct alt_handler_list {
    unsigned int allocated;
    unsigned int used;
    struct alt_handler_data *handlers;
};


static struct alt_handler_list *
fetch_handler_list(BOOL create)
{
    _objc_pthread_data *data = _objc_fetch_pthread_data(create);
    if (!data) return NULL;

    struct alt_handler_list *list = data->handlerList;
    if (!list) {
        if (!create) return NULL;
        list = _calloc_internal(1, sizeof(*list));
        data->handlerList = list;
    }

    return list;
}


__private_extern__ void _destroyAltHandlerList(struct alt_handler_list *list)
{
    if (list) {
        if (list->handlers) {
            _free_internal(list->handlers);
        }
        _free_internal(list);
    }
}


uintptr_t objc_addExceptionHandler(objc_exception_handler fn, void *context)
{ 
    struct frame_range target_frame = {0, 0, 0};

    // Find the closest enclosing frame with objc catch handlers
    _Unwind_Backtrace(&frame_finder, &target_frame);
    if (!target_frame.ip_start) {
        // No suitable enclosing handler found.
        return 0;
    }

    // Record this alt handler for the discovered frame.
    struct alt_handler_list *list = fetch_handler_list(YES);
    unsigned int i = 0;

    if (list->used == list->allocated) {
        list->allocated = list->allocated*2 ?: 4;
        list->handlers = _realloc_internal(list->handlers, list->allocated * sizeof(list->handlers[0]));
        bzero(&list->handlers[list->used], (list->allocated - list->used) * sizeof(list->handlers[0]));
        i = list->used;
    }
    else {
        for (i = 0; i < list->allocated; i++) {
            if (list->handlers[i].ip_start == 0  &&  
                list->handlers[i].ip_end == 0  &&  
                list->handlers[i].cfa == 0) 
            {
                break;
            }
        }
        if (i == list->allocated) {
            _objc_fatal("alt handlers in objc runtime are buggy!");
        }
    }

    struct alt_handler_data *data = &list->handlers[i];

    data->ip_start = target_frame.ip_start;
    data->ip_end = target_frame.ip_end;
    data->cfa = target_frame.cfa;
    data->fn = fn;
    data->context = context;
    list->used++;

    if (PrintAltHandlers) {
        _objc_inform("ALT HANDLERS: installing alt handler %d %p(%p) on "
                     "frame [ip=%p..%p sp=%p]", i+1, data->fn, data->context, 
                     (void *)data->ip_start, (void *)data->ip_end, 
                     (void *)data->cfa);
    }

    if (list->used > 1000) {
        static int warned = 0;
        if (!warned) {
            _objc_inform("ALT_HANDLERS: *** over 1000 alt handlers installed; "
                         "this is probably a bug");
            warned = 1;
        }
    }

    return i+1;
}


void objc_removeExceptionHandler(uintptr_t token)
{
    if (!token) {
        // objc_addExceptionHandler failed
        return;
    }
    unsigned int i = (unsigned int)(token - 1);
    
    struct alt_handler_list *list = fetch_handler_list(NO);
    if (!list  ||  list->used == 0) {
        // no handlers present
        if (PrintAltHandlers) {
            _objc_inform("ALT HANDLERS: *** can't remove alt handler %lu "
                         "(no alt handlers present)", token);
        }
        return;
    }
    if (i >= list->allocated) {
        // bogus token
        if (PrintAltHandlers) {
            _objc_inform("ALT HANDLERS: *** can't remove alt handler %lu "
                         "(current max is %u)", token, list->allocated);
        }
        return;
    }

    struct alt_handler_data *data = &list->handlers[i];
    if (PrintAltHandlers) {
        _objc_inform("ALT HANDLERS: removing   alt handler %d %p(%p) on "
                     "frame [ip=%p..%p sp=%p]", i+1, data->fn, data->context, 
                     (void *)data->ip_start, (void *)data->ip_end, 
                     (void *)data->cfa);
    }
    bzero(data, sizeof(*data));
    list->used--;
}


// called in order registered, to match 32-bit _NSAddAltHandler2
// fixme reverse registration order matches c++ destructors better
static void call_alt_handlers(struct _Unwind_Context *ctx)
{
    uintptr_t ip = _Unwind_GetIP(ctx) - 1;
    uintptr_t cfa = _Unwind_GetCFA(ctx);
    unsigned int i;
    
    struct alt_handler_list *list = fetch_handler_list(NO);
    if (!list  ||  list->used == 0) return;

    for (i = 0; i < list->allocated; i++) {
        struct alt_handler_data *data = &list->handlers[i];
        if (ip >= data->ip_start  &&  ip < data->ip_end  &&  data->cfa == cfa) 
        {
            // Copy and clear before the callback, in case the 
            // callback manipulates the alt handler list.
            struct alt_handler_data copy = *data;
            bzero(data, sizeof(*data));
            list->used--;
            if (PrintExceptions || PrintAltHandlers) {
                _objc_inform("EXCEPTIONS: calling alt handler %p(%p) from "
                             "frame [ip=%p..%p sp=%p]", copy.fn, copy.context, 
                             (void *)copy.ip_start, (void *)copy.ip_end, 
                             (void *)copy.cfa);
            }
            if (copy.fn) (*copy.fn)(nil, copy.context);
        }
    }
}


/***********************************************************************
* exception_init
* Initialize libobjc's exception handling system.
* Called by map_images().
**********************************************************************/
__private_extern__ void exception_init(void)
{
    // call std::set_terminate
    old_terminate = _ZSt13set_terminatePFvvE(&_objc_terminate);
}


// __LP64__
#endif
