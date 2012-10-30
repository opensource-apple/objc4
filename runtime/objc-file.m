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

#if defined(__APPLE__) && defined(__MACH__)
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
#if !defined(NeXT_PDO)
    extern char ***_NSGetArgv();
    argv = *_NSGetArgv();
#else
    extern char **NXArgv;
    argv = NXArgv;
#endif
       
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

#elif defined(hpux) || defined(__hpux__)

/* 
 *      Objective-C runtime information module.
 *      This module is specific to hp-ux a.out format files.
 */

#import <pdo.h>	// place where padding_bug would be
#include <a.out.h>
#include "objc-private.h"

OBJC_EXPORT int __argc_value;
OBJC_EXPORT char **__argv_value;
int NXArgc = 0;
char **NXArgv = NULL;

OBJC_EXPORT unsigned SEG_OBJC_CLASS_START;
OBJC_EXPORT unsigned SEG_OBJC_METACLASS_START;
OBJC_EXPORT unsigned SEG_OBJC_CAT_CLS_METH_START;
OBJC_EXPORT unsigned SEG_OBJC_CAT_INST_METH_START;
OBJC_EXPORT unsigned SEG_OBJC_CLS_METH_START;
OBJC_EXPORT unsigned SEG_OBJC_INST_METHODS_START;
OBJC_EXPORT unsigned SEG_OBJC_MESSAGE_REFS_START;
OBJC_EXPORT unsigned SEG_OBJC_SYMBOLS_START;
OBJC_EXPORT unsigned SEG_OBJC_CATEGORY_START;
OBJC_EXPORT unsigned SEG_OBJC_PROTOCOL_START;
OBJC_EXPORT unsigned SEG_OBJC_CLASS_VARS_START;
OBJC_EXPORT unsigned SEG_OBJC_INSTANCE_VARS_START;
OBJC_EXPORT unsigned SEG_OBJC_MODULES_START;
OBJC_EXPORT unsigned SEG_OBJC_STRING_OBJECT_START;
OBJC_EXPORT unsigned SEG_OBJC_CLASS_NAMES_START;
OBJC_EXPORT unsigned SEG_OBJC_METH_VAR_NAMES_START;
OBJC_EXPORT unsigned SEG_OBJC_METH_VAR_TYPES_START;
OBJC_EXPORT unsigned SEG_OBJC_CLS_REFS_START;

OBJC_EXPORT unsigned SEG_OBJC_CLASS_END;
OBJC_EXPORT unsigned SEG_OBJC_METACLASS_END;
OBJC_EXPORT unsigned SEG_OBJC_CAT_CLS_METH_END;
OBJC_EXPORT unsigned SEG_OBJC_CAT_INST_METH_END;
OBJC_EXPORT unsigned SEG_OBJC_CLS_METH_END;
OBJC_EXPORT unsigned SEG_OBJC_INST_METHODS_END;
OBJC_EXPORT unsigned SEG_OBJC_MESSAGE_REFS_END;
OBJC_EXPORT unsigned SEG_OBJC_SYMBOLS_END;
OBJC_EXPORT unsigned SEG_OBJC_CATEGORY_END;
OBJC_EXPORT unsigned SEG_OBJC_PROTOCOL_END;
OBJC_EXPORT unsigned SEG_OBJC_CLASS_VARS_END;
OBJC_EXPORT unsigned SEG_OBJC_INSTANCE_VARS_END;
OBJC_EXPORT unsigned SEG_OBJC_MODULES_END;
OBJC_EXPORT unsigned SEG_OBJC_STRING_OBJECT_END;
OBJC_EXPORT unsigned SEG_OBJC_CLASS_NAMES_END;
OBJC_EXPORT unsigned SEG_OBJC_METH_VAR_NAMES_END;
OBJC_EXPORT unsigned SEG_OBJC_METH_VAR_TYPES_END;
OBJC_EXPORT unsigned SEG_OBJC_CLS_REFS_END;

