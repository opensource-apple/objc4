// unload3: contains imageinfo but no other objc metadata
// libobjc must not keep it open

#if __OBJC2__
int fake __attribute__((section("__DATA,__objc_imageinfo"))) = 0;
#else
int fake __attribute__((section("__OBJC,__image_info"))) = 0;
#endif
