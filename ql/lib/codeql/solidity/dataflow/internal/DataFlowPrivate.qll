/**
 * Provides the private implementation of data flow.
 *
 * This module implements the actual flow step predicates that track
 * how data moves through a Solidity program.
 */

private import codeql.solidity.ast.internal.TreeSitter
private import codeql.solidity.controlflow.ControlFlowGraph
private import codeql.solidity.controlflow.BasicBlocks
private import DataFlowNodes
private import SsaImpl

/**
 * Holds if data flows from `nodeFrom` to `nodeTo` in a single local step.
 *
 * Local flow includes:
 * - Assignment right-hand side to left-hand side
 * - Variable definition to use (via SSA)
 * - Expression to enclosing expression
 * - Array/member access propagation
 */
predicate localFlowStep(Node nodeFrom, Node nodeTo) {
  assignmentFlowStep(nodeFrom, nodeTo) or
  ssaFlowStep(nodeFrom, nodeTo) or
  expressionFlowStep(nodeFrom, nodeTo) or
  returnFlowStep(nodeFrom, nodeTo) or
  storageAliasFlowStep(nodeFrom, nodeTo) or
  stateVariableFlowStep(nodeFrom, nodeTo) or
  argumentFlowStep(nodeFrom, nodeTo) or
  callResultFlowStep(nodeFrom, nodeTo)
}

/**
 * Holds if data flows from the right-hand side of an assignment to the left-hand side.
 */
private predicate assignmentFlowStep(Node nodeFrom, Node nodeTo) {
  // Simple assignment: x = expr
  exists(Solidity::AssignmentExpression assign |
    nodeFrom.asExpr() = assign.getRight() and
    nodeTo = TPostUpdateNode(assign.getLeft())
  )
  or
  // Augmented assignment: x += expr, x -= expr, etc.
  exists(Solidity::AugmentedAssignmentExpression aug |
    nodeFrom.asExpr() = aug.getRight() and
    nodeTo = TPostUpdateNode(aug.getLeft())
  )
  or
  // Variable declaration with initializer
  exists(Solidity::VariableDeclarationStatement decl |
    nodeFrom.asExpr() = decl.getFieldValue() and
    nodeTo = TSsaDefinitionNode(TDeclarationDef(_, decl))
  )
}

/**
 * Holds if data flows through SSA (from definition to use).
 */
private predicate ssaFlowStep(Node nodeFrom, Node nodeTo) {
  // SSA definition to SSA use
  exists(SsaDefinition def, SsaUse use |
    def.getAUse() = use and
    nodeFrom = TSsaDefinitionNode(def) and
    nodeTo = TExprNode(use)
  )
  or
  // Phi node inputs flow to phi node
  exists(SsaPhiNode phi, SsaDefinition input |
    input = phi.getAPhiInput() and
    nodeFrom = TSsaDefinitionNode(input) and
    nodeTo = TSsaDefinitionNode(phi)
  )
  or
  // Assignment to SSA definition
  exists(Solidity::AssignmentExpression assign, SsaDefinition def |
    def = TAssignmentDef(_, assign) and
    nodeFrom.asExpr() = assign.getRight() and
    nodeTo = TSsaDefinitionNode(def)
  )
}

/**
 * Holds if data flows between expressions (sub-expression to parent).
 */
private predicate expressionFlowStep(Node nodeFrom, Node nodeTo) {
  // Parenthesized expression: (expr) -> outer
  exists(Solidity::ParenthesizedExpression paren |
    nodeFrom.asExpr() = paren.getAFieldOrChild() and
    nodeTo.asExpr() = paren
  )
  or
  // Tuple expression element flow
  exists(Solidity::TupleExpression tuple, int i |
    nodeFrom.asExpr() = tuple.getChild(i) and
    nodeTo.asExpr() = tuple
  )
  or
  // Conditional expression: cond ? then : else
  // Flow from branches to the conditional
  exists(Solidity::TernaryExpression ternary |
    (
      nodeFrom.asExpr() = ternary.getChild(1) or // then branch
      nodeFrom.asExpr() = ternary.getChild(2) // else branch
    ) and
    nodeTo.asExpr() = ternary
  )
  or
  // Array access: array[index] - value flows from array to access result
  exists(Solidity::ArrayAccess access |
    nodeFrom.asExpr() = access.getBase() and // base array
    nodeTo.asExpr() = access
  )
  or
  // Member access: obj.field - value flows from object to access
  exists(Solidity::MemberExpression member |
    nodeFrom.asExpr() = member.getObject() and
    nodeTo.asExpr() = member
  )
  or
  // Type cast: Type(expr) - flow through cast
  exists(Solidity::CallExpression cast |
    isCastExpression(cast) and
    nodeFrom.asExpr() = cast.getChild(0) and
    nodeTo.asExpr() = cast
  )
  or
  // Unary expression with value preservation
  exists(Solidity::UnaryExpression unary |
    // Only for unary operations that preserve the value's taint
    not unary.getOperator().getValue().trim() = "!" and // logical not changes boolean, doesn't propagate taint
    nodeFrom.asExpr() = unary.getArgument() and
    nodeTo.asExpr() = unary
  )
  or
  // Binary expression - operands flow to result for taint purposes
  // Only arithmetic and bitwise operations propagate taint, NOT comparisons or logical ops
  exists(Solidity::BinaryExpression binary |
    (
      nodeFrom.asExpr() = binary.getLeft() or
      nodeFrom.asExpr() = binary.getRight()
    ) and
    nodeTo.asExpr() = binary and
    // Only propagate for value-preserving operations
    isTaintPropagatingOperator(binary.getOperator().toString())
  )
}

