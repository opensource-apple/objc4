/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
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
* objc-runtime.m
* Copyright 1988-1996, NeXT Software, Inc.
* Author:	s. naroff
*
**********************************************************************/



/***********************************************************************
* Imports.
**********************************************************************/

#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_gdb.h>
#include <mach-o/dyld_priv.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <crt_externs.h>
#include <libgen.h>

#include <crt_externs.h>
#include <libgen.h>

#import "objc-private.h"
#import "hashtable2.h"
#import "maptable.h"
#import "Object.h"
#import "objc-rtp.h"
#import "objc-auto.h"
#import "objc-loadmethod.h"

OBJC_EXPORT Class getOriginalClassForPosingClass(Class);


/***********************************************************************
* Exports.
**********************************************************************/

// Settings from environment variables
__private_extern__ int PrintImages = -1;     // env OBJC_PRINT_IMAGES
__private_extern__ int PrintLoading = -1;    // env OBJC_PRINT_LOAD_METHODS
__private_extern__ int PrintInitializing = -1; // env OBJC_PRINT_INITIALIZE_METHODS
__private_extern__ int PrintResolving = -1;  // env OBJC_PRINT_RESOLVED_METHODS
__private_extern__ int PrintConnecting = -1; // env OBJC_PRINT_CLASS_SETUP
__private_extern__ int PrintProtocols = -1;  // env OBJC_PRINT_PROTOCOL_SETUP
__private_extern__ int PrintIvars = -1;      // env OBJC_PRINT_IVAR_SETUP
__private_extern__ int PrintFuture = -1;     // env OBJC_PRINT_FUTURE_CLASSES
__private_extern__ int PrintRTP = -1;        // env OBJC_PRINT_RTP
__private_extern__ int PrintGC = -1;         // env OBJC_PRINT_GC
__private_extern__ int PrintSharing = -1;    // env OBJC_PRINT_SHARING
__private_extern__ int PrintCxxCtors = -1;   // env OBJC_PRINT_CXX_CTORS
__private_extern__ int PrintExceptions = -1; // env OBJC_PRINT_EXCEPTIONS
__private_extern__ int PrintAltHandlers = -1; // env OBJC_PRINT_ALT_HANDLERS
__private_extern__ int PrintDeprecation = -1;// env OBJC_PRINT_DEPRECATION_WARNINGS
__private_extern__ int PrintReplacedMethods = -1; // env OBJC_PRINT_REPLACED_METHODS
__private_extern__ int PrintCacheCollection = -1; // env OBJC_PRINT_CACHE_COLLECTION

__private_extern__ int UseInternalZone = -1; // env OBJC_USE_INTERNAL_ZONE
__private_extern__ int AllowInterposing = -1;// env OBJC_ALLOW_INTERPOSING

__private_extern__ int DebugUnload = -1;     // env OBJC_DEBUG_UNLOAD
__private_extern__ int DebugFragileSuperclasses = -1; // env OBJC_DEBUG_FRAGILE_SUPERCLASSES
__private_extern__ int DebugNilSync = -1;    // env OBJC_DEBUG_NIL_SYNC

__private_extern__ int DisableGC = -1;       // env OBJC_DISABLE_GC
__private_extern__ int DebugFinalizers = -1; // env OBJC_DEBUG_FINALIZERS


// objc's key for pthread_getspecific
static pthread_key_t _objc_pthread_key = 0;

// Selectors for which @selector() doesn't work
__private_extern__ SEL cxx_construct_sel = NULL;
__private_extern__ SEL cxx_destruct_sel = NULL;
__private_extern__ const char *cxx_construct_name = ".cxx_construct";
__private_extern__ const char *cxx_destruct_name = ".cxx_destruct";


/***********************************************************************
* Function prototypes internal to this module.
**********************************************************************/

static void _objc_unmap_image(header_info *hi);


/***********************************************************************
* Static data internal to this module.
**********************************************************************/

// we keep a linked list of header_info's describing each image as told to us by dyld
static header_info *FirstHeader NOBSS = 0;  // NULL means empty list
static header_info *LastHeader  NOBSS = 0;  // NULL means invalid; recompute it
static int HeaderCount NOBSS = 0;


/***********************************************************************
* objc_getClass.  Return the id of the named class.  If the class does
* not exist, call _objc_classLoader and then objc_classHandler, either of 
* which may create a new class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id objc_getClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, YES class handler
    return look_up_class(aClassName, NO, YES);
}


/***********************************************************************
* objc_getRequiredClass.  
* Same as objc_getClass, but kills the process if the class is not found. 
* This is used by ZeroLink, where failing to find a class would be a 
* compile-time link error without ZeroLink.
**********************************************************************/
id objc_getRequiredClass(const char *aClassName)
{
    id cls = objc_getClass(aClassName);
    if (!cls) _objc_fatal("link error: class '%s' not found.", aClassName);
    return cls;
}


/***********************************************************************
* objc_lookUpClass.  Return the id of the named class.
* If the class does not exist, call _objc_classLoader, which may create 
* a new class.
*
* Formerly objc_getClassWithoutWarning ()
**********************************************************************/
id objc_lookUpClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, NO class handler
    return look_up_class(aClassName, NO, NO);
}

/***********************************************************************
* objc_getFutureClass.  Return the id of the named class.
* If the class does not exist, return an uninitialized class 
* structure that will be used for the class when and if it 
* does get loaded.
* Not thread safe. 
**********************************************************************/
Class objc_getFutureClass(const char *name)
{
    Class cls;

    // YES unconnected, NO class handler
    // (unconnected is OK because it will someday be the real class)
    cls = look_up_class(name, YES, NO);
    if (cls) {
        if (PrintFuture) {
            _objc_inform("FUTURE: found %p already in use for %s", cls, name);
        }
        return cls;
    }
    
    // No class or future class with that name yet. Make one.
    // fixme not thread-safe with respect to 
    // simultaneous library load or getFutureClass.
    return _objc_allocateFutureClass(name);
}


