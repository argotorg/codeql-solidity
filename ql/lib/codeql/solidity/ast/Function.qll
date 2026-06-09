/**
 * Function-related nodes in Solidity AST.
 *
 * This module provides classes for functions, constructors, modifiers,
 * and related constructs.
 */

private import codeql.solidity.ast.internal.TreeSitter

/**
 * A function definition in Solidity.
 */
class FunctionDef extends Solidity::FunctionDefinition {
  /** Gets the name of this function as a string. */
  string getFunctionName() {
    exists(Solidity::AstNode name | name = super.getName() |
      solidity_tokeninfo(name, _, result)
    )
  }

  /** Gets a parameter. */
  Solidity::AstNode getAParameter() {
    result = this.getAChild() and result instanceof Solidity::Parameter
  }

  /** Gets the return type specification. */
  Solidity::AstNode getReturnTypeNode() { result = super.getReturnType() }

  /** Gets the function body. */
  Solidity::AstNode getBodyNode() { result = super.getBody() }

  /** Gets the visibility (public, internal, private, external). */
  string getVisibility() {
    // The `Visibility` node is a wrapper; the actual keyword
    // (public/external/internal/private) is the value of its child token.
    exists(Solidity::AstNode vis |
      vis = this.getAChild() and vis instanceof Solidity::Visibility |
      result = vis.getAChild().getValue()
    )
    or
    not exists(Solidity::AstNode vis |
      vis = this.getAChild() and vis instanceof Solidity::Visibility
    ) and
    result = "internal"
  }

  /** Gets a modifier applied to this function. */
  Solidity::AstNode getAModifier() {
    result = this.getAChild() and result instanceof Solidity::ModifierInvocation
  }

  /** Holds if this function is public. */
  predicate isPublic() { this.getVisibility() = "public" }

  /** Holds if this function is external. */
  predicate isExternal() { this.getVisibility() = "external" }

  /** Holds if this function is internal. */
  predicate isInternal() { this.getVisibility() = "internal" }

  /** Holds if this function is private. */
  predicate isPrivate() { this.getVisibility() = "private" }

  /** Holds if this function is publicly callable (public or external). */
  predicate isPubliclyCallable() {
    this.isPublic() or this.isExternal()
  }

  /**
   * Gets the state-mutability keyword (`view`, `pure`, or `payable`) of this
   * function. The keyword is the value of a token nested under the
   * `StateMutability` wrapper node, which is itself a child of the function.
   */
  string getStateMutability() {
    exists(Solidity::AstNode sm |
      sm = this.getAChild() and sm instanceof Solidity::StateMutability |
      result = sm.getAChild().getValue()
    )
  }

  /** Holds if this function is payable. */
  predicate isPayable() { this.getStateMutability() = "payable" }

  /** Holds if this function is view. */
  predicate isView() { this.getStateMutability() = "view" }

  /** Holds if this function is pure. */
  predicate isPure() { this.getStateMutability() = "pure" }
}

/**
 * A constructor definition.
 */
class ConstructorDef extends Solidity::ConstructorDefinition {
  /** Gets a parameter. */
  Solidity::AstNode getAParameter() {
    result = this.getAChild() and result instanceof Solidity::Parameter
  }

  /** Gets the constructor body. */
  Solidity::AstNode getBodyNode() { result = super.getBody() }

  /** Holds if this constructor is payable. */
  predicate isPayable() {
    exists(Solidity::AstNode mod |
      mod = this.getAChild() |
      solidity_tokeninfo(mod, _, "payable")
    )
  }
}

/**
 * A modifier definition.
 */
class ModifierDef extends Solidity::ModifierDefinition {
  /** Gets the name of this modifier as a string. */
  string getModifierName() {
    exists(Solidity::AstNode name | name = super.getName() |
      solidity_tokeninfo(name, _, result)
    )
  }

  /** Gets a parameter. */
  Solidity::AstNode getAParameter() {
    result = this.getAChild() and result instanceof Solidity::Parameter
  }

  /** Gets the modifier body. */
  Solidity::AstNode getBodyNode() { result = super.getBody() }
}

/**
 * A fallback function definition.
 */
class FallbackDef extends Solidity::FallbackReceiveDefinition {
  FallbackDef() {
    exists(Solidity::AstNode kw | kw = this.getAChild() |
      solidity_tokeninfo(kw, _, "fallback")
    )
  }

  /** Gets the function body. */
  Solidity::AstNode getBodyNode() { result = super.getBody() }

  /** Holds if this fallback is payable. */
  predicate isPayable() {
    exists(Solidity::AstNode mod |
      mod = this.getAChild() |
      solidity_tokeninfo(mod, _, "payable")
    )
  }
}

/**
 * A receive function definition.
 */
class ReceiveDef extends Solidity::FallbackReceiveDefinition {
  ReceiveDef() {
    exists(Solidity::AstNode kw | kw = this.getAChild() |
      solidity_tokeninfo(kw, _, "receive")
    )
  }

  /** Gets the function body. */
  Solidity::AstNode getBodyNode() { result = super.getBody() }
}

/**
 * A modifier invocation on a function.
 */
class ModifierInvocation_ extends Solidity::ModifierInvocation {
  /** Gets the modifier being invoked. */
  Solidity::AstNode getModifierRef() { result = this.getChild(0) }

  /** Gets an argument to the modifier. */
  Solidity::AstNode getAnArgument() {
    exists(int i | i > 0 | result = this.getChild(i))
  }
}

/**
 * A parameter in a function or modifier.
 */
class Parameter_ extends Solidity::Parameter {
  /** Gets the type of this parameter. */
  Solidity::AstNode getTypeNode() { result = super.getType() }

  /** Gets the name of this parameter, if any. */
  string getParameterName() {
    exists(Solidity::AstNode name | name = super.getName() |
      solidity_tokeninfo(name, _, result)
    )
  }

  /** Gets the storage location (memory, storage, calldata). */
  string getStorageLocation_() {
    exists(Solidity::AstNode loc | loc = super.getStorageLocation() |
      solidity_tokeninfo(loc, _, result)
    )
  }
}
