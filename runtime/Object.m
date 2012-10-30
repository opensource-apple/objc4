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
/*
	Object.m
	Copyright 1988-1996 NeXT Software, Inc.
*/

#ifdef WINNT
#include <winnt-pdo.h>
#endif

#ifdef NeXT_PDO			// pickup BUG fix flags
#import <pdo.h>
#endif

#import <objc/Object.h>
#import "objc-private.h"
#import <objc/objc-runtime.h>
#import <objc/Protocol.h>
#import <stdarg.h> 
#import <string.h> 

OBJC_EXPORT id (*_cvtToId)(const char *);
OBJC_EXPORT id (*_poseAs)();

#define ISMETA(cls)		(((struct objc_class *)cls)->info & CLS_META) 

// Error Messages
static const char
	_errNoMem[] = "failed -- out of memory(%s, %u)",
	_errReAllocNil[] = "reallocating nil object",
	_errReAllocFreed[] = "reallocating freed object",
	_errReAllocTooSmall[] = "(%s, %u) requested size too small",
	_errShouldHaveImp[] = "should have implemented the '%s' method.",
	_errShouldNotImp[] = "should NOT have implemented the '%s' method.",
	_errLeftUndone[] = "method '%s' not implemented",
	_errBadSel[] = "method %s given invalid selector %s",
	_errDoesntRecognize[] = "does not recognize selector %c%s";


@implementation Object 


+ initialize
{
	return self; 
}

- awake 
{
	return self; 
}

+ poseAs: aFactory
{ 
	return (*_poseAs)(self, aFactory); 
}

+ new
{
	id newObject = (*_alloc)((Class)self, 0);
	struct objc_class * metaClass = ((struct objc_class *) self)->isa;
	if (metaClass->version > 1)
	    return [newObject init];
	else
	    return newObject;
}

+ alloc
{
	return (*_zoneAlloc)((Class)self, 0, malloc_default_zone()); 
}

+ allocFromZone:(void *) z
{
	return (*_zoneAlloc)((Class)self, 0, z); 
}

- init
{
    return self;
}

- (const char *)name
{
	return ((struct objc_class *)isa)->name; 
}

+ (const char *)name
{
	return ((struct objc_class *)self)->name; 
}

- (unsigned)hash
{
	return ((uarith_t)self) >> 2;
}

- (BOOL)isEqual:anObject
{
	return anObject == self; 
}

- free 
{ 
	return (*_dealloc)(self); 
}

+ free
{
	return nil; 
}

- self
{
	return self; 
}

- class
{
	return (id)isa; 
}

+ class 
{
	return self;
}

- (void *)zone
{
	void *z = malloc_zone_from_ptr(self);
	return z ? z : malloc_default_zone();
}

+ superclass 
{ 
	return ((struct objc_class *)self)->super_class; 
}

- superclass 
{ 
	return ((struct objc_class *)isa)->super_class; 
}

+ (int) version
{
	struct objc_class *	class = (struct objc_class *) self;
	return class->version;
}

+ setVersion: (int) aVersion
{
	struct objc_class *	class = (struct objc_class *) self;
	class->version = aVersion;
	return self;
}

- (BOOL)isKindOf:aClass
{
	register Class cls;
	for (cls = isa; cls; cls = ((struct objc_class *)cls)->super_class) 
		if (cls == (Class)aClass)
			return YES;
	return NO;
}

- (BOOL)isMemberOf:aClass
{
	return isa == (Class)aClass;
}

- (BOOL)isKindOfClassNamed:(const char *)aClassName
{
	register Class cls;
	for (cls = isa; cls; cls = ((struct objc_class *)cls)->super_class) 
		if (strcmp(aClassName, ((struct objc_class *)cls)->name) == 0)
			return YES;
	return NO;
}

- (BOOL)isMemberOfClassNamed:(const char *)aClassName 
{
	return strcmp(aClassName, ((struct objc_class *)isa)->name) == 0;
}

+ (BOOL)instancesRespondTo:(SEL)aSelector 
{
	return class_respondsToMethod((Class)self, aSelector);
}

