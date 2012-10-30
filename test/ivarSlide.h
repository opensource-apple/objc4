@interface Base {
  @public
    id isa;
}

+class;
+new;
-(void)dealloc;
@end

@interface Super : Base { 
  @public 
#if OLD
    // nothing
#else
    char superIvar;
#endif
}
@end


@interface ShrinkingSuper : Base {
  @public
#if OLD
    id superIvar[5];
    __weak id superIvar2[5];
#else
    // nothing
#endif
}
@end;


@interface MoreStrongSuper : Base {
  @public
#if OLD
    void *superIvar;
#else
    id superIvar;
#endif
}
@end;


@interface MoreWeakSuper : Base {
  @public
#if OLD
    id superIvar;
#else
    __weak id superIvar;
#endif
}
@end;

@interface MoreWeak2Super : Base {
  @public
#if OLD
    void *superIvar;
#else
    __weak id superIvar;
#endif
}
@end;

@interface LessStrongSuper : Base {
  @public
#if OLD
    id superIvar;
#else
    void *superIvar;
#endif
}
@end;

@interface LessWeakSuper : Base {
  @public
#if OLD
    __weak id superIvar;
#else
    id superIvar;
#endif
}
@end;

@interface LessWeak2Super : Base {
  @public
#if OLD
    __weak id superIvar;
#else
    void *superIvar;
#endif
}
@end;

@interface NoGCChangeSuper : Base {
  @public
    intptr_t d;
    char superc1;
#if OLD
    // nothing
#else
    char superc2;
#endif
}
@end

@interface RunsOf15 : Base {
  @public
    id scan1;
    intptr_t skip15[15];
    id scan15[15];
    intptr_t skip15_2[15];
    id scan15_2[15];
#if OLD
    // nothing
#else
    intptr_t skip1;
#endif
}
@end
