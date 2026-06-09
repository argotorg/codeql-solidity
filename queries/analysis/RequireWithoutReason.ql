/**
 * @name require() without a reason string
 * @description A `require(condition)` call with no second argument reverts with
 *              no reason string, making failures hard to diagnose on-chain and in
 *              tooling. Supply a human-readable reason string or a custom error.
 * @kind problem
 * @problem.severity recommendation
 * @precision high
 * @id solidity/require-without-reason
 * @tags analysis
 *       maintainability
 *       error-handling
 *       solidity
 */

import codeql.solidity.ast.internal.TreeSitter

/** Gets the callee name of a call expression (the identifier in its function position). */
string calleeName(Solidity::CallExpression c) {
  result = c.getFunction().(Solidity::Identifier).getValue()
}

/** Gets the number of arguments passed to call `c`. */
int argCount(Solidity::CallExpression c) {
  result = count(Solidity::CallArgument a | a.getParent() = c)
}

from Solidity::CallExpression call
where
  calleeName(call) = "require" and
  argCount(call) <= 1
select call, "require() has no reason string; failures will revert without an explanation."