- (BOOL)respondsTo:(SEL)aSelector 
{
	return class_respondsToMethod(isa, aSelector);
}

- copy 
{
	return [self copyFromZone: [self zone]];
}

- copyFromZone:(void *)z
{
	return (*_zoneCopy)(self, 0, z); 
}

- (IMP)methodFor:(SEL)aSelector 
{
	return class_lookupMethod(isa, aSelector);
}

+ (IMP)instanceMethodFor:(SEL)aSelector 
{
	return class_lookupMethod(self, aSelector);
}

#if defined(__alpha__)
#define MAX_RETSTRUCT_SIZE 256

typedef struct _foolGCC {
	char c[MAX_RETSTRUCT_SIZE];
} _variableStruct;

typedef _variableStruct (*callReturnsStruct)();

OBJC_EXPORT long sizeOfReturnedStruct(char **);

long sizeOfType(char **pp)
{
  char *p = *pp;
  long stack_size = 0, n = 0;
  switch(*p) {
  case 'c':
  case 'C':
    stack_size += sizeof(char); // Alignment ?
    break;
  case 's':
  case 'S':
    stack_size += sizeof(short);// Alignment ?
    break;
  case 'i':
  case 'I':
  case '!':
    stack_size += sizeof(int);
    break;
  case 'l':
  case 'L':
    stack_size += sizeof(long int);
    break;
  case 'f':
    stack_size += sizeof(float);
    break;
  case 'd':
    stack_size += sizeof(double);
    break;
  case '*':
  case ':':
  case '@':
  case '%':
    stack_size += sizeof(char*);
    break;
  case '{':
    stack_size += sizeOfReturnedStruct(&p);
    while(*p!='}') p++;
    break;
  case '[':
    p++;
    while(isdigit(*p))
      n = 10 * n + (*p++ - '0');
    stack_size += (n * sizeOfType(&p));
    break;
  default:
    break;
  }
  *pp = p;
  return stack_size;
}

long
sizeOfReturnedStruct(char **pp)
{
  char *p = *pp;
  long stack_size = 0, n = 0;
  while(p!=NULL && *++p!='=') ; // skip the struct name
  while(p!=NULL && *++p!='}')
    stack_size += sizeOfType(&p);
  return stack_size + 8;	// Add 8 as a 'forfait value'
  				// to take alignment into account
}

- perform:(SEL)aSelector 
{
  char *p;
  long stack_size;
  _variableStruct *dummyRetVal;
  Method	method;

  if (aSelector) {
    method = class_getInstanceMethod((Class)self->isa,
				     aSelector);
    if(method==NULL)
      method = class_getClassMethod((Class)self->isa,
				    aSelector);
    if(method!=NULL) {
      p = &method->method_types[0];
      if(*p=='{') {
	// Method returns a structure
	stack_size = sizeOfReturnedStruct(&p);
	if(stack_size<MAX_RETSTRUCT_SIZE)
	  {
	    //
	    // The MAX_RETSTRUCT_SIZE value allow us to support methods that
	    // return structures whose size is not grater than
	    // MAX_RETSTRUCT_SIZE.
	    // This is because the compiler allocates space on the stack
	    // for the size of the return structure, and when the method
	    // returns, the structure is copied on the space allocated
	    // on the stack: if the structure is greater than the space
	    // allocated... bang! (the stack is gone:-)
	    //
	    ((callReturnsStruct)objc_msgSend)(self, aSelector);
	  }
	else
	  {
	    dummyRetVal  = (_variableStruct*) malloc(stack_size);

	    // Following asm code is equivalent to:
	    // *dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector);
#if 0
	    asm("ldq $16,%0":"=g" (dummyRetVal):);
	    asm("ldq $17,%0":"=g" (self):);
	    asm("ldq $18,%0":"=g" (aSelector):);
	    asm("bis $31,1,$25");
	    asm("lda $27,objc_msgSend");
	    asm("jsr $26,($27),objc_msgSend");
	    asm("ldgp $29,0($26)");
#else
*dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector);
#endif
	    free(dummyRetVal);
	  }
	// When the method return a structure, we cannot return it here
	// becuse we're not called in the right way, so we must return
	// something else: wether it is self or NULL is a matter of taste.
	return (id)NULL;
      }
    }
    // We fall back here either because the method doesn't return
    // a structure, or because method is NULL: in this latter
    // case the call to msgSend will try to forward the message.
    return objc_msgSend(self, aSelector);
  }

  // We fallback here only when aSelector is NULL
  return [self error:_errBadSel, SELNAME(_cmd), aSelector];
}