/**
 * Holds if the operator is a comparison operator (produces boolean, no taint).
 */
private predicate isComparisonOperator(string op) {
  op = "==" or
  op = "!=" or
  op = "<" or
  op = ">" or
  op = "<=" or
  op = ">="
}

/**
 * Holds if the operator is a logical operator (produces boolean, no taint).
 */
private predicate isLogicalOperator(string op) { op = "&&" or op = "||" }

/**
 * Holds if the operator propagates taint from operands to result.
 * Arithmetic and bitwise operators propagate taint.
 * Comparison and logical operators produce booleans and do NOT propagate taint.
 */
private predicate isTaintPropagatingOperator(string op) {
  // Arithmetic operators
  op in ["+", "-", "*", "/", "%", "**"]
  or
  // Bitwise operators
  op in ["&", "|", "^", "~", "<<", ">>"]
  or
  // String concatenation (Solidity 0.8.12+)
  op = "++"
}

/**
 * Holds if `call` is a type cast expression (e.g., uint256(x)).
 */
private predicate isCastExpression(Solidity::CallExpression call) {
  exists(Solidity::AstNode func |
    func = call.getFunction() and
    (
      func instanceof Solidity::PrimitiveType
      or
      // Contract/struct casts
      func instanceof Solidity::Identifier
    )
  )
}

/**
 * Holds if data flows through a return statement.
 */
private predicate returnFlowStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::ReturnStatement ret |
    nodeFrom.asExpr() = ret.getAFieldOrChild() and
    nodeTo = TReturnNode(ret)
  )
}

/**
 * Holds if data flows from `nodeFrom` to `nodeTo` in a single "jump" step.
 *
 * Jump steps represent inter-procedural flow:
 * - Argument to parameter
 * - Return value to call result
 */
predicate jumpStep(Node nodeFrom, Node nodeTo) {
  argumentToParameterFlow(nodeFrom, nodeTo) or
  returnToCallResultFlow(nodeFrom, nodeTo)
}

/**
 * Holds if data flows from a call argument to the corresponding parameter.
 */
private predicate argumentToParameterFlow(Node nodeFrom, Node nodeTo) {
  exists(
    Solidity::CallExpression call, Solidity::FunctionDefinition func, int i,
    Solidity::Parameter param
  |
    resolveCall(call, func) and
    nodeFrom = TArgumentNode(call, i) and
    // Parameters are children of the function definition
    param = func.getChild(i) and
    param instanceof Solidity::Parameter and
    nodeTo = TParameterNode(param)
  )
}

/**
 * Holds if data flows from a return statement to the call result.
 */
private predicate returnToCallResultFlow(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call, Solidity::FunctionDefinition func |
    resolveCall(call, func) and
    exists(Solidity::ReturnStatement ret |
      ret.getParent+() = func and
      nodeFrom = TReturnNode(ret) and
      nodeTo = TCallResultNode(call)
    )
  )
}

/**
 * Resolves a call expression to its target function definition.
 */
private predicate resolveCall(Solidity::CallExpression call, Solidity::FunctionDefinition func) {
  // Direct function call by name
  exists(Solidity::Identifier id |
    id = call.getFunction() and
    id.toString() = func.getName().(Solidity::AstNode).toString() and
    // Must be in same contract (simplified)
    call.getParent+().(Solidity::ContractDeclaration) = func.getParent()
  )
  or
  // Member call: contract.method()
  exists(Solidity::MemberExpression member |
    member = call.getFunction() and
    member.getProperty().(Solidity::AstNode).getValue() =
      func.getName().(Solidity::AstNode).toString()
  )
}

/**
 * Holds if `nodeFrom` flows to `nodeTo` via an argument passing.
 */
