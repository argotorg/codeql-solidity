/**
 * @name Call callee kinds
 * @description Classifies every call expression by the syntactic kind of its
 *              callee. Useful for understanding how calls resolve to their
 *              targets and for sanity-checking that call -> callee linking is
 *              complete.
 * @id solidity/callee-kinds
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Gets the callee node of `c`, i.e. the expression in its `function` position
 * (an `Identifier` for `f(...)`, a `MemberExpression` for `a.b(...)`, a
 * `NewExpression` for `new T(...)`, etc.). The extractor collapses the grammar's
 * generic `expression` wrapper, so `getFunction()` is the concrete callee.
 */
Solidity::AstNode getCallee(Solidity::CallExpression c) { result = c.getFunction() }

/** Gets the syntactic kind of `c`'s callee (e.g. `Identifier`, `MemberExpression`). */
string calleeKind(Solidity::CallExpression c) { result = getCallee(c).getAPrimaryQlClass() }

/**
 * Gets a human-readable name for `c`'s callee where one is resolvable: the
 * identifier for a direct call, or the member/property name for a member call.
 */
string calleeName(Solidity::CallExpression c) {
  result = getCallee(c).(Solidity::Identifier).getValue()
  or
  result = getCallee(c).(Solidity::MemberExpression).getProperty().(Solidity::AstNode).getValue()
}

/** One row per call site: the syntactic kind of its callee, and the name where resolvable. */
query predicate callees(string kind, string name, Solidity::CallExpression node) {
  kind = calleeKind(node) and
  (if exists(calleeName(node)) then name = calleeName(node) else name = "")
}
