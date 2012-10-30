#include "objc-private.h"

// out-of-band parameter to objc_msgForward
#define kFwdMsgSend 1
#define kFwdMsgSendStret 0

// objc_msgSend parameters
#define self 4
#define super 4
#define selector 8
#define first_arg 12

// objc_msgSend_stret parameters
#define struct_addr 4
#define self_stret 8
#define super_stret 8
#define selector_stret 12

// objc_super parameter to sendSuper
#define super_receiver 0
#define super_class 4

// struct objc_class fields
#define isa 0
#define cache 32

// struct objc_method fields
#define method_name 0
#define method_imp 8

// struct objc_cache fields
#define mask 0
#define occupied 4
#define buckets 8

void *_objc_forward_handler = NULL;
void *_objc_forward_stret_handler = NULL;

__declspec(naked) Method _cache_getMethod(Class cls, SEL sel, IMP objc_msgForward_imp)
{
    __asm {
        mov ecx, selector[esp]
        mov edx, self[esp]

// CacheLookup WORD_RETURN, CACHE_GET
        push edi
        mov edi, cache[edx]

        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

MISS:
        xor eax, eax
        pop esi
        pop edi
        ret

HIT:
        mov ecx, 8+first_arg[esp]
        cmp ecx, method_imp[eax]
        je MISS
        pop esi
        pop edi
        ret
    }
}

__declspec(naked) IMP _cache_getImp(Class cls, SEL sel)
{
    __asm {
        mov ecx, selector[esp]
        mov edx, self[esp]

// CacheLookup WORD_RETURN, CACHE_GET
        push edi
        mov edi, cache[edx]

        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

MISS:
        pop esi
        pop edi
        xor eax, eax
        ret

HIT:
        pop esi
        pop edi
        mov eax, method_imp[eax]
        ret

    }
}


OBJC_EXPORT __declspec(naked) id objc_msgSend(id a, SEL b, ...)
{
    __asm {
        // load receiver and selector
        mov ecx, selector[esp]
        mov eax, self[esp]

#if !defined(NO_GC)
        // check whether selector is ignored
#error oops
#endif

        // check whether receiver is nil
        test eax, eax
        je NIL

        // receiver (in eax) is non-nil: search the cache
        mov edx, isa[eax]

        // CacheLookup WORD_RETURN, MSG_SEND
        push edi
        mov edi, cache[edx]
        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

HIT:
        mov eax, method_imp[eax]
        pop esi
        pop edi
        mov edx, kFwdMsgSend
        jmp eax

        // cache miss: search method lists
MISS:
        pop esi
        pop edi
        mov eax, self[esp]
        mov eax, isa[eax]

        // MethodTableLookup WORD_RETURN, MSG_SEND
        sub esp, 4
        push ecx
        push eax
        call _class_lookupMethodAndLoadCache
        add esp, 12

        mov edx, kFwdMsgSend
        jmp eax

        // message send to nil: return zero
NIL:
        // eax is already zero
        mov edx, 0
        ret
    }
}


OBJC_EXPORT __declspec(naked) double objc_msgSend_fpret(id a, SEL b, ...)
{
    __asm {
        // load receiver and selector
        mov ecx, selector[esp]
        mov eax, self[esp]

#if !defined(NO_GC)
        // check whether selector is ignored
#error oops
#endif

        // check whether receiver is nil
        test eax, eax
        je NIL

        // receiver (in eax) is non-nil: search the cache
        mov edx, isa[eax]

        // CacheLookup WORD_RETURN, MSG_SEND
        push edi
        mov edi, cache[edx]
        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

HIT:
        mov eax, method_imp[eax]
        pop esi
        pop edi
        mov edx, kFwdMsgSend
        jmp eax

        // cache miss: search method lists
MISS:
        pop esi
        pop edi
        mov eax, self[esp]
        mov eax, isa[eax]

        // MethodTableLookup WORD_RETURN, MSG_SEND
        sub esp, 4
        push ecx
        push eax
        call _class_lookupMethodAndLoadCache
        add esp, 12

        mov edx, kFwdMsgSend
        jmp eax

        // message send to nil: return zero
NIL:
        fldz
        ret
    }
}


