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
// Copyright 1988-1996 NeXT Software, Inc.

#define OLD 1
#include "objc-private.h"

#if TARGET_OS_WIN32

__private_extern__ const char *_getObjcHeaderName(const headerType *head)
{
    return "??";
}

/*
__private_extern__ Module 
_getObjcModules(const header_info *hi, size_t *nmodules)
{
    if (nmodules) *nmodules = hi->os.moduleCount;
    return hi->os.modules;
}
*/
__private_extern__ SEL *
_getObjcSelectorRefs(const header_info *hi, size_t *nmess)
{
    if (nmess) *nmess = hi->os.selrefCount;
    return hi->os.selrefs;
}

__private_extern__ struct old_protocol **
_getObjcProtocols(const header_info *hi, size_t *nprotos)
{
    if (nprotos) *nprotos = hi->os.protocolCount;
    return hi->os.protocols;
}

__private_extern__ struct old_class **
_getObjcClassRefs(const header_info *hi, size_t *nclasses)
{
    if (nclasses) *nclasses = hi->os.clsrefCount;
    return (struct old_class **)hi->os.clsrefs;
}

// __OBJC,__class_names section only emitted by CodeWarrior  rdar://4951638
__private_extern__ const char *
_getObjcClassNames(const header_info *hi, size_t *size)
{
    if (size) *size = 0;
    return NULL;
}

#else

#ifndef __LP64__
#define SEGMENT_CMD LC_SEGMENT
#define GETSECTDATAFROMHEADER(mh, seg, sect, sizep) \
    getsectdatafromheader(mh, seg, sect, (uint32_t *)sizep)
#else
#define SEGMENT_CMD LC_SEGMENT_64
#define GETSECTDATAFROMHEADER(mh, seg, sect, sizep) \
    getsectdatafromheader_64(mh, seg, sect, (uint64_t *)sizep)
#endif

__private_extern__ objc_image_info *
_getObjcImageInfo(const headerType *head, ptrdiff_t slide, size_t *sizep)
{
  objc_image_info *info = (objc_image_info *)
#if __OBJC2__
      GETSECTDATAFROMHEADER(head, SEG_DATA, "__objc_imageinfo", sizep);
  if (!info) info = (objc_image_info *)
#endif
      GETSECTDATAFROMHEADER(head, SEG_OBJC, "__image_info", sizep);
  // size is BYTES, not count!
  if (info) info = (objc_image_info *)((uintptr_t)info + slide);
  return info;
}

// fixme !objc2 only (used for new-abi paranoia)
__private_extern__ Module 
_getObjcModules(const header_info *hi, size_t *nmodules)
{
  size_t size;
  void *mods = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC, SECT_OBJC_MODULES, &size);
#if !__OBJC2__
  *nmodules = size / sizeof(struct objc_module);
#endif
  if (mods) mods = (void *)((uintptr_t)mods + hi->os.image_slide);
  return (Module)mods;
}

// fixme !objc2 only (used for new-abi paranoia)
__private_extern__ SEL *
_getObjcSelectorRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC, "__message_refs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->os.image_slide);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

#if !__OBJC2__

__private_extern__ BOOL
_hasObjcContents(const header_info *hi)
{
    // Look for an __OBJC,* section other than __OBJC,__image_info
    const segmentType *seg = hi->os.objcSegmentHeader;
    const sectionType *sect;
    uint32_t i;
    for (i = 0; i < seg->nsects; i++) {
        sect = ((const sectionType *)(seg+1))+i;
        if (0 != strncmp(sect->sectname, "__image_info", 12)) {
            return YES;
        }
    }

    return NO;
}

__private_extern__ struct old_protocol **
_getObjcProtocols(const header_info *hi, size_t *nprotos)
{
    size_t size;
    struct old_protocol *protos = (struct old_protocol *)
        GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC, "__protocol", &size);
    *nprotos = size / sizeof(struct old_protocol);
    if (protos) protos = (struct old_protocol *)((uintptr_t)protos+hi->os.image_slide);
    
    if (!hi->os.proto_refs  &&  *nprotos) {
        size_t i;
        header_info *whi = (header_info *)hi;
        whi->os.proto_refs = malloc(*nprotos * sizeof(*hi->os.proto_refs));
        for (i = 0; i < *nprotos; i++) {
            hi->os.proto_refs[i] = protos+i;
        }
    }
    
    return hi->os.proto_refs;
}