typedef struct	_simple_header_struct {
	char * 	subspace_name	;
	void *	start_address	;
	void *	end_address	;
	} simple_header_struct ;

static simple_header_struct our_objc_header[] = {
	{ "$$OBJC_CLASS$$", 		&SEG_OBJC_CLASS_START, 		&SEG_OBJC_CLASS_END },
	{ "$$OBJC_METACLASS$$", 	&SEG_OBJC_METACLASS_START, 	&SEG_OBJC_METACLASS_END },
	{ "$$OBJC_CAT_CLS_METH$$",	&SEG_OBJC_CAT_CLS_METH_START, 	&SEG_OBJC_CAT_CLS_METH_END },
	{ "$$OBJC_CAT_INST_METH$$", 	&SEG_OBJC_CAT_INST_METH_START, 	&SEG_OBJC_CAT_INST_METH_END },
	{ "$$OBJC_CLS_METH$$", 		&SEG_OBJC_CLS_METH_START, 	&SEG_OBJC_CLS_METH_END },
	{ "$$OBJC_INST_METHODS$$",	&SEG_OBJC_INST_METHODS_START, 	&SEG_OBJC_INST_METHODS_END },
	{ "$$OBJC_MESSAGE_REFS$$",	&SEG_OBJC_MESSAGE_REFS_START, 	&SEG_OBJC_MESSAGE_REFS_END },
	{ "$$OBJC_SYMBOLS$$", 		&SEG_OBJC_SYMBOLS_START, 	&SEG_OBJC_SYMBOLS_END },
	{ "$$OBJC_CATEGORY$$", 		&SEG_OBJC_CATEGORY_START, 	&SEG_OBJC_CATEGORY_END },
	{ "$$OBJC_PROTOCOL$$", 		&SEG_OBJC_PROTOCOL_START, 	&SEG_OBJC_PROTOCOL_END },
	{ "$$OBJC_CLASS_VARS$$", 	&SEG_OBJC_CLASS_VARS_START, 	&SEG_OBJC_CLASS_VARS_END },
	{ "$$OBJC_INSTANCE_VARS$$", 	&SEG_OBJC_INSTANCE_VARS_START, 	&SEG_OBJC_INSTANCE_VARS_END },
	{ "$$OBJC_MODULES$$", 		&SEG_OBJC_MODULES_START, 	&SEG_OBJC_MODULES_END },
	{ "$$OBJC_STRING_OBJECT$$", 	&SEG_OBJC_STRING_OBJECT_START, 	&SEG_OBJC_STRING_OBJECT_END },
	{ "$$OBJC_CLASS_NAMES$$", 	&SEG_OBJC_CLASS_NAMES_START, 	&SEG_OBJC_CLASS_NAMES_END },
	{ "$$OBJC_METH_VAR_NAMES$$", 	&SEG_OBJC_METH_VAR_TYPES_START, &SEG_OBJC_METH_VAR_NAMES_END },
	{ "$$OBJC_METH_VAR_TYPES$$",	&SEG_OBJC_METH_VAR_TYPES_START, &SEG_OBJC_METH_VAR_TYPES_END },
	{ "$$OBJC_CLS_REFS$$", 		&SEG_OBJC_CLS_REFS_START, 	&SEG_OBJC_CLS_REFS_END },
	{ NULL, NULL, NULL }
	};

/* Returns an array of all the objc headers in the executable (and shlibs)
 * Caller is responsible for freeing.
 */
headerType **_getObjcHeaders()
{

  /* Will need to fill in with any shlib info later as well.  Need more
   * info on this.
   */
  
  /*
   *	this is truly ugly, hpux does not map in the header so we have to
   * 	try and find it and map it in.  their crt0 has some global vars
   *    that hold argv[0] which we will use to find the executable file
   */

  headerType **hdrs = (headerType**)malloc(2 * sizeof(headerType*));
  NXArgv = __argv_value;
  NXArgc = __argc_value;
  hdrs[0] = &our_objc_header;
  hdrs[1] = 0;
  return hdrs;
}

