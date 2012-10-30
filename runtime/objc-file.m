/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 1999-2003 Apple Computer, Inc.  All Rights Reserved.
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

#import "objc-private.h"
#import <mach-o/ldsyms.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#include <string.h>
#include <stdlib.h>

#import <crt_externs.h>


/* Returns an array of all the objc headers in the executable
 * Caller is responsible for freeing.
 */	
headerType **_getObjcHeaders()
{
  const struct mach_header **headers;
  headers = malloc(sizeof(struct mach_header *) * 2);
  headers[0] = (const struct mach_header *)_NSGetMachExecuteHeader();
  headers[1] = 0;
  return (headerType**)headers;
}

Module _getObjcModules(const headerType *head, int *nmodules)
{
  uint32_t size;
  void *mods = getsectdatafromheader((headerType *)head,
                                     SEG_OBJC,
				     SECT_OBJC_MODULES,
				     &size);
  *nmodules = size / sizeof(struct objc_module);
  return (Module)mods;
}

SEL *_getObjcMessageRefs(headerType *head, int *nmess)
{
  uint32_t size;
  void *refs = getsectdatafromheader ((headerType *)head,
				  SEG_OBJC, "__message_refs", &size);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

ProtocolTemplate *_getObjcProtocols(headerType *head, int *nprotos)
{
  uint32_t size;
  void *protos = getsectdatafromheader ((headerType *)head,
				 SEG_OBJC, "__protocol", &size);
  *nprotos = size / sizeof(ProtocolTemplate);
  return (ProtocolTemplate *)protos;
}

NXConstantStringTemplate *_getObjcStringObjects(headerType *head, int *nstrs)
{
  *nstrs = 0;
  return NULL;
}

Class *_getObjcClassRefs(headerType *head, int *nclasses)
{
  uint32_t size;
  void *classes = getsectdatafromheader ((headerType *)head,
				 SEG_OBJC, "__cls_refs", &size);
  *nclasses = size / sizeof(Class);
  return (Class *)classes;
}

objc_image_info *_getObjcImageInfo(const headerType *head, uint32_t *sizep)
{
  objc_image_info *info = (objc_image_info *)
      getsectdatafromheader(head, SEG_OBJC, "__image_info", sizep);
  return info;
}

const struct segment_command *getsegbynamefromheader(const headerType *head, 
                                                     const char *segname)
{
    const struct segment_command *sgp;
    unsigned long i;
    
    sgp = (const struct segment_command *) ((char *)head + sizeof(headerType));
    for (i = 0; i < head->ncmds; i++){
        if (sgp->cmd == LC_SEGMENT) {
            if (strncmp(sgp->segname, segname, sizeof(sgp->segname)) == 0) {
                return sgp;
            }
        }
        sgp = (const struct segment_command *)((char *)sgp + sgp->cmdsize);
    }
    return NULL;
}

static const headerType *_getExecHeader (void)
{
	return (const struct mach_header *)_NSGetMachExecuteHeader();
}

const char *_getObjcHeaderName(const headerType *header)
{
    const headerType *execHeader;
    const struct fvmlib_command *libCmd, *endOfCmds;
       
    if (header && ((headerType *)header)->filetype == MH_FVMLIB) {
	    execHeader = _getExecHeader();
	    for (libCmd = (const struct fvmlib_command *)(execHeader + 1),
		  endOfCmds = ((void *)libCmd) + execHeader->sizeofcmds;
		  libCmd < endOfCmds; ((void *)libCmd) += libCmd->cmdsize) {
		    if ((libCmd->cmd == LC_LOADFVMLIB) && (libCmd->fvmlib.header_addr
			    == (unsigned long)header)) {
			    return (char *)libCmd
				    + libCmd->fvmlib.name.offset;
		    }
	    }
	    return NULL;
   } else {
      unsigned long i, n = _dyld_image_count();
      for( i = 0; i < n ; i++ ) {
         if ( _dyld_get_image_header(i) == header )
            return _dyld_get_image_name(i);
      }

      return (*_NSGetArgv())[0];
   }
}


// 1. Find segment with file offset == 0 and file size != 0. This segment's 
//    contents span the Mach-O header. (File size of 0 is .bss, for example)
// 2. Slide is header's address - segment's preferred address
ptrdiff_t _getImageSlide(const headerType *header)
{
    int i;
    const struct segment_command *sgp = 
        (const struct segment_command *)(header + 1);

    for (i = 0; i < header->ncmds; i++){
        if (sgp->cmd == LC_SEGMENT) {
            if (sgp->fileoff == 0  &&  sgp->filesize != 0) {
                return (uintptr_t)header - (uintptr_t)sgp->vmaddr;
            }
        }
        sgp = (const struct segment_command *)((char *)sgp + sgp->cmdsize);
    }

    // uh-oh
    _objc_fatal("could not calculate VM slide for image '%s'", 
                _getObjcHeaderName(header));
    return 0;  // not reached
}
