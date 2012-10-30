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

test:
	make -C test

.SUFFIXES:
.PHONY: default all test build optimized debug profile installsrc installhdrs install clean prebuild build-optimized build-debug build-profile prebuild-optimized prebuild-debug prebuild-profile compile-optimized compile-debug compile-profile link-optimized link-debug link-profile postbuild

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
WARNING_FLAGS = -Wall -Wno-four-char-constants -Wshorten-64-to-32 -Wno-deprecated-declarations
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
ORDERFILE = $(SRCROOT)/libobjc.order
endif
ifneq "$(ORDERFILE)" ""
ORDER = -Wl,-order_file,$(ORDERFILE)
else 
ORDER = 
endif

ifeq "$(USER)" ""
USER = unknown
endif

CFLAGS = -g -fno-common -fdollars-in-identifiers -pipe $(PLATFORM_CFLAGS) $(WARNING_FLAGS) -I$(SYMROOT) -I. -I$(SYMROOT)/ProjectHeaders
LDFLAGS = 

LIBRARY_EXT = .dylib

PUBLIC_HEADER_INSTALLDIR = usr/include/objc
OTHER_HEADER_INSTALLDIR = usr/local/include/objc
INSTALLDIR = usr/lib

ifeq "$(PLATFORM)" "Darwin"
LDFLAGS += -dynamiclib -dynamic -compatibility_version 1 -current_version $(CURRENT_PROJECT_VERSION) 
endif

ifeq "$(PLATFORM)" "Darwin"
# GC flags
LDFLAGS += -lauto
#CFLAGS += -fobjc-gc -Wassign-intercept
endif

CFLAGS += $(OTHER_CFLAGS) $(RC_CFLAGS)
LDFLAGS += $(OTHER_LDFLAGS)

ifndef OPTIMIZATION_CFLAGS
OPTIMIZATION_CFLAGS = -Os -DNDEBUG
endif
ifndef DEBUG_CFLAGS
DEBUG_CFLAGS = -DDEBUG
endif
ifndef PROFILE_CFLAGS
PROFILE_CFLAGS = -DPROFILE -pg -Os -DNDEBUG
endif

CFLAGS_OPTIMIZED = $(OPTIMIZATION_CFLAGS) $(CFLAGS)
CFLAGS_DEBUG     = $(DEBUG_CFLAGS) $(CFLAGS)
CFLAGS_PROFILE   = $(PROFILE_CFLAGS) $(CFLAGS)

LDFLAGS_OPTIMIZED = $(LDFLAGS) -g
LDFLAGS_DEBUG     = $(LDFLAGS) -g
LDFLAGS_PROFILE   = $(LDFLAGS) -g -pg

SUBDIRS = . runtime runtime/OldClasses.subproj runtime/Messengers.subproj runtime/Accessors.subproj runtime/Auto.subproj

# files to compile
SOURCES=
# files to compile into separate linker modules
MODULE_SOURCES=
# files to not compile
OTHER_SOURCES=
# headers to install in /usr/include/objc
PUBLIC_HEADERS=
# headers that don't get installed
PRIVATE_HEADERS=
# headers to install in /usr/local/include/objc
OTHER_HEADERS=

# runtime
SOURCES += $(addprefix runtime/, \
	Object.m Protocol.m hashtable2.m maptable.m objc-class.m \
	objc-errors.m objc-cache.m objc-initialize.m \
	objc-file.m objc-load.m objc-runtime.m objc-sel.m \
	objc-sync.m objc-exception.m objc-auto.m objc-sel-set.m objc-rtp.m \
	objc-layout.m objc-loadmethod.m objc-class-old.m objc-runtime-old.m \
	objc-runtime-new.m objc-typeencoding.m objc-lockdebug.m \
	phash.m lookupa.m \
	)
PUBLIC_HEADERS += $(addprefix runtime/, \
	objc.h runtime.h message.h \
	objc-class.h objc-api.h objc-load.h objc-runtime.h Object.h \
	objc-sync.h objc-exception.h objc-auto.h  \
	Protocol.h error.h hashtable2.h \
	)
PRIVATE_HEADERS += $(addprefix runtime/, \
	objc-private.h objc-config.h objc-sel-table.h objc-sel-set.h \
	objc-rtp.h objc-initialize.h objc-loadmethod.h objc-runtime-new.h \
	phash.h lookupa.h standard.h \
	)
OTHER_HEADERS += runtime/maptable.h runtime/objc-auto.h