// I think we are getting the address of the table (ie the table itself) 
//	isn't that expensive ?
static void *getsubspace(headerType *objchead, char *sname, unsigned *size)
{
	simple_header_struct *table = (simple_header_struct *)objchead;
	int i = 0;

	while (  table[i].subspace_name){
		if (!strcmp(table[i].subspace_name, sname)){
			*size = table[i].end_address - table[i].start_address;
			return table[i].start_address;
		}
		i++;
	}
	*size = 0;
	return nil;
}

Module _getObjcModules(headerType *head, int *nmodules)
{
  unsigned size;
  void *mods = getsubspace(head,"$$OBJC_MODULES$$",&size);
  *nmodules = size / sizeof(struct objc_module);
  return (Module)mods;
}

SEL *_getObjcMessageRefs(headerType *head, int *nmess)
{
  unsigned size;
  void *refs = getsubspace (head,"$$OBJC_MESSAGE_REFS$$", &size);
  *nmess = size / sizeof(SEL);
  return (SEL *)refs;
}

struct proto_template *_getObjcProtocols(headerType *head, int *nprotos)
{
  unsigned size;
  char *p;
  char *end;
  char *start;

  start = getsubspace (head,"$$OBJC_PROTOCOL$$", &size);

#ifdef PADDING_BUG
  /*
   * XXX: Look for padding of 4 zero bytes and remove it.
   * XXX: Depends upon first four bytes of a proto_template never being 0.
   * XXX: Somebody should check to see if this is really the case.
   */
  end = start + size;
  for (p = start; p < end; p += sizeof(struct proto_template)) {
      if (!p[0] && !p[1] && !p[2] && !p[3]) {
          memcpy(p, p + sizeof(long), (end - p) - sizeof(long));
          end -= sizeof(long);
      }
  }
  size = end - start;
#endif
  *nprotos = size / sizeof(struct proto_template);
  return ((struct proto_template *)start);
}

NXConstantStringTemplate *_getObjcStringObjects(headerType *head, int *nstrs)
{
  unsigned size;
  void *str = getsubspace (head,"$$OBJC_STRING_OBJECT$$", &size);
  *nstrs = size / sizeof(NXConstantStringTemplate);
  return (NXConstantStringTemplate *)str;
}

Class *_getObjcClassRefs(headerType *head, int *nclasses)
{
  unsigned size;
  void *classes = getsubspace (head,"$$OBJC_CLS_REFS$$", &size);
  *nclasses = size / sizeof(Class);
  return (Class *)classes;
}

/* returns start of all objective-c info and the size of the data */
void *_getObjcHeaderData(headerType *head, unsigned *size)
{
#warning _getObjcHeaderData not implemented yet
  *size = 0;
  return nil;
}


const char *_getObjcHeaderName(headerType *header)
{
  return "oh poo";
}

#else

/* 
 *      Objective-C runtime information module.
 *      This module is generic for all object format files.
 */

#import <pdo.h>
#import <Protocol.h>
#import "objc-private.h"
#if defined(WIN32)
    #import <stdlib.h>
#endif

int		NXArgc = 0;
char	**	NXArgv = NULL;


char ***_NSGetArgv(void)
{
	return &NXArgv;
}

int *_NSGetArgc(void)
{
	return &NXArgc;

}

#if defined(WIN32)
    OBJC_EXPORT char ***_environ_dll;
#elif defined(NeXT_PDO)
    OBJC_EXPORT char ***environ;
#endif

char ***_NSGetEnviron(void)
{
#if defined(WIN32)
	return (char ***)_environ_dll;
#elif defined(NeXT_PDO)
	return (char ***)&environ;
#else
        #warning "_NSGetEnviron() is unimplemented for this architecture"
	return (char ***)NULL;
#endif
}


#if !defined(__hpux__) && !defined(hpux) && !defined(__osf__) 
    const char OBJC_METH_VAR_NAME_FORWARD[10]="forward::";
#else
    OBJC_EXPORT char OBJC_METH_VAR_NAME_FORWARD[];
#endif

