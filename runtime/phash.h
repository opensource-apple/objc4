/* Perfect hash definitions */
#ifndef STANDARD
#include "standard.h"
#endif /* STANDARD */
#ifndef PHASH
#define PHASH

extern const ub1 tab[];
#define PHASHLEN 0x2000  /* length of hash mapping table */
#define PHASHNKEYS 29798  /* How many keys were hashed */
#define PHASHRANGE 32768  /* Range any input might map to */
#define PHASHSALT 0x5384540f /* internal, initialize normal hash */

ub4 phash();

#endif  /* PHASH */

