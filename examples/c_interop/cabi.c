/* A tiny C library exercising by-value struct passing — the shapes raylib uses.
 * Build it the way any C dependency would be built, then link it from Gabbro.
 *
 *   clang -c -target x86_64-pc-windows-msvc -O2 cabi.c -o cabi.obj
 *   llvm-lib /out:cabi.lib cabi.obj
 */
#include <stdint.h>

typedef struct { float x, y; } Vector2;        /* 8 bytes  -> passed in a register */
typedef struct { uint8_t r, g, b, a; } Color;  /* 4 bytes  -> passed in a register */
typedef struct { float x, y, w, h; } Rectangle;/* 16 bytes -> passed by pointer     */

int vec2_sum_i(Vector2 v)   { return (int)(v.x + v.y); }
int color_sum(Color c)      { return (int)c.r + (int)c.g + (int)c.b + (int)c.a; }
int rect_sum_i(Rectangle r) { return (int)(r.x + r.y + r.w + r.h); }

Vector2   make_vec(float a, float b)                    { Vector2 v = { a, b }; return v; }
Rectangle make_rect(float a, float b, float c, float d) { Rectangle r = { a, b, c, d }; return r; }
