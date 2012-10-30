# a "simple test" contains a single .m file
# and optionally an expected-stderr file
SIMPLE_TESTS = category classname classpair classversion copyIvarList \
	copyMethodList copyPropertyList createInstance \
	definitions duplicateClass exc exchangeImp \
	forward gdb getMethod layout ignoredSelector initialize \
	instanceSize ismeta ivar load \
	msgSend property protocol protocol_copyMethodList addMethod \
	protocol_copyPropertyList protocol_cw sel super setSuper methodArgs \
	nilAPIArgs resolve runtime zone weakcopy

# a "simple foundation test" is a simple test with -framework Foundation
SIMPLE_FOUNDATION_TESTS = nsobject foreach accessors \
	classgetclass gdb-lock unwind method_getName \
	synchronized synchronized-counter synchronized-grid

# a "simple CF test" is a simple test with -framework CoreFoundation
SIMPLE_CF_TESTS = association-cf

# a "complex build test" has a dedicated testname.out build rule below
COMPLEX_BUILD_TESTS = cacheflush future unload ivarSlide ivarSlidexx \
	gcenforcer imageorder nsexc concurrentcat load-parallel load-order \
	load-reentrant

# a "complex test" has a dedicated testname run rule below
COMPLEX_RUN_TESTS = gcenforcer_noobjc gcenforcer_nogc gcenforcer_supportsgc \
	gcenforcer_requiresgc weak-missing weak-not-missing

# `make fail` just fails
FAIL_TESTS = fail

# Test-specific flags
CFLAGS_gdb = -Wno-deprecated-declarations -Wno-\#warnings
CFLAGS_setSuper = -Wno-deprecated-declarations
CFLAGS_duplicateClass = -Wno-deprecated-declarations
CFLAGS_protocol = -Wno-deprecated-declarations
CFLAGS_protocol_cw = -Wno-deprecated-declarations
CFLAGS_methodArgs = -Wno-deprecated-declarations
CFLAGS_ignoredSelector = -Wno-deprecated-declarations
CFLAGS_method_getName = -Wno-deprecated-declarations

# `make OBJC_LIB=/path/to/libobjc.A.dylib` tests a specific objc build
ifndef OBJC_LIB
OBJC_LIB = -lobjc
endif
ifneq "$(OBJC_LIB)" "-lobjc"
ENV_PREFIX += DYLD_LIBRARY_PATH=$(dir $(OBJC_LIB))
endif

# `make ARCHS=cpu` tests with the specified architecture (only one allowed)
ifndef ARCHS
ARCHS=$(shell /usr/bin/arch)
endif

# `make ARCH` is unsupported
ifdef ARCH
echo "*** use ARCHS not ARCH!"
exit 1
endif

# `make OTHER_CFLAGS=x` tests with specified flags
CFLAGS = -W -Wall -Wshorten-64-to-32 -g -O0 -fobjc-new-property
CFLAGS += $(OTHER_CFLAGS) -arch $(ARCHS)
LIBS = $(OBJC_LIB) -lauto

# `make GC=YES` tests with GC on
GC_state = nogc
ifdef GC
ifneq "$(GC)" "no"
ifneq "$(GC)" "NO"
GC_state = gc
CFLAGS += -fobjc-gc
endif
endif
endif

# `make LEAK_CHECK=NO` disables leak checking
# `make VALGRIND=YES` runs tests under Valgrind
ifdef VALGRIND
ifneq "$(VALGRIND)" "NO"
VALGRIND_PREFIX = ~public/bin/valgrind --db-listen=no --track-origins=yes
ifeq "$(LEAK_CHECK)" "NO"
VALGRIND_PREFIX += --leak-check=no
else
VALGRIND_PREFIX += --leak-check=full --leak-resolution=high
endif
endif
endif

# `make GUARDMALLOC=YES` runs tests with libgmalloc
ifdef GUARDMALLOC
ifneq "$(GUARDMALLOC)" "NO"
ENV_PREFIX += DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib
endif
endif


RUN = $(ENV_PREFIX) $(VALGRIND_PREFIX)
ERR_CHECK = 2>&1 | perl errcheck.pl

# `make HALT=YES` halts on the first test to fail, this is easier for automated harnesses to detect and report
ifneq "$(HALT)" "YES"
# if we are supposed to continue after error (the default), do something successful if errcheck.pl failed
EAT_ERR = || sh -c ""
endif

