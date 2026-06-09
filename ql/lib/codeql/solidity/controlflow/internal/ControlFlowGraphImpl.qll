/**
 * Provides the core implementation of the Control Flow Graph for Solidity.
 *
 * This module computes successors for all control flow constructs:
 * - Sequential statements
 * - If/else branches
 * - For/while/do-while loops
 * - Try-catch blocks
 * - Return/break/continue/revert statements
 * - Function calls and expressions
 */

private import codeql.solidity.ast.internal.TreeSitter
private import Completion

/**
 * Holds if `id` is an identifier that names something rather than reading it, and
 * so never executes: a declaration's name, a member expression's property (`b` in
 * `a.b`), a type name, or the name in a modifier invocation or `emit`.
 *
 * Without this every such identifier was a `CfgNode` with no possible edges,
 * which made the graph look far less connected than it is.
 */
private predicate namesRatherThanReads(Solidity::Identifier id) {
  id.getParent() instanceof Solidity::Parameter or
  id.getParent() instanceof Solidity::VariableDeclaration or
  id.getParent() instanceof Solidity::FunctionDefinition or
  id.getParent() instanceof Solidity::ConstructorDefinition or
  id.getParent() instanceof Solidity::ModifierDefinition or
  id.getParent() instanceof Solidity::ModifierInvocation or
  id.getParent() instanceof Solidity::UserDefinedType or
  id.getParent() instanceof Solidity::EmitStatement or
  id = any(Solidity::MemberExpression m).getProperty() or
  id = any(Solidity::StructFieldAssignment f).getName()
}

/**
 * A node in the control flow graph.
 */
class CfgNode extends Solidity::AstNode {
  CfgNode() {
    // Every concrete expression kind. `Solidity::Expression` is NOT a supertype:
    // it is the generated class for the grammar's `expression` wrapper node, which
    // the extractor collapses, so it has zero instances. Naming it here meant no
    // expression was ever a CFG node, and every statement's `first` came back empty.
    this instanceof Solidity::ArrayAccess
    or
    this instanceof Solidity::AssignmentExpression
    or
    this instanceof Solidity::AugmentedAssignmentExpression
    or
    this instanceof Solidity::BinaryExpression
    or
    this instanceof Solidity::BooleanLiteral
    or
    this instanceof Solidity::CallExpression
    or
    this instanceof Solidity::False
    or
    this instanceof Solidity::HexStringLiteral
    or
    this instanceof Solidity::Identifier and not namesRatherThanReads(this)
    or
    this instanceof Solidity::InlineArrayExpression
    or
    this instanceof Solidity::MemberExpression
    or
    this instanceof Solidity::MetaTypeExpression
    or
    this instanceof Solidity::NewExpression
    or
    this instanceof Solidity::NumberLiteral
    or
    this instanceof Solidity::ParenthesizedExpression
    or
    this instanceof Solidity::PayableConversionExpression
    or
    this instanceof Solidity::StringLiteral
    or
    this instanceof Solidity::StructExpression
    or
    this instanceof Solidity::TernaryExpression
    or
    this instanceof Solidity::True
    or
    this instanceof Solidity::TupleExpression
    or
    this instanceof Solidity::TypeCastExpression
    or
    this instanceof Solidity::UnaryExpression
    or
    this instanceof Solidity::UpdateExpression
    or
    this instanceof Solidity::ExpressionStatement
    or
    this instanceof Solidity::IfStatement
    or
    this instanceof Solidity::ForStatement
    or
    this instanceof Solidity::WhileStatement
    or
    this instanceof Solidity::DoWhileStatement
    or
    this instanceof Solidity::BlockStatement
    or
    this instanceof Solidity::FunctionBody
    or
    this instanceof Solidity::ReturnStatement
    or
    this instanceof Solidity::BreakStatement
    or
    this instanceof Solidity::ContinueStatement
    or
    this instanceof Solidity::EmitStatement
    or
    this instanceof Solidity::RevertStatement
    or
    this instanceof Solidity::VariableDeclarationStatement
    or
    this instanceof Solidity::TryStatement
    or
    this instanceof Solidity::Unchecked
    or
    this instanceof Solidity::AssemblyStatement
    or
    // Function entry/exit points
    this instanceof Solidity::FunctionDefinition
    or
    this instanceof Solidity::ConstructorDefinition
    or
    this instanceof Solidity::ModifierDefinition
    or
    this instanceof Solidity::FallbackReceiveDefinition
    or
    // Yul/Assembly control flow nodes
    this instanceof Solidity::YulBlock
    or
    this instanceof Solidity::YulIfStatement
    or
    this instanceof Solidity::YulForStatement
    or
    this instanceof Solidity::YulSwitchStatement
    or
    this instanceof Solidity::YulBreak
    or
    this instanceof Solidity::YulContinue
    or
    this instanceof Solidity::YulLeave
    or
    this instanceof Solidity::YulAssignment
    or
    this instanceof Solidity::YulVariableDeclaration
    or
    this instanceof Solidity::YulFunctionCall
    or
    this instanceof Solidity::YulFunctionDefinition
    or
    this instanceof Solidity::YulIdentifier
    or
    this instanceof Solidity::YulBoolean
    or
    this instanceof Solidity::YulDecimalNumber
    or
    this instanceof Solidity::YulHexNumber
    or
    this instanceof Solidity::YulStringLiteral
    or
    this instanceof Solidity::YulHexStringLiteral
  }
}

/**
 * A node that is pure syntax on an evaluation path: it wraps the expression that
 * actually executes rather than executing itself (an argument-list entry, a
 * `revert` argument list, a Yul path). Flow passes straight through to its
 * semantic children, so these are deliberately not `CfgNode`s.
 *
 * Before the extractor populated the child relation these were invisible —
 * `call.getChild(0)` returned nothing, so the callee flowed directly to the call
 * and the graph happened to be connected. With real children they sit on the
 * path and have to be traversed.
 */
