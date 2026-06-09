/**
 * @name Data flow analysis
 * @description Data flow: taint sources, sinks, and propagation.
 * @id solidity/data-flow-analysis
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.ExternalCalls

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

/** The transaction-environment reads treated as taint sources. */
predicate environmentSource(string object, string property) {
  object = "msg" and property in ["sender", "value", "data"]
  or
  object = "block" and property = "timestamp"
  or
  object = "tx" and property = "origin"
}

/** Reads of `msg.*`, `block.timestamp` and `tx.origin`. */
query predicate environmentSources(
  string contract, string function, string source, Solidity::MemberExpression node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, string obj, string prop |
    node.getParent+() = f and
    f.getParent+() = c and
    obj = node.getObject().(Solidity::Identifier).getValue() and
    prop = node.getProperty().(Solidity::AstNode).getValue() and
    environmentSource(obj, prop) and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    source = obj + "." + prop
  )
}

/** Parameters of externally callable functions. */
query predicate parameterSources(
  string contract, string function, string param, string type, Solidity::Parameter node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    param = node.getName().(Solidity::AstNode).getValue() and
    type = node.getType().(Solidity::AstNode).toString() and
    exists(Solidity::AstNode vis |
      vis.getParent() = f and
      vis.toString() = "Visibility" and
      vis.getAChild().getValue() in ["external", "public"]
    )
  )
}

/** Calls that hand control or value to another address. */
query predicate taintSinks(
  string contract, string function, string sink, Solidity::CallExpression node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    (
      ExternalCalls::isDelegateCall(node) and sink = "delegatecall"
      or
      ExternalCalls::isCall(node) and sink = "call"
      or
      ExternalCalls::isStaticCall(node) and sink = "staticcall"
      or
      ExternalCalls::isContractReferenceCall(node) and
      not ExternalCalls::isLowLevelCall(node) and
      sink = "high_level_call"
      or
      ExternalCalls::isEtherTransfer(node) and sink = "ether_transfer"
    )
  )
}

/** Reads of a state variable inside a function body. */
query predicate stateReads(
  string contract, string function, string variable, Solidity::Identifier node
) {
  exists(
    Solidity::FunctionDefinition f, Solidity::ContractDeclaration c,
    Solidity::StateVariableDeclaration sv
  |
    node.getParent+() = f.getBody() and
    f.getParent+() = c and
    sv.getParent+() = c and
    sv.getName().(Solidity::AstNode).getValue() = node.getValue() and
    not exists(Solidity::AssignmentExpression assign | node.getParent+() = assign.getLeft()) and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    variable = node.getValue()
  )
}

/** Writes to a state variable — also the sink for storage taint. */
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

/** `return` statements. */
query predicate returnStatements(
  string contract, string function, Solidity::ReturnStatement node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f)
  )
}

/** `require` / `assert` / `revert` validation points. */
query predicate validations(
  string contract, string function, string kind, Solidity::CallExpression node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    kind = node.getFunction().(Solidity::Identifier).getValue() and
    kind in ["require", "assert", "revert"]
  )
}

/** `if` statements, flagged when the condition reads a taint source. */
query predicate conditionals(
  string contract, string function, string guardSource, Solidity::IfStatement node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c |
    node.getParent+() = f and
    f.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    (
      exists(Solidity::MemberExpression m, string obj, string prop |
        m.getParent+() = node.getCondition() and
        obj = m.getObject().(Solidity::Identifier).getValue() and
        prop = m.getProperty().(Solidity::AstNode).getValue() and
        environmentSource(obj, prop) and
        guardSource = obj + "." + prop
      )
      or
      not exists(Solidity::MemberExpression m, string obj, string prop |
        m.getParent+() = node.getCondition() and
        obj = m.getObject().(Solidity::Identifier).getValue() and
        prop = m.getProperty().(Solidity::AstNode).getValue() and
        environmentSource(obj, prop)
      ) and
      guardSource = "none"
    )
  )
}
