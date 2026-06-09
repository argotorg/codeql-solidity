/**
 * @name Event pattern analysis
 * @description Event definitions, emissions, and state-changing functions that emit nothing.
 * @id solidity/event-patterns
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

/** One row per `event` declaration. */
query predicate eventDefinitions(
  string contract, string name, int paramCount, Solidity::EventDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    name = node.getName().(Solidity::AstNode).getValue() and
    paramCount = count(Solidity::EventParameter p | p.getParent() = node)
  )
}

/**
 * One row per `emit` statement.
 *
 * The grammar does not nest a `CallExpression` under `emit`: the event name
 * `Identifier` and the `CallArgument`s hang directly off the `EmitStatement`.
 */
query predicate eventEmissions(
  string contract, string function, string event, int argCount, Solidity::EmitStatement node
) {
  exists(Solidity::FunctionDefinition f, Solidity::ContractDeclaration c, Solidity::Identifier id |
    node.getParent+() = f and
    f.getParent+() = c and
    id.getParent() = node and
    contract = getContractName(c) and
    function = getFunctionName(f) and
    event = id.getValue() and
    argCount = count(Solidity::CallArgument a | a.getParent() = node)
  )
}

/** Externally reachable functions that write state but emit no event. */
query predicate silentStateWriters(
  string contract, string function, int stateWrites, Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    function = getFunctionName(node) and
    stateWrites =
      count(Solidity::AssignmentExpression assign |
        assign.getParent+() = node and
        exists(Solidity::Identifier id, Solidity::StateVariableDeclaration sv |
          id.getParent+() = assign.getLeft() and
          sv.getParent+() = c and
          sv.getName().(Solidity::AstNode).getValue() = id.getValue()
        )
      ) and
    stateWrites > 0 and
    not exists(Solidity::EmitStatement emit | emit.getParent+() = node) and
    exists(Solidity::AstNode vis |
      vis.getParent() = node and
      vis.toString() = "Visibility" and
      vis.getAChild().getValue() in ["external", "public"]
    )
  )
}
