/**
 * @name Assembly block analysis
 * @description Inline assembly and Yul blocks with security classification.
 * @id solidity/assembly-analysis
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Gets the contract name from a contract declaration.
 */
string getContractName(Solidity::ContractDeclaration contract) {
  result = contract.getName().(Solidity::AstNode).getValue()
}

/**
 * Gets the function name from a function definition.
 */
string getFunctionName(Solidity::FunctionDefinition func) {
  result = func.getName().(Solidity::AstNode).getValue()
}

/**
 * Represents an inline assembly block.
 */
class AssemblyBlock extends Solidity::AssemblyStatement {
  /** Gets the enclosing function. */
  Solidity::FunctionDefinition getEnclosingFunction() { this.getParent+() = result }

  /** Gets the enclosing contract. */
  Solidity::ContractDeclaration getEnclosingContract() { this.getParent+() = result }
}

/**
 * Dangerous operations in assembly with risk levels.
 */
predicate dangerousOperation(string op, string risk) {
  op = "delegatecall" and risk = "critical"
  or
  op = "selfdestruct" and risk = "critical"
  or
  op = "call" and risk = "high"
  or
  op = "create" and risk = "high"
  or
  op = "create2" and risk = "high"
  or
  op = "sstore" and risk = "high"
  or
  op = "staticcall" and risk = "medium"
  or
  op = "sload" and risk = "medium"
  or
  op = "extcodecopy" and risk = "medium"
  or
  op = "codecopy" and risk = "medium"
  or
  op = "mstore" and risk = "low"
  or
  op = "mload" and risk = "low"
  or
  op = "mstore8" and risk = "low"
  or
  op = "returndatacopy" and risk = "low"
  or
  op = "extcodesize" and risk = "low"
}

/**
 * Holds if the assembly block contains a specific operation.
 */
predicate assemblyContainsOp(AssemblyBlock asm, string op) {
  exists(Solidity::AstNode child |
    child.getParent+() = asm and
    (
      child.getValue().toLowerCase() = op
      or
      child.toString().toLowerCase() = op
    )
  )
}

/**
 * Gets the highest risk level from a set of operations.
 */
bindingset[ops]
string getHighestRisk(string ops) {
  (ops.matches("%delegatecall%") or ops.matches("%selfdestruct%")) and result = "critical"
  or
  not (ops.matches("%delegatecall%") or ops.matches("%selfdestruct%")) and
  (
    ops.matches("%call%") or ops.matches("%create%") or ops.matches("%sstore%")
  ) and
  result = "high"
  or
  not (ops.matches("%delegatecall%") or ops.matches("%selfdestruct%")) and
  not (ops.matches("%call%") or ops.matches("%create%") or ops.matches("%sstore%")) and
  (
    ops.matches("%staticcall%") or ops.matches("%sload%") or ops.matches("%extcode%") or
    ops.matches("%codecopy%")
  ) and
  result = "medium"
  or
  not (ops.matches("%delegatecall%") or ops.matches("%selfdestruct%")) and
  not (ops.matches("%call%") or ops.matches("%create%") or ops.matches("%sstore%")) and
  not (
    ops.matches("%staticcall%") or ops.matches("%sload%") or ops.matches("%extcode%") or
    ops.matches("%codecopy%")
  ) and
  result = "low"
}

/** One row per inline assembly block, with its risk-ranked operation set. */
query predicate assemblyBlocks(
  string contract, string function, string operations, string risk, AssemblyBlock node
) {
  contract = getContractName(node.getEnclosingContract()) and
  function = getFunctionName(node.getEnclosingFunction()) and
  operations =
    concat(string op | dangerousOperation(op, _) and assemblyContainsOp(node, op) | op, ",") and
  (
    operations != "" and risk = getHighestRisk(operations)
    or
    operations = "" and risk = "low"
  )
}

/**
 * One row per (assembly block, dangerous operation) pair. Filter on `op` for the
 * storage / call / create / selfdestruct subsets.
 */
query predicate assemblyOperations(
  string contract, string function, string op, string risk, AssemblyBlock node
) {
  contract = getContractName(node.getEnclosingContract()) and
  function = getFunctionName(node.getEnclosingFunction()) and
  dangerousOperation(op, risk) and
  assemblyContainsOp(node, op)
}