predicate argumentFlowStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call, int i |
    nodeFrom.asExpr() = call.getChild(i) and
    nodeTo = TArgumentNode(call, i)
  )
}

/**
 * Holds if `nodeFrom` flows to `nodeTo` via call result retrieval.
 */
predicate callResultFlowStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call |
    nodeFrom = TCallResultNode(call) and
    nodeTo.asExpr() = call
  )
}

/**
 * Additional taint steps specific to Solidity.
 *
 * These represent taint propagation that goes beyond simple value flow.
 */
predicate additionalTaintStep(Node nodeFrom, Node nodeTo) {
  // String concatenation (abi.encodePacked, string.concat)
  stringConcatTaintStep(nodeFrom, nodeTo)
  or
  // Array operations
  arrayTaintStep(nodeFrom, nodeTo)
  or
  // ABI encoding/decoding
  abiEncodeTaintStep(nodeFrom, nodeTo)
  or
  // Keccak256 hashing (taint flows through hash)
  hashTaintStep(nodeFrom, nodeTo)
  or
  // Low-level call data
  lowLevelCallTaintStep(nodeFrom, nodeTo)
}

/**
 * Taint flows through string concatenation.
 */
private predicate stringConcatTaintStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call, Solidity::MemberExpression member |
    member = call.getFunction() and
    (
      // abi.encodePacked(...)
      member.getObject().(Solidity::Identifier).getValue() = "abi" and
      member.getProperty().(Solidity::AstNode).getValue() = "encodePacked"
      or
      // string.concat(...)
      member.getObject().(Solidity::Identifier).getValue() = "string" and
      member.getProperty().(Solidity::AstNode).getValue() = "concat"
      or
      // bytes.concat(...)
      member.getObject().(Solidity::Identifier).getValue() = "bytes" and
      member.getProperty().(Solidity::AstNode).getValue() = "concat"
    ) and
    nodeFrom.asExpr() = call.getChild(_) and
    nodeTo.asExpr() = call
  )
}

/**
 * Taint flows through array operations.
 */
private predicate arrayTaintStep(Node nodeFrom, Node nodeTo) {
  // Array push
  exists(Solidity::CallExpression call, Solidity::MemberExpression member |
    member = call.getFunction() and
    member.getProperty().(Solidity::AstNode).getValue() = "push" and
    nodeFrom.asExpr() = call.getChild(0) and
    nodeTo.asExpr() = member.getObject()
  )
}

/**
 * Taint flows through ABI encoding/decoding.
 */
private predicate abiEncodeTaintStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call, Solidity::MemberExpression member |
    member = call.getFunction() and
    member.getObject().(Solidity::Identifier).getValue() = "abi" and
    (
      member.getProperty().(Solidity::AstNode).getValue() = "encode" or
      member.getProperty().(Solidity::AstNode).getValue() = "encodePacked" or
      member.getProperty().(Solidity::AstNode).getValue() = "encodeWithSelector" or
      member.getProperty().(Solidity::AstNode).getValue() = "encodeWithSignature" or
      member.getProperty().(Solidity::AstNode).getValue() = "encodeCall"
    ) and
    nodeFrom.asExpr() = call.getChild(_) and
    nodeTo.asExpr() = call
  )
  or
  // abi.decode - return value is tainted if input is tainted
  exists(Solidity::CallExpression call, Solidity::MemberExpression member |
    member = call.getFunction() and
    member.getObject().(Solidity::Identifier).getValue() = "abi" and
    member.getProperty().(Solidity::AstNode).getValue() = "decode" and
    nodeFrom.asExpr() = call.getChild(0) and
    nodeTo.asExpr() = call
  )
}

/**
 * Taint flows through hashing functions.
 */
private predicate hashTaintStep(Node nodeFrom, Node nodeTo) {
  exists(Solidity::CallExpression call |
    (
      call.getFunction().(Solidity::Identifier).getValue() = "keccak256" or
      call.getFunction().(Solidity::Identifier).getValue() = "sha256" or
      call.getFunction().(Solidity::Identifier).getValue() = "ripemd160"
    ) and
    nodeFrom.asExpr() = call.getChild(0) and
    nodeTo.asExpr() = call
  )
}

/**
 * Taint flows through low-level calls.
 */
private predicate lowLevelCallTaintStep(Node nodeFrom, Node nodeTo) {
  // address.call(data) - data is tainted if input is tainted
  exists(Solidity::CallExpression call, Solidity::MemberExpression member |
    member = call.getFunction() and
    (
      member.getProperty().(Solidity::AstNode).getValue() = "call" or
      member.getProperty().(Solidity::AstNode).getValue() = "delegatecall" or
      member.getProperty().(Solidity::AstNode).getValue() = "staticcall"
    ) and
    nodeFrom.asExpr() = call.getChild(0) and
    nodeTo.asExpr() = call
  )
}

