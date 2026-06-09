/**
 * @name assert() used in production code
 * @description `assert` is meant to check invariants that should never fail; a
 *              failing assert signals a bug and (pre-0.8.0) consumes all
 *              remaining gas. Input validation and access checks belong in
 *              `require`. This query flags `assert` calls outside of test and
 *              property-checking harnesses.
 * @kind problem
 * @problem.severity recommendation
 * @precision medium
 * @id solidity/assert-in-production
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

/**
 * Holds if `c` lives in a test or property-checking harness, where `assert`
 * is the idiomatic way to express invariants (e.g. Echidna/Foundry fuzzing).
 */
predicate inTestHarness(Solidity::CallExpression c) {
  c.getLocation().getFile().getName().matches(["%/test/%", "%/echidna/%", "%/crytic/%", "%/audits/%"])
  or
  c.getLocation().getFile().getName().matches(["%Test.sol", "%EchidnaTest.sol"])
}

from Solidity::CallExpression call
where
  calleeName(call) = "assert" and
  not inTestHarness(call)
select call, "assert() in production code: use require() for validation and reserve assert for invariants."
