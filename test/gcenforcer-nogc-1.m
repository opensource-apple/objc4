// gc-off app loading gc-off dylib: should work

/*
TEST_CONFIG GC=0 SDK=macos

TEST_BUILD
    $C{COMPILE_C} $DIR/gc.c -dynamiclib -o libnoobjc.dylib
    $C{COMPILE_NOGC} $DIR/gc.m -dynamiclib -o libnogc.dylib
    $C{COMPILE} $DIR/gc.m -dynamiclib -o libsupportsgc.dylib -fobjc-gc
    $C{COMPILE} $DIR/gc.m -dynamiclib -o librequiresgc.dylib -fobjc-gc-only
    $C{COMPILE} $DIR/gc.m -dynamiclib -o librequiresgc.fake.dylib -fobjc-gc -install_name librequiresgc.dylib

    $C{COMPILE} $DIR/gc-main.m -x none libnogc.dylib -o gcenforcer-nogc-1.out
END
*/