/**
 * State variable flow steps.
 */
predicate stateVariableFlowStep(Node nodeFrom, Node nodeTo) {
  // Write to state variable
  exists(Solidity::AssignmentExpression assign, Solidity::StateVariableDeclaration decl |
    nodeFrom.asExpr() = assign.getRight() and
    nodeTo = TStateVarWriteNode(assign, decl)
  )
  or
  // Read from state variable flows to expression
  exists(Solidity::Identifier id, Solidity::StateVariableDeclaration decl |
    nodeFrom = TStateVarReadNode(id, decl) and
    nodeTo.asExpr() = id
  )
}

/**
 * Storage array/mapping aliasing.
 *
 * In Solidity, storage arrays and mappings can have aliasing issues:
 * - arr[i] = taint; ... x = arr[j]; // arr[j] may be tainted if i could equal j
 * - mapping[key1] = taint; ... x = mapping[key2]; // may alias if keys overlap
 *
 * We conservatively assume all elements of the same container may alias.
 */
predicate storageAliasFlowStep(Node nodeFrom, Node nodeTo) {
  // Array element write to array element read (conservative: any index may alias)
  // Storage is global — cross-function aliasing within same contract is valid
  exists(
    Solidity::AssignmentExpression writeAssign, Solidity::ArrayAccess writeAccess,
    Solidity::ArrayAccess readAccess
  |
    writeAssign.getLeft() = writeAccess and
    nodeFrom.asExpr() = writeAssign.getRight() and
    nodeTo.asExpr() = readAccess and
    // Same base array (by name) within same contract
    getArrayBaseName(writeAccess) = getArrayBaseName(readAccess) and
    writeAssign.getParent+().(Solidity::ContractDeclaration) =
      readAccess.getParent+().(Solidity::ContractDeclaration)
  )
  or
  // Mapping element write to mapping element read
  exists(
    Solidity::AssignmentExpression writeAssign, Solidity::ArrayAccess writeAccess,
    Solidity::ArrayAccess readAccess
  |
    writeAssign.getLeft() = writeAccess and
    nodeFrom.asExpr() = writeAssign.getRight() and
    nodeTo.asExpr() = readAccess and
    // Same mapping (by name) within same contract
    getMappingBaseName(writeAccess) = getMappingBaseName(readAccess) and
    getMappingBaseName(writeAccess) != "" and
    writeAssign.getParent+().(Solidity::ContractDeclaration) =
      readAccess.getParent+().(Solidity::ContractDeclaration)
  )
}

/**
 * Gets the base name of an array access (e.g., "arr" from "arr[i]").
 */
private string getArrayBaseName(Solidity::ArrayAccess access) {
  result = access.getBase().(Solidity::Identifier).getValue()
  or
  // Nested access: arr[i][j] -> "arr"
  result = getArrayBaseName(access.getBase())
}

/**
 * Gets the base name of a mapping access.
 * Mappings use array access syntax: mapping[key]
 */
private string getMappingBaseName(Solidity::ArrayAccess access) {
  exists(Solidity::Identifier base |
    base = access.getBase() and
    result = base.getValue() and
    // Heuristic: if used with non-integer index, likely a mapping
    not access.getIndex() instanceof Solidity::NumberLiteral
  )
  or
  // Nested mapping: mapping[k1][k2]
  result = getMappingBaseName(access.getBase())
}

/**
 * Holds if there is potential aliasing between two storage accesses.
 * This is a may-alias analysis - conservative approximation.
 */
predicate mayAliasStorageAccess(Solidity::ArrayAccess access1, Solidity::ArrayAccess access2) {
  access1 != access2 and
  (
    // Same array/mapping base name
    getArrayBaseName(access1) = getArrayBaseName(access2)
    or
    getMappingBaseName(access1) = getMappingBaseName(access2)
  )
}

/**
 * Gets the enclosing callable (function/constructor/modifier) of a node.
 */
Solidity::AstNode getEnclosingCallable(Node n) { result = n.getEnclosingCallable() }

/**
 * Holds if `n` is an expression node.
 */
predicate isExprNode(Node n) { n instanceof ExprNode }

/**
 * Holds if `n` is a parameter node.
 */
predicate isParameterNode(Node n) { n instanceof ParameterNode }

/**
 * Holds if `n` represents a value at the entry of a function.
 */
predicate isEntryNode(Node n) { n instanceof ParameterNode }

/**
 * Holds if `n` is an argument node.
 */
predicate isArgumentNode(Node n) { n instanceof ArgumentNode }

/**
 * Holds if `n` is a return node.
 */
predicate isReturnNode(Node n) { n instanceof ReturnValueNode }