- perform:(SEL)aSelector with:anObject 
{
  char *p;
  long stack_size;
  _variableStruct *dummyRetVal;
  Method	method;

  if (aSelector) {
    method = class_getInstanceMethod((Class)self->isa,
				     aSelector);
    if(method==NULL)
      method = class_getClassMethod((Class)self->isa,
				    aSelector);
    if(method!=NULL) {
      p = &method->method_types[0];
      if(*p=='{') {
	// Method returns a structure
	stack_size = sizeOfReturnedStruct(&p);
	if(stack_size<MAX_RETSTRUCT_SIZE)
	  {
	    //
	    // The MAX_RETSTRUCT_SIZE value allow us to support methods that
	    // return structures whose size is not grater than
	    // MAX_RETSTRUCT_SIZE.
	    // This is because the compiler allocates space on the stack
	    // for the size of the return structure, and when the method
	    // returns, the structure is copied on the space allocated
	    // on the stack: if the structure is greater than the space
	    // allocated... bang! (the stack is gone:-)
	    //
	    ((callReturnsStruct)objc_msgSend)(self, aSelector, anObject);
	  }
	else
	  {
	    dummyRetVal  = (_variableStruct*) malloc(stack_size);

	    // Following asm code is equivalent to:
	    // *dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector,anObject);
#if 0
	    asm("ldq $16,%0":"=g" (dummyRetVal):);
	    asm("ldq $17,%0":"=g" (self):);
	    asm("ldq $18,%0":"=g" (aSelector):);
	    asm("ldq $19,%0":"=g" (anObject):);
	    asm("bis $31,1,$25");
	    asm("lda $27,objc_msgSend");
	    asm("jsr $26,($27),objc_msgSend");
	    asm("ldgp $29,0($26)");
#else
 *dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector,anObject);
#endif
	    free(dummyRetVal);
	  }
	// When the method return a structure, we cannot return it here
	// becuse we're not called in the right way, so we must return
	// something else: wether it is self or NULL is a matter of taste.
	return (id)NULL;
      }
    }
    // We fall back here either because the method doesn't return
    // a structure, or because method is NULL: in this latter
    // case the call to msgSend will try to forward the message.
    return objc_msgSend(self, aSelector, anObject);
  }

  // We fallback here only when aSelector is NULL
  return [self error:_errBadSel, SELNAME(_cmd), aSelector];
}

