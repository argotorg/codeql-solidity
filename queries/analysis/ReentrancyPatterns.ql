/**
 * @name Reentrancy pattern analysis
 * @description CEI violations found by control flow reachability instead of line numbers.
 * @id solidity/reentrancy-patterns
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.ExternalCalls
import codeql.solidity.callgraph.CallResolution
import codeql.solidity.controlflow.internal.ControlFlowGraphImpl

/** Gets the contract name. */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/** Gets the function name. */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the name of a modifier invocation.
 *
 * `ModifierInvocation` is not a leaf token, so `getValue()` on it is empty; the
 * name is its `Identifier` child.
 */
string getModifierName(Solidity::ModifierInvocation mod) {
  exists(Solidity::Identifier id | id.getParent() = mod and result = id.getValue())
}

/** Holds if a function has a reentrancy guard modifier. */
predicate hasReentrancyGuard(Solidity::FunctionDefinition func) {
  exists(string name |
    name = getModifierName(any(Solidity::ModifierInvocation m | m.getParent() = func)).toLowerCase()
  |
    name.matches("%nonreentrant%") or
    name.matches("%lock%") or
    name.matches("%mutex%") or
    name.matches("%guard%")
  )
}

/**
 * Holds if `id` refers to a state variable `varName` declared in `contract`.
 */
private predicate isStateVarIdentifier(
  Solidity::Identifier id, Solidity::ContractDeclaration contract, string varName
) {
  exists(Solidity::StateVariableDeclaration sv |
    sv.getParent+() = contract and
    varName = sv.getName().(Solidity::AstNode).getValue() and
    id.getValue() = varName
  )
}

/**
 * Holds if `node` directly modifies a state variable declared in `contract`.
 *
 * Covers: assignment, augmented assignment (+=, -=), update (++, --),
 * delete, and array push/pop.
 */
predicate directlyModifiesState(
  Solidity::AstNode node, Solidity::ContractDeclaration contract, string varName
) {
  exists(Solidity::Identifier id |
    isStateVarIdentifier(id, contract, varName) and
    (
      // Assignment (x = ...) or augmented assignment (x += ...)
      node.(Solidity::AssignmentExpression).getLeft() = id.getParent+()
      or
      node.(Solidity::AugmentedAssignmentExpression).getLeft() = id.getParent+()
      or
      // Update expression (x++, x--, ++x, --x)
      id = node.(Solidity::UpdateExpression).getArgument().getAChild*()
      or
      // Delete expression (delete x)
      exists(Solidity::UnaryExpression unary |
        node = unary and
        unary.getOperator().(Solidity::AstNode).getValue() = "delete" and
        id = unary.getArgument().getAChild*()
      )
      or
      // Array push/pop (arr.push(...), arr.pop())
      exists(Solidity::MemberExpression mem |
        node.(Solidity::CallExpression).getFunction() = mem and
        mem.getProperty().(Solidity::AstNode).getValue() in ["push", "pop"] and
        id = mem.getObject().getAChild*()
      )
    )
  )
}

/**
 * Holds if `call` is an internal function call (not external).
 */
private predicate isInternalCall(Solidity::CallExpression call) {
  CallResolution::resolveCall(call, _) and
  not ExternalCalls::isLowLevelCall(call) and
  not ExternalCalls::isContractReferenceCall(call) and
  not ExternalCalls::isEtherTransfer(call) and
  not ExternalCalls::isThisCall(call)
}

/**
 * Holds if `func` (or any function it transitively calls internally)
 * modifies a state variable in `contract`.
 *
 * Uses QL fixpoint: base case is direct modification, recursive case
 * follows internal call edges via CallResolution.
 */
predicate functionModifiesState(
  Solidity::FunctionDefinition func, Solidity::ContractDeclaration contract, string varName
) {
  // Base: func directly contains a state-modifying node
  exists(Solidity::AstNode mod |
    mod.getParent+() = func and
    directlyModifiesState(mod, contract, varName)
  )
  or
  // Recursive: func calls an internal function that modifies state
  exists(Solidity::CallExpression internalCall, Solidity::FunctionDefinition callee |
    internalCall.getParent+() = func and
    isInternalCall(internalCall) and
    CallResolution::resolveCall(internalCall, callee) and
    functionModifiesState(callee, contract, varName)
  )
}

/**
 * Holds if `call` is an external call (low-level, contract reference, or ether transfer).
 */
private predicate isExternalCall(Solidity::CallExpression call) {
  ExternalCalls::isLowLevelCall(call) or
  ExternalCalls::isContractReferenceCall(call) or
  ExternalCalls::isEtherTransfer(call)
}

/**
 * Holds if `later` can execute after `earlier`, both within `func`.
 *
 * Control flow reachability, so mutually exclusive branches are excluded and loop
 * back edges are followed — a state write earlier in the source than the call is
 * still reported when the loop can bring it round again.
 */
predicate executesAfter(
  Solidity::AstNode earlier, Solidity::AstNode later, Solidity::FunctionDefinition func
) {
  earlier.getParent+() = func and
  later.getParent+() = func and
  successor+(earlier, later)
}

