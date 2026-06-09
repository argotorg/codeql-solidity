/**
 * Provides classes and predicates for data flow analysis.
 *
 * Data flow analysis tracks how values move through a program.
 * This is the public API for data flow in Solidity.
 */

/** Provides classes for data flow analysis. */
module DataFlow {
  private import codeql.solidity.ast.internal.TreeSitter
  private import codeql.solidity.dataflow.internal.DataFlowNodes as DataFlowNodesImpl
  private import codeql.solidity.dataflow.internal.DataFlowPrivate

  /**
   * A node in the data flow graph.
   */
  class Node extends DataFlowNodesImpl::Node {
    /**
     * Gets the expression associated with this node, if any.
     */
    override Solidity::AstNode asExpr() { result = super.asExpr() }

    /**
     * Gets the parameter associated with this node, if any.
     */
    override Solidity::Parameter asParameter() { result = super.asParameter() }

    /**
     * Holds if this node represents a value from `msg.sender`.
     */
    predicate isMsgSender() {
      exists(Solidity::MemberExpression member |
        this.asExpr() = member and
        member.getObject().(Solidity::Identifier).getValue() = "msg" and
        member.getProperty().(Solidity::AstNode).getValue() = "sender"
      )
    }

    /**
     * Holds if this node represents a value from `msg.value`.
     */
    predicate isMsgValue() {
      exists(Solidity::MemberExpression member |
        this.asExpr() = member and
        member.getObject().(Solidity::Identifier).getValue() = "msg" and
        member.getProperty().(Solidity::AstNode).getValue() = "value"
      )
    }

    /**
     * Holds if this node represents a value from `msg.data`.
     */
    predicate isMsgData() {
      exists(Solidity::MemberExpression member |
        this.asExpr() = member and
        member.getObject().(Solidity::Identifier).getValue() = "msg" and
        member.getProperty().(Solidity::AstNode).getValue() = "data"
      )
    }

    /**
     * Holds if this node represents a value from `tx.origin`.
     */
    predicate isTxOrigin() {
      exists(Solidity::MemberExpression member |
        this.asExpr() = member and
        member.getObject().(Solidity::Identifier).getValue() = "tx" and
        member.getProperty().(Solidity::AstNode).getValue() = "origin"
      )
    }

    /**
     * Holds if this node represents a value from `block.timestamp`.
     */
    predicate isBlockTimestamp() {
      exists(Solidity::MemberExpression member |
        this.asExpr() = member and
        member.getObject().(Solidity::Identifier).getValue() = "block" and
        member.getProperty().(Solidity::AstNode).getValue() = "timestamp"
      )
    }

    /**
     * Holds if this node is a source of user-controllable data.
     */
    predicate isSource() {
      this.isMsgSender() or
      this.isMsgValue() or
      this.isMsgData() or
      this.isTxOrigin() or
      this.isBlockTimestamp() or
      this.isExternalCallResult() or
      this.isParameter()
    }

    /**
     * Holds if this node represents the result of an external call.
     */
    predicate isExternalCallResult() {
      exists(Solidity::CallExpression call |
        this = DataFlowNodesImpl::TCallResultNode(call) and
        isExternalCall(call)
      )
    }

    /**
     * Holds if this node is a parameter.
     */
    predicate isParameter() { this instanceof ParameterNode }
  }

  /**
   * Holds if `call` is an external call.
   */
  private predicate isExternalCall(Solidity::CallExpression call) {
    exists(Solidity::MemberExpression member |
      member = call.getFunction() and
      (
        member.getProperty().(Solidity::AstNode).getValue() = "call" or
        member.getProperty().(Solidity::AstNode).getValue() = "delegatecall" or
        member.getProperty().(Solidity::AstNode).getValue() = "staticcall" or
        member.getProperty().(Solidity::AstNode).getValue() = "transfer" or
        member.getProperty().(Solidity::AstNode).getValue() = "send"
      )
    )
    or
    // Interface/contract method calls
    exists(Solidity::MemberExpression member |
      member = call.getFunction() and
      not member.getObject().(Solidity::Identifier).getValue() = "this" and
      not member.getObject().(Solidity::Identifier).getValue() = "super" and
      not member.getObject().(Solidity::Identifier).getValue() = "abi" and
      not member.getObject().(Solidity::Identifier).getValue() = "msg" and
      not member.getObject().(Solidity::Identifier).getValue() = "block" and
      not member.getObject().(Solidity::Identifier).getValue() = "tx"
    )
  }

  /**
   * An expression node in the data flow graph.
   */
  class ExprNode extends Node instanceof DataFlowNodesImpl::ExprNode {
    /** Gets the expression. */
    Solidity::AstNode getExpr() { result = DataFlowNodesImpl::ExprNode.super.getExpr() }
  }

  /**
   * A parameter node in the data flow graph.
   */
  class ParameterNode extends Node instanceof DataFlowNodesImpl::ParameterNode {
    /** Gets the parameter. */
    Solidity::Parameter getParameter() {
      result = DataFlowNodesImpl::ParameterNode.super.getParameter()
    }

    /** Gets the position of this parameter (0-indexed). */
    int getPosition() { result = DataFlowNodesImpl::ParameterNode.super.getPosition() }
  }

  /**
   * An argument node in a call.
   */
  class ArgumentNode extends Node instanceof DataFlowNodesImpl::ArgumentNode {
    /** Gets the call expression. */
    Solidity::CallExpression getCall() { result = DataFlowNodesImpl::ArgumentNode.super.getCall() }

    /** Gets the argument index. */
    int getIndex() { result = DataFlowNodesImpl::ArgumentNode.super.getIndex() }
  }

  /**
   * A return value node.
   */
  class ReturnNode extends Node instanceof DataFlowNodesImpl::ReturnValueNode {
    /** Gets the return statement. */
    Solidity::ReturnStatement getReturnStatement() {
      result = DataFlowNodesImpl::ReturnValueNode.super.getReturnStatement()
    }
  }

  /**
   * A call result node (value returned from a call).
   */
  class CallResultNode extends Node instanceof DataFlowNodesImpl::CallResultNode {
    /** Gets the call expression. */
    Solidity::CallExpression getCall() {
      result = DataFlowNodesImpl::CallResultNode.super.getCall()
    }
  }

  /**
   * A post-update node representing the value after modification.
   */
  class PostUpdateNode extends Node instanceof DataFlowNodesImpl::PostUpdateNode {
    /** Gets the pre-update node. */
    Node getPreUpdateNode() { result = DataFlowNodesImpl::PostUpdateNode.super.getPreUpdateNode() }
  }

  /**
   * Holds if data flows from `source` to `sink` in zero or more local steps.
   */
  predicate localFlow(Node source, Node sink) {
    source = sink
    or
    exists(Node mid |
      localFlow(source, mid) and
      localFlowStep(mid, sink)
    )
  }

  /**
   * Holds if data flows from `source` to `sink` in zero or more steps
   * including inter-procedural flow.
   */
  predicate flow(Node source, Node sink) {
    localFlow(source, sink)
    or
    exists(Node mid |
      flow(source, mid) and
      jumpStep(mid, sink)
    )
    or
    exists(Node mid |
      flow(source, mid) and
      localFlow(mid, sink)
    )
  }

  /**
   * Gets a node from an expression (AST node).
   */
  Node exprNode(Solidity::AstNode e) { result = DataFlowNodesImpl::TExprNode(e) }

  /**
   * Gets a node from a parameter.
   */
  Node parameterNode(Solidity::Parameter p) { result = DataFlowNodesImpl::TParameterNode(p) }
}
