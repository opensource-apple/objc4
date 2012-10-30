# use LDFLAGS not LFLAGS
#
# Simple makefile for building objc4 on Darwin
#
# These make variables (or environment variables) are used
# when defined:
#	SRCROOT		path location of root of source hierarchy;
#			defaults to ".", but must be set to a
#			destination path for installsrc target.
#	OBJROOT		path location where .o files will be put;
#			defaults to SRCROOT.
#	SYMROOT		path location where build products will be
#			put; defaults to SRCROOT.
#	DSTROOT		path location where installed products will
#			be put; defaults to / .
# OBJROOT and SYMROOT should not be directories shared with other
# built projects.
#	PLATFORM	name of platform being built on
#	USER		name of user building the project
#	ARCHS		list of archs for which to build
#	RC_ARCHS	more archs for which to build (build system)
#	OTHER_CFLAGS	other flags to be passed to compiler
#	RC_CFLAGS	more flags to be passed to compiler (build system)
#	OTHER_LDFLAGS	other flags to be passed to the link stage
#

# Default targets
default: build
all: build

.SUFFIXES:
.PHONY: default all build optimized debug profile installsrc installhdrs install clean prebuild build-optimized build-debug build-profile prebuild-optimized prebuild-debug prebuild-profile compile-optimized compile-debug compile-profile link-optimized link-debug link-profile postbuild

CURRENT_PROJECT_VERSION = 227

VERSION_NAME = A

# First figure out the platform if not specified, so we can use it in the
# rest of this file.  Currently defined values: Darwin
ifeq "$(PLATFORM)" ""
PLATFORM := $(shell uname)
endif

ifndef SRCROOT
SRCROOT = .
endif

ifndef OBJROOT
OBJROOT = $(SRCROOT)
endif

ifndef SYMROOT
SYMROOT = $(SRCROOT)
endif

ifndef DSTROOT
DSTROOT = /
endif

ifeq "$(PLATFORM)" "Darwin"
CC = /usr/bin/cc
else
CC = /usr/bin/gcc
endif

ECHO = @/bin/echo
MKDIRS = /bin/mkdir -p
CD = cd
COPY = /bin/cp
COPY_RECUR = /bin/cp -r
REMOVE = /bin/rm
REMOVE_RECUR = /bin/rm -rf
SYMLINK = /bin/ln -s
CHMOD = /bin/chmod
CHOWN = /usr/sbin/chown
TAR = /usr/bin/tar
STRIP = /usr/bin/strip
NMEDIT = /usr/bin/nmedit
LIPO = /usr/bin/lipo

ifeq "$(PLATFORM)" "Darwin"
WARNING_FLAGS = -Wmost -Wno-precomp -Wno-four-char-constants
endif

ARCH_LIST= 
ifeq "$(PLATFORM)" "Darwin"

ifneq "$(ARCHS)" ""
ARCH_LIST += $(ARCHS)
else
ifneq "$(RC_ARCHS)" ""
ARCH_LIST += $(RC_ARCHS)
else
ARCH_LIST += $(shell /usr/bin/arch)
endif
endif

ARCH_FLAGS = $(foreach A, $(ARCH_LIST), $(addprefix -arch , $(A)))

endif


ifeq "$(ORDERFILE)" ""
ORDERFILE = $(wildcard /usr/local/lib/OrderFiles/libobjc.order)
endif
ifneq "$(ORDERFILE)" ""
ORDER = -sectorder __TEXT __text $(ORDERFILE)
else 
ORDER = 
endif

ifeq "$(USER)" ""
USER = unknown
endif

CFLAGS = -g -fno-common -fobjc-exceptions -pipe $(PLATFORM_CFLAGS) $(WARNING_FLAGS) -I$(SYMROOT) -I. -I$(SYMROOT)/ProjectHeaders
LDFLAGS = 

LIBRARY_EXT = .dylib

PUBLIC_HEADER_INSTALLDIR = usr/include/objc
OTHER_HEADER_INSTALLDIR = usr/local/include/objc
INSTALLDIR = usr/lib

ifeq "$(PLATFORM)" "Darwin"
LDFLAGS += -dynamiclib -dynamic -compatibility_version 1 -current_version $(CURRENT_PROJECT_VERSION) 
endif


CFLAGS += $(OTHER_CFLAGS) $(RC_CFLAGS)
LDFLAGS += $(OTHER_LDFLAGS)

ifndef OPTIMIZATION_CFLAGS
OPTIMIZATION_CFLAGS = -Os
endif
ifndef DEBUG_CFLAGS
DEBUG_CFLAGS = -DDEBUG
endif
ifndef PROFILE_CFLAGS
PROFILE_CFLAGS = -DPROFILE -pg -Os
endif

CFLAGS_OPTIMIZED = $(OPTIMIZATION_CFLAGS) $(CFLAGS)
CFLAGS_DEBUG     = $(DEBUG_CFLAGS) $(CFLAGS)
CFLAGS_PROFILE   = $(PROFILE_CFLAGS) $(CFLAGS)

LDFLAGS_OPTIMIZED = $(LDFLAGS) -g
LDFLAGS_DEBUG     = $(LDFLAGS) -g
LDFLAGS_PROFILE   = $(LDFLAGS) -g -pg

SUBDIRS = . runtime runtime/OldClasses.subproj runtime/Messengers.subproj runtime/Auto.subproj

# files to compile
SOURCES=
# files to compile into separate linker modules
MODULE_SOURCES=
# files to not compile
OTHER_SOURCES=
# headers to install in /usr/include/objc
PUBLIC_HEADERS=
