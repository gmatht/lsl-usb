//! C99 `round`/`roundf` shims.
//!
//! On MSVC targets, `compiler_builtins` delegates float routines to the CRT.
//! The VC6 static CRT we link (most Win9x-compatible) predates C99, so
//! `f32::round`/`f64::round` produce undefined `roundf`/`round` symbols.
//!
//! We implement "round half away from zero" manually — importantly WITHOUT
//! calling `f32::round()`/`f64::round()` or `trunc()`, which would lower to a
//! call to `roundf`/`round`/`truncf` and recurse infinitely. Truncation is
//! done with an `as i32`/`as i64` cast, which Rust defines as saturating
//! truncation (lowered to the CRT's `_ftol`-style helper, present in VC6).

#![allow(non_snake_case)]

const F32_BIG: f32 = 8_388_608.0; // 2^23 — |x| >= this is already integral
const F64_BIG: f64 = 9_007_199_254_740_992.0; // 2^53

#[unsafe(no_mangle)]
pub extern "C" fn roundf(x: f32) -> f32 {
    if x.is_nan() || x.abs() >= F32_BIG {
        return x;
    }
    let t = if x < 0.0 { x - 0.5 } else { x + 0.5 };
    (t as i32) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn round(x: f64) -> f64 {
    if x.is_nan() || x.abs() >= F64_BIG {
        return x;
    }
    let t = if x < 0.0 { x - 0.5 } else { x + 0.5 };
    (t as i64) as f64
}