FOUNDATION = -framework Foundation
CF = -framework CoreFoundation

# Rebuild executables every time in case arch or cflags changed
.PHONY: $(wildcard *.out) $(wildcard *.dylib)

CC=cc $(CFLAGS)
CXX=c++ $(CFLAGS)  -fobjc-call-cxx-cdtors
CC_C=$(filter-out -fobjc-gc,$(CC))

all: print $(SIMPLE_TESTS) $(COMPLEX_BUILD_TESTS) $(COMPLEX_RUN_TESTS) $(SIMPLE_CF_TESTS) $(SIMPLE_FOUNDATION_TESTS)

print: 
	@echo "Testing library $(OBJC_LIB) ..."
	@echo "CFLAGS = $(CFLAGS)"

debug:
	@ make OBJC_LIB=`pwd`/../build/Debug/libobjc.A.dylib
release:
	@ make OBJC_LIB=`pwd`/../build/Release/libobjc.A.dylib
buildit:
	@ make OBJC_LIB=/tmp/objc.roots/objc~sym/libobjc.A.dylib
buildit-%:
	@ make OBJC_LIB=/tmp/objc-$*.roots/objc-$*~sym/libobjc.A.dylib
clean:
	rm -f *.out *.o *.dylib 
	rm -rf *.dSYM

reallyclean: clean
	rm -f *~

$(SIMPLE_TESTS) $(FAIL_TESTS) $(COMPLEX_BUILD_TESTS) $(SIMPLE_FOUNDATION_TESTS) $(SIMPLE_CF_TESTS) : % : %.out
	@ $(RUN) ./$@.out $(ERR_CHECK) $@ $(EAT_ERR)

$(addsuffix .out,$(SIMPLE_TESTS) $(FAIL_TESTS)) : %.out : %.m test.h Makefile
	@ $(CC) $(CFLAGS_$*) $< -o $@ $(LIBS)

$(addsuffix .out,$(SIMPLE_FOUNDATION_TESTS)) : %.out : %.m test.h Makefile
	@ $(CC) $(CFLAGS_$*) $(FOUNDATION) $< -o $@ $(LIBS)

$(addsuffix .out,$(SIMPLE_CF_TESTS)) : %.out : %.m test.h Makefile
	@ $(CC) $(CFLAGS_$*) $(CF) $< -o $@ $(LIBS)

nsexc.out: exc.m test.h Makefile
	@ $(CC) $(FOUNDATION) exc.m -o nsexc.out $(LIBS) -DUSE_FOUNDATION=1

imageorder.out:  imageorder.m imageorder.h imageorder3.out test.h Makefile
	@ $(CC)  imageorder.m imageorder3.out imageorder2.out imageorder1.out -o imageorder.out $(LIBS)
imageorder3.out: imageorder3.m imageorder.h imageorder2.out test.h Makefile
	@ $(CC)  -dynamiclib imageorder3.m imageorder2.out imageorder1.out -o imageorder3.out $(LIBS)
imageorder2.out: imageorder2.m imageorder.h imageorder1.out test.h Makefile
	@ $(CC)  -dynamiclib imageorder2.m imageorder1.out -o imageorder2.out $(LIBS)
imageorder1.out: imageorder1.m imageorder.h test.h Makefile
	@ $(CC)  -dynamiclib imageorder1.m -o imageorder1.out $(LIBS)

ivarSlide.out: ivarSlide1.m ivarSlide2.m ivarSlide.h test.h Makefile
	@ $(CC) ivarSlide1.m ivarSlide2.m -o ivarSlide.out $(LIBS)

ivarSlidexx.out: ivarSlide1.m ivarSlide2.m ivarSlide.h test.h Makefile
	@ $(CXX) -x objective-c++ ivarSlide1.m ivarSlide2.m -x none -o ivarSlidexx.out $(LIBS)

future.out: future1.m future.h future0.out future2.out test.h Makefile
	@ $(CC) future1.m future0.out -o future.out $(LIBS)
future0.out: future0.m future.h test.h Makefile
	@ $(CC) -dynamiclib future0.m -o future0.out $(LIBS)
future2.out: future2.m future.h future0.out test.h Makefile
	@ $(CC) -dynamiclib future2.m future0.out -o future2.out $(LIBS)

