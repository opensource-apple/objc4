// TEST_CONFIG OS=macosx
// TEST_CFLAGS -framework AppleScriptObjC -framework Foundation

// Verify that trivial AppleScriptObjC apps run with GC off.

#include <Foundation/Foundation.h>
#include "test.h"

int main()
{
    [NSBundle class];
    succeed(__FILE__);
}