/***********************************************************************
* objc_getMetaClass.  Return the id of the meta class the named class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
id objc_getMetaClass(const char *aClassName)
{
    Class cls;

    if (!aClassName) return Nil;

    cls = objc_getClass (aClassName);
    if (!cls)
    {
        _objc_inform ("class `%s' not linked into application", aClassName);
        return Nil;
    }

    return ((id)cls)->isa;
}


#if !__LP64__
// Not updated for 64-bit ABI

/***********************************************************************
* _headerForAddress.
* addr can be a class or a category
**********************************************************************/
static const header_info *_headerForAddress(void *addr)
{
    unsigned long			size;
    unsigned long			seg;
    header_info *		hInfo;

    // Check all headers in the vector
    for (hInfo = FirstHeader; hInfo != NULL; hInfo = hInfo->next)
    {
        // Locate header data, if any
        if (!hInfo->objcSegmentHeader) continue;
        seg = hInfo->objcSegmentHeader->vmaddr + hInfo->image_slide;
        size = hInfo->objcSegmentHeader->filesize;

        // Is the class in this header?
        if ((seg <= (unsigned long) addr) &&
            ((unsigned long) addr < (seg + size)))
            return hInfo;
    }

    // Not found
    return 0;
}


/***********************************************************************
* _headerForClass
* Return the image header containing this class, or NULL.
* Returns NULL on runtime-constructed classes, and the NSCF classes.
**********************************************************************/
__private_extern__ const header_info *_headerForClass(Class cls)
{
    return _headerForAddress(cls);
}

// !__LP64__
#endif


/***********************************************************************
* _nameForHeader.
**********************************************************************/
__private_extern__ const char *_nameForHeader(const headerType *header)
{
    return _getObjcHeaderName ((headerType *) header);
}


/***********************************************************************
* _gcForHInfo.
**********************************************************************/
__private_extern__ const char *_gcForHInfo(const header_info *hinfo)
{
    if (_objcHeaderRequiresGC(hinfo)) return "requires GC";
    else if (_objcHeaderSupportsGC(hinfo)) return "supports GC";
    else return "does not support GC";
}
__private_extern__ const char *_gcForHInfo2(const header_info *hinfo)
{
    if (_objcHeaderRequiresGC(hinfo)) return " (requires GC)";
    else if (_objcHeaderSupportsGC(hinfo)) return " (supports GC)";
    else return "";
}


/***********************************************************************
* bad_magic.
* Return YES if the header has invalid Mach-o magic.
**********************************************************************/
static BOOL bad_magic(const headerType *mhdr)
{
    return (mhdr->magic != MH_MAGIC  &&  mhdr->magic != MH_MAGIC_64  &&  
            mhdr->magic != MH_CIGAM  &&  mhdr->magic != MH_CIGAM_64);
}


/***********************************************************************
* _objc_headerStart.  Return what headers we know about.
**********************************************************************/
__private_extern__ header_info *_objc_headerStart(void)
{
    // Take advatage of our previous work
    return FirstHeader;
}


/***********************************************************************
* _objc_addHeader.
* Returns NULL if the header has no ObjC metadata.
**********************************************************************/

// tested with 2; typical case is 4, but OmniWeb & Mail push it towards 20
#define HINFO_SIZE 16

static int HeaderInfoCounter NOBSS = 0;
static header_info HeaderInfoTable[HINFO_SIZE] NOBSS = { {0} };

static header_info * _objc_addHeader(const headerType *header)
{
    size_t info_size = 0;
    const segmentType *objc_segment;
    const segmentType *objc2_segment;
    const objc_image_info *image_info;
    const segmentType *data_segment;
    header_info *result;
    ptrdiff_t image_slide;

    // Weed out duplicates
    for (result = FirstHeader; result; result = result->next) {
        if (header == result->mhdr) return NULL;
    }

    // Locate the __OBJC segment
    image_slide = _getImageSlide(header);
    image_info = _getObjcImageInfo(header, image_slide, &info_size);
    objc_segment = getsegbynamefromheader(header, SEG_OBJC);
    objc2_segment = getsegbynamefromheader(header, SEG_OBJC2);
    data_segment = getsegbynamefromheader(header, SEG_DATA);
    if (!objc_segment  &&  !image_info  &&  !objc2_segment) return NULL;

    // Find or allocate a header_info entry.
    if (HeaderInfoCounter < HINFO_SIZE) {
        result = &HeaderInfoTable[HeaderInfoCounter++];
    } else {
        result = _malloc_internal(sizeof(header_info));
    }

    // Set up the new header_info entry.
    result->mhdr = header;
    result->image_slide	= image_slide;
    result->objcSegmentHeader = objc_segment;
    result->dataSegmentHeader = data_segment;
#if !__OBJC2__
    result->mod_count = 0;
    result->mod_ptr = _getObjcModules(header, result->image_slide, &result->mod_count);
#endif
    result->info = image_info;
    dladdr(result->mhdr, &result->dl_info);
    result->allClassesRealized = NO;

    // dylibs are not allowed to unload
    if (result->mhdr->filetype == MH_DYLIB) {
        dlopen(result->dl_info.dli_fname, RTLD_NOLOAD);
    }

    // Make sure every copy of objc_image_info in this image is the same.
    // This means same version and same bitwise contents.
    if (result->info) {
        const objc_image_info *start = result->info;
        const objc_image_info *end = 
            (objc_image_info *)(info_size + (uint8_t *)start);
        const objc_image_info *info = start;
        while (info < end) {
            // version is byte size, except for version 0
            size_t struct_size = info->version;
            if (struct_size == 0) struct_size = 2 * sizeof(uint32_t);
            if (info->version != start->version  ||  
                0 != memcmp(info, start, struct_size))
            {
                _objc_inform("'%s' has inconsistently-compiled Objective-C "
                            "code. Please recompile all code in it.", 
                            _nameForHeader(header));
            }
            info = (objc_image_info *)(struct_size + (uint8_t *)info);
        }
    }

    // Add the header to the header list. 
    // The header is appended to the list, to preserve the bottom-up order.
    HeaderCount++;
    result->next = NULL;
    if (!FirstHeader) {
        // list is empty
        FirstHeader = LastHeader = result;
    } else {
        if (!LastHeader) {
            // list is not empty, but LastHeader is invalid - recompute it
            LastHeader = FirstHeader;
            while (LastHeader->next) LastHeader = LastHeader->next;
        }
        // LastHeader is now valid
        LastHeader->next = result;
        LastHeader = result;
    }
    
    return result;
}