weak.out: weak.m weak2.m weak.h test.h Makefile
	@ $(CC) weak2.m -dynamiclib -o libweak.dylib $(LIBS)
	@ $(CC) weak2.m -DEMPTY= -dynamiclib -o libweak_empty.dylib $(LIBS)
	@ $(CC) weak.m -L. -weak-lweak -o weak.out $(LIBS)

weak-not-missing: weak.out
	@ $(RUN) ./weak.out $(ERR_CHECK) weak-not-missing $(EAT_ERR)
weak-missing: weak.out
	@ DYLD_IMAGE_SUFFIX=_empty $(RUN) ./weak.out $(ERR_CHECK) weak-missing $(EAT_ERR)

CONCURRENT_IN=cc1 cc2 cc3 cc4 cc5 cc6 cc7 cc8 cc9 cc10 cc11 cc12 cc13 cc14 cc15
CONCURRENT_DYLIBS=$(addsuffix .out,$(CONCURRENT_IN))

$(CONCURRENT_DYLIBS) : %.out : concurrentcat_category.m test.h Makefile
	@ $(CC) -undefined dynamic_lookup -dynamiclib -DTN=$* $< -o $@ $(LIBS)

concurrentcat.out: concurrentcat.m $(CONCURRENT_DYLIBS)
	@ $(CC) concurrentcat.m -o concurrentcat.out $(LIBS) $(FOUNDATION)

cacheflush.out: cacheflush.m cacheflush.h cacheflush0.out cacheflush2.out cacheflush3.out test.h Makefile
	@ $(CC) cacheflush.m cacheflush0.out -o cacheflush.out $(LIBS)
cacheflush0.out: cacheflush0.m cacheflush.h test.h Makefile
	@ $(CC) -dynamiclib cacheflush0.m -o cacheflush0.out $(LIBS)
cacheflush2.out: cacheflush2.m cacheflush.h cacheflush0.out test.h Makefile
	@ $(CC) -dynamiclib cacheflush2.m cacheflush0.out -o cacheflush2.out $(LIBS)
cacheflush3.out: cacheflush3.m cacheflush.h cacheflush0.out test.h Makefile
	@ $(CC) -dynamiclib cacheflush3.m cacheflush0.out -o cacheflush3.out $(LIBS)


unload.out: unload.m unload.h unload2.out unload3.out unload4.out test.h Makefile
	@ $(CC) unload.m -o unload.out $(LIBS)
unload2.out: unload2.m unload.h test.h Makefile
	@ $(CC) -bundle unload2.m -o unload2.out $(LIBS)
unload3.out: unload3.m Makefile
	@ $(CC) -dynamiclib unload3.m -o unload3.out $(LIBS)
unload4.out: unload4.m Makefile
	@ $(CC) -dynamiclib unload4.m -o unload4.out $(LIBS)

load-reentrant.out: load-reentrant.m load-reentrant2.m
	@ $(CC) load-reentrant.m -o load-reentrant.out $(LIBS)
	@ $(CC) -bundle load-reentrant2.m -o libload-reentrant2.dylib -bundle_loader load-reentrant.out $(LIBS)

load-order.out: load-order.m libload-order1.dylib
	@ $(CC) load-order.m -o load-order.out -L. -lload-order1 -lload-order2 -lload-order3 $(LIBS)
libload-order1.dylib: load-order1.m libload-order2.dylib
	@ $(CC) -dynamiclib load-order1.m -o libload-order1.dylib -L. -lload-order2 -lload-order3 $(LIBS)
libload-order2.dylib: load-order2.m libload-order3.dylib
	@ $(CC) -dynamiclib load-order2.m -o libload-order2.dylib -L. -lload-order3 $(LIBS)
libload-order3.dylib: load-order3.m
	@ $(CC) -dynamiclib load-order3.m -o libload-order3.dylib $(LIBS)

load-parallel.out: load-parallel.m libload-parallel00.dylib load-parallel0.out load-parallel1.out load-parallel2.out load-parallel3.out load-parallel4.out load-parallel5.out load-parallel6.out load-parallel7.out load-parallel8.out load-parallel9.out
	@ $(CC) -DCOUNT=10 load-parallel.m -o load-parallel.out -L. -lload-parallel00 $(LIBS)
libload-parallel00.dylib: load-parallel00.m Makefile
	@ $(CC) -dynamiclib load-parallel00.m -o libload-parallel00.dylib $(LIBS)
