#include "test.h"

#include <dlfcn.h>
#include <pthread.h>

#ifndef COUNT
#error -DCOUNT=c missing
#endif

extern int state;

void *thread(void *arg)
{
    uintptr_t num = (uintptr_t)arg;
    char *buf;

    objc_registerThreadWithCollector();

    asprintf(&buf, "load-parallel%lu.out", (unsigned long)num);
    testprintf("%s\n", buf);
    void *dlh = dlopen(buf, RTLD_LAZY);
    if (!dlh) {
        fail("dlopen failed: %s", dlerror());
    }

    return NULL;
}

int main()
{
    pthread_t t[COUNT];
    uintptr_t i;

    for (i = 0; i < COUNT; i++) {
        pthread_create(&t[i], NULL, thread, (void *)i);
    }

    for (i = 0; i < COUNT; i++) {
        pthread_join(t[i], NULL);
    }

    testprintf("loaded %d/%d\n", state, COUNT*26);
    testassert(state == COUNT*26);

    succeed(__FILE__);
}
