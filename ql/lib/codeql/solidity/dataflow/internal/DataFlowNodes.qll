/**
 * Provides classes representing nodes in the data flow graph.
 *
 * Data flow nodes represent values that can flow through the program.
 * Unlike CFG nodes which represent execution points, data flow nodes
 * represent the values computed at those points.
 */

private import codeql.solidity.ast.internal.TreeSitter
private import codeql.solidity.controlflow.ControlFlowGraph
private import SsaImpl

/**
 * A node in the data flow graph.
 */
newtype TNode =
  /** An expression node. */
  TExprNode(Solidity::AstNode expr) {
    // Include all expression-like AST nodes
    expr instanceof Solidity::BinaryExpression or
    expr instanceof Solidity::UnaryExpression or
    expr instanceof Solidity::CallExpression or
    expr instanceof Solidity::MemberExpression or
    expr instanceof Solidity::Identifier or
    expr instanceof Solidity::NumberLiteral or
    expr instanceof Solidity::StringLiteral or
    expr instanceof Solidity::BooleanLiteral or
    expr instanceof Solidity::AssignmentExpression or
    expr instanceof Solidity::TernaryExpression or
    expr instanceof Solidity::ArrayAccess or
    expr instanceof Solidity::TupleExpression or
    expr instanceof Solidity::NewExpression or
    expr instanceof Solidity::TypeCastExpression or
    expr instanceof Solidity::PayableConversionExpression or
    expr instanceof Solidity::ParenthesizedExpression
  } or
  /** A parameter node (at function entry). */
  TParameterNode(Solidity::Parameter param) or
  /** An SSA definition node. */
  TSsaDefinitionNode(SsaDefinition def) or
  /** A return value node. */
  TReturnNode(Solidity::ReturnStatement ret) or
  /** A call result node (value returned from a call). */
  TCallResultNode(Solidity::CallExpression call) or
  /** An argument node in a call. */
  TArgumentNode(Solidity::CallExpression call, int i) { exists(call.getChild(i)) } or
  /** A post-update node (value after modification). */
  TPostUpdateNode(Solidity::AstNode expr) {
    // For expressions that are modified (e.g., left side of assignment)
    exists(Solidity::AssignmentExpression assign | assign.getLeft() = expr)
    or
    exists(Solidity::AugmentedAssignmentExpression aug | aug.getLeft() = expr)
  } or
  /** A state variable read node. */
  TStateVarReadNode(Solidity::Identifier id, Solidity::StateVariableDeclaration decl) {
    id.toString() = decl.getName().(Solidity::AstNode).toString()
  } or
  /** A state variable write node. */
  TStateVarWriteNode(Solidity::AssignmentExpression assign, Solidity::StateVariableDeclaration decl) {
    exists(Solidity::Identifier id |
      id = assign.getLeft() and
      id.toString() = decl.getName().(Solidity::AstNode).toString()
    )
  }

/**
 * A node in the data flow graph.
 */
class Node extends TNode {
  /** Gets the expression associated with this node, if any. */
  Solidity::AstNode asExpr() { this = TExprNode(result) }

  /** Gets the parameter associated with this node, if any. */
  Solidity::Parameter asParameter() { this = TParameterNode(result) }

  /** Gets the SSA definition associated with this node, if any. */
  SsaDefinition asSsaDefinition() { this = TSsaDefinitionNode(result) }

  /** Gets the enclosing callable (function/constructor/modifier). */
  Solidity::AstNode getEnclosingCallable() {
    exists(Solidity::AstNode e |
      this = TExprNode(e) and
      result = getEnclosingFunction(e)
    )
    or
    exists(Solidity::Parameter p |
      this = TParameterNode(p) and
      result = p.getParent().getParent()
    )
  }

  /** Gets the type of this node, if known. */
  string getType() {
    // For now, return a placeholder
    result = "unknown"
  }

  /** Gets the location of this node. */
  Location getLocation() {
    result = this.asExpr().getLocation()
    or
    result = this.asParameter().getLocation()
    or
    result = this.asSsaDefinition().getLocation()
    or
    exists(Solidity::ReturnStatement ret |
      this = TReturnNode(ret) and
      result = ret.getLocation()
    )
    or
    exists(Solidity::CallExpression call |
      this = TCallResultNode(call) and
      result = call.getLocation()
    )
    or
    exists(Solidity::CallExpression call, int i |
      this = TArgumentNode(call, i) and
      result = call.getChild(i).getLocation()
    )
  }

  /** Gets a textual representation of this node. */
  string toString() {
    result = this.asExpr().toString()
    or
    result = "param " + this.asParameter().toString()
    or
    result = this.asSsaDefinition().toString()
    or
    exists(Solidity::ReturnStatement ret |
      this = TReturnNode(ret) and
      result = "return"
    )
    or
    exists(Solidity::CallExpression call |
      this = TCallResultNode(call) and
      result = "call result: " + call.toString()
    )
    or
    exists(Solidity::CallExpression call, int i |
      this = TArgumentNode(call, i) and
      result = "arg " + i.toString() + " of " + call.toString()
    )
    or
    exists(Solidity::Expression expr |
      this = TPostUpdateNode(expr) and
      result = "post-update: " + expr.toString()
    )
    or
    exists(Solidity::Identifier id |
      this = TStateVarReadNode(id, _) and
      result = "state read: " + id.toString()
    )
    or
    exists(Solidity::AssignmentExpression assign |
      this = TStateVarWriteNode(assign, _) and
      result = "state write: " + assign.getLeft().toString()
    )
  }
}