class TransparentNode extends Solidity::AstNode {
  TransparentNode() {
    this instanceof Solidity::CallArgument or
    this instanceof Solidity::RevertArguments or
    this instanceof Solidity::YulPath
  }
}

/**
 * A node whose semantic children are a sequence of statements: a `{ ... }` block,
 * or the `function_body` the grammar puts under a function or modifier
 * definition. Both sequence identically; only their node kind differs.
 */
class StatementSequence extends CfgNode {
  StatementSequence() {
    this instanceof Solidity::BlockStatement or
    this instanceof Solidity::FunctionBody
  }
}

/**
 * An entry node for a function-like construct.
 */
class EntryNode extends CfgNode {
  EntryNode() {
    this instanceof Solidity::FunctionDefinition or
    this instanceof Solidity::ConstructorDefinition or
    this instanceof Solidity::ModifierDefinition or
    this instanceof Solidity::FallbackReceiveDefinition
  }

  /** Gets the body of this function-like construct. */
  Solidity::AstNode getBody() {
    result = this.(Solidity::FunctionDefinition).getBody()
    or
    result = this.(Solidity::ConstructorDefinition).getBody()
    or
    result = this.(Solidity::ModifierDefinition).getBody()
    or
    result = this.(Solidity::FallbackReceiveDefinition).getBody()
  }
}

/**
 * Gets the first CFG node to execute within a statement or expression.
 */
CfgNode first(Solidity::AstNode node) {
  // Simple expression types (leaf nodes) - they are their own first node
  (
    node instanceof Solidity::Identifier or
    node instanceof Solidity::NumberLiteral or
    node instanceof Solidity::StringLiteral or
    node instanceof Solidity::HexStringLiteral or
    node instanceof Solidity::True or
    node instanceof Solidity::False or
    node instanceof Solidity::BooleanLiteral or
    node instanceof Solidity::NewExpression or
    node instanceof Solidity::TypeCastExpression or
    node instanceof Solidity::ParenthesizedExpression or
    node instanceof Solidity::InlineArrayExpression or
    node instanceof Solidity::TupleExpression or
    node instanceof Solidity::StructExpression or
    node instanceof Solidity::PayableConversionExpression or
    node instanceof Solidity::MetaTypeExpression
  ) and
  result = node
  or
  // Compound assignment `a += b`: evaluate the right side first, like a plain
  // assignment. Treating it as a leaf left its operands off the graph entirely —
  // including the `msg.sender` read in `balances[msg.sender] -= amount`.
  exists(Solidity::AugmentedAssignmentExpression aug | node = aug | result = first(aug.getRight()))
  or
  // Update expression `x++` / `--x`: evaluate the operand
  exists(Solidity::UpdateExpression upd | node = upd | result = first(upd.getArgument()))
  or
  // Binary expression: evaluate left first
  exists(Solidity::BinaryExpression bin | node = bin | result = first(bin.getLeft()))
  or
  // Unary expression: evaluate operand first
  exists(Solidity::UnaryExpression unary | node = unary | result = first(unary.getArgument()))
  or
  // Call expression: evaluate callee first
  exists(Solidity::CallExpression call | node = call | result = first(call.getFunction()))
  or
  // Assignment: evaluate right side first
  exists(Solidity::AssignmentExpression assign | node = assign | result = first(assign.getRight()))
  or
  // Ternary: evaluate condition first (child 0 is condition)
  exists(Solidity::TernaryExpression tern | node = tern | result = first(tern.getChild(0)))
  or
  // Member expression: evaluate object first
  exists(Solidity::MemberExpression mem | node = mem | result = first(mem.getObject()))
  or
  // Array access: evaluate base first
  exists(Solidity::ArrayAccess arr | node = arr | result = first(arr.getBase()))
  or
  // Transparent wrapper: first node of its first semantic child
  exists(TransparentNode t | node = t |
    result = first(t.getChild(0))
    or
    not exists(t.getChild(0)) and result = first(t.getAChild())
  )
  or
  // Struct field initialiser `name: value` — only the value is evaluated
  exists(Solidity::StructFieldAssignment f | node = f | result = first(f.getFieldValue()))
  or
  // Statement sequence (block or function body): first statement in it
  exists(StatementSequence block | node = block |
    result = first(block.getChild(0))
    or
    // Empty sequence
    not exists(block.getChild(0)) and result = block
  )
  or
  // If statement: evaluate condition first
  exists(Solidity::IfStatement ifStmt | node = ifStmt | result = first(ifStmt.getCondition()))
  or
  // For statement: evaluate initializer first (if present)
  exists(Solidity::ForStatement forStmt | node = forStmt |
    result = first(forStmt.getInitial())
    or
    not exists(forStmt.getInitial()) and result = first(forStmt.getCondition())
    or
    not exists(forStmt.getInitial()) and
    not exists(forStmt.getCondition()) and
    result = first(forStmt.getBody())
  )
  or
  // While statement: evaluate condition first
  exists(Solidity::WhileStatement whileStmt | node = whileStmt |
    result = first(whileStmt.getCondition())
  )
  or
  // Do-while statement: execute body first
  exists(Solidity::DoWhileStatement doWhile | node = doWhile | result = first(doWhile.getBody()))
  or
  // Try statement: evaluate the external call first
  exists(Solidity::TryStatement tryStmt | node = tryStmt | result = first(tryStmt.getAttempt()))
  or
  // Expression statement: evaluate expression
  exists(Solidity::ExpressionStatement exprStmt | node = exprStmt |
    result = first(exprStmt.getChild(0))
  )
  or
  // Variable declaration: evaluate initializer (if present)
  exists(Solidity::VariableDeclarationStatement varDecl | node = varDecl |
    result = first(varDecl.getFieldValue())
    or
    not exists(varDecl.getFieldValue()) and result = varDecl
  )
  or
  // Return statement: evaluate expression (if present)
  exists(Solidity::ReturnStatement ret | node = ret |
    result = first(ret.getChild(0))
    or
    not exists(ret.getChild(0)) and result = ret
  )
  or
  // Emit statement: the grammar hangs the event-name `Identifier` and the
  // `CallArgument`s directly off the statement, with no nested call. The name is
  // not evaluated, so flow starts at the first argument.
  exists(Solidity::EmitStatement emit | node = emit |
    result =
      first(min(Solidity::CallArgument a |
          a.getParent() = emit
        |
          a order by a.getLocation().getStartColumn()
        ))
    or
    not exists(Solidity::CallArgument a | a.getParent() = emit) and result = emit
  )
  or
  // Revert statement: evaluate error (if present)
  exists(Solidity::RevertStatement revert | node = revert |
    result = first(revert.getChild(0))
    or
    not exists(revert.getChild(0)) and result = revert
  )
  or
  // Other statements that are their own first node
  (
    node instanceof Solidity::BreakStatement or
    node instanceof Solidity::ContinueStatement or
    node instanceof Solidity::Unchecked
  ) and
  result = node
  or
  // Assembly statement: first is the inner YulBlock
  exists(Solidity::AssemblyStatement asm | node = asm |
    result = first(asm.getChild(0))
    or
    not exists(asm.getChild(0)) and result = asm
  )
  or
  // Yul block: first statement in block
  exists(Solidity::YulBlock yulBlock | node = yulBlock |
    result = first(yulBlock.getChild(0))
    or
    not exists(yulBlock.getChild(0)) and result = yulBlock
  )
  or
  // Yul if statement: evaluate condition first (child 0 is condition, child 1 is body)
  exists(Solidity::YulIfStatement yulIf | node = yulIf | result = first(yulIf.getChild(0)))
  or
  // Yul for statement: init block first (children: 0=init, 1=cond, 2=update, 3=body)
  exists(Solidity::YulForStatement yulFor | node = yulFor | result = first(yulFor.getChild(0)))
  or
  // Yul switch statement: evaluate expression first (child 0)
  exists(Solidity::YulSwitchStatement yulSwitch | node = yulSwitch |
    result = first(yulSwitch.getChild(0))
  )
  or
  // Yul assignment: evaluate right side first (children are expressions)
  exists(Solidity::YulAssignment yulAssign | node = yulAssign |
    result = first(yulAssign.getChild(0))
    or
    not exists(yulAssign.getChild(0)) and result = yulAssign
  )
  or
  // Yul variable declaration: evaluate right side (if present)
  exists(Solidity::YulVariableDeclaration yulVar | node = yulVar |
    result = first(yulVar.getRight())
    or
    not exists(yulVar.getRight()) and result = yulVar
  )
  or
  // Yul function call: evaluate function name first
  exists(Solidity::YulFunctionCall yulCall | node = yulCall |
    result = first(yulCall.getFunction())
    or
    not exists(yulCall.getFunction()) and result = yulCall
  )
  or
  // Yul function definition: first is the body (child after name)
  exists(Solidity::YulFunctionDefinition yulFunc | node = yulFunc | result = yulFunc)
  or
  // Yul jump statements: they are their own first
  (
    node instanceof Solidity::YulBreak or
    node instanceof Solidity::YulContinue or
    node instanceof Solidity::YulLeave
  ) and
  result = node
  or
  // Yul literals and identifiers: they are their own first
  (
    node instanceof Solidity::YulIdentifier or
    node instanceof Solidity::YulBoolean or
    node instanceof Solidity::YulDecimalNumber or
    node instanceof Solidity::YulHexNumber or
    node instanceof Solidity::YulStringLiteral or
    node instanceof Solidity::YulHexStringLiteral
  ) and
  result = node
}