# OldClasses
SOURCES += runtime/OldClasses.subproj/List.m
PUBLIC_HEADERS += runtime/OldClasses.subproj/List.h

# Messengers
SOURCES += runtime/Messengers.subproj/objc-msg.s
OTHER_SOURCES += runtime/Messengers.subproj/objc-msg-ppc.s runtime/Messengers.subproj/objc-msg-ppc64.s runtime/Messengers.subproj/objc-msg-i386.s runtime/Messengers.subproj/objc-msg-x86_64.s

# Property Accessors
SOURCES += runtime/Accessors.subproj/objc-accessors.m runtime/Accessors.subproj/objc-accessors-arch.s
PRIVATE_HEADERS += runtime/Accessors.subproj/objc-accessors.h runtime/Accessors.subproj/objc-accessors-table.h
OTHER_SOURCES += runtime/Accessors.subproj/objc-accessors-ppc.s runtime/Accessors.subproj/objc-accessors-ppc64.s
OTHER_SOURCES += runtime/Accessors.subproj/objc-accessors-i386.s runtime/Accessors.subproj/objc-accessors-x86_64.s

# Auto support
SOURCES += runtime/Auto.subproj/objc-auto.s
OTHER_SOURCES += runtime/Auto.subproj/objc-auto-ppc.s runtime/Auto.subproj/objc-auto-ppc64.s runtime/Auto.subproj/objc-auto-i386.s runtime/Auto.subproj/objc-auto-x86_64.s

# RTP symbols for gdb
# See also $(OBJROOT)/runtime/objc-rtp-sym.ppc.o rule below.
OTHER_SOURCES += runtime/objc-rtp-sym.s

# Interposing support.
# This code is built into a second module so dyld's function interposing 
# can manipulate the calls.
MODULE_SOURCES += runtime/Messengers.subproj/objc-msg-stub.s
OTHER_SOURCES += runtime/Messengers.subproj/objc-msg-stub-ppc.s runtime/Messengers.subproj/objc-msg-stub-ppc64.s runtime/Messengers.subproj/objc-msg-stub-i386.s runtime/Messengers.subproj/objc-msg-stub-x86_64.s

# project root
OTHER_SOURCES += Makefile APPLE_LICENSE libobjc.order

# The GC Mark tool that marks our .o files as if they had been compiled with write-barriers
OTHER_SOURCES += markgc.c
MARKGC = $(OBJROOT)/markgc


OBJECTS = $(addprefix $(OBJROOT)/, $(addsuffix .o, $(basename $(SOURCES) ) ) )
OBJECTS_OPTIMIZED = $(OBJECTS:.o=.opt.o)
OBJECTS_DEBUG = $(OBJECTS:.o=.debug.o)
OBJECTS_PROFILE = $(OBJECTS:.o=.profile.o)

MODULE_OBJECTS = $(addprefix $(OBJROOT)/, $(addsuffix .o, $(basename $(MODULE_SOURCES) ) ) )
MODULE_OBJECTS_OPTIMIZED = $(MODULE_OBJECTS:.o=.opt.o)
MODULE_OBJECTS_DEBUG = $(MODULE_OBJECTS:.o=.debug.o)
MODULE_OBJECTS_PROFILE = $(MODULE_OBJECTS:.o=.profile.o)

# For simplicity, each object target depends on all objc headers. Most of 
# them come close to requiring this anyway, and rebuild from scratch is fast.
DEPEND_HEADERS = $(addprefix $(SRCROOT)/, \
        $(PUBLIC_HEADERS) $(PRIVATE_HEADERS) $(OTHER_HEADERS) )

$(OBJROOT)/%.opt.o :     $(SRCROOT)/%.m  $(DEPEND_HEADERS) $(MARKGC)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_OPTIMIZED) "$<" -c -o "$@"
	$(SILENT) $(MARKGC) -p "$@"

$(OBJROOT)/%.debug.o :   $(SRCROOT)/%.m  $(DEPEND_HEADERS) $(MARKGC)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_DEBUG)     "$<" -c -o "$@"
	$(SILENT) $(MARKGC) -p "$@"

$(OBJROOT)/%.profile.o : $(SRCROOT)/%.m  $(DEPEND_HEADERS) $(MARKGC)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_PROFILE)   "$<" -c -o "$@"
	$(SILENT) $(MARKGC) -p "$@"

$(OBJROOT)/%.opt.o :     $(SRCROOT)/%.c  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_OPTIMIZED) "$<" -c -o "$@"

$(OBJROOT)/%.debug.o :   $(SRCROOT)/%.c  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_DEBUG)     "$<" -c -o "$@"

