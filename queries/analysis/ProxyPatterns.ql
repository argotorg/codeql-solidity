/**
 * @name Proxy pattern analysis
 * @description Library usage, delegatecalls, and proxy patterns.
 * @id solidity/proxy-patterns
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.InheritanceGraph
import codeql.solidity.callgraph.ExternalCalls

/**
 * Gets the contract name from a contract declaration.
 */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the library name.
 */
string getLibraryName(Solidity::LibraryDeclaration lib) {
  result = lib.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the function name from a function definition.
 */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/** `using L for T` directives. `appliedTo` is `*` when the directive is unrestricted. */
query predicate usingForDirectives(
  string contract, string library, string appliedTo, Solidity::UsingDirective node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    (
      exists(Solidity::Identifier libId | libId.getParent+() = node and library = libId.getValue())
      or
      not exists(Solidity::Identifier libId | libId.getParent+() = node) and library = "unknown"
    ) and
    (
      exists(Solidity::AstNode typeNode |
        typeNode.getParent() = node and
        typeNode.toString() != "Identifier" and
        appliedTo = typeNode.toString()
      )
      or
      not exists(Solidity::AstNode typeNode |
        typeNode.getParent() = node and
        typeNode.toString() != "Identifier"
      ) and
      appliedTo = "*"
    )
  )
}

/** Library definitions and how many functions they declare. */
query predicate libraries(string name, int functionCount, Solidity::LibraryDeclaration node) {
  name = getLibraryName(node) and
  functionCount = count(Solidity::FunctionDefinition f | f.getParent+() = node)
}

/** `delegatecall` sites. */
query predicate delegatecalls(
  string contract, string function, Solidity::CallExpression node
) {
  ExternalCalls::isDelegateCall(node) and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/** Address-typed state variables named like an implementation pointer. */
query predicate implementationSlots(
  string contract, string variable, string type, Solidity::StateVariableDeclaration node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    variable = node.getName().(Solidity::AstNode).getValue() and
    type = node.getType().(Solidity::AstNode).toString() and
    (
      variable.toLowerCase().matches("%implementation%") or
      variable.toLowerCase().matches("%logic%") or
      variable.toLowerCase().matches("%target%") or
      variable.toLowerCase().matches("%beacon%")
    ) and
    type.toLowerCase().matches("%address%")
  )
}

/** Literals matching a standard EIP-1967 storage slot hash. */
query predicate eip1967Slots(string contract, string slot, Solidity::AstNode node) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    (
      node.getValue()
          .matches("%360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc%") and
      slot = "implementation"
      or
      node.getValue()
          .matches("%b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103%") and
      slot = "admin"
      or
      node.getValue()
          .matches("%a3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50%") and
      slot = "beacon"
    )
  )
}

/** Proxy patterns inferred from the names of inherited contracts. */
query predicate proxyPatterns(
  string contract, string pattern, string inheritedFrom, Solidity::ContractDeclaration node
) {
  exists(Solidity::ContractDeclaration base |
    base = InheritanceGraph::getInheritanceChain(node) and
    base != node and
    contract = getContractName(node) and
    inheritedFrom = getContractName(base) and
    (
      inheritedFrom.toLowerCase().matches("%uupsupgradeable%") and pattern = "UUPS"
      or
      inheritedFrom.toLowerCase().matches("%transparentupgradeableproxy%") and
      pattern = "Transparent"
      or
      inheritedFrom.toLowerCase().matches("%erc1967%") and pattern = "EIP-1967"
      or
      inheritedFrom.toLowerCase().matches("%beacon%") and pattern = "Beacon"
      or
      inheritedFrom.toLowerCase().matches("%proxy%") and
      not inheritedFrom.toLowerCase().matches("%transparent%") and
      not inheritedFrom.toLowerCase().matches("%uups%") and
      pattern = "Generic Proxy"
    )
  )
}

/** Contracts whose name suggests a diamond/facet layout. */
query predicate diamondPatterns(string contract, Solidity::ContractDeclaration node) {
  contract = getContractName(node) and
  (contract.toLowerCase().matches("%diamond%") or contract.toLowerCase().matches("%facet%"))
}