/**
 * Gets the last CFG node to execute within a statement or expression,
 * given that execution completes with the given completion.
 */
CfgNode last(Solidity::AstNode node, Completion c) {
  // Simple expression types (leaf nodes) - they are their own last node
  (
    node instanceof Solidity::Identifier or
    node instanceof Solidity::NumberLiteral or
    node instanceof Solidity::StringLiteral or
    node instanceof Solidity::HexStringLiteral or
    node instanceof Solidity::True or
    node instanceof Solidity::False or
    node instanceof Solidity::BooleanLiteral or
    node instanceof Solidity::NewExpression or
    node instanceof Solidity::TypeCastExpression or
    node instanceof Solidity::ParenthesizedExpression or
    node instanceof Solidity::InlineArrayExpression or
    node instanceof Solidity::TupleExpression or
    node instanceof Solidity::StructExpression or
    node instanceof Solidity::PayableConversionExpression or
    node instanceof Solidity::MetaTypeExpression or
    // `unchecked` extracts as a bare keyword node; the block it guards is its
    // sibling, so it sequences as a no-op.
    node instanceof Solidity::Unchecked or
    node instanceof Solidity::BreakStatement or
    node instanceof Solidity::ContinueStatement
  ) and
  c instanceof NormalCompletion and
  result = node
  or
  // Compound assignment and update complete with themselves
  exists(Solidity::AugmentedAssignmentExpression aug | node = aug |
    c instanceof NormalCompletion and result = aug
  )
  or
  exists(Solidity::UpdateExpression upd | node = upd |
    c instanceof NormalCompletion and result = upd
  )
  or
  // Binary expression: completes with binary node itself
  exists(Solidity::BinaryExpression bin | node = bin |
    c instanceof NormalCompletion and result = bin
  )
  or
  // Unary expression: completes with unary node itself
  exists(Solidity::UnaryExpression unary | node = unary |
    c instanceof NormalCompletion and result = unary
  )
  or
  // Call expression: completes with call node itself
  exists(Solidity::CallExpression call | node = call |
    c instanceof NormalCompletion and result = call
  )
  or
  // Assignment: completes with assignment node itself
  exists(Solidity::AssignmentExpression assign | node = assign |
    c instanceof NormalCompletion and result = assign
  )
  or
  // Ternary: completes with either branch (child 1 is consequence, child 2 is alternative)
  exists(Solidity::TernaryExpression tern | node = tern |
    result = last(tern.getChild(1), c)
    or
    result = last(tern.getChild(2), c)
  )
  or
  // Member expression: completes with member node itself
  exists(Solidity::MemberExpression mem | node = mem |
    c instanceof NormalCompletion and result = mem
  )
  or
  // Array access: completes with array access node itself
  exists(Solidity::ArrayAccess arr | node = arr | c instanceof NormalCompletion and result = arr)
  or
  // Transparent wrapper: last node of its last semantic child
  exists(TransparentNode t | node = t |
    exists(int n | n = max(int i | exists(t.getChild(i))) and result = last(t.getChild(n), c))
    or
    not exists(t.getChild(0)) and result = last(t.getAChild(), c)
  )
  or
  // Struct field initialiser `name: value` — only the value is evaluated
  exists(Solidity::StructFieldAssignment f | node = f | result = last(f.getFieldValue(), c))
  or
  // Statement sequence (block or function body): last node of last statement
  exists(StatementSequence block | node = block |
    exists(int n |
      n = max(int i | exists(block.getChild(i))) and
      result = last(block.getChild(n), c)
    )
    or
    // Empty sequence
    not exists(block.getChild(0)) and c instanceof NormalCompletion and result = block
  )
  or
  // If statement: last node of taken branch
  exists(Solidity::IfStatement ifStmt | node = ifStmt |
    result = last(ifStmt.getBody(0), c)
    or
    result = last(ifStmt.getElse(), c)
    or
    // No else branch, condition is false
    not exists(ifStmt.getElse()) and
    c instanceof NormalCompletion and
    result = ifStmt.getCondition()
  )
  or
  // For statement: can exit via body, condition, or break
  exists(Solidity::ForStatement forStmt | node = forStmt |
    // Normal exit when condition is false
    // Normal exit is where the condition's *evaluation* ends, not the condition
    // node itself — for `for (...; i < n; ...)` the grammar's condition is an
    // expression_statement, which is never on the graph.
    result = last(forStmt.getCondition(), _) and c instanceof NormalCompletion
    or
    // Break exits the loop
    result = last(forStmt.getBody(), c) and c instanceof BreakCompletion
    or
    // Propagate return/revert from body
    result = last(forStmt.getBody(), c) and c.isAbnormal()
  )
  or
  // While statement: similar to for
  exists(Solidity::WhileStatement whileStmt | node = whileStmt |
    // Normal exit is where the condition's *evaluation* ends, not the condition
    // node itself — for `for (...; i < n; ...)` the grammar's condition is an
    // expression_statement, which is never on the graph.
    result = last(whileStmt.getCondition(), _) and c instanceof NormalCompletion
    or
    result = last(whileStmt.getBody(), c) and c instanceof BreakCompletion
    or
    result = last(whileStmt.getBody(), c) and c.isAbnormal()
  )
  or
  // Do-while statement
  exists(Solidity::DoWhileStatement doWhile | node = doWhile |
    // Normal exit is where the condition's *evaluation* ends, not the condition
    // node itself — for `for (...; i < n; ...)` the grammar's condition is an
    // expression_statement, which is never on the graph.
    result = last(doWhile.getCondition(), _) and c instanceof NormalCompletion
    or
    result = last(doWhile.getBody(), c) and c instanceof BreakCompletion
    or
    result = last(doWhile.getBody(), c) and c.isAbnormal()
  )
  or
  // Try statement: completes via success body or catch clauses
  // Catch clauses are stored as children of the try statement
  exists(Solidity::TryStatement tryStmt | node = tryStmt |
    result = last(tryStmt.getBody(), c)
    or
    exists(Solidity::CatchClause catch |
      catch = tryStmt.getChild(_) and
      result = last(catch.getBody(), c)
    )
  )
  or
  // Expression statement: completes when expression completes
  exists(Solidity::ExpressionStatement exprStmt | node = exprStmt |
    result = last(exprStmt.getChild(0), c)
  )
  or
  // Variable declaration: completes normally
  exists(Solidity::VariableDeclarationStatement varDecl | node = varDecl |
    c instanceof NormalCompletion and
    (
      result = varDecl.getFieldValue()
      or
      not exists(varDecl.getFieldValue()) and result = varDecl
    )
  )
  or
  // Return statement: completes with return
  exists(Solidity::ReturnStatement ret | node = ret |
    c instanceof ReturnCompletion and result = ret
  )
  or
  // Break statement: completes with break
  exists(Solidity::BreakStatement brk | node = brk | c instanceof BreakCompletion and result = brk)
  or
  // Continue statement: completes with continue
  exists(Solidity::ContinueStatement cont | node = cont |
    c instanceof ContinueCompletion and result = cont
  )
  or
  // Revert statement: completes with revert
  exists(Solidity::RevertStatement revert | node = revert |
    c instanceof RevertCompletion and result = revert
  )
  or
  // Emit statement: completes normally
  exists(Solidity::EmitStatement emit | node = emit |
    c instanceof NormalCompletion and result = emit
  )
  or
  // Assembly statement: completes via inner YulBlock
  exists(Solidity::AssemblyStatement asm | node = asm |
    result = last(asm.getChild(0), c)
    or
    not exists(asm.getChild(0)) and c instanceof NormalCompletion and result = asm
  )
  or
  // Yul block: last node of last statement
  exists(Solidity::YulBlock yulBlock | node = yulBlock |
    exists(int n |
      n = max(int i | exists(yulBlock.getChild(i))) and
      result = last(yulBlock.getChild(n), c)
    )
    or
    not exists(yulBlock.getChild(0)) and c instanceof NormalCompletion and result = yulBlock
  )
  or
  // Yul if statement: body end OR condition fallthrough (Yul if has no else)
  exists(Solidity::YulIfStatement yulIf | node = yulIf |
    // Body completes normally or abnormally
    result = last(yulIf.getChild(1), c)
    or
    // Condition is false (fallthrough) - child 0 is condition
    c instanceof NormalCompletion and result = yulIf.getChild(0)
  )
  or
  // Yul for statement: condition (false), break, or abnormal exit from body
  exists(Solidity::YulForStatement yulFor | node = yulFor |
    // Normal exit is where the condition's evaluation ends (child 1 is condition)
    result = last(yulFor.getChild(1), _) and c instanceof NormalCompletion
    or
    // Break exits the loop
    result = last(yulFor.getChild(3), c) and c instanceof BreakCompletion
    or
    // Propagate return/revert/leave from body
    result = last(yulFor.getChild(3), c) and c.isAbnormal()
  )
  or
  // Yul switch statement: any case can be the last
  exists(Solidity::YulSwitchStatement yulSwitch, int i | node = yulSwitch |
    i > 0 and // Children after 0 are case/default blocks
    result = last(yulSwitch.getChild(i), c)
  )
  or
  // Yul assignment: completes normally with itself
  exists(Solidity::YulAssignment yulAssign | node = yulAssign |
    c instanceof NormalCompletion and result = yulAssign
  )
  or
  // Yul variable declaration: completes normally
  exists(Solidity::YulVariableDeclaration yulVar | node = yulVar |
    c instanceof NormalCompletion and result = yulVar
  )
  or
  // Yul function call: completes normally with itself
  exists(Solidity::YulFunctionCall yulCall | node = yulCall |
    c instanceof NormalCompletion and result = yulCall
  )
  or
  // Yul function definition: completes when body completes
  exists(Solidity::YulFunctionDefinition yulFunc | node = yulFunc |
    c instanceof NormalCompletion and result = yulFunc
  )
  or
  // Yul break: completes with break
  exists(Solidity::YulBreak yulBreak | node = yulBreak |
    c instanceof BreakCompletion and result = yulBreak
  )
  or
  // Yul continue: completes with continue
  exists(Solidity::YulContinue yulCont | node = yulCont |
    c instanceof ContinueCompletion and result = yulCont
  )
  or
  // Yul leave: completes with leave (exits Yul function)
  exists(Solidity::YulLeave yulLeave | node = yulLeave |
    c instanceof YulLeaveCompletion and result = yulLeave
  )
  or
  // Yul literals and identifiers: complete normally with themselves
  (
    node instanceof Solidity::YulIdentifier or
    node instanceof Solidity::YulBoolean or
    node instanceof Solidity::YulDecimalNumber or
    node instanceof Solidity::YulHexNumber or
    node instanceof Solidity::YulStringLiteral or
    node instanceof Solidity::YulHexStringLiteral
  ) and
  c instanceof NormalCompletion and
  result = node
}