$(OBJROOT)/%.profile.o : $(SRCROOT)/%.c  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_PROFILE)   "$<" -c -o "$@"

$(OBJROOT)/%.opt.o :     $(SRCROOT)/%.s  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_OPTIMIZED) "$<" -c -o "$@"

$(OBJROOT)/%.debug.o :   $(SRCROOT)/%.s  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_DEBUG)     "$<" -c -o "$@"

$(OBJROOT)/%.profile.o : $(SRCROOT)/%.s  $(DEPEND_HEADERS)
	$(SILENT) $(ECHO) "    ... $<"
	$(SILENT) $(CC) $(ARCH_FLAGS) $(CFLAGS_PROFILE)   "$<" -c -o "$@"

# Additional dependency: objc-msg.s depends on objc-msg-ppc.s and 
# objc-msg-i386.s, which it includes.
$(OBJROOT)/runtime/Messengers.subproj/objc-msg.opt.o \
$(OBJROOT)/runtime/Messengers.subproj/objc-msg.debug.o \
$(OBJROOT)/runtime/Messengers.subproj/objc-msg.profile.o : \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-ppc.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-ppc64.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-i386.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-x86_64.s

# Additional dependency: objc-msg-sutb.s depends on objc-msg-stub-ppc.s and 
# objc-msg-stub-i386.s, which it includes.
$(OBJROOT)/runtime/Messengers.subproj/objc-msg-stub.opt.o \
$(OBJROOT)/runtime/Messengers.subproj/objc-msg-stub.debug.o \
$(OBJROOT)/runtime/Messengers.subproj/objc-msg-stub.profile.o : \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-stub-ppc.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-stub-ppc64.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-stub-i386.s \
	$(SRCROOT)/runtime/Messengers.subproj/objc-msg-stub-x86_64.s

# Additional dependency: objc-auto.s depends on objc-auto-ppc.s and 
# objc-auto-i386.s, which it includes.
$(OBJROOT)/runtime/Auto.subproj/objc-auto.opt.o \
$(OBJROOT)/runtime/Auto.subproj/objc-auto.debug.o \
$(OBJROOT)/runtime/Auto.subproj/objc-auto.profile.o : \
	$(SRCROOT)/runtime/Auto.subproj/objc-auto-ppc.s \
	$(SRCROOT)/runtime/Auto.subproj/objc-auto-ppc64.s \
	$(SRCROOT)/runtime/Auto.subproj/objc-auto-i386.s \
	$(SRCROOT)/runtime/Auto.subproj/objc-auto-x86_64.s

# Additional rules: objc-rtp-sym.s needs to be built with a per-arch seg1addr, 
# and need to be stripped here because stripping the dylib does not remove 
# debug info from the magic sections.
# objc-rtp-sym.s is not in SOURCES, and objc-rtp-sym.o is not in OBJECTS
$(OBJROOT)/runtime/objc-rtp-sym.ppc.o: $(SRCROOT)/runtime/objc-rtp-sym.s
	$(SILENT) $(CC) $(CFLAGS_OPTIMIZED) -arch ppc "$<" -c -o "$@.temp"
	$(SILENT) $(STRIP) -S "$@.temp"
	$(SILENT) $(LD) -arch ppc -seg1addr 0xfffec000 "$@.temp" -r -o "$@"

$(OBJROOT)/runtime/objc-rtp-sym.ppc64.o: $(SRCROOT)/runtime/objc-rtp-sym.s
	$(SILENT) $(CC) $(CFLAGS_OPTIMIZED) -arch ppc64 "$<" -c -o "$@.temp"
	$(SILENT) $(STRIP) -S "$@.temp"
	$(SILENT) $(LD) -arch ppc64 -seg1addr 0xfffffffffffec000 "$@.temp" -r -o "$@"

$(OBJROOT)/runtime/objc-rtp-sym.i386.o: $(SRCROOT)/runtime/objc-rtp-sym.s
	$(SILENT) $(CC) $(CFLAGS_OPTIMIZED) -arch i386 "$<" -c -o "$@.temp"
	$(SILENT) $(STRIP) -S "$@.temp"
	$(SILENT) $(LD) -arch i386 -seg1addr 0xfffe8000 "$@.temp" -r -o "$@"

