// TEST_ENV OBJC_DEBUG_DUPLICATE_CLASSES=YES
// TEST_CRASHES
/* 
TEST_RUN_OUTPUT
objc\[\d+\]: Class GKScore is implemented in both [^\s]+ and [^\s]+ One of the two will be used. Which one is undefined.
CRASHED: SIG(ILL|TRAP)
END
 */

#include "test.h"
#include "testroot.i"

@interface GKScore : TestRoot @end
@implementation GKScore @end

int main()
{
    void *dl = dlopen("/System/Library/Frameworks/GameKit.framework/GameKit", RTLD_LAZY);
    if (!dl) fail("couldn't open GameKit");
    fail("should have crashed already");
}
