// TEST_CFLAGS -framework Foundation
// TEST_CONFIG GC=0

#include "test.h"

#if TARGET_OS_IPHONE

int main()
{
    testwarn("iOS Foundation doesn't call _objc_root* yet");
    succeed(__FILE__);
}

#else

#define FOUNDATION 0
#define NAME "rr-autorelease"

#include "rr-autorelease2.m"

#endif
