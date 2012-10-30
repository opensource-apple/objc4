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
 *	objc-load.m
 *	Copyright 1988-1996, NeXT Software, Inc.
 *	Author:	s. naroff
 *
 */

#import "objc-private.h"
#import <objc/objc-runtime.h>
#import <objc/hashtable2.h>
#import <objc/Object.h>
#import <objc/Protocol.h>

#if defined(__MACH__) || defined(WIN32)	
#import <streams/streams.h>
#endif 


#if !defined(NeXT_PDO)
    // MACH
    #include <mach-o/dyld.h>
#endif 

#if defined(WIN32)
    #import <winnt-pdo.h>
    #import <windows.h>
#endif

#if defined(__svr4__)
    #import <dlfcn.h>
#endif

#if defined(__hpux__) || defined(hpux)
    #import "objc_hpux_register_shlib.c"
#endif

extern char *	getsectdatafromheader	(const headerType * mhp, const char * segname, const char * sectname,  int * size);

/* Private extern */
OBJC_EXPORT void (*callbackFunction)( Class, const char * );


struct objc_method_list **get_base_method_list(Class cls) {
    struct objc_method_list **ptr = ((struct objc_class * )cls)->methodLists;
    if (!*ptr) return NULL;
    while ( *ptr != 0 && *ptr != END_OF_METHODS_LIST ) { ptr++; }
    --ptr;
    return ptr;
}


#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
    void send_load_message_to_class(Class cls, void *header_addr)
    {
    	struct objc_method_list **mlistp = get_base_method_list(cls->isa);
    	struct objc_method_list *mlist = mlistp ? *mlistp : NULL;
    	IMP load_method;

	if (mlist) {
		load_method = 
		   class_lookupNamedMethodInMethodList(mlist, "finishLoading:");

		/* go directly there, we do not want to accidentally send
	           the finishLoading: message to one of its categories...
	 	*/
		if (load_method)
			(*load_method)((id)cls, @selector(finishLoading:), 
				header_addr);
	}
    }

    void send_load_message_to_category(Category cat, void *header_addr)
    {
	struct objc_method_list *mlist = cat->class_methods;
	IMP load_method;
	Class cls;

	if (mlist) {
		load_method = 
		   class_lookupNamedMethodInMethodList(mlist, "finishLoading:");

		cls = objc_getClass (cat->class_name);

		/* go directly there, we do not want to accidentally send
	           the finishLoading: message to one of its categories...
	 	*/
		if (load_method)
			(*load_method)(cls, @selector(finishLoading:), 
				header_addr);
	}
    }
#endif // GENERIC_OBJ_FILE

/**********************************************************************************
 * objc_loadModule.
 *
 * NOTE: Loading isn't really thread safe.  If a load message recursively calls
 * objc_loadModules() both sets will be loaded correctly, but if the original
 * caller calls objc_unloadModules() it will probably unload the wrong modules.
 * If a load message calls objc_unloadModules(), then it will unload
 * the modules currently being loaded, which will probably cause a crash.
 *
 * Error handling is still somewhat crude.  If we encounter errors while
 * linking up classes or categories, we will not recover correctly.
 *
 * I removed attempts to lock the class hashtable, since this introduced
 * deadlock which was hard to remove.  The only way you can get into trouble
 * is if one thread loads a module while another thread tries to access the
 * loaded classes (using objc_lookUpClass) before the load is complete.
 **********************************************************************************/
