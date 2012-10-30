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
 *      objc_hpux_register_shlib.c
 *      Author: Laurent Ramontianu
 */

#warning "OBJC SHLIB SUPPORT WARNING:"
#warning "Compiling objc_hpux_register_shlib.c"
#warning "Shlibs containing objc code must be built using"
#warning "the ld option: +I'objc_hpux_register_shlib_$(NAME)'"
#warning "Be advised that if collect isn't fixed to ignore"
#warning "shlibs, your app may (and will) CRASH!!!"

#include <dl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/unistd.h>
#include <sys/stat.h>

static char *_loaded_shlibs_init[128] = {
        "java",
        "cl",
        "isamstub",
        "c",
        "m",
        "dld",
        "gen",
        "pthread",
        "lwp"
};

static unsigned _loaded_shlibs_size = 128;
static unsigned _loaded_shlibs_count = 9;

static char **_loaded_shlibs = _loaded_shlibs_init;

static void dump_loaded_shlibs() {
    int i;
    printf("****    Loaded shlibs    ****\n");
    for ( i=0; i<_loaded_shlibs_count; i++ ) {
        printf("\t%s\n", _loaded_shlibs[i]);
    }
    printf("---                      ----\n");
}


static char *my_basename(char *path)
{
    char *res = 0;
    unsigned idx = strlen(path) - 1;

    if ( path[idx] == '/' ) idx--;
    for ( ; (idx > 0) && (path[idx] != '/') ; idx-- ) {
        if ( path[idx] == '.' ) path[idx] = '\000';
    }
    if ( path[idx] == '/') idx++;
    res = strstr(&path[idx], "lib");
    if ( !res ) {
        return &path[idx];
    }
    if ( res == &path[idx] ) {
        return &path[idx+3];
    }
    return &path[idx];
}


extern void *malloc(unsigned);
extern void  free(void *);

// Hooks if we decide to provide alternate malloc/free functions
static void*(*_malloc_ptr)(unsigned) = malloc;
static void(*_free_ptr)(void*) = free;


static char *dep_shlibs_temp[128];
static unsigned dep_shlibs_temp_count = 0;

static void dump_dependent_shlibs() {
    int i;
    printf("****    Dependent shlibs    ****\n");
    for ( i=0; i<dep_shlibs_temp_count; i++ ) {
        printf("\t%s\n", dep_shlibs_temp[i]);
    }
    printf("---                      ----\n");
}


static void init_dependent_shlibs(char *name)
{
    dep_shlibs_temp[0] = name;
    dep_shlibs_temp_count = 1;
}


static int already_loaded(char *path);

static void insert_dependent_shlib(char *path)
{
    if ( ! already_loaded(path) ) {
        dep_shlibs_temp[dep_shlibs_temp_count] = path;
        dep_shlibs_temp_count++;
        return;
    }
}

static char **dependent_shlibs()
{
    unsigned size;
    unsigned idx;
    char *ptr;
    char *name;
    unsigned ref_size;

    insert_dependent_shlib("<NULL>");

    size = 0;
    for ( idx = 0; idx < dep_shlibs_temp_count; idx++ ) {
        size += sizeof(char*) + strlen(dep_shlibs_temp[idx]) + 1;
    }

    if ( ! (ptr = _malloc_ptr(size)) ) {
        fprintf(stderr, "dependent_shlibs: fatal - malloc() failed\n");
        exit(-1);
    }

    ref_size = dep_shlibs_temp_count * sizeof(char*);
    size = 0;
    for ( idx = 0; idx < dep_shlibs_temp_count; idx++ ) {
        name = ptr + ref_size + size;
        *((char **)ptr + idx) = name;
        strcpy(name, dep_shlibs_temp[idx]);
        size += strlen(name) + 1;
    }

    dep_shlibs_temp_count = 0;
    return (char **)ptr;
}