static objcSectionStruct objcHeaders = {0,0,sizeof(objcModHeader)};
objcModHeader *CMH = 0;  // Current Module Header

int _objcModuleCount() {
   return objcHeaders.count;
}

const char *_objcModuleNameAtIndex(int i) {
   if ( i < 0 || i >= objcHeaders.count)
      return NULL;
   return ((objcModHeader*)objcHeaders.data + i)->name;
}

static inline void allocElements (objcSectionStruct *ptr, int nelmts)
{
    if (ptr->data == 0) {
        ptr->data = (void*)malloc ((ptr->count+nelmts) * ptr->size);
    } else {
        volatile void *tempData = (void *)realloc(ptr->data, (ptr->count+nelmts) * ptr->size);
        ptr->data = (void **)tempData;
    }

    bzero((char*)ptr->data + ptr->count * ptr->size, ptr->size * nelmts);
}

OBJC_EXPORT void _objcInit(void);
void objc_finish_header (void)
{
     _objcInit ();
     CMH = (objcModHeader *)0;
     // leaking like a stuck pig.
}

void objc_register_header_name (const char * name) {
    if (name) {
        CMH->name = malloc(strlen(name)+1);
#if defined(WIN32) || defined(__svr4__)
		bzero(CMH->name, (strlen(name)+1));
#endif 
        strcpy(CMH->name, name);
    }
}

void objc_register_header (const char * name)
{
    if (CMH) {
      	// we've already registered a header (probably via __objc_execClass), 
	// so just update the name.
       if (CMH->name)
         free(CMH->name);
    } else {
        allocElements (&objcHeaders, 1);
        CMH = (objcModHeader *)objcHeaders.data + objcHeaders.count;
        objcHeaders.count++;
        bzero(CMH, sizeof(objcModHeader));

        CMH->Modules.size       = sizeof(struct objc_module);
        CMH->Classes.size       = sizeof(void *);
        CMH->Protocols.size     = sizeof(void *);
        CMH->StringObjects.size = sizeof(void *);
    }
    objc_register_header_name(name);
}

#if defined(DEBUG)
void printModule(Module mod)
{
    printf("name=\"%s\", symtab=%x\n", mod->name, mod->symtab);
}

void dumpModules(void)
{
    int i,j;
    Module mod;
    objcModHeader *cmh;

    printf("dumpModules(): found %d header(s)\n", objcHeaders.count);
    for (j=0; j<objcHeaders.count; ++j) {
	        cmh = (objcModHeader *)objcHeaders.data + j;

	printf("===%s, found %d modules\n", cmh->name, cmh->Modules.count);


	mod = (Module)cmh->Modules.data;
    
	for (i=0; i<cmh->Modules.count; i++) {
		    printf("\tname=\"%s\", symtab=%x, sel_ref_cnt=%d\n", mod->name, mod->symtab, (Symtab)(mod->symtab)->sel_ref_cnt);
	    mod++;
	}
    }
}
#endif  // DEBUG

static inline void addObjcProtocols(struct objc_protocol_list * pl)
{
   if ( !pl )
      return;
   else {
      int count = 0;
      struct objc_protocol_list *list = pl;
      while ( list ) {
         count += list->count;
         list = list->next;
      }
      allocElements( &CMH->Protocols, count );

      list = pl;
      while ( list ) {
         int i = 0;
         while ( i < list->count )
            CMH->Protocols.data[ CMH->Protocols.count++ ] = (void*) list->list[i++];
         list = list->next;
      }

      list = pl;
      while ( list ) {
         int i = 0;
         while ( i < list->count )
            addObjcProtocols( ((ProtocolTemplate*)list->list[i++])->protocol_list );
         list = list->next;
      }
   }
}