/**
 * Holds if `succ` is an immediate successor of `pred` in the CFG.
 */
predicate successor(CfgNode pred, CfgNode succ) { successorWithCompletion(pred, succ, _) }

/**
 * Holds if `succ` is an immediate successor of `pred` in the CFG,
 * when `pred` completes with completion `c`.
 */
predicate successorWithCompletion(CfgNode pred, CfgNode succ, Completion c) {
  // Sequential flow within expressions
  expressionSuccessor(pred, succ, c)
  or
  // Control flow between statements
  statementSuccessor(pred, succ, c)
  or
  // Function entry (including modifier expansion)
  functionEntrySuccessor(pred, succ, c)
  or
  // Modifier placeholder `_;` flow to/from function body
  modifierPlaceholderSuccessor(pred, succ, c)
}

/**
 * Holds if there's a sequential successor within an expression.
 */
private predicate expressionSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  c instanceof NormalCompletion and
  (
    // Binary expression: left -> right -> binary
    exists(Solidity::BinaryExpression bin |
      pred = last(bin.getLeft(), c) and succ = first(bin.getRight())
      or
      pred = last(bin.getRight(), c) and succ = bin
    )
    or
    // Unary expression: operand -> unary
    exists(Solidity::UnaryExpression unary | pred = last(unary.getArgument(), c) and succ = unary)
    or
    // Call expression: callee -> args -> call
    // Note: arguments are stored as children of the call expression
    exists(Solidity::CallExpression call |
      pred = last(call.getFunction(), c) and
      (
        succ = first(call.getChild(0))
        or
        not exists(call.getChild(0)) and succ = call
      )
      or
      exists(int i |
        pred = last(call.getChild(i), c) and
        (
          succ = first(call.getChild(i + 1))
          or
          not exists(call.getChild(i + 1)) and succ = call
        )
      )
    )
    or
    // Emit statement: arg -> arg -> emit
    exists(Solidity::EmitStatement emit, Solidity::CallArgument a |
      a.getParent() = emit and
      pred = last(a, c) and
      (
        succ =
          first(min(Solidity::CallArgument b |
              b.getParent() = emit and
              b.getLocation().getStartColumn() > a.getLocation().getStartColumn()
            |
              b order by b.getLocation().getStartColumn()
            ))
        or
        not exists(Solidity::CallArgument b |
          b.getParent() = emit and
          b.getLocation().getStartColumn() > a.getLocation().getStartColumn()
        ) and
        succ = emit
      )
    )
    or
    // Compound assignment: right -> left -> assignment
    exists(Solidity::AugmentedAssignmentExpression aug |
      pred = last(aug.getRight(), c) and succ = first(aug.getLeft())
      or
      pred = last(aug.getLeft(), c) and succ = aug
    )
    or
    // Update expression: operand -> update
    exists(Solidity::UpdateExpression upd | pred = last(upd.getArgument(), c) and succ = upd)
    or
    // Assignment: right -> left -> assignment
    exists(Solidity::AssignmentExpression assign |
      pred = last(assign.getRight(), c) and succ = first(assign.getLeft())
      or
      pred = last(assign.getLeft(), c) and succ = assign
    )
    or
    // Member expression: object -> member
    exists(Solidity::MemberExpression mem | pred = last(mem.getObject(), c) and succ = mem)
    or
    // Array access: base -> index -> access
    exists(Solidity::ArrayAccess arr |
      pred = last(arr.getBase(), c) and succ = first(arr.getIndex())
      or
      pred = last(arr.getIndex(), c) and succ = arr
    )
  )
  or
  // Ternary: condition branches to consequence or alternative
  // Child 0 = condition, child 1 = consequence, child 2 = alternative
  exists(Solidity::TernaryExpression tern |
    pred = last(tern.getChild(0), _) and
    c instanceof TrueCompletion and
    succ = first(tern.getChild(1))
    or
    pred = last(tern.getChild(0), _) and
    c instanceof FalseCompletion and
    succ = first(tern.getChild(2))
  )
}

