//! Compile-time constant folding for Solidity expressions.
//!
//! Solidity evaluates constant integer expressions (literals combined with the
//! arithmetic/bitwise operators) at compile time, and several language features
//! take such a constant — most notably the `layout at <expr>` storage-layout
//! specifier, whose argument is a 256-bit slot base. The CodeQL AST only records
//! the syntax tree, so a query that wants to reason about the *value* of such an
//! expression would otherwise have to re-implement arbitrary-precision arithmetic
//! in QL. Instead we fold the value here, during extraction, and emit it as the
//! `solidity_const_value` relation (a canonical decimal string, since values can
//! exceed 64 bits — `2**256 - 2**64` does not fit in any native integer).
//!
//! The folder is intentionally limited to *literal* arithmetic: it does not
//! resolve named `constant`/`immutable` variables (that needs cross-declaration
//! symbol resolution). Anything it cannot evaluate simply yields `None` and no
//! tuple is emitted, so queries see a folded value only when it is exact.

use num_bigint::BigInt;
use num_traits::{Signed, Zero};
use tree_sitter::Node;

/// Cap on the exponent of `**` (and the shift distance of `<<`). Solidity
/// constants are bounded to 256 bits, but intermediate sub-expressions may be
/// larger; this keeps a pathological `2**100000000` from exhausting memory while
/// comfortably covering every realistic 256-bit constant.
const MAX_EXPONENT: u32 = 4096;

/// Folds the expression rooted at `node` to its constant integer value, if it is
/// a literal arithmetic expression. Returns `None` for anything non-constant
/// (identifiers, calls, member accesses, ...) or unsupported.
pub fn fold(node: Node, source: &str) -> Option<BigInt> {
    match node.kind() {
        // Transparent wrappers: the grammar wraps every expression in a single-child
        // `expression` node, and parentheses are their own node. Both just defer to
        // the inner expression.
        "expression" | "parenthesized_expression" => {
            let mut cursor = node.walk();
            let result = node
                .named_children(&mut cursor)
                .find_map(|c| fold(c, source));
            result
        }
        "number_literal" => fold_number_literal(node, source),
        "unary_expression" => fold_unary(node, source),
        "binary_expression" => fold_binary(node, source),
        _ => None,
    }
}

/// Folds a `number_literal`, including hex (`0x..`), decimal, scientific
/// (`2e10`) forms and an optional trailing unit (`wei`/`gwei`/`ether`,
/// `seconds`..`weeks`). Underscores in digit groups are ignored, as in Solidity.
fn fold_number_literal(node: Node, source: &str) -> Option<BigInt> {
    let text = node.utf8_text(source.as_bytes()).ok()?.trim();

    // Split off an optional unit suffix (the grammar models it as a `number_unit`
    // child, but reading the text is simpler and robust to whitespace).
    let (number_part, unit_mul) = split_unit(text);
    let number_part: String = number_part.chars().filter(|c| *c != '_').collect();
    let number_part = number_part.trim();

    let base = if let Some(hex) = number_part
        .strip_prefix("0x")
        .or_else(|| number_part.strip_prefix("0X"))
    {
        BigInt::parse_bytes(hex.as_bytes(), 16)?
    } else if let Some((mantissa, exp)) = number_part.split_once(['e', 'E']) {
        // Scientific notation: mantissa * 10^exp (Solidity requires this to be an integer).
        let mantissa = BigInt::parse_bytes(mantissa.as_bytes(), 10)?;
        let exp: u32 = exp.parse().ok()?;
        if exp > MAX_EXPONENT {
            return None;
        }
        mantissa * pow10(exp)
    } else {
        BigInt::parse_bytes(number_part.as_bytes(), 10)?
    };

    Some(base * unit_mul)
}

/// Splits a trailing Solidity number unit off `text`, returning the numeric part
/// and the multiplier the unit denotes (1 if there is no unit).
fn split_unit(text: &str) -> (&str, BigInt) {
    const UNITS: &[(&str, u64)] = &[
        ("wei", 1),
        ("gwei", 1_000_000_000),
        ("ether", 1_000_000_000_000_000_000),
        ("seconds", 1),
        ("minutes", 60),
        ("hours", 3600),
        ("days", 86_400),
        ("weeks", 604_800),
    ];
    for (unit, mul) in UNITS {
        if let Some(rest) = text.strip_suffix(unit) {
            // Require the unit to be a separate word (preceded by space or digit).
            if rest.is_empty() || rest.ends_with(|c: char| c.is_whitespace() || c.is_ascii_digit())
            {
                return (rest.trim_end(), BigInt::from(*mul));
            }
        }
    }
    (text, BigInt::from(1u32))
}