static void
_parseObjcModule(struct objc_symtab *symtab)
{
    int i=0, j=0, k;
    SEL *refs = symtab->refs, sel;


    // Add the selector references

    if (refs)
    {
        symtab->sel_ref_cnt = 0;

        while (*refs)
        {
            symtab->sel_ref_cnt++;
            // don't touvh the VM page if not necessary
            if ( (sel = sel_registerNameNoCopy ((const char *)*refs)) != *refs ) {
                *refs = sel;
            }
            refs++;
        }
    }

    // Walk through all of the ObjC Classes

    if ((k = symtab->cls_def_cnt))
      {
	allocElements (&CMH->Classes, k);

	for ( i=0, j = symtab->cls_def_cnt; i < j; i++ )
	  {
	    struct objc_class       *class;
 	    unsigned loop;
	    
	    class  = (struct objc_class *)symtab->defs[i];
	    objc_addClass(class);
	    CMH->Classes.data[ CMH->Classes.count++ ] = (void*) class->name;
	    addObjcProtocols (class->protocols);

            // ignore fixing up the selectors to be unique (for now; done lazily later)

	  }
      }

    // Walk through all of the ObjC Categories

    if ((k = symtab->cat_def_cnt))
      {
	allocElements (&CMH->Classes, k);

	for ( j += symtab->cat_def_cnt;
	     i < j;
	     i++ )
	  {
	    struct objc_category       *category;
	    
	    category  = (struct objc_category *)symtab->defs[i];
	    CMH->Classes.data[ CMH->Classes.count++ ] = 
		(void*) category->class_name;

	    addObjcProtocols (category->protocols);

            // ignore fixing the selectors to be unique
            // this is now done lazily upon use
	    //_objc_inlined_fixup_selectors_in_method_list(category->instance_methods);
	    //_objc_inlined_fixup_selectors_in_method_list(category->class_methods);
	  }
      }


    // Walk through all of the ObjC Static Strings

    if ((k = symtab->obj_defs))
      {
	allocElements (&CMH->StringObjects, k);

	for ( j += symtab->obj_defs;
	     i < j;
	     i++ )
	  {
	    NXConstantStringTemplate *string = ( NXConstantStringTemplate *)symtab->defs[i];
	    CMH->StringObjects.data[ CMH->StringObjects.count++ ] = 
		(void*) string;
	  }
      }

    // Walk through all of the ObjC Static Protocols

    if ((k = symtab->proto_defs))
      {
	allocElements (&CMH->Protocols, k);

	for ( j += symtab->proto_defs;
	     i < j;
	     i++ )
	  {
	    ProtocolTemplate *proto = ( ProtocolTemplate *)symtab->defs[i];
            allocElements (&CMH->Protocols, 1);
	    CMH->Protocols.data[ CMH->Protocols.count++ ] = 
		(void*) proto;

	    addObjcProtocols(proto->protocol_list);
	  }
      }
}

// used only as a dll initializer on Windows and/or hppa (!)
void __objc_execClass(Module mod)
{
    sel_registerName ((const char *)OBJC_METH_VAR_NAME_FORWARD);

    if (CMH == 0) {
	    objc_register_header(NXArgv ? NXArgv[0] : "");
    }

    allocElements (&CMH->Modules, 1);

    memcpy( (Module)CMH->Modules.data 
                  + CMH->Modules.count,
	    mod,
	    sizeof(struct objc_module));
    CMH->Modules.count++;

    _parseObjcModule(mod->symtab);
}

const char * NSModulePathForClass(Class cls)
{
#if defined(WIN32)
    int i, j, k;

    for (i = 0; i < objcHeaders.count; i++) {
	volatile objcModHeader *aHeader = (objcModHeader *)objcHeaders.data + i;
	for (j = 0; j < aHeader->Modules.count; j++) {
	    Module mod = (void *)(aHeader->Modules.data) + j * aHeader->Modules.size;
	    struct objc_symtab *symtab = mod->symtab;
	    for (k = 0; k < symtab->cls_def_cnt; k++) {
		if (cls == (Class)symtab->defs[k])
		    return aHeader->name;
	    }
	}
    }
#else
    #warning "NSModulePathForClass is not fully implemented!"
#endif
    return NULL;
}

unsigned int _objc_goff_headerCount (void)
{
    return objcHeaders.count;
}