- perform:(SEL)aSelector with:obj1 with:obj2 
{
  char *p;
  long stack_size;
  _variableStruct *dummyRetVal;
  Method	method;

  if (aSelector) {
    method = class_getInstanceMethod((Class)self->isa,
				     aSelector);
    if(method==NULL)
      method = class_getClassMethod((Class)self->isa,
				    aSelector);
    if(method!=NULL) {
      p = &method->method_types[0];
      if(*p=='{') {
	// Method returns a structure
	stack_size = sizeOfReturnedStruct(&p);
	if(stack_size<MAX_RETSTRUCT_SIZE)
	  {
	    //
	    // The MAX_RETSTRUCT_SIZE value allow us to support methods that
	    // return structures whose size is not grater than
	    // MAX_RETSTRUCT_SIZE.
	    // This is because the compiler allocates space on the stack
	    // for the size of the return structure, and when the method
	    // returns, the structure is copied on the space allocated
	    // on the stack: if the structure is greater than the space
	    // allocated... bang! (the stack is gone:-)
	    //
	    ((callReturnsStruct)objc_msgSend)(self, aSelector, obj1, obj2);
	  }
	else
	  {
	    dummyRetVal  = (_variableStruct*) malloc(stack_size);

	    // Following asm code is equivalent to:
	    // *dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector,obj1,obj2);

#if 0
	    asm("ldq $16,%0":"=g" (dummyRetVal):);
	    asm("ldq $17,%0":"=g" (self):);
	    asm("ldq $18,%0":"=g" (aSelector):);
	    asm("ldq $19,%0":"=g" (obj1):);
	    asm("ldq $20,%0":"=g" (obj2):);
	    asm("bis $31,1,$25");
	    asm("lda $27,objc_msgSend");
	    asm("jsr $26,($27),objc_msgSend");
	    asm("ldgp $29,0($26)");
#else
*dummyRetVal=((callReturnsStruct)objc_msgSend)(self,aSelector,obj1,obj2);
#endif
	    free(dummyRetVal);
	  }
	// When the method return a structure, we cannot return it here
	// becuse we're not called in the right way, so we must return
	// something else: wether it is self or NULL is a matter of taste.
	return (id)NULL;
      }
    }
    // We fall back here either because the method doesn't return
    // a structure, or because method is NULL: in this latter
    // case the call to msgSend will try to forward the message.
    return objc_msgSend(self, aSelector, obj1, obj2);
  }

  // We fallback here only when aSelector is NULL
  return [self error:_errBadSel, SELNAME(_cmd), aSelector];

}
#else
- perform:(SEL)aSelector 
{ 
	if (aSelector)
		return objc_msgSend(self, aSelector); 
	else
		return [self error:_errBadSel, SELNAME(_cmd), aSelector];
}

- perform:(SEL)aSelector with:anObject 
{
	if (aSelector)
		return objc_msgSend(self, aSelector, anObject); 
	else
		return [self error:_errBadSel, SELNAME(_cmd), aSelector];
}

- perform:(SEL)aSelector with:obj1 with:obj2 
{
	if (aSelector)
		return objc_msgSend(self, aSelector, obj1, obj2); 
	else
		return [self error:_errBadSel, SELNAME(_cmd), aSelector];
}
#endif

- subclassResponsibility:(SEL)aSelector 
{
	return [self error:_errShouldHaveImp, sel_getName(aSelector)];
}

- notImplemented:(SEL)aSelector
{
	return [self error:_errLeftUndone, sel_getName(aSelector)];
}

- doesNotRecognize:(SEL)aMessage
{
	return [self error:_errDoesntRecognize, 
		ISMETA (isa) ? '+' : '-', SELNAME(aMessage)];
}

- error:(const char *)aCStr, ... 
{
	va_list ap;
	va_start(ap,aCStr); 
	(*_error)(self, aCStr, ap); 
	_objc_error (self, aCStr, ap);	/* In case (*_error)() returns. */
	va_end(ap);
        return nil;
}

- (void) printForDebugger:(void *)stream
{
}

- write:(void *) stream 
{
	return self;
}

- read:(void *) stream 
{
	return self;
}

- forward: (SEL) sel : (marg_list) args 
{
    return [self doesNotRecognize: sel];
}

/* this method is not part of the published API */

- (unsigned)methodArgSize:(SEL)sel 
{
    Method	method = class_getInstanceMethod((Class)isa, sel);
    if (! method) return 0;
    return method_getSizeOfArguments(method);
}

#if defined(__alpha__)

typedef struct {
	unsigned long int i16;
	unsigned long int i17;
	unsigned long int i18;
	unsigned long int i19;
	unsigned long int i20;
	unsigned long int i21;
	unsigned long int i25;
	unsigned long int f16;
	unsigned long int f17;
	unsigned long int f18;
	unsigned long int f19;
	unsigned long int f20;
	unsigned long int f21;
	unsigned long int sp;
 } *_m_args_p;