$(OBJROOT)/runtime/objc-rtp-sym.x86_64.o: $(SRCROOT)/runtime/objc-rtp-sym.s
	$(SILENT) $(CC) $(CFLAGS_OPTIMIZED) -arch x86_64 "$<" -c -o "$@.temp"
	$(SILENT) $(STRIP) -S "$@.temp"
	$(SILENT) $(LD) -arch x86_64 -seg1addr 0xfffffffffffec000 "$@.temp" -r -o "$@"

# Additional rule: markgc tool to pretend we compiled with GC write-barriers
$(MARKGC): $(SRCROOT)/markgc.c
	$(SILENT) $(ECHO) "Building markgc tool ..."
	$(SILENT) $(CC) -std=gnu99 "$<" -o "$@"

# Additional linkage: LP64 targets require libstdc++
LIBS_ppc64 = -lstdc++
LIBS_x86_64 = -lstdc++

# These are the main targets:
#    build		builds the library to OBJROOT and SYMROOT
#    installsrc		copies the sources to SRCROOT
#    installhdrs	install only the headers to DSTROOT
#    install		build, then install the headers and library to DSTROOT
#    clean		removes build products in OBJROOT and SYMROOT
#
#    optimized          same as 'build' but builds optimized library only
#    debug              same as 'build' but builds debug library only
#    profile            same as 'build' but builds profile library only

# Default build doesn't currently build the debug library.
build: prebuild build-optimized build-profile postbuild

optimized: prebuild build-optimized postbuild
debug: prebuild build-debug postbuild
profile: prebuild build-profile postbuild

installsrc:
	$(SILENT) $(ECHO) "Installing source from . to $(SRCROOT)..."
ifeq "$(SRCROOT)" "."
	$(SILENT) $(ECHO) "SRCROOT must be defined to be the destination directory; it cannot be '.'"
	exit 1
endif
	$(SILENT) $(TAR) -cf $(SRCROOT)/objc4.sources.tar $(SOURCES) $(PUBLIC_HEADERS) $(PRIVATE_HEADERS) $(OTHER_HEADERS) $(OTHER_SOURCES) $(MODULE_SOURCES)
	$(SILENT) $(CD) $(SRCROOT) && $(TAR) -xf $(SRCROOT)/objc4.sources.tar 
	$(SILENT) $(REMOVE) -f $(SRCROOT)/objc4.sources.tar