static char **__objc_get_referenced_shlibs(char *path)
{
    static char **dict[128];
    static unsigned dict_size = 0;
    static char *res_nil[] = { "<NULL>" };
    static char file_name[48];

    int fd;
    int child_pid;
    unsigned long size;
    void *addr;

    char *ptr;
    char *ptr2;
    char buf[256], *name;
    unsigned idx;

    strcpy(buf, path);
    name = my_basename(buf);

    for (idx = 0; idx < dict_size; idx++ ) {
        if ( ! strcmp(name, *(dict[idx])) )
            return dict[idx]+1;
    }

    child_pid = vfork();
    if ( child_pid < 0 ) {
        fprintf(stderr, "__objc_get_referenced_shlibs: fatal - vfork() failed\n");
        exit(-1);
    }

    if ( child_pid > 0 ) {
        wait(0);
        sprintf(file_name, "/tmp/apple_shlib_reg.%d", child_pid);
        if ( (fd = open(file_name, O_RDONLY)) < 0 ) {
            fprintf(stderr, "__objc_get_referenced_shlibs: fatal - open() failed\n");
            exit(-1);
        }
        size = lseek(fd, 0, SEEK_END);
        addr = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);

        init_dependent_shlibs(name);
        if ( ptr = strstr(addr, "list:") ) {
            ptr2 = strtok(ptr, " \n\t");
            for ( ; ; ) {
                ptr2 = strtok(0, " \n\t");
                if ( ! ptr2 || strcmp(ptr2, "dynamic") ) break;
                ptr2 = strtok(0, " \n\t");
                if ( ! ptr2 ) {
                    fprintf(stderr, "__objc_get_referenced_shlibs: fatal - %s has bad format\n", file_name);
                    exit(-1);
                }
                insert_dependent_shlib(ptr2);
            }
        }

        dict[dict_size] = dependent_shlibs();
        munmap(addr, size);
        close(fd);
        unlink(file_name);
        return dict[dict_size++];
    }
    else {
        sprintf(file_name, "/tmp/apple_shlib_reg.%d", getpid());
        close(1);
        if ( open(file_name, O_WRONLY | O_CREAT, 0) < 0 ) { exit(-1); }
// Uncomment next 2 lines if it's needed to redirect stderr as well
/*
        close(2);
        dup(1);
*/
        /* aB. For some reason the file seems to be created with no read permission if done as a normal user */
        chmod(file_name, S_IRUSR | S_IRGRP | S_IROTH);
        execl("/usr/bin/chatr", "chatr", path, 0);
        fprintf(stderr, "__objc_get_referenced_shlibs: failed to exec chatr\n");
        exit(-1);
    }

    return res_nil;
}


static int _verbose = -1;
static int _reg_mechanism = -1;

#define OBJC_SHLIB_INIT_REGISTRATION if (_reg_mechanism == -1) {registration_init();}
#define REG_METHOD_CHATR 0
#define REG_METHOD_DLD 1

static void registration_init() {
    const char *str_value = getenv("OBJC_SHOW_SHLIB_REGISTRATION");
    if ( str_value ) {
        if      ( !strcmp(str_value, "ALL") )   _verbose = 4;
        else if ( !strcmp(str_value, "LIBS") )  _verbose = 1;
        else if ( !strcmp(str_value, "LIST") )  _verbose = 2;
        else if ( !strcmp(str_value, "CTORS") ) _verbose = 3;
        else _verbose = 0;
    }
    else _verbose = 0;

    str_value = getenv("OBJC_SHLIB_REGISTRATION_METHOD");
    if ( str_value ) {
        if      ( !strcmp(str_value, "DLD") ) _reg_mechanism = REG_METHOD_DLD;
        else if ( !strcmp(str_value, "AB") )  _reg_mechanism = REG_METHOD_DLD;
        else if ( !strcmp(str_value, "NEW") ) _reg_mechanism = REG_METHOD_DLD;
        else _reg_mechanism = REG_METHOD_CHATR;
    }
    else _reg_mechanism = REG_METHOD_DLD;

    if (_verbose > 0) {
        if (_reg_mechanism == REG_METHOD_CHATR) {
            fprintf(stderr, "objc_hpux_register_shlib(): Using old (chatr) registration method\n");
        } else {
            fprintf(stderr, "objc_hpux_register_shlib(): Using new (dld) registration method\n");
        }
    }
}