/**
 * Holds if `func`, or any function it transitively calls internally, performs an
 * external call. The mirror of `functionModifiesState`.
 */
predicate functionMakesExternalCall(Solidity::FunctionDefinition func) {
  exists(Solidity::CallExpression call |
    call.getParent+() = func and
    isExternalCall(call)
  )
  or
  exists(Solidity::CallExpression internalCall, Solidity::FunctionDefinition callee |
    internalCall.getParent+() = func and
    isInternalCall(internalCall) and
    CallResolution::resolveCall(internalCall, callee) and
    functionMakesExternalCall(callee)
  )
}

/**
 * CEI violations where the state write sits in the same function as the call.
 * `write` and `node` are separate entity columns, so both locations survive
 * into the exported JSON.
 */
query predicate ceiViolations(
  string contract, string function, string variable, Solidity::AstNode write,
  Solidity::CallExpression node
) {
  isExternalCall(node) and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    not hasReentrancyGuard(f) and
    directlyModifiesState(write, c, variable) and
    executesAfter(node, write, f) and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/**
 * CEI violations where the state write happens inside a function called after
 * the external call — invisible to any line-order check.
 */
query predicate interproceduralCeiViolations(
  string contract, string function, string callee, string variable,
  Solidity::CallExpression internalCall, Solidity::CallExpression node
) {
  isExternalCall(node) and
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c,
    Solidity::FunctionDefinition target
  |
    node.getParent+() = f and
    f.getParent+() = c and
    not hasReentrancyGuard(f) and
    isInternalCall(internalCall) and
    CallResolution::resolveCall(internalCall, target) and
    executesAfter(node, internalCall, f) and
    functionModifiesState(target, c, variable) and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    callee = getFunctionName(target)
  )
}

/**
 * CEI violations where the *external call* is hidden in a callee: `node` is an
 * internal call whose callee reaches out, and a state write follows it.
 */
query predicate hiddenCallCeiViolations(
  string contract, string function, string callee, string variable, Solidity::AstNode write,
  Solidity::CallExpression node
) {
  isInternalCall(node) and
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c,
    Solidity::FunctionDefinition target
  |
    node.getParent+() = f and
    f.getParent+() = c and
    not hasReentrancyGuard(f) and
    CallResolution::resolveCall(node, target) and
    functionMakesExternalCall(target) and
    directlyModifiesState(write, c, variable) and
    executesAfter(node, write, f) and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    callee = getFunctionName(target)
  )
}

/** Every external call site, and whether its function carries a reentrancy guard. */
query predicate externalCalls(
  string contract, string function, string callType, boolean guarded, Solidity::CallExpression node
) {
  isExternalCall(node) and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    (
      ExternalCalls::isDelegateCall(node) and callType = "delegatecall"
      or
      ExternalCalls::isCall(node) and callType = "call"
      or
      ExternalCalls::isStaticCall(node) and callType = "staticcall"
      or
      ExternalCalls::isEtherTransfer(node) and callType = "transfer"
      or
      ExternalCalls::isContractReferenceCall(node) and
      not ExternalCalls::isLowLevelCall(node) and
      not ExternalCalls::isEtherTransfer(node) and
      callType = "high_level"
    ) and
    (if hasReentrancyGuard(f) then guarded = true else guarded = false)
  )
}

/** Every state mutation: assignment, `+=`, `++`, `delete`, `push`/`pop`. */
query predicate stateModifications(
  string contract, string function, string variable, Solidity::AstNode node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    directlyModifiesState(node, c, variable) and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/** Unguarded functions that both call out and write state. */
query predicate unguardedFunctions(
  string contract, string function, int externalCallCount, int stateModCount,
  Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    not hasReentrancyGuard(node) and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    externalCallCount =
      count(Solidity::CallExpression call | call.getParent+() = node and isExternalCall(call)) and
    stateModCount =
      count(Solidity::AstNode mod | mod.getParent+() = node and directlyModifiesState(mod, c, _)) and
    externalCallCount > 0 and
    stateModCount > 0
  )
}

/** Externally reachable functions whose name marks them as a reentrancy entry point. */
query predicate callbackFunctions(
  string contract, string function, Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    exists(Solidity::AstNode vis |
      vis.getParent() = node and
      vis.toString() = "Visibility" and
      vis.getAChild().getValue() in ["external", "public"]
    ) and
    (
      function.toLowerCase().matches("%callback%") or
      function.toLowerCase().matches("%hook%") or
      function.toLowerCase().matches("%on%received%") or
      function.toLowerCase().matches("%flashloan%") or
      function.toLowerCase() in [
          "tokensreceived", "ontokentransfer", "onerc721received", "onerc1155received",
          "uniswapv2call", "uniswapv3swapcallback"
        ]
    )
  )
}

/** `receive()` and `fallback()` functions. */
query predicate etherReceivers(string contract, string kind, Solidity::FunctionDefinition node) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    kind = getFunctionName(node) and
    kind in ["receive", "fallback"]
  )
}