fn fold_unary(node: Node, source: &str) -> Option<BigInt> {
    let arg = fold(node.child_by_field_name("argument")?, source)?;
    let op = node.child_by_field_name("operator")?;
    match op.kind() {
        "-" => Some(-arg),
        // Bitwise NOT on an unbounded integer is `-(x + 1)`; this matches Solidity
        // only for non-negative widths but is irrelevant for the high-slot use case.
        "~" => Some(-(arg + BigInt::from(1u32))),
        _ => None,
    }
}

fn fold_binary(node: Node, source: &str) -> Option<BigInt> {
    let left = fold(node.child_by_field_name("left")?, source)?;
    let right = fold(node.child_by_field_name("right")?, source)?;
    let op = node.child_by_field_name("operator")?;
    match op.kind() {
        "+" => Some(left + right),
        "-" => Some(left - right),
        "*" => Some(left * right),
        "/" => {
            if right.is_zero() {
                None
            } else {
                Some(left / right)
            }
        }
        "%" => {
            if right.is_zero() {
                None
            } else {
                Some(left % right)
            }
        }
        "**" => {
            let exp = bounded_exponent(&right)?;
            Some(pow(left, exp))
        }
        "<<" => {
            let sh = bounded_exponent(&right)?;
            Some(left << sh)
        }
        ">>" => {
            let sh = bounded_exponent(&right)?;
            Some(left >> sh)
        }
        "&" => Some(left & right),
        "|" => Some(left | right),
        "^" => Some(left ^ right),
        // Comparison/logical operators do not yield integers we model.
        _ => None,
    }
}

/// Validates that `n` is a small non-negative integer usable as an exponent or
/// shift distance, rejecting negatives and anything above `MAX_EXPONENT`.
fn bounded_exponent(n: &BigInt) -> Option<u32> {
    if n.is_negative() {
        return None;
    }
    let v: u32 = u32::try_from(n).ok()?;
    if v > MAX_EXPONENT {
        None
    } else {
        Some(v)
    }
}

fn pow(base: BigInt, exp: u32) -> BigInt {
    base.pow(exp)
}

fn pow10(exp: u32) -> BigInt {
    BigInt::from(10u32).pow(exp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    fn fold_expr(src: &str) -> Option<String> {
        // Wrap the expression in a contract layout specifier so the grammar parses it,
        // then locate the layout value expression and fold it.
        let full = format!("contract C layout at {} {{}}", src);
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_solidity::LANGUAGE.into())
            .unwrap();
        let tree = parser.parse(&full, None).unwrap();
        let layout = find_kind(tree.root_node(), "layout_specifier")?;
        let mut cursor = layout.walk();
        let expr = layout
            .named_children(&mut cursor)
            .find(|c| c.kind() != "number_unit")?;
        fold(expr, &full).map(|v| v.to_string())
    }

    fn find_kind<'a>(node: Node<'a>, kind: &str) -> Option<Node<'a>> {
        if node.kind() == kind {
            return Some(node);
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if let Some(found) = find_kind(child, kind) {
                return Some(found);
            }
        }
        None
    }

    #[test]
    fn folds_high_slot_expression() {
        assert_eq!(
            fold_expr("2**256 - 2**64").as_deref(),
            Some("115792089237316195423570985008687907853269984665640564039439137263839420088320")
        );
    }

    #[test]
    fn folds_power_and_literals() {
        assert_eq!(
            fold_expr("2**256").as_deref(),
            Some("115792089237316195423570985008687907853269984665640564039457584007913129639936")
        );
        assert_eq!(
            fold_expr("2**256 - 1").as_deref(),
            Some("115792089237316195423570985008687907853269984665640564039457584007913129639935")
        );
        assert_eq!(fold_expr("100").as_deref(), Some("100"));
        assert_eq!(fold_expr("1_000_000").as_deref(), Some("1000000"));
    }

    #[test]
    fn folds_hex_and_shift_and_parens() {
        assert_eq!(fold_expr("0xff").as_deref(), Some("255"));
        assert_eq!(
            fold_expr("1 << 64").as_deref(),
            Some("18446744073709551616")
        );
        assert_eq!(fold_expr("(2 + 3) * 4").as_deref(), Some("20"));
    }

    #[test]
    fn rejects_non_constant_and_unsupported() {
        assert_eq!(fold_expr("SOME_CONST"), None);
        assert_eq!(fold_expr("a + 1"), None);
        assert_eq!(fold_expr("2 ** 100000000"), None);
    }
}
