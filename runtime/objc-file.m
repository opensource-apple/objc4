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

#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <string.h>
#include <stdlib.h>
#include <crt_externs.h>

#define OLD 1
#import "objc-private.h"

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
_getObjcModules(const headerType *head, ptrdiff_t slide, size_t *nmodules)
{
  size_t size;
  void *mods = 
      GETSECTDATAFROMHEADER(head, SEG_OBJC, SECT_OBJC_MODULES, &size);
#if !__OBJC2__
  *nmodules = size / sizeof(struct objc_module);
#endif
  if (mods) mods = (void *)((uintptr_t)mods + slide);
  return (Module)mods;
}

// fixme !objc2 only (used for new-abi paranoia)
__private_extern__ SEL *
_getObjcSelectorRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC, "__message_refs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->image_slide);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

#if !__OBJC2__

__private_extern__ struct old_protocol *
_getObjcProtocols(const header_info *hi, size_t *nprotos)
{
  size_t size;
  void *protos = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC, "__protocol", &size);
  *nprotos = size / sizeof(struct old_protocol);
  if (protos) protos = (struct old_protocol *)((uintptr_t)protos+hi->image_slide);
  return (struct old_protocol *)protos;
}

__private_extern__ struct old_class **
_getObjcClassRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC, "__cls_refs", &size);
  *nclasses = size / sizeof(struct old_class *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->image_slide);
  return (struct old_class **)classes;
}

// __OBJC,__class_names section only emitted by CodeWarrior  rdar://4951638
__private_extern__ const char *
_getObjcClassNames(const header_info *hi, size_t *size)
{
  void *names = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC, "__class_names", size);
  if (names) names = (void *)((uintptr_t)names + hi->image_slide);
  return (const char *)names;
}

#endif

#if __OBJC2__

__private_extern__ SEL *
_getObjc2SelectorRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_selrefs", &size);
  if (!refs) refs =
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC2, "__selector_refs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->image_slide);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

__private_extern__ message_ref *
_getObjc2MessageRefs(const header_info *hi, size_t *nmess)
{
  size_t size;
  void *refs = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_msgrefs", &size);
  if (!refs) refs =
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC2, "__message_refs", &size);
  if (refs) refs = (void *)((uintptr_t)refs + hi->image_slide);
  *nmess = size / sizeof(message_ref);
  return (message_ref *)refs;
}

__private_extern__ struct class_t **
_getObjc2ClassRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_classrefs", &size);
  if (!classes) classes =
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__class_refs", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2SuperRefs(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_superrefs", &size);
  if (!classes) classes =
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__super_refs", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2ClassList(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_classlist", &size);
  if (!classes) classes =
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__class_list", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct class_t **
_getObjc2NonlazyClassList(const header_info *hi, size_t *nclasses)
{
  size_t size;
  void *classes = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_nlclslist", &size);
  if (!classes) classes =
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__nonlazy_class", &size);
  *nclasses = size / sizeof(struct class_t *);
  if (classes) classes = (void *)((uintptr_t)classes + hi->image_slide);
  return (struct class_t **)classes;
}

__private_extern__ struct category_t **
_getObjc2CategoryList(const header_info *hi, size_t *ncats)
{
  size_t size;
  void *cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_catlist", &size);
  if (!cats) cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__category_list", &size);
  *ncats = size / sizeof(struct category_t *);
  if (cats) cats = (void *)((uintptr_t)cats + hi->image_slide);
  return (struct category_t **)cats;
}

__private_extern__ struct category_t **
_getObjc2NonlazyCategoryList(const header_info *hi, size_t *ncats)
{
  size_t size;
  void *cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_DATA, "__objc_nlcatlist", &size);
  if (!cats) cats = 
      GETSECTDATAFROMHEADER(hi->mhdr, SEG_OBJC2, "__nonlazy_catgry", &size);
  *ncats = size / sizeof(struct category_t *);
  if (cats) cats = (void *)((uintptr_t)cats + hi->image_slide);
  return (struct category_t **)cats;
}

__private_extern__ struct protocol_t **
_getObjc2ProtocolList(const header_info *hi, size_t *nprotos)
{
  size_t size;
  void *protos = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_protolist", &size);
  if (!protos) protos =
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC2, "__protocol_list", &size);
  *nprotos = size / sizeof(struct protocol_t *);
  if (protos) protos = (struct protocol_t **)((uintptr_t)protos+hi->image_slide);
  return (struct protocol_t **)protos;
}

__private_extern__ struct protocol_t **
_getObjc2ProtocolRefs(const header_info *hi, size_t *nprotos)
{
  size_t size;
  void *protos = 
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_DATA, "__objc_protorefs", &size);
  if (!protos) protos =
      GETSECTDATAFROMHEADER (hi->mhdr, SEG_OBJC2, "__protocol_refs", &size);
  *nprotos = size / sizeof(struct protocol_t *);
  if (protos) protos = (struct protocol_t **)((uintptr_t)protos+hi->image_slide);
  return (struct protocol_t **)protos;
}

#endif

__private_extern__ const segmentType *
getsegbynamefromheader(const headerType *head, const char *segname)
{
    const segmentType *sgp;
    unsigned long i;
    
    sgp = (const segmentType *) (head + 1);
    for (i = 0; i < head->ncmds; i++){
        if (sgp->cmd == SEGMENT_CMD) {
            if (strncmp(sgp->segname, segname, sizeof(sgp->segname)) == 0) {
                return sgp;
            }
        }
        sgp = (const segmentType *)((char *)sgp + sgp->cmdsize);
    }
    return NULL;
}

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