/**
 * Holds if there's a control flow successor between statements.
 */
private predicate statementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  // Sequential statements in a block or function body
  exists(StatementSequence block, int i |
    pred = last(block.getChild(i), c) and
    c instanceof NormalCompletion and
    succ = first(block.getChild(i + 1))
  )
  or
  // If statement: condition -> body or else
  exists(Solidity::IfStatement ifStmt |
    // True branch
    pred = last(ifStmt.getCondition(), _) and
    c instanceof TrueCompletion and
    succ = first(ifStmt.getBody(0))
    or
    // False branch (else)
    pred = last(ifStmt.getCondition(), _) and
    c instanceof FalseCompletion and
    exists(ifStmt.getElse()) and
    succ = first(ifStmt.getElse())
  )
  or
  // For statement control flow
  forStatementSuccessor(pred, succ, c)
  or
  // While statement control flow
  whileStatementSuccessor(pred, succ, c)
  or
  // Do-while statement control flow
  doWhileStatementSuccessor(pred, succ, c)
  or
  // Try statement control flow
  tryStatementSuccessor(pred, succ, c)
  or
  // Yul control flow
  yulBlockSuccessor(pred, succ, c)
  or
  yulIfStatementSuccessor(pred, succ, c)
  or
  yulForStatementSuccessor(pred, succ, c)
  or
  yulSwitchStatementSuccessor(pred, succ, c)
  or
  yulExpressionSuccessor(pred, succ, c)
  or
  // Returned expression -> the return statement, which carries the completion.
  //
  // `expression_statement` and `variable_declaration_statement` deliberately have
  // no rule here: `first()` descends straight into the inner expression, so the
  // statement node is never entered and an edge out of it would start from an
  // unreachable node. `return` is different — it is the node that completes.
  exists(Solidity::ReturnStatement ret |
    pred = last(ret.getChild(0), c) and
    c instanceof NormalCompletion and
    succ = ret
  )
}