/**
 * Gets the enclosing function of an AST node.
 */
private Solidity::AstNode getEnclosingFunction(Solidity::AstNode node) {
  result = node.getParent() and
  (
    result instanceof Solidity::FunctionDefinition or
    result instanceof Solidity::ConstructorDefinition or
    result instanceof Solidity::ModifierDefinition or
    result instanceof Solidity::FallbackReceiveDefinition
  )
  or
  not (
    node.getParent() instanceof Solidity::FunctionDefinition or
    node.getParent() instanceof Solidity::ConstructorDefinition or
    node.getParent() instanceof Solidity::ModifierDefinition or
    node.getParent() instanceof Solidity::FallbackReceiveDefinition
  ) and
  result = getEnclosingFunction(node.getParent())
}

/**
 * An expression node in the data flow graph.
 */
class ExprNode extends Node {
  Solidity::AstNode expr;

  ExprNode() { this = TExprNode(expr) }

  /** Gets the expression. */
  Solidity::AstNode getExpr() { result = expr }
}

/**
 * A parameter node in the data flow graph.
 */
class ParameterNode extends Node {
  Solidity::Parameter param;

  ParameterNode() { this = TParameterNode(param) }

  /** Gets the parameter. */
  Solidity::Parameter getParameter() { result = param }

  /** Gets the position of this parameter (0-indexed). */
  int getPosition() {
    exists(Solidity::AstNode params |
      params = param.getParent() and
      param = params.getChild(result)
    )
  }

  /** Holds if this is a `memory` parameter. */
  predicate isMemory() {
    exists(Solidity::AstNode loc |
      loc = param.getStorageLocation() and
      loc.getValue().trim() = "memory"
    )
  }

  /** Holds if this is a `calldata` parameter. */
  predicate isCalldata() {
    exists(Solidity::AstNode loc |
      loc = param.getStorageLocation() and
      loc.getValue().trim() = "calldata"
    )
  }

  /** Holds if this is a `storage` parameter. */
  predicate isStorage() {
    exists(Solidity::AstNode loc |
      loc = param.getStorageLocation() and
      loc.getValue().trim() = "storage"
    )
  }
}

/**
 * An argument node in a call.
 */
class ArgumentNode extends Node {
  Solidity::CallExpression call;
  int index;

  ArgumentNode() { this = TArgumentNode(call, index) }

  /** Gets the call expression. */
  Solidity::CallExpression getCall() { result = call }

  /** Gets the argument index (0-indexed). */
  int getIndex() { result = index }

  /** Gets the argument expression. */
  Solidity::Expression getArgument() { result = call.getChild(index) }
}

/**
 * A return node in the data flow graph.
 */
class ReturnValueNode extends Node {
  Solidity::ReturnStatement ret;

  ReturnValueNode() { this = TReturnNode(ret) }

  /** Gets the return statement. */
  Solidity::ReturnStatement getReturnStatement() { result = ret }

  /** Gets the returned expression, if any. */
  Solidity::Expression getReturnedExpr() { result = ret.getAFieldOrChild() }
}

/**
 * A call result node (the value returned from a call).
 */
class CallResultNode extends Node {
  Solidity::CallExpression call;

  CallResultNode() { this = TCallResultNode(call) }

  /** Gets the call expression. */
  Solidity::CallExpression getCall() { result = call }
}

/**
 * A post-update node representing the value of an expression after modification.
 */
class PostUpdateNode extends Node {
  Solidity::AstNode expr;

  PostUpdateNode() { this = TPostUpdateNode(expr) }

  /** Gets the expression before update. */
  Solidity::AstNode getPreUpdateExpr() { result = expr }

  /** Gets the pre-update node. */
  Node getPreUpdateNode() { result = TExprNode(expr) }
}

/**
 * A state variable read node.
 */
class StateVarReadNode extends Node {
  Solidity::Identifier id;
  Solidity::StateVariableDeclaration decl;

  StateVarReadNode() { this = TStateVarReadNode(id, decl) }

  /** Gets the identifier being read. */
  Solidity::Identifier getIdentifier() { result = id }

  /** Gets the state variable declaration. */
  Solidity::StateVariableDeclaration getDeclaration() { result = decl }
}

/**
 * A state variable write node.
 */
class StateVarWriteNode extends Node {
  Solidity::AssignmentExpression assign;
  Solidity::StateVariableDeclaration decl;

  StateVarWriteNode() { this = TStateVarWriteNode(assign, decl) }

  /** Gets the assignment expression. */
  Solidity::AssignmentExpression getAssignment() { result = assign }

  /** Gets the state variable declaration. */
  Solidity::StateVariableDeclaration getDeclaration() { result = decl }

  /** Gets the value being written. */
  Solidity::Expression getValue() { result = assign.getRight() }
}