/***********************************************************************
* _objc_RemoveHeader
* Remove the given header from the header list.
* FirstHeader is updated. 
* LastHeader is set to NULL. Any code that uses LastHeader must 
* detect this NULL and recompute LastHeader by traversing the list.
**********************************************************************/
static void _objc_removeHeader(header_info *hi)
{
    header_info **hiP;

    for (hiP = &FirstHeader; *hiP != NULL; hiP = &(**hiP).next) {
        if (*hiP == hi) {
            header_info *deadHead = *hiP;

            // Remove from the linked list (updating FirstHeader if necessary).
            *hiP = (**hiP).next;
            
            // Update LastHeader if necessary.
            if (LastHeader == deadHead) {
                LastHeader = NULL;  // will be recomputed next time it's used
            }

            // Free the memory, unless it was in the static HeaderInfoTable.
            if (deadHead < HeaderInfoTable  ||
                deadHead >= HeaderInfoTable + HINFO_SIZE)
            {
                _free_internal(deadHead);
            }

            HeaderCount--;

            break;
        }
    }
}


/***********************************************************************
* check_gc
* Check whether the executable supports or requires GC, and make sure 
* all already-loaded libraries support the executable's GC mode.
* Returns TRUE if the executable wants GC on.
**********************************************************************/
static BOOL check_wants_gc(void)
{
    const header_info *hi;
    BOOL appWantsGC;

    // Environment variables can override the following.
    if (DisableGC) {
        _objc_inform("GC: forcing GC OFF because OBJC_DISABLE_GC is set");
        appWantsGC = NO;
    }
    else {
        // Find the executable and check its GC bits. 
        // If the executable cannot be found, default to NO.
        // (The executable will not be found if the executable contains 
        // no Objective-C code.)
        appWantsGC = NO;
        for (hi = FirstHeader; hi != NULL; hi = hi->next) {
            if (hi->mhdr->filetype == MH_EXECUTE) {
                appWantsGC = _objcHeaderSupportsGC(hi) ? YES : NO;
                if (PrintGC) {
                    _objc_inform("GC: executable '%s' %s",
                                 _nameForHeader(hi->mhdr), _gcForHInfo(hi));
                }
            }
        }
    }
    return appWantsGC;
}

/***********************************************************************
* verify_gc_readiness
* if we want gc, verify that every header describes files compiled
* and presumably ready for gc.
************************************************************************/

static void verify_gc_readiness(BOOL wantsGC, header_info **hList, 
                                uint32_t hCount) 
{
    BOOL busted = NO;
    uint32_t i;

    // Find the libraries and check their GC bits against the app's request
    for (i = 0; i < hCount; i++) {
        header_info *hi = hList[i];
        if (hi->mhdr->filetype == MH_EXECUTE) {
            continue;
        }
        else if (hi->mhdr == &_mh_dylib_header) {
            // libobjc itself works with anything even though it is not 
            // compiled with -fobjc-gc (fixme should it be?)
        } 
        else if (wantsGC  &&  ! _objcHeaderSupportsGC(hi)) {
            // App wants GC but library does not support it - bad
            _objc_inform_now_and_on_crash
                ("'%s' was not compiled with -fobjc-gc or -fobjc-gc-only, "
                 "but the application requires GC",
                 _nameForHeader(hi->mhdr));
            busted = YES;
        } 
        else if (!wantsGC  &&  _objcHeaderRequiresGC(hi)) {
            // App doesn't want GC but library requires it - bad
            _objc_inform_now_and_on_crash
                ("'%s' was compiled with -fobjc-gc-only, "
                 "but the application does not support GC",
                 _nameForHeader(hi->mhdr));
            busted = YES;            
        }

        if (PrintGC) {
            _objc_inform("GC: library '%s' %s", 
                         _nameForHeader(hi->mhdr), _gcForHInfo(hi));
        }
    }
    
    if (busted) {
        // GC state is not consistent. 
        // Kill the process unless one of the forcing flags is set.
        if (!DisableGC) {
            _objc_fatal("*** GC capability of application and some libraries did not match");
        }
    }
}