/**
 * For statement control flow.
 */
private predicate forStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::ForStatement forStmt |
    // Init -> condition (or body if no condition)
    pred = last(forStmt.getInitial(), c) and
    c instanceof NormalCompletion and
    (
      succ = first(forStmt.getCondition())
      or
      not exists(forStmt.getCondition()) and succ = first(forStmt.getBody())
    )
    or
    // Condition true -> body
    pred = last(forStmt.getCondition(), _) and
    c instanceof TrueCompletion and
    succ = first(forStmt.getBody())
    or
    // Body normal completion -> update (or condition if no update)
    pred = last(forStmt.getBody(), c) and
    c instanceof NormalCompletion and
    (
      succ = first(forStmt.getUpdate())
      or
      not exists(forStmt.getUpdate()) and succ = first(forStmt.getCondition())
    )
    or
    // Update -> condition
    pred = last(forStmt.getUpdate(), c) and
    c instanceof NormalCompletion and
    succ = first(forStmt.getCondition())
    or
    // Continue -> update (or condition)
    pred = last(forStmt.getBody(), c) and
    c instanceof ContinueCompletion and
    (
      succ = first(forStmt.getUpdate())
      or
      not exists(forStmt.getUpdate()) and succ = first(forStmt.getCondition())
    )
  )
}

/**
 * While statement control flow.
 */
private predicate whileStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::WhileStatement whileStmt |
    // Condition true -> body
    pred = last(whileStmt.getCondition(), _) and
    c instanceof TrueCompletion and
    succ = first(whileStmt.getBody())
    or
    // Body normal completion -> condition (loop back)
    pred = last(whileStmt.getBody(), c) and
    c instanceof NormalCompletion and
    succ = first(whileStmt.getCondition())
    or
    // Continue -> condition
    pred = last(whileStmt.getBody(), c) and
    c instanceof ContinueCompletion and
    succ = first(whileStmt.getCondition())
  )
}

/**
 * Do-while statement control flow.
 */
private predicate doWhileStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::DoWhileStatement doWhile |
    // Body normal completion -> condition
    pred = last(doWhile.getBody(), c) and
    c instanceof NormalCompletion and
    succ = first(doWhile.getCondition())
    or
    // Condition true -> body (loop back)
    pred = last(doWhile.getCondition(), _) and
    c instanceof TrueCompletion and
    succ = first(doWhile.getBody())
    or
    // Continue -> condition
    pred = last(doWhile.getBody(), c) and
    c instanceof ContinueCompletion and
    succ = first(doWhile.getCondition())
  )
}

/**
 * Try statement control flow.
 *
 * Solidity try-catch has the form:
 *   try someContract.someFunc() returns (Type var) {
 *       // success body
 *   } catch Error(string memory reason) {
 *       // catch Error
 *   } catch Panic(uint code) {
 *       // catch Panic
 *   } catch (bytes memory lowLevelData) {
 *       // catch all
 *   }
 *
 * We use over-approximation for catch clauses since we cannot statically
 * determine which error type will be thrown at runtime.
 */
