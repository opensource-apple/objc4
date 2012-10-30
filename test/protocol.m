// TEST_CFLAGS -Wno-deprecated-declarations

#include "test.h"

#include <string.h>
#include <objc/objc-runtime.h>

#if !__OBJC2__
#include <objc/Protocol.h>
#endif

@protocol Proto1 
+proto1ClassMethod;
-proto1InstanceMethod;
@end

@protocol Proto2
+proto2ClassMethod;
-proto2InstanceMethod;
@end

@protocol Proto3 <Proto2>
+proto3ClassMethod;
-proto3InstanceMethod;
@end

@protocol Proto4
@property int i;
@end

@protocol ProtoEmpty
@end

@interface Super <Proto1> { id isa; } @end
@implementation Super
+class { return self; }
+(void)initialize { } 
+proto1ClassMethod { return self; }
-proto1InstanceMethod { return self; }
@end

@interface SubNoProtocols : Super { } @end
@implementation SubNoProtocols @end

@interface SuperNoProtocols { id isa; } @end
@implementation SuperNoProtocols
+class { return self; }
+(void)initialize { } 
@end

@interface SubProp : Super <Proto4> { int i; } @end
@implementation SubProp 
@synthesize i;
@end


int main()
{
    Class cls;
    Protocol * const *list;
    Protocol *protocol, *empty;
#if !__OBJC2__
    struct objc_method_description *desc;
#endif
    struct objc_method_description desc2;
    objc_property_t *proplist;
    unsigned int count;

    protocol = @protocol(Proto3);
    empty = @protocol(ProtoEmpty);
    testassert(protocol);
    testassert(empty);

#if !__OBJC2__
    testassert([protocol isKindOf:[Protocol class]]);
    testassert([empty isKindOf:[Protocol class]]);
    testassert(0 == strcmp([protocol name], "Proto3"));
    testassert(0 == strcmp([empty name], "ProtoEmpty"));
#endif
    testassert(0 == strcmp(protocol_getName(protocol), "Proto3"));
    testassert(0 == strcmp(protocol_getName(empty), "ProtoEmpty"));

    testassert(class_conformsToProtocol([Super class], @protocol(Proto1)));
    testassert(!class_conformsToProtocol([SubProp class], @protocol(Proto1)));
    testassert(class_conformsToProtocol([SubProp class], @protocol(Proto4)));
    testassert(!class_conformsToProtocol([SubProp class], @protocol(Proto3)));
    testassert(!class_conformsToProtocol([Super class], @protocol(Proto3)));

    testassert(!protocol_conformsToProtocol(@protocol(Proto1), @protocol(Proto2)));
    testassert(protocol_conformsToProtocol(@protocol(Proto3), @protocol(Proto2)));
    testassert(!protocol_conformsToProtocol(@protocol(Proto2), @protocol(Proto3)));

#if !__OBJC2__
    testassert([@protocol(Proto1) isEqual:@protocol(Proto1)]);
    testassert(! [@protocol(Proto1) isEqual:@protocol(Proto2)]);
#endif
    testassert(protocol_isEqual(@protocol(Proto1), @protocol(Proto1)));
    testassert(! protocol_isEqual(@protocol(Proto1), @protocol(Proto2)));

#if !__OBJC2__
    desc = [protocol descriptionForInstanceMethod:@selector(proto3InstanceMethod)];
    testassert(desc);
    testassert(desc->name == @selector(proto3InstanceMethod));
    desc = [protocol descriptionForClassMethod:@selector(proto3ClassMethod)];
    testassert(desc);
    testassert(desc->name == @selector(proto3ClassMethod));
    desc = [protocol descriptionForInstanceMethod:@selector(proto3ClassMethod)];
    testassert(!desc);
    desc = [protocol descriptionForClassMethod:@selector(proto3InstanceMethod)];
    testassert(!desc);    
    desc = [empty descriptionForInstanceMethod:@selector(proto3ClassMethod)];
    testassert(!desc);
    desc = [empty descriptionForClassMethod:@selector(proto3InstanceMethod)];
    testassert(!desc);    
#endif
    desc2 = protocol_getMethodDescription(protocol, @selector(proto3InstanceMethod), YES, YES);
    testassert(desc2.name && desc2.types);
    testassert(desc2.name == @selector(proto3InstanceMethod));
    desc2 = protocol_getMethodDescription(protocol, @selector(proto3ClassMethod), YES, NO);
    testassert(desc2.name && desc2.types);
    testassert(desc2.name == @selector(proto3ClassMethod));

    desc2 = protocol_getMethodDescription(protocol, @selector(proto3ClassMethod), YES, YES);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(protocol, @selector(proto3InstanceMethod), YES, NO);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(empty, @selector(proto3ClassMethod), YES, YES);
    testassert(!desc2.name && !desc2.types);
    desc2 = protocol_getMethodDescription(empty, @selector(proto3InstanceMethod), YES, NO);
    testassert(!desc2.name && !desc2.types);

    count = 100;
    list = protocol_copyProtocolList(@protocol(Proto2), &count);
    testassert(!list);
    testassert(count == 0);
    count = 100;
    list = protocol_copyProtocolList(@protocol(Proto3), &count);
    testassert(list);
    testassert(count == 1);
    testassert(protocol_isEqual(list[0], @protocol(Proto2)));
    testassert(!list[1]);
    free((void*)list);    

    count = 100;
    cls = objc_getClass("Super");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(list);
    testassert(list[count] == NULL);
    testassert(count == 1);
    testassert(0 == strcmp(protocol_getName(list[0]), "Proto1"));
    free((void*)list);

    count = 100;
    cls = objc_getClass("SuperNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(!list);
    testassert(count == 0);

    count = 100;
    cls = objc_getClass("SubNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, &count);
    testassert(!list);
    testassert(count == 0);


    cls = objc_getClass("SuperNoProtocols");
    testassert(cls);
    list = class_copyProtocolList(cls, NULL);
    testassert(!list);

    cls = objc_getClass("Super");
    testassert(cls);
    list = class_copyProtocolList(cls, NULL);
    testassert(list);
    free((void*)list);

    count = 100;
    list = class_copyProtocolList(NULL, &count);
    testassert(!list);
    testassert(count == 0);


    // Check property added by protocol
    cls = objc_getClass("SubProp");
    testassert(cls);

    count = 100;
    list = class_copyProtocolList(cls, &count);
    testassert(list);
    testassert(count == 1);
    testassert(0 == strcmp(protocol_getName(list[0]), "Proto4"));
    testassert(list[1] == NULL);
    free((void*)list);

    count = 100;
    proplist = class_copyPropertyList(cls, &count);
    testassert(proplist);
    testassert(count == 1);
    testassert(0 == strcmp(property_getName(proplist[0]), "i"));
    testassert(proplist[1] == NULL);
    free(proplist);

    succeed(__FILE__);
}