load-parallel0.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=0 -o load-parallel0.out -L. -lload-parallel00 $(LIBS)
load-parallel1.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=1 -o load-parallel1.out -L. -lload-parallel00 $(LIBS)
load-parallel2.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=2 -o load-parallel2.out -L. -lload-parallel00 $(LIBS)
load-parallel3.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=3 -o load-parallel3.out -L. -lload-parallel00 $(LIBS)
load-parallel4.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=4 -o load-parallel4.out -L. -lload-parallel00 $(LIBS)
load-parallel5.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=5 -o load-parallel5.out -L. -lload-parallel00 $(LIBS)
load-parallel6.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=6 -o load-parallel6.out -L. -lload-parallel00 $(LIBS)
load-parallel7.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=7 -o load-parallel7.out -L. -lload-parallel00 $(LIBS)
load-parallel8.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=8 -o load-parallel8.out -L. -lload-parallel00 $(LIBS)
load-parallel9.out: load-parallel0.m Makefile libload-parallel00.dylib
	@ $(CC) -dynamiclib load-parallel0.m -DN=9 -o load-parallel9.out -L. -lload-parallel00 $(LIBS)

libnoobjc.dylib: gc.c Makefile
	@ $(CC_C) gc.c -dynamiclib -o libnoobjc.dylib
libnogc.dylib: gc.m Makefile
	@ $(CC) gc.m -dynamiclib -o libnogc.dylib -fno-objc-gc $(LIBS)
libsupportsgc.dylib: gc.m Makefile
	@ $(CC) gc.m -dynamiclib -o libsupportsgc.dylib -fobjc-gc $(LIBS)
librequiresgc.real.dylib: gc.m Makefile
	@ $(CC) gc.m -dynamiclib -o librequiresgc.real.dylib -install_name librequiresgc.dylib -fobjc-gc-only $(LIBS)
librequiresgc.fake.dylib: gc.m Makefile
	@ $(CC) gc.m -dynamiclib -o librequiresgc.fake.dylib -install_name librequiresgc.dylib -fobjc-gc $(LIBS)
librequiresgc.dylib: librequiresgc.real.dylib librequiresgc.fake.dylib
	@ cp -f librequiresgc.real.dylib librequiresgc.dylib

gcenforcer.out: gcenforcer.m libsupportsgc.dylib librequiresgc.dylib libnogc.dylib libnoobjc.dylib test.h Makefile
	@ $(CC) gcenforcer.m -o gcenforcer.out $(LIBS)

gcenforcer_noobjc.out: main.m libnoobjc.dylib test.h Makefile
	@ $(CC) main.m libnoobjc.dylib -o gcenforcer_noobjc.out $(LIBS)
gcenforcer_noobjc: gcenforcer_noobjc.out Makefile
	@ $(RUN) ./gcenforcer_noobjc.out $(ERR_CHECK) $@ $(EAT_ERR)

gcenforcer_nogc.out: main.m libnogc.dylib test.h Makefile
	@ $(CC) main.m libnogc.dylib -o gcenforcer_nogc.out $(LIBS)
gcenforcer_nogc: gcenforcer_nogc.out Makefile
	@ $(RUN) ./gcenforcer_nogc.out $(ERR_CHECK) $@ gcenforcer_nogc.$(GC_state).expected-stderr $(EAT_ERR)

gcenforcer_supportsgc.out: main.m libsupportsgc.dylib test.h Makefile
	@ $(CC) main.m libsupportsgc.dylib -o gcenforcer_supportsgc.out $(LIBS)
gcenforcer_supportsgc: gcenforcer_supportsgc.out Makefile
	@ $(RUN) ./gcenforcer_supportsgc.out $(ERR_CHECK) $@ $(EAT_ERR)

# Linker sees librequiresgc.fake.dylib, runtime uses librequiresgc.real.dylib
gcenforcer_requiresgc.out: main.m librequiresgc.dylib libsupportsgc.dylib test.h Makefile
	@ $(CC) main.m librequiresgc.fake.dylib -o gcenforcer_requiresgc.out $(LIBS)

gcenforcer_requiresgc: gcenforcer_requiresgc.out Makefile
	@ $(RUN) ./gcenforcer_requiresgc.out $(ERR_CHECK) $@ gcenforcer_requiresgc.$(GC_state).expected-stderr $(EAT_ERR)