private predicate tryStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::TryStatement tryStmt |
    // Attempt success -> success body
    pred = last(tryStmt.getAttempt(), c) and
    c instanceof NormalCompletion and
    succ = first(tryStmt.getBody())
    or
    // Attempt failure -> any catch clause (over-approximation)
    // All catch clauses are potential successors since we can't determine
    // which error type will be thrown at runtime
    // Catch clauses are stored as children of the try statement
    pred = last(tryStmt.getAttempt(), _) and
    c instanceof RevertCompletion and
    exists(Solidity::CatchClause catch |
      catch = tryStmt.getChild(_) and
      succ = first(catch.getBody())
    )
  )
}

/**
 * Function entry control flow.
 *
 * For functions with chained modifiers (e.g., `function foo() mod0 mod1 { body }`),
 * the CFG flows through modifier bodies in source order:
 *   entry → mod0_pre → mod0's `_;` → mod1_pre → mod1's `_;` → body
 *   body → mod1_post → mod0_post → exit
 *
 * For functions without modifiers, flow goes directly to function body.
 */
private predicate functionEntrySuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(EntryNode entry |
    pred = entry and
    c instanceof NormalCompletion and
    (
      // Function with modifiers: flow to first modifier's body (source order)
      exists(Solidity::ModifierDefinition modDef |
        nthResolvedModifier(entry, 0, _, modDef) and
        succ = first(modDef.getBody())
      )
      or
      // Function without resolved modifiers: flow directly to function body
      not hasResolvedModifier(entry) and
      succ = first(entry.getBody())
    )
  )
}

/**
 * Resolves a modifier invocation to its definition within the contract hierarchy.
 */
private predicate modifierInvocationResolves(
  Solidity::ModifierInvocation invoc, Solidity::ModifierDefinition modDef
) {
  exists(Solidity::ContractDeclaration contract |
    invoc.getParent+() = contract and
    (
      // Modifier defined in same contract
      modDef.getParent+() = contract
      or
      // Modifier defined in base contract
      exists(Solidity::InheritanceSpecifier spec |
        spec.getParent() = contract and
        modDef.getParent+() = spec.getAncestor().(Solidity::ContractDeclaration)
      )
    ) and
    invoc.getValue() = modDef.getName().(Solidity::AstNode).getValue()
  )
}

/**
 * Holds if modifier invocation `a` appears before `b` in source order.
 */
private predicate modifierSourceBefore(
  Solidity::ModifierInvocation a, Solidity::ModifierInvocation b
) {
  a.getParent() = b.getParent() and
  (
    a.getLocation().getStartLine() < b.getLocation().getStartLine()
    or
    a.getLocation().getStartLine() = b.getLocation().getStartLine() and
    a.getLocation().getStartColumn() < b.getLocation().getStartColumn()
  )
}

/**
 * Gets the n-th resolved modifier (0-based, source order) on `funcLike`.
 * Position is determined by counting how many other resolved modifiers precede it.
 */
private predicate nthResolvedModifier(
  EntryNode funcLike, int pos, Solidity::ModifierInvocation modInvoc,
  Solidity::ModifierDefinition modDef
) {
  modInvoc.getParent() = funcLike and
  modifierInvocationResolves(modInvoc, modDef) and
  pos =
    count(Solidity::ModifierInvocation prior |
      prior.getParent() = funcLike and
      modifierInvocationResolves(prior, _) and
      modifierSourceBefore(prior, modInvoc)
    )
}

/** Gets the number of resolved modifiers on `funcLike`. */
private int resolvedModifierCount(EntryNode funcLike) {
  result =
    count(Solidity::ModifierInvocation m |
      m.getParent() = funcLike and modifierInvocationResolves(m, _)
    )
}

/** Holds if `funcLike` has at least one resolved modifier. */
private predicate hasResolvedModifier(EntryNode funcLike) {
  exists(Solidity::ModifierInvocation m |
    m.getParent() = funcLike and modifierInvocationResolves(m, _)
  )
}

/**
 * Gets the CFG return target after the inner execution at modifier position `pos` completes.
 *
 * If the modifier at `pos` has code after its `_;`, that code's first node is the target.
 * If `_;` is the last statement (no post-`_;` code), cascades to the parent modifier (pos-1).
 * If pos=0 with no post-`_;` code, no target exists (function body completion is the exit).
 */
private predicate modifierReturnTarget(EntryNode funcLike, int pos, CfgNode target) {
  exists(
    Solidity::ModifierDefinition modDef, Solidity::BlockStatement modBody,
    Solidity::AstNode placeholder, int placeholderIdx
  |
    nthResolvedModifier(funcLike, pos, _, modDef) and
    modBody = modDef.getBody() and
    placeholder = modBody.getChild(placeholderIdx) and
    placeholder.getAChild*().(Solidity::Identifier).getValue() = "_" and
    (
      // Post-`_;` code exists: return here
      target = first(modBody.getChild(placeholderIdx + 1))
      or
      // No post-`_;` code: cascade to parent modifier
      not exists(modBody.getChild(placeholderIdx + 1)) and
      pos > 0 and
      modifierReturnTarget(funcLike, pos - 1, target)
    )
  )
}

/**
 * Modifier placeholder (`_;`) control flow for chained modifiers.
 *
 * Forward: `_;` in modifier N → modifier N+1 body (or function body if N is last).
 * Return: inner execution completion → resume after `_;` in the enclosing modifier.
 */
