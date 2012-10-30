#include "test.h"

extern int state1, state2, state3;

int main()
{
    testassert(state1 == 1  &&  state2 == 2  &&  state3 == 3);
    succeed(__FILE__);
}