static void insert_loaded_shlib(char *path);

static int already_loaded(char *path)
{
    static int first_time_here = 1;
    unsigned idx;
    char buf[256], *name;
    
    strcpy(buf, path);
    name = my_basename(buf);

    OBJC_SHLIB_INIT_REGISTRATION;

    for ( idx = 0; idx < _loaded_shlibs_count; idx++ ) {
        if ( ! strcmp(_loaded_shlibs[idx], name) ) {
            return 1;
        }
    }

    if ( first_time_here ) { // the root executable is the first shlib(sic)
        first_time_here = 0;
        insert_loaded_shlib(path);
        return 1;
    }

    return 0;
}

static void insert_loaded_shlib(char *path)
{
    char **_loaded_shlibs_temp;
    char buf[256], *name;

    strcpy(buf, path);
    name = my_basename(buf);

    if ( already_loaded(path) ) {
        return;
    }
    if ( _loaded_shlibs_count >= _loaded_shlibs_size ) {
        _loaded_shlibs_temp = _loaded_shlibs;
        _loaded_shlibs_size += 32;
        _loaded_shlibs = (char **)_malloc_ptr(_loaded_shlibs_size*sizeof(char *));
        if ( ! _loaded_shlibs ) {
            fprintf(stderr, "objc_hpux_register_shlib() - fatal: Failed to malloc _loaded_shlibs list. Exit\n");
            exit(-1);
        }
        memcpy(_loaded_shlibs, _loaded_shlibs_temp, _loaded_shlibs_count);
        if ( _loaded_shlibs_temp != _loaded_shlibs_init ) {
            _free_ptr(_loaded_shlibs_temp);
        }
    }

    if ( ! (_loaded_shlibs[_loaded_shlibs_count] = _malloc_ptr(strlen(name)+1)) ) {
        fprintf(stderr, "objc_hpux_register_shlib() - fatal: Failed to malloc _loaded_shlibs entry. Exit\n");
        exit(-1);
    }
    strcpy(_loaded_shlibs[_loaded_shlibs_count++], name);
    return;
}


static char *_pending_shlibs_init[128] = { "nhnd<NULL>" };

static unsigned _pending_shlibs_size = 128;
static unsigned _pending_shlibs_count = 1;

static char **_pending_shlibs = _pending_shlibs_init;

static void dump_pending_shlibs() {
    int i;
    printf("****    Pending shlibs    ****\n");
    for ( i=0; i<_pending_shlibs_count; i++ ) {
        printf("\t%s\n", _pending_shlibs[i]+sizeof(void*));
    }
    printf("---                      ----\n");
}


static int already_pending(const char *path)
{
    unsigned idx;
    for ( idx = 0; idx < _pending_shlibs_count; idx++ ) {
        if ( ! strcmp(_pending_shlibs[idx]+sizeof(void*), path) ) {
            if (_verbose > 1) {
                fprintf(stderr, "already_pending(): Already pended shlib %s\n", path);
            }
            return 1;
        }
    }
    if (_verbose > 1) {
        fprintf(stderr, "already_pending(): Pending shlib %s\n", path);
    }
    return 0;
}

static void insert_pending_shlib(struct shl_descriptor *desc)
{
    char **_pending_shlibs_temp;
    char *ptr;
    int mask;

    if (_verbose > 1) {
        fprintf(stderr, "insert_pending_shlib(): Inserting shlib %s\n", desc->filename);
    }

    if ( already_pending(desc->filename) )
        return;

    if ( _pending_shlibs_count >= _pending_shlibs_size ) {
        _pending_shlibs_temp = _pending_shlibs;
        _pending_shlibs_size += 32;
        _pending_shlibs = (char **)_malloc_ptr(_pending_shlibs_size*sizeof(char *));
        if ( ! _pending_shlibs ) {
            fprintf(stderr, "objc_hpux_register_shlib() - fatal: Failed to malloc _pending_shlibs list. Exit\n");
            exit(-1);
        }
        memcpy(_pending_shlibs, _pending_shlibs_temp, _pending_shlibs_count);
        if ( _pending_shlibs_temp != _pending_shlibs_init ) {
            _free_ptr(_pending_shlibs_temp);
        }
    }

    if ( ! (ptr = _malloc_ptr(strlen(desc->filename)+1+sizeof(void *)*2)) ) {
        fprintf(stderr, "objc_hpux_register_shlib() - fatal: Failed to malloc _pending_shlibs entry. Exit\n");
        exit(-1);
    }
    strcpy(ptr+sizeof(void*), desc->filename);
    *(void **)ptr = desc->handle;
    _pending_shlibs[_pending_shlibs_count] = ptr;
    return;
}