private predicate modifierPlaceholderSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  // Forward: `_;` in modifier at pos N → next modifier (N+1) or function body (if last)
  exists(
    Solidity::ModifierDefinition modDef, EntryNode funcLike, Solidity::AstNode placeholder, int pos
  |
    placeholder.getParent+() = modDef and
    placeholder.(Solidity::Identifier).getValue() = "_" and
    pred = placeholder and
    c instanceof NormalCompletion and
    nthResolvedModifier(funcLike, pos, _, modDef) and
    (
      // Chain to next modifier's body
      exists(Solidity::ModifierDefinition nextModDef |
        nthResolvedModifier(funcLike, pos + 1, _, nextModDef) and
        succ = first(nextModDef.getBody())
      )
      or
      // Last modifier: chain to function body
      pos = resolvedModifierCount(funcLike) - 1 and
      succ = first(funcLike.getBody())
    )
  )
  or
  // Return: function body completion → nearest modifier with post-`_;` code
  exists(EntryNode funcLike, int lastPos |
    lastPos = resolvedModifierCount(funcLike) - 1 and
    lastPos >= 0 and
    pred = last(funcLike.getBody(), c) and
    c instanceof NormalCompletion and
    modifierReturnTarget(funcLike, lastPos, succ)
  )
  or
  // Return: modifier N body completion → parent modifier's post-`_;` code
  // Only when modifier N has post-`_;` code (otherwise handled by modifierReturnTarget cascade)
  exists(
    EntryNode funcLike, Solidity::ModifierDefinition modDef, Solidity::BlockStatement modBody,
    Solidity::AstNode placeholder, int placeholderIdx, int pos
  |
    pos > 0 and
    nthResolvedModifier(funcLike, pos, _, modDef) and
    modBody = modDef.getBody() and
    placeholder = modBody.getChild(placeholderIdx) and
    placeholder.getAChild*().(Solidity::Identifier).getValue() = "_" and
    // Only create return edge when this modifier has post-`_;` code
    // (its body genuinely completes here, not at the `_;` placeholder)
    exists(modBody.getChild(placeholderIdx + 1)) and
    pred = last(modBody, c) and
    c instanceof NormalCompletion and
    modifierReturnTarget(funcLike, pos - 1, succ)
  )
}

/**
 * Gets an exit node for the given function-like construct.
 */
CfgNode getAnExitNode(EntryNode entry) {
  exists(Completion c |
    result = last(entry.getBody(), c) and
    (c instanceof NormalCompletion or c instanceof ReturnCompletion)
  )
}

// =============================================================================
// Yul/Assembly Control Flow
// =============================================================================
/**
 * Yul block sequential control flow.
 */
private predicate yulBlockSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  // Sequential statements in a Yul block
  exists(Solidity::YulBlock block, int i |
    pred = last(block.getChild(i), c) and
    c instanceof NormalCompletion and
    succ = first(block.getChild(i + 1))
  )
  or
  // Assembly statement -> inner YulBlock
  exists(Solidity::AssemblyStatement asm |
    pred = asm and
    c instanceof NormalCompletion and
    succ = first(asm.getChild(0))
  )
}

/**
 * Yul if statement control flow.
 * Note: Yul if has no else branch - condition either leads to body or falls through.
 */
private predicate yulIfStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::YulIfStatement yulIf |
    // Condition is non-zero -> body (child 1)
    pred = last(yulIf.getChild(0), _) and
    c instanceof TrueCompletion and
    succ = first(yulIf.getChild(1))
  )
}

/**
 * Yul for statement control flow.
 * Children: 0=init block, 1=condition, 2=update block, 3=body
 */
private predicate yulForStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::YulForStatement yulFor |
    // Init -> condition
    pred = last(yulFor.getChild(0), c) and
    c instanceof NormalCompletion and
    succ = first(yulFor.getChild(1))
    or
    // Condition true -> body
    pred = last(yulFor.getChild(1), _) and
    c instanceof TrueCompletion and
    succ = first(yulFor.getChild(3))
    or
    // Body normal completion -> update
    pred = last(yulFor.getChild(3), c) and
    c instanceof NormalCompletion and
    succ = first(yulFor.getChild(2))
    or
    // Update -> condition (loop back)
    pred = last(yulFor.getChild(2), c) and
    c instanceof NormalCompletion and
    succ = first(yulFor.getChild(1))
    or
    // Continue -> update
    pred = last(yulFor.getChild(3), c) and
    c instanceof ContinueCompletion and
    succ = first(yulFor.getChild(2))
  )
}

/**
 * Yul switch statement control flow.
 * Child 0 is the expression, children 1+ are case/default blocks.
 * We use over-approximation: all cases are potential successors since
 * we don't track values statically.
 */
private predicate yulSwitchStatementSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  exists(Solidity::YulSwitchStatement yulSwitch, int i |
    // Expression -> any case (over-approximation)
    pred = last(yulSwitch.getChild(0), _) and
    c instanceof NormalCompletion and
    i > 0 and
    succ = first(yulSwitch.getChild(i))
  )
}

/**
 * Yul expression/assignment control flow.
 */
private predicate yulExpressionSuccessor(CfgNode pred, CfgNode succ, Completion c) {
  c instanceof NormalCompletion and
  (
    // Yul function call: function -> args -> call
    exists(Solidity::YulFunctionCall call |
      pred = last(call.getFunction(), c) and
      (
        succ = first(call.getChild(0))
        or
        not exists(call.getChild(0)) and succ = call
      )
      or
      exists(int i |
        pred = last(call.getChild(i), c) and
        (
          succ = first(call.getChild(i + 1))
          or
          not exists(call.getChild(i + 1)) and succ = call
        )
      )
    )
    or
    // Yul variable declaration: go to right side if present
    exists(Solidity::YulVariableDeclaration decl |
      pred = decl and
      succ = first(decl.getRight())
    )
    or
    // Yul assignment: evaluate children sequentially, then self
    exists(Solidity::YulAssignment assign, int i |
      pred = last(assign.getChild(i), c) and
      (
        succ = first(assign.getChild(i + 1))
        or
        not exists(assign.getChild(i + 1)) and succ = assign
      )
    )
  )
}
