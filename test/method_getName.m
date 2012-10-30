#include "test.h"
#include <Foundation/NSObject.h>
#include <objc/runtime.h>
#include "../runtime/objc-rtp.h"

int main() {
  unsigned i;
  Class c = [NSObject class];
  unsigned numMethods;
  Method *methods = class_copyMethodList(c, &numMethods);

  for (i=0; i<numMethods; ++i) {
      // <rdar://problem/6190950> method_getName crash on NSObject method when GC is enabled
      SEL aMethod = method_getName(methods[i]);
      if (aMethod == (SEL)kIgnore)
	  fail(__FILE__);
  }

  succeed(__FILE__);
}