/* Build the header vector, of all headers seen so far. */

struct header_info *_objc_goff_headerVector ()
{
  unsigned int hidx;
  struct header_info *hdrVec;

  hdrVec = malloc_zone_malloc (_objc_create_zone(),
                         objcHeaders.count * sizeof (struct header_info));
#if defined(WIN32) || defined(__svr4__)
  bzero(hdrVec, (objcHeaders.count * sizeof (struct header_info)));
#endif

  for (hidx = 0; hidx < objcHeaders.count; hidx++)
    {
      objcModHeader *aHeader = (objcModHeader *)objcHeaders.data + hidx;
 
      hdrVec[hidx].mhdr = (headerType**) aHeader;
      hdrVec[hidx].mod_ptr = (Module)(aHeader->Modules.data);
    }
  return hdrVec;
}


#if defined(sparc)
    int __NXArgc = 0;
    char ** __NXArgv = 0;  
#endif 

/* Returns an array of all the objc headers in the executable (and shlibs)
 * Caller is responsible for freeing.
 */
headerType **_getObjcHeaders()
{
								   
#if defined(__hpux__) || defined(hpux)
    OBJC_EXPORT int __argc_value;
    OBJC_EXPORT char ** __argv_value;
#endif

  /* Will need to fill in with any shlib info later as well.  Need more
   * info on this.
   */
  
  headerType **hdrs = (headerType**)malloc(2 * sizeof(headerType*));
#if defined(WIN32) || defined(__svr4__)
  bzero(hdrs, (2 * sizeof(headerType*)));
#endif
#if defined(__hpux__) || defined(hpux)
  NXArgv = __argv_value;
  NXArgc = __argc_value;
#else /* __hpux__ || hpux */
#if defined(sparc) 
  NXArgv = __NXArgv;
  NXArgc = __NXArgc;
#endif /* sparc */
#endif /* __hpux__ || hpux */

  hdrs[0] = (headerType*)CMH;
  hdrs[1] = 0;
  return hdrs;
}

static objcModHeader *_getObjcModHeader(headerType *head)
{
	return (objcModHeader *)head;
}
 
Module _getObjcModules(headerType *head, int *size)
{
    objcModHeader *modHdr = _getObjcModHeader(head);
    if (modHdr) {
	*size = modHdr->Modules.count;
	return (Module)(modHdr->Modules.data);
    }
    else {
	*size = 0;
	return (Module)0;
    }
}

ProtocolTemplate **_getObjcProtocols(headerType *head, int *nprotos)
{
    objcModHeader *modHdr = _getObjcModHeader(head);

    if (modHdr) {
	*nprotos = modHdr->Protocols.count;
	return (ProtocolTemplate **)modHdr->Protocols.data;
    }
    else {
	*nprotos = 0;
	return (ProtocolTemplate **)0;
    }
}


NXConstantStringTemplate **_getObjcStringObjects(headerType *head, int *nstrs)
{
    objcModHeader *modHdr = _getObjcModHeader(head);

    if (modHdr) {
	*nstrs = modHdr->StringObjects.count;
	return (NXConstantStringTemplate **)modHdr->StringObjects.data;
    }
    else {
	*nstrs = 0;
	return (NXConstantStringTemplate **)0;
    }
}

Class *_getObjcClassRefs(headerType *head, int *nclasses)
{
    objcModHeader *modHdr = _getObjcModHeader(head);

    if (modHdr) {
	*nclasses = modHdr->Classes.count;
	return (Class *)modHdr->Classes.data;
    }
    else {
	*nclasses = 0;
	return (Class *)0;
    }
}

/* returns start of all objective-c info and the size of the data */
void *_getObjcHeaderData(headerType *head, unsigned *size)
{
  *size = 0;
  return NULL;
}

SEL *_getObjcMessageRefs(headerType *head, int *nmess)
{
  *nmess = 0;
  return (SEL *)NULL;
}

const char *_getObjcHeaderName(headerType *header)
{
  return "InvalidHeaderName";
}
#endif
