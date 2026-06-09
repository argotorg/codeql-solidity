/**
 * @name External call graph extraction
 * @description External calls: low-level, delegate, interface and value transfers.
 * @id solidity/external-call-graph
 */

import codeql.solidity.ast.internal.TreeSitter
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
 * Gets the external call type.
 */
string getExternalCallType(ExternalCalls::ExternalCall call) {
  ExternalCalls::isCall(call) and result = "call"
  or
  ExternalCalls::isDelegateCall(call) and result = "delegatecall"
  or
  ExternalCalls::isStaticCall(call) and result = "staticcall"
  or
  ExternalCalls::isThisCall(call) and not ExternalCalls::isLowLevelCall(call) and result = "this"
  or
  ExternalCalls::isContractReferenceCall(call) and result = "interface"
  or
  ExternalCalls::isEtherTransfer(call) and result = "transfer"
}

/** One row per external call site. */
query predicate externalCalls(
  string contract, string function, string callType, ExternalCalls::ExternalCall node
) {
  contract = getContractName(node.getEnclosingContract()) and
  function = getFunctionName(node.getEnclosingFunction()) and
  callType = getExternalCallType(node)
}