/***********************************************************************
* objc_setConfiguration
* Read environment variables that affect the runtime.
* Also print environment variable help, if requested.
**********************************************************************/
static void objc_setConfiguration() {
    int PrintHelp = (getenv("OBJC_HELP") != NULL);
    int PrintOptions = (getenv("OBJC_PRINT_OPTIONS") != NULL);
    int secure = issetugid();

    if (secure) {
        // All environment variables are ignored when setuid or setgid.
        if (PrintHelp) _objc_inform("OBJC_HELP ignored when running setuid or setgid");
        if (PrintOptions) _objc_inform("OBJC_PRINT_OPTIONS ignored when running setuid or setgid");
    } 
    else {
        if (PrintHelp) {
            _objc_inform("OBJC_HELP: describe Objective-C runtime environment variables");
            if (PrintOptions) {
                _objc_inform("OBJC_HELP is set");
            }
            _objc_inform("OBJC_PRINT_OPTIONS: list which options are set");
        }
        if (PrintOptions) {
            _objc_inform("OBJC_PRINT_OPTIONS is set");
        }
    }
    
#define OPTION(var, env, help) \
    if ( var == -1 ) { \
        char *value = getenv(#env); \
        var = value != NULL && !strcmp("YES", value); \
        if (secure) { \
            if (var) _objc_inform(#env " ignored when running setuid or setgid"); \
            var = 0; \
        } else { \
            if (PrintHelp) _objc_inform(#env ": " help); \
            if (PrintOptions && var) _objc_inform(#env " is set"); \
        } \
    }
    
    OPTION(PrintImages, OBJC_PRINT_IMAGES,
           "log image and library names as they are loaded");
    OPTION(PrintLoading, OBJC_PRINT_LOAD_METHODS,
           "log calls to class and category +load methods");
    OPTION(PrintInitializing, OBJC_PRINT_INITIALIZE_METHODS,
           "log calls to class +initialize methods");
    OPTION(PrintResolving, OBJC_PRINT_RESOLVED_METHODS,
           "log methods created by +resolveClassMethod: and +resolveInstanceMethod:");
    OPTION(PrintConnecting, OBJC_PRINT_CLASS_SETUP,
           "log progress of class and category setup");
    OPTION(PrintProtocols, OBJC_PRINT_PROTOCOL_SETUP,
           "log progresso of protocol setup");
    OPTION(PrintIvars, OBJC_PRINT_IVAR_SETUP,
           "log processing of non-fragile ivars");
    OPTION(PrintFuture, OBJC_PRINT_FUTURE_CLASSES, 
           "log use of future classes for toll-free bridging");
    OPTION(PrintRTP, OBJC_PRINT_RTP,
           "log initialization of the Objective-C runtime pages");
    OPTION(PrintGC, OBJC_PRINT_GC,
           "log some GC operations");
    OPTION(PrintSharing, OBJC_PRINT_SHARING,
           "log cross-process memory sharing");
    OPTION(PrintCxxCtors, OBJC_PRINT_CXX_CTORS, 
           "log calls to C++ ctors and dtors for instance variables");
    OPTION(PrintExceptions, OBJC_PRINT_EXCEPTIONS, 
           "log exception handling");
    OPTION(PrintAltHandlers, OBJC_PRINT_ALT_HANDLERS, 
           "log processing of exception alt handlers");
    OPTION(PrintReplacedMethods, OBJC_PRINT_REPLACED_METHODS, 
           "log methods replaced by category implementations");
    OPTION(PrintDeprecation, OBJC_PRINT_DEPRECATION_WARNINGS, 
           "warn about calls to deprecated runtime functions");
    OPTION(PrintCacheCollection, OBJC_PRINT_CACHE_COLLECTION, 
           "log cleanup of stale method caches");

    OPTION(DebugUnload, OBJC_DEBUG_UNLOAD,
           "warn about poorly-behaving bundles when unloaded");
    OPTION(DebugFragileSuperclasses, OBJC_DEBUG_FRAGILE_SUPERCLASSES, 
           "warn about subclasses that may have been broken by subsequent changes to superclasses");
    OPTION(DebugFinalizers, OBJC_DEBUG_FINALIZERS, 
           "warn about classes that implement -dealloc but not -finalize");
    OPTION(DebugNilSync, OBJC_DEBUG_NIL_SYNC, 
           "warn about @synchronized(nil), which does no synchronization");

    OPTION(UseInternalZone, OBJC_USE_INTERNAL_ZONE,
           "allocate runtime data in a dedicated malloc zone");
    OPTION(AllowInterposing, OBJC_ALLOW_INTERPOSING,
           "allow function interposing of objc_msgSend()");

    OPTION(DisableGC, OBJC_DISABLE_GC,
           "force GC OFF, even if the executable wants it on");

#undef OPTION
}


/***********************************************************************
* objc_setMultithreaded.
**********************************************************************/
void objc_setMultithreaded (BOOL flag)
{
    OBJC_WARN_DEPRECATED;

    // Nothing here. Thread synchronization in the runtime is always active.
}


/***********************************************************************
* _objc_fetch_pthread_data
* Fetch objc's pthread data for this thread.
* If the data doesn't exist yet and create is NO, return NULL.
* If the data doesn't exist yet and create is YES, allocate and return it.
**********************************************************************/
__private_extern__ _objc_pthread_data *_objc_fetch_pthread_data(BOOL create)
{
    _objc_pthread_data *data;

    data = pthread_getspecific(_objc_pthread_key);
    if (!data  &&  create) {
        data = _calloc_internal(1, sizeof(_objc_pthread_data));
        pthread_setspecific(_objc_pthread_key, data);
    }

    return data;
}


/***********************************************************************
* _objc_pthread_destroyspecific
* Destructor for objc's per-thread data.
* arg shouldn't be NULL, but we check anyway.
**********************************************************************/
extern void _destroyInitializingClassList(struct _objc_initializing_classes *list);
__private_extern__ void _objc_pthread_destroyspecific(void *arg)
{
    _objc_pthread_data *data = (_objc_pthread_data *)arg;
    if (data != NULL) {
        _destroyInitializingClassList(data->initializingClasses);
        _destroyLockList(data->lockList);
        _destroySyncCache(data->syncCache);
        _destroyAltHandlerList(data->handlerList);

        // add further cleanup here...

        _free_internal(data);
    }
}


/***********************************************************************
* _objcInit
* Former library initializer. This function is now merely a placeholder 
* for external callers. All runtime initialization has now been moved 
* to map_images() and _objc_init.
**********************************************************************/
void _objcInit(void)
{
    // do nothing
}


/***********************************************************************
* gc_enforcer
* Make sure that images about to be loaded by dyld are GC-acceptable.
* Images linked to the executable are always permitted; they are 
* enforced inside map_images() itself.
**********************************************************************/
static BOOL InitialDyldRegistration = NO;
static const char *gc_enforcer(enum dyld_image_states state, 
                               uint32_t infoCount, 
                               const struct dyld_image_info info[])
{
    uint32_t i;

    // Linked images get a free pass
    if (InitialDyldRegistration) return NULL;

    if (PrintImages) {
        _objc_inform("IMAGES: checking %d images for compatibility...", 
                     infoCount);
    }

    for (i = 0; i < infoCount; i++) {
        const headerType *mhdr = (const headerType *)info[i].imageLoadAddress;
        if (bad_magic(mhdr)) continue;

        objc_image_info *image_info;
        size_t size;

        if (mhdr == &_mh_dylib_header) {
            // libobjc itself - OK
            continue;
        }

#if !__LP64__
        // 32-bit: __OBJC seg but no image_info means no GC support
        if (!getsegbynamefromheader(mhdr, SEG_OBJC)) {
            // not objc - assume OK
            continue;
        }
        image_info = _getObjcImageInfo(mhdr, _getImageSlide(mhdr), &size);
        if (!image_info) {
            // No image_info - assume GC unsupported
            if (!UseGC) {
                // GC is OFF - ok
                continue;
            } else {
                // GC is ON - bad
                if (PrintImages  ||  PrintGC) {
                    _objc_inform("IMAGES: rejecting %d images because %s doesn't support GC (no image_info)", infoCount, info[i].imageFilePath);
                }
                return "GC capability mismatch";
            }
        }
#else
        // 64-bit: no image_info means no objc at all
        image_info = _getObjcImageInfo(mhdr, _getImageSlide(mhdr), &size);
        if (!image_info) {
            // not objc - assume OK
            continue;
        }
#endif

        if (UseGC  &&  !_objcInfoSupportsGC(image_info)) {
            // GC is ON, but image does not support GC
            if (PrintImages  ||  PrintGC) {
                _objc_inform("IMAGES: rejecting %d images because %s doesn't support GC", infoCount, info[i].imageFilePath);
            }
            return "GC capability mismatch";
        }
        if (!UseGC  &&  _objcInfoRequiresGC(image_info)) {
            // GC is OFF, but image requires GC
            if (PrintImages  ||  PrintGC) {
                _objc_inform("IMAGES: rejecting %d images because %s requires GC", infoCount, info[i].imageFilePath);
            }
            return "GC capability mismatch";
        }
    }

    return NULL;
}


/***********************************************************************
* map_images
* Process the given images which are being mapped in by dyld.
* All class registration and fixups are performed (or deferred pending
* discovery of missing superclasses etc), and +load methods are called.
*
* info[] is in bottom-up order i.e. libobjc will be earlier in the 
* array than any library that links to libobjc.
**********************************************************************/
static const char *map_images(enum dyld_image_states state, uint32_t infoCount,
                              const struct dyld_image_info infoList[])
{
    static BOOL firstTime = YES;
    static BOOL wantsGC NOBSS = NO;
    uint32_t i;
    header_info *hInfo;
    header_info *hList[infoCount];
    uint32_t hCount;

    // Perform first-time initialization if necessary.
    // This function is called before ordinary library initializers. 
    if (firstTime) {
        extern SEL FwdSel;  // in objc-msg-*.s
        // workaround for rdar://5198739
        pthread_key_t unused;
        pthread_key_create(&unused, NULL);
        pthread_key_create(&_objc_pthread_key, _objc_pthread_destroyspecific);
        objc_setConfiguration();   // read environment variables
        // grab selectors for which @selector() doesn't work
        cxx_construct_sel = sel_registerName(cxx_construct_name);
        cxx_destruct_sel  = sel_registerName(cxx_destruct_name);
        FwdSel = sel_registerName("forward::");  // in objc-msg-*.s
        exception_init();

        InitialDyldRegistration = YES;
        dyld_register_image_state_change_handler(dyld_image_state_mapped, 0 /* batch */, &gc_enforcer);
        InitialDyldRegistration = NO;
    }

    if (PrintImages) {
        _objc_inform("IMAGES: processing %u newly-mapped images...\n", infoCount);
    }


    // Find all images with Objective-C metadata.
    hCount = 0;
    i = infoCount;
    while (i--) {
        const headerType *mhdr = (headerType *)infoList[i].imageLoadAddress;
        if (bad_magic(mhdr)) continue;

        hInfo = _objc_addHeader(mhdr);
        if (!hInfo) {
            // no objc data in this entry
            continue;
        }

        hList[hCount++] = hInfo;
        
        if (PrintImages) {
            _objc_inform("IMAGES: loading image for %s%s%s%s\n", 
                         _nameForHeader(mhdr), 
                         mhdr->filetype == MH_BUNDLE ? " (bundle)" : "", 
                         _objcHeaderIsReplacement(hInfo) ? " (replacement)":"",
                         _gcForHInfo2(hInfo));
        }
    }

    // Perform one-time runtime initialization that must be deferred until 
    // the executable itself is found. This needs to be done before 
    // further initialization.
    // (The executable may not be present in this infoList if the 
    // executable does not contain Objective-C code but Objective-C 
    // is dynamically loaded later. In that case, check_wants_gc() 
    // will do the right thing.)
    if (firstTime) {
        wantsGC = check_wants_gc();

        verify_gc_readiness(wantsGC, hList, hCount);
        
        gc_init(wantsGC);           // needs executable for GC decision
        rtp_init();                 // needs GC decision first
    } else {
        verify_gc_readiness(wantsGC, hList, hCount);
    }

    _read_images(hList, hCount);

    firstTime = NO;

    return NULL;
}


static const char *load_images(enum dyld_image_states state,uint32_t infoCount,
                               const struct dyld_image_info infoList[])
{
    BOOL found = NO;
    uint32_t i;

    i = infoCount;
    while (i--) {
        header_info *hi;
        for (hi = FirstHeader; hi != NULL; hi = hi->next) {
            const headerType *mhdr = (headerType*)infoList[i].imageLoadAddress;
            if (hi->mhdr == mhdr) {
                prepare_load_methods(hi);
                found = YES;
            }
        }
    }

    if (found) call_load_methods();

    return NULL;
}

/***********************************************************************
* unmap_image
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
**********************************************************************/
static void unmap_image(const struct mach_header *mh, intptr_t vmaddr_slide)
{
    if (PrintImages) {
        _objc_inform("IMAGES: processing 1 newly-unmapped image...\n");
    }

    header_info *hi;
    
    // Find the runtime's header_info struct for the image
    for (hi = FirstHeader; hi != NULL; hi = hi->next) {
        if (hi->mhdr == (const headerType *)mh) {
            _objc_unmap_image(hi);
            return;
        }
    }

    // no objc data for this image
}


/***********************************************************************
* _objc_init
* Static initializer. Registers our image notifier with dyld.
* fixme move map_images' firstTime code here - but GC code might need 
* another earlier image notifier
**********************************************************************/
static __attribute__((constructor))
void _objc_init(void)
{
    // Register for unmap first, in case some +load unmaps something
    _dyld_register_func_for_remove_image(&unmap_image);
    dyld_register_image_state_change_handler(dyld_image_state_bound,
                                             1/*batch*/, &map_images);
    dyld_register_image_state_change_handler(dyld_image_state_dependents_initialized, 0/*not batch*/, &load_images);
}


/***********************************************************************
* _objc_unmap_image.
* Destroy any Objective-C data for the given image, which is about to 
* be unloaded by dyld.
* Note: not thread-safe, but image loading isn't either.
**********************************************************************/
static void	_objc_unmap_image(header_info *hi) 
{
    if (PrintImages) { 
        _objc_inform("IMAGES: unloading image for %s%s%s%s\n", 
                     _nameForHeader(hi->mhdr), 
                     hi->mhdr->filetype == MH_BUNDLE ? " (bundle)" : "", 
                     _objcHeaderIsReplacement(hi) ? " (replacement)" : "", 
                     _gcForHInfo2(hi));
    }

    _unload_image(hi);

    // Remove header_info from header list
    _objc_removeHeader(hi);
}


/***********************************************************************
* _objc_setNilReceiver
**********************************************************************/
id _objc_setNilReceiver(id newNilReceiver)
{
    id oldNilReceiver;

    oldNilReceiver = _objc_nilReceiver;
    _objc_nilReceiver = newNilReceiver;

    return oldNilReceiver;
}

/***********************************************************************
* _objc_getNilReceiver
**********************************************************************/
id _objc_getNilReceiver(void)
{
    return _objc_nilReceiver;
}


/***********************************************************************
* objc_setForwardHandler
**********************************************************************/
void objc_setForwardHandler(void *fwd, void *fwd_stret)
{
    _objc_forward_handler = fwd;
    _objc_forward_stret_handler = fwd_stret;
}


#if defined(__ppc__)  ||  defined(__ppc64__)

// Test to see if either the displacement or destination is within 
// the +/- 2^25 range needed for a PPC branch immediate instruction.  
// Shifting the high bit of the displacement (or destination)
// left 6 bits and then 6 bits arithmetically to the right does a 
// sign extend of the 26th bit.  If that result is equivalent to the 
// original value, then the displacement (or destination) will fit
// into a simple branch.  Otherwise a larger branch sequence is required. 
// ppc64: max displacement is still +/- 2^25, but intptr_t is bigger

// tiny:  bc*
// small: b, ba (unconditional only)
// 32:    bctr with lis+ori only
static BOOL ppc_tiny_displacement(intptr_t displacement)
{
    size_t shift = sizeof(intptr_t) - 16;  // ilp32=16, lp64=48
    return (((displacement << shift) >> shift) == displacement);
}

static BOOL ppc_small_displacement(intptr_t displacement)
{
    size_t shift = sizeof(intptr_t) - 26;  // ilp32=6, lp64=38
    return (((displacement << shift) >> shift) == displacement);
}

#if defined(__ppc64__)
// Same as ppc_small_displacement, but decides whether 32 bits is big enough.
static BOOL ppc_32bit_displacement(intptr_t displacement)
{
    size_t shift = sizeof(intptr_t) - 32;
    return (((displacement << shift) >> shift) == displacement);
}
#endif

/**********************************************************************
* objc_branch_size
* Returns the number of instructions needed 
* for a branch from entry to target. 
**********************************************************************/
__private_extern__ size_t objc_branch_size(void *entry, void *target)
{
    return objc_cond_branch_size(entry, target, COND_ALWAYS);
}

__private_extern__ size_t 
objc_cond_branch_size(void *entry, void *target, unsigned cond)
{
    intptr_t destination = (intptr_t)target;
    intptr_t displacement = (intptr_t)destination - (intptr_t)entry;

    if (cond == COND_ALWAYS  &&  ppc_small_displacement(displacement)) {
        // fits in unconditional relative branch immediate
        return 1;
    } 
    if (cond == COND_ALWAYS  &&  ppc_small_displacement(destination)) {
        // fits in unconditional absolute branch immediate
        return 1;
    }
    if (ppc_tiny_displacement(displacement)) {
        // fits in conditional relative branch immediate
        return 1;
    } 
    if (ppc_tiny_displacement(destination)) {
        // fits in conditional absolute branch immediate
        return 1;
    }
#if defined(__ppc64__)
    if (!ppc_32bit_displacement(destination)) {
        // fits in 64-bit absolute branch through CTR
        return 7;
    }
#endif
    
    // fits in 32-bit absolute branch through CTR
    return 4;
}

/**********************************************************************
* objc_write_branch
* Writes at entry a PPC branch instruction sequence that branches to target.
* The sequence written will be objc_branch_size(entry, target) instructions.
* Returns the number of instructions written.
**********************************************************************/
__private_extern__ size_t objc_write_branch(void *entry, void *target) 
{
    return objc_write_cond_branch(entry, target, COND_ALWAYS);
}

__private_extern__ size_t 
objc_write_cond_branch(void *entry, void *target, unsigned cond) 
{
    unsigned *address = (unsigned *)entry;                              // location to store the 32 bit PPC instructions
    intptr_t destination = (intptr_t)target;                            // destination as an absolute address
    intptr_t displacement = (intptr_t)destination - (intptr_t)address;  // destination as a branch relative offset

    if (cond == COND_ALWAYS  &&  ppc_small_displacement(displacement)) {
        // use unconditional relative branch with the displacement
        address[0] = 0x48000000 | (unsigned)(displacement & 0x03fffffc); // b *+displacement
        // issued 1 instruction
        return 1;
    } 
    if (cond == COND_ALWAYS  &&  ppc_small_displacement(destination)) {
        // use unconditional absolute branch with the destination
        address[0] = 0x48000000 | (unsigned)(destination & 0x03fffffc) | 2; // ba destination (2 is the absolute flag)
        // issued 1 instruction
        return 1;
    }

    if (ppc_tiny_displacement(displacement)) {
        // use conditional relative branch with the displacement
        address[0] = 0x40000000 | cond | (unsigned)(displacement & 0x0000fffc); // b *+displacement
        // issued 1 instruction
        return 1;
    } 
    if (ppc_tiny_displacement(destination)) {
        // use conditional absolute branch with the destination
        address[0] = 0x40000000 | cond | (unsigned)(destination & 0x0000fffc) | 2; // ba destination (2 is the absolute flag)
        // issued 1 instruction
        return 1;
    }


    // destination is large and far away. 
    // Use an absolute branch via CTR.

#if defined(__ppc64__)
    if (!ppc_32bit_displacement(destination)) {
        uint16_t lo = destination & 0xffff;
        uint16_t hi = (destination >> 16) & 0xffff;
        uint16_t hi2 = (destination >> 32) & 0xffff;
        uint16_t hi3 = (destination >> 48) & 0xffff;
        
        address[0] = 0x3d800000 | hi3;   // lis  r12, hi3
        address[1] = 0x618c0000 | hi2;   // ori  r12, r12, hi2
        address[2] = 0x798c07c6;         // sldi r12, r12, 32
        address[3] = 0x658c0000 | hi;    // oris r12, r12, hi
        address[4] = 0x618c0000 | lo;    // ori  r12, r12, lo
        address[5] = 0x7d8903a6;         // mtctr r12
        address[6] = 0x4c000420 | cond;  // bctr
        // issued 7 instructions
        return 7;
    }
#endif

    {
        uint16_t lo = destination & 0xffff;
        uint16_t hi = (destination >> 16) & 0xffff;

        address[0] = 0x3d800000 | hi;               // lis r12,hi
        address[1] = 0x618c0000 | lo;               // ori r12,r12,lo
        address[2] = 0x7d8903a6;                    // mtctr r12
        address[3] = 0x4c000420 | cond;             // bctr
        // issued 4 instructions
        return 4;
    }
}

// defined(__ppc__)  ||  defined(__ppc64__)
#endif

#if defined(__i386__) || defined(__x86_64__)

/**********************************************************************
* objc_branch_size
* Returns the number of BYTES needed 
* for a branch from entry to target. 
**********************************************************************/
__private_extern__ size_t objc_branch_size(void *entry, void *target)
{
    return objc_cond_branch_size(entry, target, COND_ALWAYS);
}

__private_extern__ size_t 
objc_cond_branch_size(void *entry, void *target, unsigned cond)
{
    // For simplicity, always use 32-bit relative jumps.
    if (cond == COND_ALWAYS) return 5;
    else return 6;
}

/**********************************************************************
* objc_write_branch
* Writes at entry an i386 branch instruction sequence that branches to target.
* The sequence written will be objc_branch_size(entry, target) BYTES.
* Returns the number of BYTES written.
**********************************************************************/
__private_extern__ size_t objc_write_branch(void *entry, void *target) 
{
    return objc_write_cond_branch(entry, target, COND_ALWAYS);
}

__private_extern__ size_t 
objc_write_cond_branch(void *entry, void *target, unsigned cond) 
{
    uint8_t *address = (uint8_t *)entry;  // instructions written to here
    intptr_t destination = (intptr_t)target;  // branch dest as absolute address
    intptr_t displacement = (intptr_t)destination - ((intptr_t)address + objc_cond_branch_size(entry, target, cond)); // branch dest as relative offset
    
    // For simplicity, always use 32-bit relative jumps
    if (cond != COND_ALWAYS) {
        *address++ = 0x0f;  // Jcc prefix
    }
    *address++ = cond;
    *address++ = displacement & 0xff;
    *address++ = (displacement >> 8) & 0xff;
    *address++ = (displacement >> 16) & 0xff;
    *address++ = (displacement >> 24) & 0xff;

    return address - (uint8_t *)entry;
}

// defined __i386__
#endif


/**********************************************************************
* secure_open
* Securely open a file from a world-writable directory (like /tmp)
* If the file does not exist, it will be atomically created with mode 0600
* If the file exists, it must be, and remain after opening: 
*   1. a regular file (in particular, not a symlink)
*   2. owned by euid
*   3. permissions 0600
*   4. link count == 1
* Returns a file descriptor or -1. Errno may or may not be set on error.
**********************************************************************/
__private_extern__ int secure_open(const char *filename, int flags, uid_t euid)
{
    struct stat fs, ls;
    int fd = -1;
    BOOL truncate = NO;
    BOOL create = NO;

    if (flags & O_TRUNC) {
        // Don't truncate the file until after it is open and verified.
        truncate = YES;
        flags &= ~O_TRUNC;
    }
    if (flags & O_CREAT) {
        // Don't create except when we're ready for it
        create = YES;
        flags &= ~O_CREAT;
        flags &= ~O_EXCL;
    }

    if (lstat(filename, &ls) < 0) {
        if (errno == ENOENT  &&  create) {
            // No such file - create it
            fd = open(filename, flags | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                // File was created successfully.
                // New file does not need to be truncated.
                return fd;
            } else {
                // File creation failed.
                return -1;
            }
        } else {
            // lstat failed, or user doesn't want to create the file
            return -1;
        }
    } else {
        // lstat succeeded - verify attributes and open
        if (S_ISREG(ls.st_mode)  &&  // regular file?
            ls.st_nlink == 1  &&     // link count == 1?
            ls.st_uid == euid  &&    // owned by euid?
            (ls.st_mode & ALLPERMS) == (S_IRUSR | S_IWUSR))  // mode 0600?
        {
            // Attributes look ok - open it and check attributes again
            fd = open(filename, flags, 0000);
            if (fd >= 0) {
                // File is open - double-check attributes
                if (0 == fstat(fd, &fs)  &&  
                    fs.st_nlink == ls.st_nlink  &&  // link count == 1?
                    fs.st_uid == ls.st_uid  &&      // owned by euid?
                    fs.st_mode == ls.st_mode  &&    // regular file, 0600?
                    fs.st_ino == ls.st_ino  &&      // same inode as before?
                    fs.st_dev == ls.st_dev)         // same device as before?
                {
                    // File is open and OK
                    if (truncate) ftruncate(fd, 0);
                    return fd;
                } else {
                    // Opened file looks funny - close it
                    close(fd);
                    return -1;
                }
            } else {
                // File didn't open
                return -1;
            }
        } else {
            // Unopened file looks funny - don't open it
            return -1;
        }
    }
}


#if !__OBJC2__
// GrP fixme
extern Class _objc_getOrigClass(const char *name);
#endif
const char *class_getImageName(Class cls)
{
    int ok;
    Dl_info info;

    if (!cls) return NULL;

#if !__OBJC2__
    cls = _objc_getOrigClass(_class_getName(cls));
#endif

    ok = dladdr(cls, &info);
    if (ok) return info.dli_fname;
    else return NULL;
}


const char **objc_copyImageNames(unsigned int *outCount)
{
    header_info *hi;
    int count = 0;
    int max = HeaderCount;
    const char **names = calloc(max+1, sizeof(char *));
    
    for (hi = _objc_headerStart(); 
         hi != NULL && count < max; 
         hi = hi->next) 
    {
        if (hi->dl_info.dli_fname) {
            names[count++] = hi->dl_info.dli_fname;
        }
    }
    names[count] = NULL;
    
    if (count == 0) {
        // Return NULL instead of empty list if there are no images
        free(names);
        names = NULL;
    }

    if (outCount) *outCount = count;
    return names;
}


/**********************************************************************
*
**********************************************************************/
const char ** 
objc_copyClassNamesForImage(const char *image, unsigned int *outCount)
{
    header_info *hi;

    if (!image) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    // Find the image.
    for (hi = _objc_headerStart(); hi != NULL; hi = hi->next) {
        if (0 == strcmp(image, hi->dl_info.dli_fname)) break;
    }
    
    if (!hi) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    return _objc_copyClassNamesForImage(hi, outCount);
}
	

/**********************************************************************
* Fast Enumeration Support
**********************************************************************/

static void (*enumerationMutationHandler)(id);

/**********************************************************************
* objc_enumerationMutation
* called by compiler when a mutation is detected during foreach iteration
**********************************************************************/
void objc_enumerationMutation(id object) {
    if (enumerationMutationHandler == nil) {
        _objc_fatal("mutation detected during 'for(... in ...)'  enumeration of object %p.", object);
    }
    (*enumerationMutationHandler)(object);
}


/**********************************************************************
* objc_setEnumerationMutationHandler
* an entry point to customize mutation error handing
**********************************************************************/
void objc_setEnumerationMutationHandler(void (*handler)(id)) {
    enumerationMutationHandler = handler;
}
