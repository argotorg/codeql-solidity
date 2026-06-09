/**
 * @name Token pattern analysis
 * @description Token patterns: SafeERC20, transfers, approvals.
 * @id solidity/token-patterns
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Gets the contract name.
 */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the function name.
 */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/** Holds if `method` is a raw ERC-20 style call, or its SafeERC20 wrapper. */
bindingset[method]
predicate tokenMethod(string method, boolean safe) {
  method in ["transfer", "transferFrom", "approve"] and safe = false
  or
  (method.matches("safeTransfer%") or method.matches("safeApprove%") or method = "forceApprove") and
  safe = true
}

/** `using SafeERC20 for ...` directives. */
query predicate safeErc20Usage(string contract, string library, Solidity::UsingDirective node) {
  exists(Solidity::ContractDeclaration c, Solidity::Identifier libId |
    node.getParent+() = c and
    libId.getParent+() = node and
    contract = getContractName(c) and
    library = libId.getValue() and
    (library.matches("%SafeERC20%") or library.matches("%SafeTransfer%"))
  )
}

/**
 * Token transfer/approval call sites. `safe` marks the SafeERC20 wrappers;
 * `returnUsed` is false when the call is a bare statement, i.e. a raw
 * `transfer(...)` whose bool result is discarded.
 */
query predicate tokenCalls(
  string contract, string function, string method, boolean safe, boolean returnUsed,
  Solidity::CallExpression node
) {
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::MemberExpression member
  |
    node.getParent+() = f and
    f.getParent+() = c and
    member = node.getFunction() and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    method = member.getProperty().(Solidity::AstNode).getValue() and
    tokenMethod(method, safe) and
    (
      if node.getParent() instanceof Solidity::ExpressionStatement
      then returnUsed = false
      else returnUsed = true
    )
  )
}

/** Functions whose name is part of the ERC-20 or ERC-721 interface. */
query predicate tokenInterfaceFunctions(
  string contract, string function, string standard, Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    (
      function in [
          "transfer", "transferFrom", "approve", "allowance", "balanceOf", "totalSupply", "name",
          "symbol", "decimals"
        ] and
      standard = "ERC-20"
      or
      function in [
          "ownerOf", "safeTransferFrom", "setApprovalForAll", "getApproved", "isApprovedForAll",
          "tokenURI", "tokenByIndex", "tokenOfOwnerByIndex"
        ] and
      standard = "ERC-721"
    )
  )
}

/** State variables typed as, or named after, a token. */
query predicate tokenVariables(
  string contract, string name, string type, Solidity::StateVariableDeclaration node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    name = node.getName().(Solidity::AstNode).getValue() and
    type = node.getType().(Solidity::AstNode).toString() and
    (
      type.matches("%ERC20%") or
      type.matches("%ERC721%") or
      type.matches("%ERC1155%") or
      name.toLowerCase().matches("%token%")
    )
  )
}

/** Supply-changing functions, by name. */
query predicate mintBurnFunctions(
  string contract, string function, string kind, Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    (
      function.toLowerCase().matches("%mint%") and kind = "mint"
      or
      function.toLowerCase().matches("%burn%") and kind = "burn"
    )
  )
}

/** ERC-2612 style `permit` functions. */
query predicate permitFunctions(
  string contract, string function, Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    function.toLowerCase().matches("%permit%")
  )
}
