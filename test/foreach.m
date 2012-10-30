
#import <Foundation/Foundation.h>

/* foreach tester */

int Verbosity = 0;
int Errors = 0;

bool testHandwritten(char *style, char *test, char *message, id collection, NSSet *reference) {
    unsigned int counter = 0;
    bool result = true;
    if (Verbosity) {
        printf("testing: %s %s %s\n", style, test, message);
    }
/*
    for (id elem in collection)
        if ([reference member:elem]) ++counter;
 */
   NSFastEnumerationState state; 
   id buffer[4];
   state.state = 0;
   NSUInteger limit = [collection countByEnumeratingWithState:&state objects:buffer count:4];
   if (limit != 0) {
        unsigned long mutationsPtr = *state.mutationsPtr;
        do {
            unsigned long innerCounter = 0;
            do {
                if (mutationsPtr != *state.mutationsPtr) objc_enumerationMutation(collection);
                id elem = state.itemsPtr[innerCounter++];
                
                if ([reference member:elem]) ++counter;
                
            } while (innerCounter < limit);
        } while ((limit = [collection countByEnumeratingWithState:&state objects:buffer count:4]));
    }
            
 
 
    if (counter == [reference count]) {
        if (Verbosity) {
            printf("success: %s %s %s\n", style, test, message);
        }
    }
    else {
        result = false;
        printf("** failed: %s %s %s (%d vs %d)\n", style, test, message, counter, (int)[reference count]);
        ++Errors;
    }
    return result;
}

bool testCompiler(char *style, char *test, char *message, id collection, NSSet *reference) {
    unsigned int counter = 0;
    bool result = true;
    if (Verbosity) {
        printf("testing: %s %s %s\n", style, test, message);
    }
    for (id elem in collection)
        if ([reference member:elem]) ++counter;
    if (counter == [reference count]) {
        if (Verbosity) {
            printf("success: %s %s %s\n", style, test, message);
        }
    }
    else {
        result = false;
        printf("** failed: %s %s %s (%d vs %d)\n", style, test, message, counter, (int)[reference count]);
        ++Errors;
    }
    return result;
}

void testContinue(NSArray *array) {
    bool broken = false;
    if (Verbosity) {
        printf("testing: continue statements\n");
    }
    for (id elem in array) {
        if ([array count])
            continue;
        broken = true;
    }
    if (broken) {
        printf("** continue statement did not work\n");
        ++Errors;
    }
}

            
// array is filled with NSNumbers, in order, from 0 - N
bool testBreak(unsigned int where, NSArray *array) {
    unsigned int counter = 0;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    id enumerator = [array objectEnumerator];
    for (id elem in enumerator) {
        if (++counter == where)
            break;
    }
    if (counter != where) {
        ++Errors;
        printf("*** break at %d didn't work (actual was %d)\n", where, counter);
        return false;
    }
    for (id elem in enumerator)
        ++counter;
    if (counter != [array count]) {
        ++Errors;
        printf("*** break at %d didn't finish (actual was %d)\n", where, counter);
        return false;
    }
    [pool drain];
    return true;
}
    
bool testBreaks(NSArray *array) {
    bool result = true;
    if (Verbosity) printf("testing breaks\n");
    unsigned int counter = 0;
    for (counter = 1; counter < [array count]; ++counter) {
        result = testBreak(counter, array) && result;
    }
    return result;
}
        
bool testCompleteness(char *test, char *message, id collection, NSSet *reference) {
    bool result = true;
    result = result && testHandwritten("handwritten", test, message, collection, reference);
    result = result && testCompiler("compiler", test, message, collection, reference);
    return result;
}

bool testEnumerator(char *test, char *message, id collection, NSSet *reference) {
    bool result = true;
    result = result && testHandwritten("handwritten", test, message, [collection objectEnumerator], reference);
    result = result && testCompiler("compiler", test, message, [collection objectEnumerator], reference);
    return result;
}    
    
NSMutableSet *ReferenceSet = nil;
NSMutableArray *ReferenceArray = nil;

void makeReferences(int n) {
    if (!ReferenceSet) {
        int i;
        ReferenceSet = [[NSMutableSet alloc] init];
        ReferenceArray = [[NSMutableArray alloc] init];
        for (i = 0; i < n; ++i) {
            NSNumber *number = [[NSNumber alloc] initWithInt:i];
            [ReferenceSet addObject:number];
            [ReferenceArray addObject:number];
            [number release];
        }
    }
}
    
void testCollections(char *test, NSArray *array, NSSet *set) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    id collection;
    collection = [NSMutableArray arrayWithArray:array];
    testCompleteness(test, "mutable array", collection, set);
    testEnumerator(test, "mutable array enumerator", collection, set);
    collection = [NSArray arrayWithArray:array];
    testCompleteness(test, "immutable array", collection, set);
    testEnumerator(test, "immutable array enumerator", collection, set);
    collection = set;
    testCompleteness(test, "immutable set", collection, set);
    testEnumerator(test, "immutable set enumerator", collection, set);
    collection = [NSMutableSet setWithArray:array];
    testCompleteness(test, "mutable set", collection, set);
    testEnumerator(test, "mutable set enumerator", collection, set);
    [pool drain];
}

void testInnerDecl(char *test, char *message, id collection) {
    unsigned int counter = 0;
    for (id x in collection)
        ++counter;
    if (counter != [collection count]) {
        printf("** failed: %s %s\n", test, message);
        ++Errors;
    }
}


void testOuterDecl(char *test, char *message, id collection) {
    unsigned int counter = 0;
    id x;
    for (x in collection)
        ++counter;
    if (counter != [collection count]) {
        printf("** failed: %s %s\n", test, message);
        ++Errors;
    }
}
void testInnerExpression(char *test, char *message, id collection) {
    unsigned int counter = 0;
    for (id x in [collection self])
        ++counter;
    if (counter != [collection count]) {
        printf("** failed: %s %s\n", test, message);
        ++Errors;
    }
}
void testOuterExpression(char *test, char *message, id collection) {
    unsigned int counter = 0;
    id x;
    for (x in [collection self])
        ++counter;
    if (counter != [collection count]) {
        printf("** failed: %s %s\n", test, message);
        ++Errors;
    }
}

void testExpressions(char *message, id collection) {
    testInnerDecl("inner", message, collection);
    testOuterDecl("outer", message, collection);
    testInnerExpression("outer expression", message, collection);
    testOuterExpression("outer expression", message, collection);
}
    

int main() {
    Verbosity = (getenv("VERBOSE") != NULL);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    testCollections("nil", nil, nil);
    testCollections("empty", [NSArray array], [NSSet set]);
    makeReferences(100);
    testCollections("100 item", ReferenceArray, ReferenceSet);
    testExpressions("array", ReferenceArray);
    testBreaks(ReferenceArray);
    testContinue(ReferenceArray);
    if (Errors == 0) printf("OK: foreach\n");
    else printf("BAD: foreach %d errors detected\n", Errors);
    [pool drain];
    exit(Errors);
}
