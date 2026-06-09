/**
 * @name Call graph extraction
 * @description Caller to callee edges for every call the resolver can resolve.
 * @id solidity/call-graph
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.CallResolution
import codeql.solidity.callgraph.ExternalCalls

/**
 * Gets the function name from a function definition.
 */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the contract name from a contract declaration.
 */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the enclosing contract of a function.
 */
Solidity::ContractDeclaration getEnclosingContract(Solidity::FunctionDefinition func) {
  func.getParent+() = result
}

/**
 * Gets the enclosing function of a call expression.
 */
Solidity::FunctionDefinition getEnclosingFunction(Solidity::CallExpression call) {
  call.getParent+() = result
}

/**
 * Gets the call type as a string.
 */
string getCallType(Solidity::CallExpression call, Solidity::FunctionDefinition target) {
  CallResolution::resolveInternalCall(call, target) and result = "internal"
  or
  CallResolution::resolveInheritedCall(call, target) and result = "inherited"
  or
  CallResolution::resolveSuperCall(call, target) and result = "super"
  or
  CallResolution::resolveThisCall(call, target) and result = "this"
  or
  CallResolution::resolveMemberCallToInterface(call, target) and result = "interface"
  or
  CallResolution::resolveMemberCallFromParameter(call, target) and result = "parameter"
}

/**
 * One row per resolved call edge. `caller` and `target` are entity columns, so
 * the exported JSON carries the definition sites alongside the call site.
 */
query predicate calls(
  string callerContract, string callerFunction, string targetContract, string targetFunction,
  string callType, Solidity::FunctionDefinition caller, Solidity::FunctionDefinition target,
  Solidity::CallExpression node
) {
  CallResolution::resolveCall(node, target) and
  caller = getEnclosingFunction(node) and
  callerContract = getContractName(getEnclosingContract(caller)) and
  callerFunction = getFunctionName(caller) and
  targetContract = getContractName(getEnclosingContract(target)) and
  targetFunction = getFunctionName(target) and
  callType = getCallType(node, target)
}
