# quick test
all:
	perl test.pl $(MAKEFLAGS)

# default-arch but otherwise comprehensive test for buildbot
buildbot: 
	perl test.pl $(MAKEFLAGS) GC=0,1 CC=clang,llvm-gcc-4.2,gcc-4.2 LANGUAGE=objc,objc++

# comprehensive tests
mac macos macosx:
	perl test.pl $(MAKEFLAGS) ARCH=x86_64,i386 GC=0,1 CC=clang,llvm-gcc-4.2,gcc-4.2 LANGUAGE=objc,objc++

iphonesimulator:
	perl test.pl $(MAKEFLAGS) ARCH=i386 SDK=iphonesimulator GC=0 CC=clang,llvm-gcc-4.2,gcc-4.2 LANGUAGE=objc,objc++

iphoneos:
	perl test.pl $(MAKEFLAGS) ARCH=armv6,armv7 SDK=iphoneos GC=0 CC=clang,llvm-gcc-4.2,gcc-4.2 LANGUAGE=objc,objc++

clean: 
	@ perl test.pl clean
