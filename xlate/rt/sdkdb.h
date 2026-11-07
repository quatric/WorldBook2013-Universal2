// SDK prototypes in the bridge type language (tools/sdkdb.py):
//   v void  c/C char  s/S short  i/I int  l/L long (32-bit guest, 64-bit host)
//   q/Q long long  f float  d double  F CGFloat (float guest, double host)
//   B bool  @ object or opaque pointer  : SEL  * byte pointer
//   P<t> pointer to t (host temporary, copied in and out)  {Name} struct
//   ^ function pointer  ? unknown
#ifndef SDKDB_H
#define SDKDB_H
#include <stddef.h>
typedef struct { const char *name, *type; int variadic; } XLFuncType;
typedef struct { const char *sel, *container, *type; int variadic; } XLMethodType;
typedef struct { const char *name, *fields; } XLStructType;
extern const XLFuncType xl_sdk_funcs[];
extern const XLMethodType xl_sdk_methods[];
extern const XLStructType xl_sdk_structs[];
extern const size_t xl_sdk_nfuncs, xl_sdk_nmethods, xl_sdk_nstructs;
#endif
