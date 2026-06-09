/**
 * @name Inheritance chain analysis
 * @description Inheritance hierarchies, overridden functions, and virtual functions.
 * @id solidity/inheritance-analysis
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.InheritanceGraph

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
 * Gets the interface name.
 */
string getInterfaceName(Solidity::InterfaceDeclaration iface) {
  result = iface.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the library name.
 */
string getLibraryName(Solidity::LibraryDeclaration lib) {
  result = lib.getName().(Solidity::AstNode).getValue()
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

/** One row per contract, with its direct bases and inheritance depth. */
query predicate contracts(
  string name, boolean isAbstract, string directBases, int depth, Solidity::ContractDeclaration node
) {
  name = getContractName(node) and
  (
    if InheritanceGraph::isAbstractContract(node) then isAbstract = true else isAbstract = false
  ) and
  directBases =
    concat(Solidity::ContractDeclaration base |
      base = InheritanceGraph::getDirectBase(node)
    |
      getContractName(base), ","
    ) and
  depth = InheritanceGraph::getInheritanceDepth(node)
}

/** One row per interface, with its direct base interfaces. */
query predicate interfaces(string name, string directBases, Solidity::InterfaceDeclaration node) {
  name = getInterfaceName(node) and
  directBases =
    concat(Solidity::InterfaceDeclaration base |
      base = InheritanceGraph::getDirectBaseInterface(node)
    |
      getInterfaceName(base), ","
    )
}

/** One row per library. */
query predicate libraries(string name, Solidity::LibraryDeclaration node) {
  name = getLibraryName(node)
}

/** Functions marked `override`, paired with the declaration they override. */
query predicate overriddenFunctions(
  string name, string contract, string overridesContract, string visibility,
  Solidity::FunctionDefinition node
) {
  InheritanceGraph::isOverrideFunction(node) and
  exists(Solidity::ContractDeclaration c, Solidity::FunctionDefinition overridden |
    node.getParent+() = c and
    overridden = InheritanceGraph::getOverriddenFunction(node) and
    name = getFunctionName(node) and
    contract = getContractName(c) and
    overridesContract = getContractName(overridden.getParent+()) and
    visibility = getFunctionVisibility(node)
  )
}

/** Functions marked `virtual`. */
query predicate virtualFunctions(
  string name, string contract, string visibility, Solidity::FunctionDefinition node
) {
  InheritanceGraph::isVirtualFunction(node) and
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    name = getFunctionName(node) and
    contract = getContractName(c) and
    visibility = getFunctionVisibility(node)
  )
}

/** Contracts reaching the same base through more than one intermediate. */
query predicate diamondInheritance(
  string contract, string repeatedBase, Solidity::ContractDeclaration node
) {
  exists(Solidity::ContractDeclaration base |
    count(Solidity::ContractDeclaration intermediate |
      InheritanceGraph::inheritsFrom(node, intermediate) and
      InheritanceGraph::inheritsFrom(intermediate, base)
    ) > 1 and
    contract = getContractName(node) and
    repeatedBase = getContractName(base)
  )
}