- performv: (SEL) sel : (marg_list) args 
{
    char *		p;
    long		stack_size;
    Method		method;
    unsigned long int	size;
    char 		scratchMem[MAX_RETSTRUCT_SIZE];
    char *		scratchMemP;

    // Messages to nil object always return nil
    if (! self) return nil;

    // Got to have a selector
    if (!sel)
        return [self error:_errBadSel, SELNAME(_cmd), sel];

    // Handle a method which returns a structure and
    // has been called as such
    if (((_m_args_p)args)->i25){
        // Calculate size of the marg_list from the method's
        // signature.  This looks for the method in self
        // and its superclasses.
        size = [self methodArgSize: sel];

        // If neither self nor its superclasses implement
        // the method, forward the message because self
        // might know someone who does.  This is a
        // "chained" forward...
        if (! size) return [self forward: sel: args];

        // Message self with the specified selector and arguments
        return objc_msgSendv (self, sel, size, args);
    }

    // Look for instance method in self's class and superclasses
    method = class_getInstanceMethod((Class)self->isa,sel);

    // Look for class method in self's class and superclass
    if(method==NULL)
        method = class_getClassMethod((Class)self->isa,sel);

    // If neither self nor its superclasses implement
    // the method, forward the message because self
    // might know someone who does.  This is a
    // "chained" forward...
    if(method==NULL)
        return [self forward: sel: args];

    // Calculate size of the marg_list from the method's
    // signature.
    size = method_getSizeOfArguments(method);

    // Ready to send message now if the return type
    // is not a structure
    p = &method->method_types[0];
    if(*p!='{')
        return objc_msgSendv(self, sel, size, args);

    // Method returns a structure
    stack_size = sizeOfReturnedStruct(&p);
    if(stack_size>=MAX_RETSTRUCT_SIZE)
        scratchMemP = (char*)malloc(stack_size);
    else
        scratchMemP = &scratchMem[0];

    // Set i25 so objc_msgSendv will know that method returns a structure
    ((_m_args_p)args)->i25 = 1;
    
    // Set first param of method to be called to safe return address
    ((_m_args_p)args)->i16 = (unsigned long int) scratchMemP;
    objc_msgSendv(self, sel, size, args);

    if(stack_size>=MAX_RETSTRUCT_SIZE)
      free(scratchMemP);

    return (id)NULL;
 }
#else
- performv: (SEL) sel : (marg_list) args 
{
    unsigned	size;
#if hppa && 0
    void *ret;
   
    // Save ret0 so methods that return a struct might work.
    asm("copy %%r28, %0": "=r"(ret): );
#endif hppa

    // Messages to nil object always return nil
    if (! self) return nil;

    // Calculate size of the marg_list from the method's
    // signature.  This looks for the method in self
    // and its superclasses.
    size = [self methodArgSize: sel];

    // If neither self nor its superclasses implement
    // it, forward the message because self might know
    // someone who does.  This is a "chained" forward...
    if (! size) return [self forward: sel: args];

#if hppa && 0
    // Unfortunately, it looks like the compiler puts something else in
    // r28 right after this instruction, so this is all for naught.
    asm("copy %0, %%r28": : "r"(ret));
#endif hppa

    // Message self with the specified selector and arguments
    return objc_msgSendv (self, sel, size, args); 
}
#endif

/* Testing protocol conformance */

- (BOOL) conformsTo: (Protocol *)aProtocolObj
{
  return [(id)isa conformsTo:aProtocolObj];
}

+ (BOOL) conformsTo: (Protocol *)aProtocolObj
{
  struct objc_class * class;

  for (class = self; class; class = class->super_class)
    {
      if (class->isa->version >= 3)
        {
	  struct objc_protocol_list *protocols = class->protocols;

	  while (protocols)
	    {
	      int i;

	      for (i = 0; i < protocols->count; i++)
		{
		  Protocol *p = protocols->list[i];
    
		  if ([p conformsTo:aProtocolObj])
		    return YES;
		}

	      if (class->isa->version <= 4)
	        break;

	      protocols = protocols->next;
	    }
	}
    }
  return NO;
}