int		objc_loadModule	   (const char *			moduleName, 
							void			(*class_callback) (Class, const char *categoryName),
							int *			errorCode)
{
	int								successFlag = 1;
	int								locErrorCode;
#if defined(__MACH__)	
	NSObjectFileImage				objectFileImage;
	NSObjectFileImageReturnCode		code;
#endif
#if defined(WIN32) || defined(__svr4__) || defined(__hpux__) || defined(hpux)
	void *		handle;
	void		(*save_class_callback) (Class, const char *) = load_class_callback;
#endif

	// So we don't have to check this everywhere
	if (errorCode == NULL)
		errorCode = &locErrorCode;

#if defined(__MACH__)
	if (moduleName == NULL)
	{
		*errorCode = NSObjectFileImageInappropriateFile;
		return 0;
	}

	if (_dyld_present () == 0)
	{
		*errorCode = NSObjectFileImageFailure;
		return 0;
	}

	callbackFunction = class_callback;
	code = NSCreateObjectFileImageFromFile (moduleName, &objectFileImage);
	if (code != NSObjectFileImageSuccess)
	{
		*errorCode = code;
 		return 0;
	}

#if !defined(__OBJC_DONT_USE_NEW_NSLINK_OPTION__)
	if (NSLinkModule(objectFileImage, moduleName, NSLINKMODULE_OPTION_RETURN_ON_ERROR) == NULL) {
	    NSLinkEditErrors error;
	    int errorNum;
	    char *fileName, *errorString;
	    NSLinkEditError(&error, &errorNum, &fileName, &errorString);
	    // These errors may overlap with other errors that objc_loadModule returns in other failure cases.
	    *errorCode = error;
	    return 0;
	}
#else
        (void)NSLinkModule(objectFileImage, moduleName, NSLINKMODULE_OPTION_NONE);
#endif
	callbackFunction = NULL;

#else
	// The PDO cases
	if (moduleName == NULL)
	{
		*errorCode = 0;
		return 0;
	}

	OBJC_LOCK(&loadLock);

#if defined(WIN32) || defined(__svr4__) || defined(__hpux__) || defined(hpux)

	load_class_callback = class_callback;

#if defined(WIN32)
	if ((handle = LoadLibrary (moduleName)) == NULL)
	{
		FreeLibrary(moduleName);
		*errorCode = 0;
		successFlag = 0;
	}

#elif defined(__svr4__)
	handle = dlopen(moduleName, (RTLD_NOW | RTLD_GLOBAL));
	if (handle == 0)
	{
		*errorCode = 0;
		successFlag = 0;
	}
	else
	{
		objc_register_header(moduleName);
		objc_finish_header();
	}

#else
        handle = shl_load(moduleName, BIND_IMMEDIATE | BIND_VERBOSE, 0L);
        if (handle == 0)
        {
                *errorCode = 0;
                successFlag = 0;
        }
        else
            ; // Don't do anything here: the shlib should have been built
              // with the +I'objc_hpux_register_shlib' option
#endif

	load_class_callback = save_class_callback;

#elif defined(NeXT_PDO) 
	// NOTHING YET...
	successFlag = 0;
#endif // WIN32

	OBJC_UNLOCK (&loadLock);

#endif // MACH

	return successFlag;
}

/**********************************************************************************
 * objc_loadModules.
 **********************************************************************************/
    /* Lock for dynamic loading and unloading. */
	static OBJC_DECLARE_LOCK (loadLock);
#if defined(NeXT_PDO) // GENERIC_OBJ_FILE
	void		(*load_class_callback) (Class, const char *);
#endif 


long	objc_loadModules   (char *			modlist[], 
							void *			errStream,
							void			(*class_callback) (Class, const char *),
							headerType **	hdr_addr,
							char *			debug_file)
{
	char **				modules;
	int					code;
	int					itWorked;

	if (modlist == 0)
		return 0;

	for (modules = &modlist[0]; *modules != 0; modules++)
	{
		itWorked = objc_loadModule (*modules, class_callback, &code);
		if (itWorked == 0)
		{
#if defined(__MACH__) || defined(WIN32)	
			if (errStream)
				NXPrintf ((NXStream *) errStream, "objc_loadModules(%s) code = %d\n", *modules, code);
#endif
			return 1;
		}

		if (hdr_addr)
			*(hdr_addr++) = 0;
	}

	return 0;
}

/**********************************************************************************
 * objc_unloadModules.
 *
 * NOTE:  Unloading isn't really thread safe.  If an unload message calls
 * objc_loadModules() or objc_unloadModules(), then the current call
 * to objc_unloadModules() will probably unload the wrong stuff.
 **********************************************************************************/

long	objc_unloadModules (void *			errStream,
							void			(*unload_callback) (Class, Category))
{
	headerType *	header_addr = 0;
	int errflag = 0;

        // TODO: to make unloading work, should get the current header

	if (header_addr)
	{
                ; // TODO: unload the current header
	}
	else
	{
		errflag = 1;
	}

  return errflag;
}

