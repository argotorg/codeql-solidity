/**
 * @name Unresolved calls
 * @description Calls that cannot be statically resolved to a target function.
 * @id solidity/unresolved-calls
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.CallResolution

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
 * Gets the enclosing function of a call expression.
 */
Solidity::FunctionDefinition getEnclosingFunction(Solidity::CallExpression call) {
  call.getParent+() = result
}

/**
 * Gets the enclosing contract of a function.
 */
Solidity::ContractDeclaration getEnclosingContract(Solidity::FunctionDefinition func) {
  func.getParent+() = result
}

/**
 * Gets a string representation of the call target.
 */
string getCallTargetString(Solidity::CallExpression call) {
  result = call.getFunction().(Solidity::Identifier).getValue()
  or
  result = call.getFunction().(Solidity::MemberExpression).getProperty().(Solidity::AstNode).getValue()
}

/** Calls the resolver could not tie to a definition, with the callee name as written. */
query predicate unresolvedCalls(
  string contract, string function, string target, Solidity::CallExpression node
) {
  CallResolution::isUnresolved(node) and
  exists(Solidity::FunctionDefinition f |
    f = getEnclosingFunction(node) and
    contract = getContractName(getEnclosingContract(f)) and
    function = getFunctionName(f) and
    target = getCallTargetString(node)
  )
}
