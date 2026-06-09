/**
 * @name DeFi pattern analysis
 * @description DeFi patterns: math operations, fees, accounting, rounding.
 * @id solidity/defi-patterns
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

/** Classifies a state variable name into a DeFi role. */
bindingset[name]
predicate variableCategory(string name, string category) {
  category = "fee" and name.toLowerCase().regexpMatch(".*(fee|tax|rate|basis|percent|bps).*")
  or
  category = "balance" and
  name.toLowerCase().regexpMatch(".*(balance|amount|total|reserve|supply|liquidity).*")
  or
  category = "price" and name.toLowerCase().regexpMatch(".*(price|oracle|rate|exchange).*")
}

/** Arithmetic operations, one row per `/`, `*` or `%` expression. */
query predicate arithmeticOperations(
  string contract, string function, string operator, Solidity::BinaryExpression node
) {
  operator = node.getOperator().(Solidity::AstNode).getValue() and
  operator in ["/", "*", "%"] and
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/**
 * State variables whose name marks them as a fee, balance or price. A variable
 * can fall in more than one category (`rate`), producing one row each.
 */
query predicate taggedVariables(
  string contract, string name, string type, string category,
  Solidity::StateVariableDeclaration node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    name = node.getName().(Solidity::AstNode).getValue() and
    type = node.getType().(Solidity::AstNode).toString() and
    variableCategory(name, category)
  )
}

/** Assignments to a state variable. */
query predicate stateWrites(
  string contract, string function, string variable, Solidity::AssignmentExpression node
) {
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::Identifier id,
    Solidity::StateVariableDeclaration sv
  |
    node.getParent+() = f and
    f.getParent+() = c and
    id.getParent+() = node.getLeft() and
    sv.getParent+() = c and
    sv.getName().(Solidity::AstNode).getValue() = id.getValue() and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    variable = id.getValue()
  )
}

/** `unchecked { ... }` blocks, where 0.8+ overflow checks are off. */
query predicate uncheckedBlocks(string contract, string function, Solidity::Unchecked node) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/** Numeric literals large enough to look like an un-named constant. */
query predicate magicNumbers(
  string contract, string function, string value, Solidity::NumberLiteral node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    value = node.getValue() and
    not value in ["0", "1", "2"] and
    not value.matches("10%") and
    not value.matches("1e%") and
    (value.toInt() > 100 or value.matches("%000%"))
  )
}

/** Multiplications containing a nested division — divide-before-multiply rounding. */
query predicate roundingRisks(
  string contract, string function, Solidity::BinaryExpression node
) {
  node.getOperator().(Solidity::AstNode).getValue() = "*" and
  exists(
    Solidity::BinaryExpression div, Solidity::FunctionDefinition f, Solidity::ContractDeclaration c
  |
    div.getOperator().(Solidity::AstNode).getValue() = "/" and
    div.getParent+() = node and
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}
