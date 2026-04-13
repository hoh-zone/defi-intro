module security_patterns::integer_safety;
#[error]
const EOverflow: vector<u8> = b"Overflow";
#[error]
const EUnderflow: vector<u8> = b"Underflow";
#[error]
const EDivisionByZero: vector<u8> = b"Division By Zero";

/// Overflow-checked multiplication
public fun safe_mul(a: u64, b: u64): u64 {
    let result = (a as u128) * (b as u128);
    assert!(result <= 0xFFFFFFFFFFFFFFFF, EOverflow);
    (result as u64)
}

/// Overflow-checked addition
public fun safe_add(a: u64, b: u64): u64 {
    let result = (a as u128) + (b as u128);
    assert!(result <= 0xFFFFFFFFFFFFFFFF, EOverflow);
    (result as u64)
}

/// Underflow-checked subtraction
public fun safe_sub(a: u64, b: u64): u64 {
    assert!(a >= b, EUnderflow);
    a - b
}

/// Division with zero check
public fun safe_div(a: u64, b: u64): u64 {
    assert!(b > 0, EDivisionByZero);
    a / b
}

/// Multiply-then-divide for precision: (a * b) / c
/// Does intermediate calculation in u128 to avoid overflow
public fun mul_div(a: u128, b: u128, c: u128): u128 {
    assert!(c > 0, EDivisionByZero);
    a * b / c
}