__private_extern__ struct old_class **
_getObjcClassRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC, "__cls_refs", &size);
  *nclasses = size / sizeof(struct old_class *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->os.image_slide);
  return (struct old_class **)classes;
}

// __OBJC,__class_names section only emitted by CodeWarrior  rdar://4951638
__private_extern__ const char *
_getObjcClassNames(const header_info *hi, size_t *size)
{
  void *names = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC, "__class_names", size);
  if (names) names = (void *)((uintptr_t)names + hi->os.image_slide);
  return (const char *)names;
}

#endif

#if __OBJC2__

__private_extern__ BOOL
_hasObjcContents(const header_info *hi)
{
    // Look for a __DATA,__objc* section other than __DATA,__objc_imageinfo
    const segmentType *seg = hi->os.dataSegmentHeader;
    const sectionType *sect;
    uint32_t i;
    for (i = 0; i < seg->nsects; i++) {
        sect = ((const sectionType *)(seg+1))+i;
        if (0 == strncmp(sect->sectname, "__objc_", 7)  &&  
            0 != strncmp(sect->sectname, "__objc_imageinfo", 16)) 
        {
            return YES;
        }
    }

    return NO;
}

__private_extern__ SEL *
_getObjc2SelectorRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_selrefs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->os.image_slide);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

__private_extern__ message_ref *
_getObjc2MessageRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_msgrefs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->os.image_slide);
  *nmess = size / sizeof(message_ref);
  return (message_ref *)refs;
}

__private_extern__ struct class_t **
_getObjc2ClassRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_classrefs", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->os.image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2SuperRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_superrefs", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->os.image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2ClassList(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_classlist", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->os.image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2NonlazyClassList(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_nlclslist", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->os.image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct category_t **
_getObjc2CategoryList(const header_info *hi, size_t *ncats)
{
  size_t size;
  void *cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_catlist", &size);
  *ncats = size / sizeof(struct category_t *);
  if (cats) cats = (void *)((uintptr_t)cats + hi->os.image_slide);
  return (struct category_t **)cats;
}

__private_extern__ struct category_t **
_getObjc2NonlazyCategoryList(const header_info *hi, size_t *ncats)
{
  size_t size;
  void *cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_nlcatlist", &size);
  *ncats = size / sizeof(struct category_t *);
  if (cats) cats = (void *)((uintptr_t)cats + hi->os.image_slide);
  return (struct category_t **)cats;
}

__private_extern__ struct protocol_t **
_getObjc2ProtocolList(const header_info *hi, size_t *nprotos)
{
  size_t size;
  void *protos = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_protolist", &size);
  *nprotos = size / sizeof(struct protocol_t *);
  if (protos) protos = (struct protocol_t **)((uintptr_t)protos+hi->os.image_slide);
  return (struct protocol_t **)protos;
}

__private_extern__ struct protocol_t **
_getObjc2ProtocolRefs(const header_info *hi, size_t *nprotos)
{
  size_t size;
  void *protos = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_protorefs", &size);
  *nprotos = size / sizeof(struct protocol_t *);
  if (protos) protos = (struct protocol_t **)((uintptr_t)protos+hi->os.image_slide);
  return (struct protocol_t **)protos;
}

#endif

__private_extern__ const char *
_getObjcHeaderName(const headerType *header)
{
    Dl_info info;

    if (dladdr(header, &info)) {
        return info.dli_fname;
    }
    else {
        return (*_NSGetArgv())[0];
    }
}


// 1. Find segment with file offset == 0 and file size != 0. This segment's 
//    contents span the Mach-O header. (File size of 0 is .bss, for example)
// 2. Slide is header's address - segment's preferred address
__private_extern__ ptrdiff_t 
_getImageSlide(const headerType *header)
{
    unsigned long i;
    const segmentType *sgp = (const segmentType *)(header + 1);

    for (i = 0; i < header->ncmds; i++){
        if (sgp->cmd == SEGMENT_CMD) {
            if (sgp->fileoff == 0  &&  sgp->filesize != 0) {
                return (uintptr_t)header - (uintptr_t)sgp->vmaddr;
            }
        }
        sgp = (const segmentType *)((char *)sgp + sgp->cmdsize);
    }

    // uh-oh
    _objc_fatal("could not calculate VM slide for image '%s'", 
                _getObjcHeaderName(header));
    return 0;  // not reached
}


#endif
