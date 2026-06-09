/**
 * @name ERC standard compliance analysis
 * @description ERC-20, ERC-721 and ERC-1155 compliance.
 * @id solidity/erc-compliance
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Gets the contract name.
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
 * Gets the function name.
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
  result = "internal"
}

/**
 * Gets mutability (view, pure, payable).
 */
string getFunctionMutability(Solidity::FunctionDefinition func) {
  exists(Solidity::AstNode mut |
    mut.getParent() = func and
    mut.getValue() in ["view", "pure", "payable"] and
    result = mut.getValue()
  )
  or
  not exists(Solidity::AstNode mut |
    mut.getParent() = func and
    mut.getValue() in ["view", "pure", "payable"]
  ) and
  result = "nonpayable"
}

/**
 * Gets parameter count.
 */
int getParamCount(Solidity::FunctionDefinition func) {
  result = count(Solidity::Parameter p | p.getParent() = func)
}

/**
 * ERC-20 required functions.
 */
predicate isERC20Function(string name) {
  name in [
      "totalSupply", "balanceOf", "transfer", "transferFrom", "approve", "allowance", "name",
      "symbol", "decimals"
    ]
}

/**
 * ERC-721 required functions.
 */
predicate isERC721Function(string name) {
  name in [
      "balanceOf", "ownerOf", "safeTransferFrom", "transferFrom", "approve", "setApprovalForAll",
      "getApproved", "isApprovedForAll", "name", "symbol", "tokenURI", "supportsInterface"
    ]
}

/**
 * ERC-1155 required functions.
 */
predicate isERC1155Function(string name) {
  name in [
      "balanceOf", "balanceOfBatch", "setApprovalForAll", "isApprovedForAll", "safeTransferFrom",
      "safeBatchTransferFrom", "uri", "supportsInterface"
    ]
}

/** Maps each supported standard to the functions it requires. */
predicate requiredFunction(string standard, string name) {
  standard = "ERC-20" and isERC20Function(name)
  or
  standard = "ERC-721" and isERC721Function(name)
  or
  standard = "ERC-1155" and isERC1155Function(name)
}

/** Functions declared in a contract. */
query predicate contractFunctions(
  string contract, string name, string visibility, string mutability, int params,
  Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    name = getFunctionName(node) and
    visibility = getFunctionVisibility(node) and
    mutability = getFunctionMutability(node) and
    params = getParamCount(node)
  )
}

/** Functions declared in an interface. */
query predicate interfaceFunctions(
  string interface, string name, string visibility, string mutability, int params,
  Solidity::FunctionDefinition node
) {
  exists(Solidity::InterfaceDeclaration i |
    node.getParent+() = i and
    interface = getInterfaceName(i) and
    name = getFunctionName(node) and
    visibility = getFunctionVisibility(node) and
    mutability = getFunctionMutability(node) and
    params = getParamCount(node)
  )
}

/** Events declared in a contract or interface. */
query predicate events(
  string container, string name, int paramCount, Solidity::EventDefinition node
) {
  (
    exists(Solidity::ContractDeclaration c |
      node.getParent+() = c and container = getContractName(c)
    )
    or
    exists(Solidity::InterfaceDeclaration i |
      node.getParent+() = i and container = getInterfaceName(i)
    )
  ) and
  name = node.getName().(Solidity::AstNode).getValue() and
  paramCount = count(Solidity::EventParameter p | p.getParent() = node)
}

/** `import` directives. */
query predicate imports(string path, Solidity::ImportDirective node) {
  path = node.getSource().(Solidity::AstNode).getValue()
}

/** Direct `is Base` relationships. */
query predicate inheritance(
  string contract, string base, Solidity::InheritanceSpecifier node
) {
  exists(Solidity::ContractDeclaration c, Solidity::Identifier baseId |
    node.getParent() = c and
    baseId = node.getAncestor().getAChild*() and
    contract = getContractName(c) and
    base = baseId.getValue()
  )
}

/** Holds if `c` declares at least one function required by `standard`. */
predicate implementsSome(Solidity::ContractDeclaration c, string standard) {
  exists(Solidity::FunctionDefinition f, string name |
    f.getParent+() = c and
    getFunctionName(f) = name and
    requiredFunction(standard, name)
  )
}

/**
 * One row per (contract, standard, required function), with whether the contract
 * declares it. Restricted to contracts that declare at least one function of the
 * standard — without that the table is every contract crossed with every standard.
 */
query predicate ercCompliance(
  string contract, string standard, string requiredFunc, boolean present,
  Solidity::ContractDeclaration node
) {
  implementsSome(node, standard) and
  contract = getContractName(node) and
  requiredFunction(standard, requiredFunc) and
  (
    if exists(Solidity::FunctionDefinition f |
        f.getParent+() = node and getFunctionName(f) = requiredFunc
      )
    then present = true
    else present = false
  )
}

/** Per (contract, standard) counts of declared vs required functions. */
query predicate ercComplianceSummary(
  string contract, string standard, int declared, int required, Solidity::ContractDeclaration node
) {
  implementsSome(node, standard) and
  contract = getContractName(node) and
  declared =
    count(string name |
      requiredFunction(standard, name) and
      exists(Solidity::FunctionDefinition f | f.getParent+() = node and getFunctionName(f) = name)
    ) and
  required = count(string name | requiredFunction(standard, name))
}
