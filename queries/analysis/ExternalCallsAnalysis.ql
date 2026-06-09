/**
 * @name External calls analysis
 * @description External call targets and interface definitions.
 * @id solidity/external-calls-analysis
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.ExternalCalls
import codeql.solidity.callgraph.CallResolution

/**
 * Gets the contract name from a contract declaration.
 */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the interface name.
 */
string getInterfaceName(Solidity::InterfaceDeclaration iface) {
  result = iface.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the function name from a function definition.
 */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets visibility of a function.
 */
string getFunctionVisibility(Solidity::FunctionDefinition func) {
  exists(Solidity::AstNode vis |
    vis.getParent() = func and
    vis.toString() = "Visibility" and
    result = vis.getAChild().getValue()
  )
  or
  not exists(Solidity::AstNode vis |
    vis.getParent() = func and
    vis.toString() = "Visibility"
  ) and
  result = "public"
}

/** Interface declarations and how many functions they declare. */
query predicate interfaceDefinitions(
  string name, int functionCount, Solidity::InterfaceDeclaration node
) {
  name = getInterfaceName(node) and
  functionCount = count(Solidity::FunctionDefinition f | f.getParent+() = node)
}

/** Functions declared in an interface. */
query predicate interfaceFunctions(
  string interface, string function, string visibility, Solidity::FunctionDefinition node
) {
  exists(Solidity::InterfaceDeclaration i |
    node.getParent+() = i and
    interface = getInterfaceName(i) and
    function = getFunctionName(node) and
    visibility = getFunctionVisibility(node)
  )
}

/** Interface-typed calls: `target.method(...)`. */
query predicate highLevelCalls(
  string contract, string function, string target, string method, Solidity::CallExpression node
) {
  ExternalCalls::isContractReferenceCall(node) and
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::MemberExpression member
  |
    node.getParent+() = f and
    f.getParent+() = c and
    member = node.getFunction() and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    target = member.getObject().(Solidity::AstNode).getAChild*().(Solidity::Identifier).getValue() and
    method = member.getProperty().(Solidity::AstNode).getValue()
  )
}

/** `call` / `delegatecall` / `staticcall` sites. */
query predicate lowLevelCalls(
  string contract, string function, string callType, Solidity::CallExpression node
) {
  ExternalCalls::isLowLevelCall(node) and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    (
      ExternalCalls::isCall(node) and callType = "call"
      or
      ExternalCalls::isDelegateCall(node) and callType = "delegatecall"
      or
      ExternalCalls::isStaticCall(node) and callType = "staticcall"
    )
  )
}

/** `transfer` / `send` value transfers. */
query predicate etherTransfers(
  string contract, string function, string transferType, Solidity::CallExpression node
) {
  ExternalCalls::isEtherTransfer(node) and
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::MemberExpression member
  |
    node.getParent+() = f and
    f.getParent+() = c and
    member = node.getFunction() and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    transferType = member.getProperty().(Solidity::AstNode).getValue()
  )
}

/** `this.method(...)` external self-calls. */
query predicate thisCalls(
  string contract, string function, string method, Solidity::CallExpression node
) {
  ExternalCalls::isThisCall(node) and
  not ExternalCalls::isLowLevelCall(node) and
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::MemberExpression member
  |
    node.getParent+() = f and
    f.getParent+() = c and
    member = node.getFunction() and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    method = member.getProperty().(Solidity::AstNode).getValue()
  )
}

/** State variables typed as another contract or interface. */
query predicate externalReferences(
  string contract, string variable, string type, Solidity::StateVariableDeclaration node
) {
  exists(Solidity::ContractDeclaration c, Solidity::Identifier typeId |
    node.getParent+() = c and
    typeId = node.getType().getAChild*() and
    contract = getContractName(c) and
    variable = node.getName().(Solidity::AstNode).getValue() and
    type = typeId.getValue() and
    (
      exists(Solidity::ContractDeclaration t | getContractName(t) = type)
      or
      exists(Solidity::InterfaceDeclaration t | getInterfaceName(t) = type)
    )
  )
}

/** Calls the call-graph resolved to a definition. */
query predicate resolvedCalls(
  string contract, string function, string targetContract, string targetFunction,
  Solidity::CallExpression node
) {
  exists(
    Solidity::FunctionDefinition f, Solidity::FunctionDefinition target,
    Solidity::ContractDeclaration c, Solidity::ContractDeclaration tc
  |
    CallResolution::resolveCall(node, target) and
    node.getParent+() = f and
    f.getParent+() = c and
    target.getParent+() = tc and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    targetContract = getContractName(tc) and
    targetFunction = getFunctionName(target)
  )
}

/** Calls the call-graph could not resolve, with the callee name as written. */
query predicate unresolvedCalls(
  string contract, string function, string target, Solidity::CallExpression node
) {
  CallResolution::isUnresolved(node) and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    (
      target = node.getFunction().(Solidity::Identifier).getValue()
      or
      target = node.getFunction().(Solidity::MemberExpression).getProperty().(Solidity::AstNode).getValue()
    )
  )
}
