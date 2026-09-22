#ifndef SETSUNA_SOFTFLOAT_PLATFORM_H
#define SETSUNA_SOFTFLOAT_PLATFORM_H
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "This SoftFloat build requires a little-endian host"
#endif
#define LITTLEENDIAN 1
#define INLINE inline
#define SOFTFLOAT_BUILTIN_CLZ 1
#define SOFTFLOAT_INTRINSIC_INT128 1
#include "opts-GCC.h"
#endif
