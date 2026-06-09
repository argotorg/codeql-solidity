/**
 * @name Function list with metadata
 * @description Every function with visibility, modifiers, and state access counts.
 * @id solidity/function-list
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.callgraph.InheritanceGraph

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
 * Gets mutability (view, pure, payable) of a function.
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
 * Gets modifiers applied to a function as comma-separated string.
 *
 * `ModifierInvocation` is not a leaf token, so its name is the `Identifier`
 * child, not `getValue()`.
 */
string getFunctionModifiers(Solidity::FunctionDefinition func) {
  result =
    concat(Solidity::ModifierInvocation mod, Solidity::Identifier id |
      mod.getParent() = func and id.getParent() = mod
    |
      id.getValue(), ","
    )
  or
  not exists(Solidity::ModifierInvocation mod | mod.getParent() = func) and
  result = ""
}

/**
 * Holds if function is an entry point (external or public).
 */
predicate isEntryPoint(Solidity::FunctionDefinition func) {
  getFunctionVisibility(func) in ["external", "public"]
}

/**
 * Holds if function is a constructor.
 */
predicate isConstructor(Solidity::FunctionDefinition func) {
  getFunctionName(func) = "constructor"
  or
  exists(Solidity::AstNode node |
    node.getParent() = func and
    node.getValue() = "constructor"
  )
}

/**
 * Gets parameter count for a function.
 */
int getParameterCount(Solidity::FunctionDefinition func) {
  result = count(Solidity::Parameter p | p.getParent() = func)
}

/**
 * Counts state variable reads in a function.
 */
int getStateReads(Solidity::FunctionDefinition func) {
  result =
    count(Solidity::Identifier id |
      id.getParent+() = func.getBody() and
      exists(Solidity::StateVariableDeclaration sv, Solidity::ContractDeclaration contract |
        func.getParent+() = contract and
        sv.getParent+() = contract and
        sv.getName().(Solidity::AstNode).getValue() = id.getValue()
      )
    )
}

/**
 * Counts state variable writes (assignments) in a function.
 */
int getStateWrites(Solidity::FunctionDefinition func) {
  result =
    count(Solidity::AssignmentExpression assign |
      assign.getParent+() = func.getBody() and
      exists(
        Solidity::Identifier id, Solidity::StateVariableDeclaration sv,
        Solidity::ContractDeclaration contract
      |
        id.getParent+() = assign.getLeft() and
        func.getParent+() = contract and
        sv.getParent+() = contract and
        sv.getName().(Solidity::AstNode).getValue() = id.getValue()
      )
    )
}

/** Every function declared in a contract, with its state access profile. */
query predicate functions(
  string contract, string name, string visibility, string mutability, string modifiers, int params,
  int stateReads, int stateWrites, boolean isEntryPoint, boolean isConstructor,
  Solidity::FunctionDefinition node
) {
  exists(Solidity::ContractDeclaration c |
    node.getParent+() = c and
    contract = getContractName(c) and
    name = getFunctionName(node) and
    visibility = getFunctionVisibility(node) and
    mutability = getFunctionMutability(node) and
    modifiers = getFunctionModifiers(node) and
    params = getParameterCount(node) and
    stateReads = getStateReads(node) and
    stateWrites = getStateWrites(node) and
    (if isEntryPoint(node) then isEntryPoint = true else isEntryPoint = false) and
    (if isConstructor(node) then isConstructor = true else isConstructor = false)
  )
}

/** Every function declared in an interface. */
query predicate interfaceFunctions(
  string interface, string name, string visibility, string mutability,
  Solidity::FunctionDefinition node
) {
  exists(Solidity::InterfaceDeclaration i |
    node.getParent+() = i and
    interface = i.getName().(Solidity::AstNode).getValue() and
    name = getFunctionName(node) and
    visibility = getFunctionVisibility(node) and
    mutability = getFunctionMutability(node)
  )
}
