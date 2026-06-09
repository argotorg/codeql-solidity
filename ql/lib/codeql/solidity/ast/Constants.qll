/**
 * Helpers for working with folded compile-time constant values.
 *
 * The extractor folds constant integer expressions and stores the result as a
 * canonical decimal string (see `AstNode.getConstantValue()`), because values can
 * exceed 64 bits — a `layout at 2**256 - 2**64` slot base does not fit in any
 * native CodeQL `int`. This module compares such strings numerically.
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Numeric comparison of canonical decimal integer strings, as produced by
 * `AstNode.getConstantValue()` (no leading zeros, optional leading `-`, `"0"`
 * for zero). These work for values of any magnitude, beyond CodeQL's 64-bit int.
 */
module BigIntComparison {
  /** Holds if the canonical decimal string `s` is negative. */
  bindingset[s]
  private predicate isNegative(string s) { s.matches("-%") }

  /** Gets the non-negative magnitude (digits only) of the canonical decimal string `s`. */
  bindingset[s]
  private string magnitude(string s) {
    if isNegative(s) then result = s.suffix(1) else result = s
  }

  /**
   * Holds if non-negative decimal magnitude `a` >= `b`. For canonical
   * (leading-zero-free) digit strings, the longer string is the larger number,
   * and equal-length strings compare correctly lexicographically.
   */
  bindingset[a, b]
  private predicate magnitudeGeq(string a, string b) {
    a.length() > b.length()
    or
    a.length() = b.length() and a >= b
  }

  /** Holds if `a` >= `b`, treating both as canonical decimal integer strings. */
  bindingset[a, b]
  predicate geq(string a, string b) {
    // non-negative vs non-negative
    not isNegative(a) and not isNegative(b) and magnitudeGeq(magnitude(a), magnitude(b))
    or
    // non-negative is always >= negative
    not isNegative(a) and isNegative(b)
    or
    // negative vs negative: larger magnitude is the smaller number, so flip the operands
    isNegative(a) and isNegative(b) and magnitudeGeq(magnitude(b), magnitude(a))
  }

  /** Holds if `a` <= `b`, treating both as canonical decimal integer strings. */
  bindingset[a, b]
  predicate leq(string a, string b) { geq(b, a) }
}