OBJC_EXPORT __declspec(naked) id objc_msgSendSuper(struct objc_super *a, SEL b, ...)
{
    __asm {
        // load class and selector
        mov eax, super[esp]
        mov ecx, selector[esp]
        mov edx, super_class[eax]

#if !defined(NO_GC)
        // check whether selector is ignored
#error oops
#endif

        // search the cache (class in edx)
        // CacheLookup WORD_RETURN, MSG_SENDSUPER
        push edi
        mov edi, cache[edx]
        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

HIT:
        mov eax, method_imp[eax]
        pop esi
        pop edi
        mov edx, super[esp]
        mov edx, super_receiver[edx]
        mov super[esp], edx
        mov edx, kFwdMsgSend
        jmp eax

        // cache miss: search method lists
MISS:

        pop esi
        pop edi
        mov edx, super[esp]
        mov eax, super_receiver[edx]
        mov super[esp], eax
        mov eax, super_class[edx]

        // MethodTableLookup WORD_RETURN, MSG_SENDSUPER
        sub esp, 4
        push ecx
        push eax
        call _class_lookupMethodAndLoadCache
        add esp, 12

        mov edx, kFwdMsgSend
        jmp eax
    }
}


OBJC_EXPORT __declspec(naked) void objc_msgSend_stret(void)
{
    __asm {
        // load receiver and selector
        mov ecx, selector_stret[esp]
        mov eax, self_stret[esp]

#if !defined(NO_GC)
        // check whether selector is ignored
#error oops
#endif

        // check whether receiver is nil
        test eax, eax
        je NIL

        // receiver (in eax) is non-nil: search the cache
        mov edx, isa[eax]

        // CacheLookup WORD_RETURN, MSG_SEND
        push edi
        mov edi, cache[edx]
        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

HIT:
        mov eax, method_imp[eax]
        pop esi
        pop edi
        mov edx, kFwdMsgSendStret
        jmp eax

        // cache miss: search method lists
MISS:
        pop esi
        pop edi
        mov eax, self_stret[esp]
        mov eax, isa[eax]

        // MethodTableLookup WORD_RETURN, MSG_SEND
        sub esp, 4
        push ecx
        push eax
        call _class_lookupMethodAndLoadCache
        add esp, 12

        mov edx, kFwdMsgSendStret
        jmp eax

        // message send to nil: return zero
NIL:
        // eax is already zero
        mov edx, 0
        ret
    }
}


OBJC_EXPORT __declspec(naked) id objc_msgSendSuper_stret(struct objc_super *a, SEL b, ...)
{
    __asm {
        // load class and selector
        mov eax, super_stret[esp]
        mov ecx, selector_stret[esp]
        mov edx, super_class[eax]

#if !defined(NO_GC)
        // check whether selector is ignored
#error oops
#endif

        // search the cache (class in edx)
        // CacheLookup WORD_RETURN, MSG_SENDSUPER
        push edi
        mov edi, cache[edx]
        push esi
        mov esi, mask[edi]
        mov edx, ecx
        shr edx, 2
SCAN:
        and edx, esi
        mov eax, buckets[edi][edx*4]
        test eax, eax
        je MISS
        cmp ecx, method_name[eax]
        je HIT
        add edx, 1
        jmp SCAN

HIT:
        mov eax, method_imp[eax]
        pop esi
        pop edi
        mov edx, super[esp]
        mov edx, super_receiver[edx]
        mov super[esp], edx
        mov edx, kFwdMsgSendStret
        jmp eax

        // cache miss: search method lists
MISS:

        pop esi
        pop edi
        mov edx, super_stret[esp]
        mov eax, super_receiver[edx]
        mov super_stret[esp], eax
        mov eax, super_class[edx]

        // MethodTableLookup WORD_RETURN, MSG_SENDSUPER
        sub esp, 4
        push ecx
        push eax
        call _class_lookupMethodAndLoadCache
        add esp, 12

        mov edx, kFwdMsgSendStret
        jmp eax
    }
}


OBJC_EXPORT __declspec(naked) id _objc_msgForward(id a, SEL b, ...)
{
    __asm {
        mov ecx, _objc_forward_handler
        // forward:: support omitted here
        jmp ecx
    }
}

OBJC_EXPORT __declspec(naked) id _objc_msgForward_stret(id a, SEL b, ...)
{
    __asm {
        mov ecx, _objc_forward_stret_handler
        // forward:: support omitted here
        jmp ecx
    }
}


__declspec(naked) id _objc_msgForward_internal(id a, SEL b, ...)
{
    __asm {
        cmp edx, kFwdMsgSendStret
        je  STRET
        jmp _objc_msgForward
STRET:
        jmp _objc_msgForward_stret
    }
}


OBJC_EXPORT __declspec(naked) void method_invoke(void)
{
    __asm {
        mov ecx, selector[esp]
        mov edx, method_name[ecx]
        mov eax, method_imp[ecx]
        mov selector[esp], edx
        jmp eax
    }
}


OBJC_EXPORT __declspec(naked) void method_invoke_stret(void)
{
    __asm {
        mov ecx, selector_stret[esp]
        mov edx, method_name[ecx]
        mov eax, method_imp[ecx]
        mov selector_stret[esp], edx
        jmp eax
    }
}