/* Looking up information for a method */

- (struct objc_method_description *) descriptionForMethod:(SEL)aSelector
{
  struct objc_class * cls;
  struct objc_method_description *m;

  /* Look in the protocols first. */
  for (cls = isa; cls; cls = cls->super_class)
    {
      if (cls->isa->version >= 3)
        {
	  struct objc_protocol_list *protocols = cls->protocols;
  
	  while (protocols)
	    {
	      int i;

	      for (i = 0; i < protocols->count; i++)
		{
		  Protocol *p = protocols->list[i];

		  if (ISMETA (cls))
		    m = [p descriptionForClassMethod:aSelector];
		  else
		    m = [p descriptionForInstanceMethod:aSelector];

		  if (m) {
		      return m;
		  }
		}
  
	      if (cls->isa->version <= 4)
		break;
  
	      protocols = protocols->next;
	    }
	}
    }

  /* Then try the class implementations. */
    for (cls = isa; cls; cls = cls->super_class) {
        void *iterator = 0;
	int i;
        struct objc_method_list *mlist;
        while ( (mlist = _class_inlinedNextMethodList( cls, &iterator )) ) {
            for (i = 0; i < mlist->method_count; i++)
                if (mlist->method_list[i].method_name == aSelector) {
		    struct objc_method_description *m;
		    m = (struct objc_method_description *)&mlist->method_list[i];
                    return m;
		}
        }
    }
 
  return 0;
}

+ (struct objc_method_description *) descriptionForInstanceMethod:(SEL)aSelector
{
  struct objc_class * cls;

  /* Look in the protocols first. */
  for (cls = self; cls; cls = cls->super_class)
    {
      if (cls->isa->version >= 3)
        {
	  struct objc_protocol_list *protocols = cls->protocols;
  
	  while (protocols)
	    {
	      int i;

	      for (i = 0; i < protocols->count; i++)
		{
		  Protocol *p = protocols->list[i];
		  struct objc_method_description *m;

		  if ((m = [p descriptionForInstanceMethod:aSelector]))
		    return m;
		}
  
	      if (cls->isa->version <= 4)
		break;
  
	      protocols = protocols->next;
	    }
	}
    }

  /* Then try the class implementations. */
    for (cls = self; cls; cls = cls->super_class) {
        void *iterator = 0;
	int i;
        struct objc_method_list *mlist;
        while ( (mlist = _class_inlinedNextMethodList( cls, &iterator )) ) {
            for (i = 0; i < mlist->method_count; i++)
                if (mlist->method_list[i].method_name == aSelector) {
		    struct objc_method_description *m;
		    m = (struct objc_method_description *)&mlist->method_list[i];
                    return m;
		}
        }
    }

  return 0;
}


/* Obsolete methods (for binary compatibility only). */

+ superClass
{
	return [self superclass];
}

- superClass
{
	return [self superclass];
}

- (BOOL)isKindOfGivenName:(const char *)aClassName
{
	return [self isKindOfClassNamed: aClassName];
}

- (BOOL)isMemberOfGivenName:(const char *)aClassName 
{
	return [self isMemberOfClassNamed: aClassName];
}

- (struct objc_method_description *) methodDescFor:(SEL)aSelector
{
  return [self descriptionForMethod: aSelector];
}

+ (struct objc_method_description *) instanceMethodDescFor:(SEL)aSelector
{
  return [self descriptionForInstanceMethod: aSelector];
}

- findClass:(const char *)aClassName
{
	return (*_cvtToId)(aClassName);
}

- shouldNotImplement:(SEL)aSelector
{
	return [self error:_errShouldNotImp, sel_getName(aSelector)];
}

@end

static id _internal_object_copyFromZone(Object *anObject, unsigned nBytes, void *z) 
{
	id obj;
	register unsigned siz;

	if (anObject == nil)
		return nil;

	obj = (*_zoneAlloc)(anObject->isa, nBytes, z);
	siz = ((struct objc_class *)anObject->isa)->instance_size + nBytes;
	bcopy((const char*)anObject, (char*)obj, siz);
	return obj;
}