static void delete_pending_shlib(const char *path)
{
    unsigned idx;
    char *ptr;

    if (_verbose > 1) {
        fprintf(stderr, "delete_pending_shlib(): Deleting shlib %s\n", path);
    }

    for ( idx = 0; idx < _pending_shlibs_count; idx++ ) {
        ptr = _pending_shlibs[idx]+sizeof(void*);
        if ( ! strcmp(ptr, path) ) {
            if ( strcmp(ptr, "<NULL>") ) {
                _free_ptr(_pending_shlibs[idx]);
                _pending_shlibs[idx] = "<NULL>";
                if (_verbose > 1) {
                    fprintf(stderr, "delete_pending_shlib(): Found and deleted shlib %s\n", path);
                }
            }
            return;
        }
    }
}

static int more_pending_shlibs()
{
    unsigned idx;
    char *ptr;

    for ( idx = 0; idx < _pending_shlibs_count; idx++ ) {
        ptr = _pending_shlibs[idx]+sizeof(void*);
        if ( strcmp(ptr, "<NULL>") ) {
            return 0;
        }
    }
    if (_verbose > 1) {
        fprintf(stderr, "more_pending_shlib(): Pending shlibs remain\n");
    }
    return 1;
}


static int dependencies_resolved(char *path)
{
    char **referenced_shlibs;

    referenced_shlibs = __objc_get_referenced_shlibs(path);
    referenced_shlibs++;
    for ( ; strcmp(*referenced_shlibs, "<NULL>"); referenced_shlibs++ ) {
        if ( !already_loaded(*referenced_shlibs) ) {
            if (_verbose > 1) {
                fprintf(stderr, "dependencies_resolved(): Dependencies remaining for shlib %s\n", path);
            }
            return 0;
        }
    }
    if (_verbose > 1) {
        fprintf(stderr, "dependencies_resolved(): Dependencies resolved for shlib %s\n", path);
    }
    return 1;
}


void objc_hpux_register_shlib_handle(void *handle);

static void resolve_pending_shlibs()
{
    char *ptr;
    unsigned idx;

    for ( idx = 0; idx < _pending_shlibs_count; idx++ ) {
        ptr = _pending_shlibs[idx]+sizeof(void*);
        if ( dependencies_resolved(ptr) ) {
            if ( _verbose >= 1 ) {
                fprintf(stderr, "resolve_pending_shlibs(): Examining shlib %s\n", ptr);
            }
            objc_hpux_register_shlib_handle(*(void **)_pending_shlibs[idx]);
            delete_pending_shlib(ptr);
            insert_loaded_shlib(ptr);
        }
    }
}


void objc_hpux_register_shlib_handle(void *handle)
{
    extern void *CMH;
    extern objc_finish_header();

    int isCMHReset;
    int sym_count, sym_idx;
    struct shl_symbol *symbols;

    // use malloc and not _malloc_ptr
    sym_count = shl_getsymbols(handle, TYPE_PROCEDURE,
                        EXPORT_SYMBOLS, malloc, &symbols);
    if ( sym_count == -1 ) {
        fprintf(stderr, "objc_hpux_register_shlib_handle() - WARNING: shl_getsymbols failed. Continue at your own risk...\n");
        //exit(-1);
        return;
    }

    isCMHReset = 0;
    for ( sym_idx = 0; sym_idx < sym_count; sym_idx++ ) {
        if ( !strncmp(symbols[sym_idx].name, "_GLOBAL_$I$", 11) ) {
            if ( ! isCMHReset ) {
                 CMH = (void *)0;
                 isCMHReset = 1;
            }
            if ( _verbose >= 3 )
                fprintf(stderr, "objc_hpux_register_shlib_handle():    found ctor %s...\n", symbols[sym_idx].name);
            ((void (*)())(symbols[sym_idx].value))();
            if ( _verbose >= 3 )
                fprintf(stderr, "objc_hpux_register_shlib_handle():    ... and executed it\n");
        }
    }
    if ( isCMHReset )
        objc_finish_header();

    // use free and not _free_ptr
    free(symbols);
    return;
}

