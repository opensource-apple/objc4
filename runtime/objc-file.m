/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Portions Copyright (c) 1999 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.1 (the "License").  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON- INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
// Copyright 1988-1996 NeXT Software, Inc.

#import "objc-private.h"
#import <mach-o/ldsyms.h>
#import <mach-o/dyld.h>
#include <string.h>
#include <stdlib.h>

#import <crt_externs.h>

/* prototype coming soon to <mach-o/getsect.h> */
extern char *getsectdatafromheader(
    struct mach_header *mhp,
    char *segname,
    char *sectname,
    int *size);

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

Module _getObjcModules(headerType *head, int *nmodules)
{
  unsigned size;
  void *mods = getsectdatafromheader((headerType *)head,
                                     SEG_OBJC,
				     SECT_OBJC_MODULES,
				     &size);
  *nmodules = size / sizeof(struct objc_module);
  return (Module)mods;
}

SEL *_getObjcMessageRefs(headerType *head, int *nmess)
{
  unsigned size;
  void *refs = getsectdatafromheader ((headerType *)head,
				  SEG_OBJC, "__message_refs", &size);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

ProtocolTemplate *_getObjcProtocols(headerType *head, int *nprotos)
{
  unsigned size;
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
  unsigned size;
  void *classes = getsectdatafromheader ((headerType *)head,
				 SEG_OBJC, "__cls_refs", &size);
  *nclasses = size / sizeof(Class);
  return (Class *)classes;
}

/* returns start of all objective-c info and the size of the data */
void *_getObjcHeaderData(headerType *head, unsigned *size)
{
  struct segment_command *sgp;
  unsigned long i;
  
  sgp = (struct segment_command *) ((char *)head + sizeof(headerType));
  for(i = 0; i < ((headerType *)head)->ncmds; i++){
      if(sgp->cmd == LC_SEGMENT)
	  if(strncmp(sgp->segname, "__OBJC", sizeof(sgp->segname)) == 0) {
	    *size = sgp->filesize;
	    return (void*)sgp;
	    }
      sgp = (struct segment_command *)((char *)sgp + sgp->cmdsize);
  }
  *size = 0;
  return nil;
}

static const headerType *_getExecHeader (void)
{
	return (const struct mach_header *)_NSGetMachExecuteHeader();
}

const char *_getObjcHeaderName(headerType *header)
{
    const headerType *execHeader;
    const struct fvmlib_command *libCmd, *endOfCmds;
    char **argv;
    extern char ***_NSGetArgv();
    argv = *_NSGetArgv();
       
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
      return argv[0];
   }
}