static id _internal_object_copy(Object *anObject, unsigned nBytes) 
{
    void *z= malloc_zone_from_ptr(anObject);
    return _internal_object_copyFromZone(anObject, 
					 nBytes,
					 z ? z : malloc_default_zone());
}

static id _internal_object_dispose(Object *anObject) 
{
	if (anObject==nil) return nil;
	anObject->isa = _objc_getFreedObjectClass (); 
	free(anObject);
	return nil;
}

static id _internal_object_reallocFromZone(Object *anObject, unsigned nBytes, void *z) 
{
	Object *newObject; 
	struct objc_class * tmp;

	if (anObject == nil)
		__objc_error(nil, _errReAllocNil, 0);

	if (anObject->isa == _objc_getFreedObjectClass ())
		__objc_error(anObject, _errReAllocFreed, 0);

	if (nBytes < ((struct objc_class *)anObject->isa)->instance_size)
		__objc_error(anObject, _errReAllocTooSmall, 
				object_getClassName(anObject), nBytes);

	// Make sure not to modify space that has been declared free
	tmp = anObject->isa; 
	anObject->isa = _objc_getFreedObjectClass ();
	newObject = (Object*)malloc_zone_realloc(z, (void*)anObject, (size_t)nBytes);
	if (newObject) {
		newObject->isa = tmp;
		return newObject;
	}
	else
            {
		__objc_error(anObject, _errNoMem, 
				object_getClassName(anObject), nBytes);
                return nil;
            }
}

static id _internal_object_realloc(Object *anObject, unsigned nBytes) 
{
    void *z= malloc_zone_from_ptr(anObject);
    return _internal_object_reallocFromZone(anObject,
					    nBytes,
					    z ? z : malloc_default_zone());
}

/* Functional Interface to system primitives */

id object_copy(Object *anObject, unsigned nBytes) 
{
	return (*_copy)(anObject, nBytes); 
}

id object_copyFromZone(Object *anObject, unsigned nBytes, void *z) 
{
	return (*_zoneCopy)(anObject, nBytes, z); 
}

id object_dispose(Object *anObject) 
{
	return (*_dealloc)(anObject); 
}

id object_realloc(Object *anObject, unsigned nBytes) 
{
	return (*_realloc)(anObject, nBytes); 
}

id object_reallocFromZone(Object *anObject, unsigned nBytes, void *z) 
{
	return (*_zoneRealloc)(anObject, nBytes, z); 
}

Ivar object_setInstanceVariable(id obj, const char *name, void *value)
{
	Ivar ivar = 0;

	if (obj && name) {
		void **ivaridx;

		if ((ivar = class_getInstanceVariable(((Object*)obj)->isa, name))) {
		       ivaridx = (void **)((char *)obj + ivar->ivar_offset);
		       *ivaridx = value;
		}
	}
	return ivar;
}

Ivar object_getInstanceVariable(id obj, const char *name, void **value)
{
	Ivar ivar = 0;

	if (obj && name) {
		void **ivaridx;

		if ((ivar = class_getInstanceVariable(((Object*)obj)->isa, name))) {
		       ivaridx = (void **)((char *)obj + ivar->ivar_offset);
		       *value = *ivaridx;
		} else
		       *value = 0;
	}
	return ivar;
}

#if defined(__hpux__)
id (*_objc_msgSend_v)(id, SEL, ...) = objc_msgSend;
#endif

id (*_copy)(id, unsigned) = _internal_object_copy;
id (*_realloc)(id, unsigned) = _internal_object_realloc;
id (*_dealloc)(id)  = _internal_object_dispose;
id (*_cvtToId)(const char *)= objc_lookUpClass;
SEL (*_cvtToSel)(const char *)= sel_getUid;
void (*_error)() = (void(*)())_objc_error;
id (*_zoneCopy)(id, unsigned, void *) = _internal_object_copyFromZone;
id (*_zoneRealloc)(id, unsigned, void *) = _internal_object_reallocFromZone;