installhdrs:
	$(SILENT) $(ECHO) "Installing headers from $(SRCROOT) to $(DSTROOT)/$(HEADER_INSTALLDIR)..."

	$(SILENT) $(MKDIRS) $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)
	-$(SILENT) $(CHMOD) +w $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)/*.h
	$(SILENT) $(COPY) $(addprefix $(SRCROOT)/, $(PUBLIC_HEADERS) ) \
                          $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)
# duplicate hashtable2.h to hashtable.h
	$(SILENT) $(COPY) $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)/hashtable2.h \
			  $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)/hashtable.h
	$(SILENT) $(CHMOD) -w  $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)/*.h
	$(SILENT) $(CHMOD) a+r $(DSTROOT)/$(PUBLIC_HEADER_INSTALLDIR)/*.h

	$(SILENT) $(MKDIRS) $(DSTROOT)/$(OTHER_HEADER_INSTALLDIR)
	-$(SILENT) $(CHMOD) +w $(DSTROOT)/$(OTHER_HEADER_INSTALLDIR)/*.h
	$(SILENT) $(COPY) $(addprefix $(SRCROOT)/, $(OTHER_HEADERS) ) \
                          $(DSTROOT)/$(OTHER_HEADER_INSTALLDIR)
	$(SILENT) $(CHMOD) -w  $(DSTROOT)/$(OTHER_HEADER_INSTALLDIR)/*.h
	$(SILENT) $(CHMOD) a+r $(DSTROOT)/$(OTHER_HEADER_INSTALLDIR)/*.h


	$(SILENT) $(RM) -f $(DSTROOT)$(PUBLIC_HEADER_DIR)$(PUBLIC_HEADER_DIR_SUFFIX)/hashtable.h


install: build installhdrs
	$(SILENT) $(ECHO) "Installing products from $(SYMROOT) to $(DSTROOT)..."

	$(SILENT) $(MKDIRS) $(DSTROOT)/$(INSTALLDIR)
	-$(SILENT) $(CHMOD) +w $(DSTROOT)/$(INSTALLDIR)

	$(SILENT) $(REMOVE) -f $(DSTROOT)/$(INSTALLDIR)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(REMOVE) -f $(DSTROOT)/$(INSTALLDIR)/libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(REMOVE) -f $(DSTROOT)/$(INSTALLDIR)/libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT)

# optimized
	$(SILENT) $(COPY) $(SYMROOT)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT) $(DSTROOT)/$(INSTALLDIR)
	$(SILENT) $(STRIP) -S $(DSTROOT)/$(INSTALLDIR)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT)
	-$(SILENT) $(CHOWN) root:wheel $(DSTROOT)/$(INSTALLDIR)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(CHMOD) 755 $(DSTROOT)/$(INSTALLDIR)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(CD) $(DSTROOT)/$(INSTALLDIR)  &&  \
		$(SYMLINK) libobjc.$(VERSION_NAME)$(LIBRARY_EXT) libobjc$(LIBRARY_EXT)

# debug (allowed not to exist)
	-$(SILENT) $(COPY) $(SYMROOT)/libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT) $(DSTROOT)/$(INSTALLDIR)
	-$(SILENT) $(CHOWN) root:wheel $(DSTROOT)/$(INSTALLDIR)/libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT)
	-$(SILENT) $(CHMOD) 755 $(DSTROOT)/$(INSTALLDIR)/libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT)
	-$(SILENT) $(CD) $(DSTROOT)/$(INSTALLDIR)  &&  \
		test -e libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT)  &&  \
		$(SYMLINK) libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT) libobjc_debug$(LIBRARY_EXT)  &&  \
		$(SYMLINK) libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT) libobjc.$(VERSION_NAME)_debug$(LIBRARY_EXT)


# profile (allowed not to exist)
	-$(SILENT) $(COPY) $(SYMROOT)/libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT) $(DSTROOT)/$(INSTALLDIR)
	-$(SILENT) $(CHOWN) root:wheel $(DSTROOT)/$(INSTALLDIR)/libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT)
	-$(SILENT) $(CHMOD) 755 $(DSTROOT)/$(INSTALLDIR)/libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT)
	-$(SILENT) $(CD) $(DSTROOT)/$(INSTALLDIR)  &&  \
		test -e libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT)  &&  \
		$(SYMLINK) libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT) libobjc_profile$(LIBRARY_EXT)  &&  \
		$(SYMLINK) libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT) libobjc.$(VERSION_NAME)_profile$(LIBRARY_EXT)


clean:
	$(SILENT) $(ECHO) "Deleting build products..."
	$(SILENT) $(REMOVE) -f \
	  $(foreach A, $(ARCH_LIST), \
	    $(OBJROOT)/libobjc_debug.$A.$(VERSION_NAME)$(LIBRARY_EXT) \
	    $(OBJROOT)/libobjc_profile.$A.$(VERSION_NAME)$(LIBRARY_EXT) \
	    $(OBJROOT)/libobjc.$A.$(VERSION_NAME)$(LIBRARY_EXT) \
	    $(OBJROOT)/runtime/objc-rtp-sym.$A.o \
	    $(OBJROOT)/runtime/objc-rtp-sym.$A.o.temp \
	  )

	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc.optimized.o
	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc.debug.o
	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc.profile.o

	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc_debug.$(VERSION_NAME)$(LIBRARY_EXT)
	$(SILENT) $(REMOVE) -f $(SYMROOT)/libobjc_profile.$(VERSION_NAME)$(LIBRARY_EXT)

	$(SILENT) $(REMOVE) -f $(OBJECTS_OPTIMIZED)
	$(SILENT) $(REMOVE) -f $(OBJECTS_DEBUG)
	$(SILENT) $(REMOVE) -f $(OBJECTS_PROFILE)

	$(SILENT) $(REMOVE) -f $(MODULE_OBJECTS_OPTIMIZED)
	$(SILENT) $(REMOVE) -f $(MODULE_OBJECTS_DEBUG)
	$(SILENT) $(REMOVE) -f $(MODULE_OBJECTS_PROFILE)

	$(SILENT) $(REMOVE) -rf $(SYMROOT)/ProjectHeaders

	$(SILENT) $(REMOVE) -f $(MARKGC)

prebuild:
	$(SILENT) $(ECHO) "Prebuild-setup..."

# Install headers into $(SYMROOT)/ProjectHeaders so #includes can find them 
# even if they're not installed in /usr. 
	$(SILENT) $(MKDIRS) $(SYMROOT)
	$(SILENT) $(REMOVE_RECUR) $(SYMROOT)/ProjectHeaders
	$(SILENT) $(MKDIRS) $(SYMROOT)/ProjectHeaders
	$(SILENT) $(ECHO) "Copying headers from $(SRCROOT) to $(SYMROOT)/ProjectHeaders..."
	$(SILENT) $(COPY) $(addprefix $(SRCROOT)/, $(PRIVATE_HEADERS) ) $(SYMROOT)/ProjectHeaders
	$(SILENT) $(MKDIRS) $(SYMROOT)/ProjectHeaders/objc
	$(SILENT) $(COPY) $(addprefix $(SRCROOT)/, $(PUBLIC_HEADERS) ) $(SYMROOT)/ProjectHeaders/objc
	$(SILENT) $(COPY) $(addprefix $(SRCROOT)/, $(OTHER_HEADERS) ) $(SYMROOT)/ProjectHeaders/objc



build-optimized: prebuild-optimized compile-optimized link-optimized
build-debug: prebuild-debug compile-debug link-debug
build-profile: prebuild-profile compile-profile link-profile


prebuild-optimized:
	$(SILENT) $(ECHO) "Building (optimized) ..."
	$(SILENT) $(MKDIRS) $(foreach S, $(SUBDIRS), $(OBJROOT)/$(S) )

prebuild-debug:
	$(SILENT) $(ECHO) "Building (debug) ..."
	$(SILENT) $(MKDIRS) $(foreach S, $(SUBDIRS), $(OBJROOT)/$(S) )

prebuild-profile:
	$(SILENT) $(ECHO) "Building (profile) ..."
	$(SILENT) $(MKDIRS) $(foreach S, $(SUBDIRS), $(OBJROOT)/$(S) )


compile-optimized: $(OBJECTS_OPTIMIZED) $(MODULE_OBJECTS_OPTIMIZED) $(foreach A, $(ARCH_LIST), $(OBJROOT)/runtime/objc-rtp-sym.$A.o )
compile-debug: $(OBJECTS_DEBUG) $(MODULE_OBJECTS_DEBUG) $(foreach A, $(ARCH_LIST), $(OBJROOT)/runtime/objc-rtp-sym.$A.o )
compile-profile: $(OBJECTS_PROFILE) $(MODULE_OBJECTS_PROFILE) $(foreach A, $(ARCH_LIST), $(OBJROOT)/runtime/objc-rtp-sym.$A.o )


# link lib-suffix, LDFLAGS, OBJECTS, MODULE_OBJECTS
#  libsuffix should be "" or _debug or _profile
ifeq "$(PLATFORM)" "Darwin"

define link
	$(foreach A, $(ARCH_LIST), \
	  $(SILENT) $(LD) -r \
	    -arch $A \
	    -o $(OBJROOT)/libobjc$1.$A.o \
	    $3 ; \
	  $(SILENT) $(CC) $2 \
	    -arch $A \
	    $(LIBS_$(A)) \
	    $(ORDER) \
	    -sectcreate __DATA __commpage $(OBJROOT)/runtime/objc-rtp-sym.$A.o \
	    -install_name /$(INSTALLDIR)/libobjc$1.$(VERSION_NAME)$(LIBRARY_EXT) \
	    -o $(OBJROOT)/libobjc$1.$A.$(VERSION_NAME)$(LIBRARY_EXT) \
	    $(OBJROOT)/libobjc$1.$A.o $4 ; \
	  )
	$(SILENT) $(LIPO) \
	  -create -output $(SYMROOT)/libobjc$1.$(VERSION_NAME)$(LIBRARY_EXT) \
	  $(foreach A, $(ARCH_LIST), -arch $A $(OBJROOT)/libobjc$1.$A.$(VERSION_NAME)$(LIBRARY_EXT) )
endef

else
# PLATFORM != Darwin
define link
	$(SILENT) $(ECHO) "Don't know how to link for platform '$(PLATFORM)'"
endef

endif


link-optimized:
	$(SILENT) $(ECHO) "Linking (optimized)..."
	$(call link,,$(LDFLAGS_OPTIMIZED),$(OBJECTS_OPTIMIZED),$(MODULE_OBJECTS_OPTIMIZED) )

link-debug:
	$(SILENT) $(ECHO) "Linking (debug)..."
	$(call link,_debug,$(LDFLAGS_DEBUG),$(OBJECTS_DEBUG),$(MODULE_OBJECTS_DEBUG) )

link-profile:
	$(SILENT) $(ECHO) "Linking (profile)..."
	$(call link,_profile,$(LDFLAGS_PROFILE),$(OBJECTS_PROFILE),$(MODULE_OBJECTS_PROFILE) )


postbuild:
	$(SILENT) $(ECHO) "Done!"