void objc_hpux_register_shlib()
{
    int idx;
    int registered_at_least_one_shlib;
    struct shl_descriptor desc;

    OBJC_SHLIB_INIT_REGISTRATION;

    if (_reg_mechanism != REG_METHOD_CHATR) return;

    if ( _verbose == 2 || _verbose == 4 )
        fprintf(stderr, "----        ----\n");

    registered_at_least_one_shlib = 0;
    for ( idx = 0; !shl_get_r(idx, &desc); idx++ ) {
        if ( already_loaded(desc.filename) ) {
            if ( _verbose == 2 || _verbose == 4 )
                fprintf(stderr, "objc_hpux_register_shlib(): Skipping shlib %s\n", desc.filename);
            continue;
        }

        if ( !dependencies_resolved(desc.filename) ) {
            insert_pending_shlib(&desc);
            continue;
        }

        if ( _verbose >= 1 || _verbose == 4 )
            fprintf(stderr, "objc_hpux_register_shlib(): Examining shlib %s\n", desc.filename);
        objc_hpux_register_shlib_handle(desc.handle);
        delete_pending_shlib(desc.filename);
        insert_loaded_shlib(desc.filename);
        registered_at_least_one_shlib = 1;
    }

    // This is the last call and the last chance to resolve them all!
    if ( ! registered_at_least_one_shlib ) {
        while ( more_pending_shlibs() )
            resolve_pending_shlibs();
    }

    if ( _verbose == 2 || _verbose == 4)
        fprintf(stderr, "----        ----\n\n");

    return;
}

/*
 * An alternative, more efficient shlib registration that relies on the initializer
 * functions in each shlib being called in the correct order. This was initially deemed not to work. aB.
 */
void objc_hpux_register_named_shlib(const char *shlib_name)
{
    int idx;
    struct shl_descriptor desc;
    char buf1[256], *p1;
    char buf2[256], *p2;

    OBJC_SHLIB_INIT_REGISTRATION;

    strcpy(buf1, shlib_name);
    p1 = my_basename(buf1);

    /* Do we use the new registration method or not ? */
    if (_reg_mechanism == REG_METHOD_DLD) {
        if ( _verbose >= 1 ) {
            fprintf(stderr, "objc_hpux_register_named_shlib(): Registering shlib %s\n", shlib_name);
        }
        for ( idx = 0; !shl_get_r(idx, &desc); idx++ ) {
            strcpy(buf2, desc.filename);
            p2 = my_basename(buf2);
            /* Avoid registering the main executable (initializer == NULL) */
            if ( strcmp(p1, p2) == 0 && desc.initializer != NULL) {
                objc_hpux_register_shlib_handle(desc.handle);
                if ( _verbose >= 1 ) {
                    fprintf(stderr, "objc_hpux_register_named_shlib(): Registered shlib %s desc.initializer %x\n", desc.filename, desc.initializer);
                }
                break;
            }
        }
    } else {
        /* Just do things the old way */
        objc_hpux_register_shlib();
    }

}

/* Hardcoded in here for now as libpdo is built in a special manner */
void objc_hpux_register_shlib_pdo()
{
    objc_hpux_register_named_shlib("libpdo.sl");
}


unsigned __objc_msg_spew(unsigned self_obj, unsigned self_cls, unsigned addr)
{
    fprintf(stderr, "\n\n****    __objc_msg_spew(self:0x%08x  self->isa:0x%08x  cls:0x%08x)    ****\n\n", self_obj, *(unsigned *)self_obj, self_cls);
    return addr;
}
