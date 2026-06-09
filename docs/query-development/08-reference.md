# Reference Documentation

Complete API reference for CodeQL Solidity query development.

## Module Reference

### AST Modules

#### codeql.solidity.ast.internal.TreeSitter

Base AST types generated from tree-sitter grammar.

**Key Classes:**
| Class | Description |
|-------|-------------|
| `Solidity::AstNode` | Base class for all AST nodes |
| `Solidity::ContractDeclaration` | Contract definition |
| `Solidity::InterfaceDeclaration` | Interface definition |
| `Solidity::LibraryDeclaration` | Library definition |
| `Solidity::FunctionDefinition` | Function definition |
| `Solidity::ModifierDefinition` | Modifier definition |
| `Solidity::StateVariableDeclaration` | State variable |
| `Solidity::Parameter` | Function parameter |
| `Solidity::CallExpression` | Function call |
| `Solidity::MemberExpression` | Member access (a.b) |
| `Solidity::BinaryExpression` | Binary operation |
| `Solidity::AssignmentExpression` | Assignment (`=`) |
| `Solidity::AugmentedAssignmentExpression` | Augmented assignment (`+=`, `-=`, etc.) |
| `Solidity::UpdateExpression` | Increment/decrement (`++`, `--`) |
| `Solidity::UnaryExpression` | Unary ops (`delete`, `!`, `-`) |
| `Solidity::Identifier` | Identifier reference |
| `Solidity::NumberLiteral` | Numeric literal |
| `Solidity::StringLiteral` | String literal |

**Common Methods:**
| Method | Return | Description |
|--------|--------|-------------|
| `getParent()` | `AstNode` | Direct parent |
| `getParent+()` | `AstNode` | Transitive parent |
| `getChild(int)` | `AstNode` | Child at index |
| `getAChild()` | `AstNode` | Any child |
| `getAFieldOrChild()` | `AstNode` | Any field or child |
| `getValue()` | `string` | Text value (for terminals) |
| `toString()` | `string` | Node type name |
| `getLocation()` | `Location` | Source location |

### Control Flow Modules

#### codeql.solidity.controlflow.ControlFlowGraph

| Class/Predicate | Description |
|-----------------|-------------|
| `ControlFlowNode` | CFG node wrapper |
| `getASuccessor()` | Next node(s) |
| `getAPredecessor()` | Previous node(s) |
| `isReachable()` | Reachable from entry |
| `isEntryNode()` | Is function entry |
| `isExitNode()` | Is function exit |
| `getBasicBlock()` | Containing block |
| `getEnclosingFunction()` | Containing function |

#### codeql.solidity.controlflow.BasicBlocks

| Class/Predicate | Description |
|-----------------|-------------|
| `BasicBlock` | Basic block |
| `JoinBasicBlock` | Block with multiple predecessors |
| `getASuccessor()` | Successor block(s) |
| `getAPredecessor()` | Predecessor block(s) |
| `getNode(int)` | Node at index |
| `getANode()` | Any node in block |
| `getFirstNode()` | First node |
| `getLastNode()` | Last node |
| `getUniquePredecessor()` | Single predecessor (if any) |

#### codeql.solidity.controlflow.Dominance

| Predicate | Description |
|-----------|-------------|
| `dominates(dom, bb)` | dom dominates bb |
| `strictlyDominates(dom, bb)` | dom strictly dominates bb |
| `getImmediateDominator(bb)` | Immediate dominator |

### Data Flow Modules

#### codeql.solidity.dataflow.DataFlow

| Class/Predicate | Description |
|-----------------|-------------|
| `DataFlow::Node` | Data flow node |
| `asExpr()` | Underlying expression |
| `asParameter()` | Underlying parameter |
| `isMsgSender()` | Is msg.sender |
| `isMsgValue()` | Is msg.value |
| `isMsgData()` | Is msg.data |
| `isTxOrigin()` | Is tx.origin |
| `isBlockTimestamp()` | Is block.timestamp |

#### codeql.solidity.dataflow.TaintTracking

| Class/Predicate | Description |
|-----------------|-------------|
| `TaintTrackingConfiguration` | Abstract taint config |
| `isSource(node)` | Define taint sources |
| `isSink(node)` | Define taint sinks |
| `isSanitizer(node)` | Define sanitizers |
| `isAdditionalTaintStep(pred, succ)` | Custom taint steps |
| `hasFlow(source, sink)` | Check if taint flows |
| `hasFlowPath(source, sink)` | Check flow with path |

### Call Graph Modules

#### codeql.solidity.callgraph.CallResolution

| Predicate | Description |
|-----------|-------------|
| `resolveCall(call, target)` | Resolve any call |
| `resolveInternalCall(call, target)` | Same-contract call |
| `resolveInheritedCall(call, target)` | Inherited function call |
| `resolveSuperCall(call, target)` | super.func() call |
| `resolveThisCall(call, target)` | this.func() call |
| `resolveMemberCallToInterface(call, target)` | Interface-typed call |
| `resolveMemberCallFromParameter(call, target)` | Parameter-typed call |
| `isResolvable(call)` | Call can be resolved |
| `isUnresolved(call)` | Call cannot be resolved |
| `isBuiltinCall(call)` | Built-in function call |
| `isKnownLibraryCall(call, lib, func)` | Known library call |

#### codeql.solidity.callgraph.InheritanceGraph

| Predicate | Description |
|-----------|-------------|
| `getDirectBase(contract)` | Direct base contract |
| `getInheritanceChain(contract)` | All bases (transitive) |
| `inheritsFrom(contract, base)` | Inheritance check |
| `getInheritanceDepth(contract)` | Inheritance depth |
| `isVirtualFunction(func)` | Has virtual keyword |
| `isOverrideFunction(func)` | Has override keyword |
| `getOverriddenFunction(func)` | Overridden function |
| `resolveVirtualCall(contract, name)` | Most derived impl |
| `hasDiamondInheritance(contract)` | Diamond pattern |
| `resolveDiamondFunction(contract, name)` | Diamond resolution |
| `hasMultipleInheritance(contract)` | Multiple bases |
| `getAllFunctions(contract)` | All available functions |

#### codeql.solidity.callgraph.ExternalCalls

| Predicate | Description |
|-----------|-------------|
| `isLowLevelCall(call)` | Any low-level call |
| `isCall(call)` | .call() |
| `isDelegateCall(call)` | .delegatecall() |
| `isStaticCall(call)` | .staticcall() |
| `isContractReferenceCall(call)` | High-level contract call |
| `isEtherTransfer(call)` | .transfer() or .send() |
| `isThisCall(call)` | this.func() external self-call |

#### ReentrancyPatterns.ql Predicates

| Predicate | Description |
|-----------|-------------|
| `directlyModifiesState(node, contract, varName)` | Node modifies state variable (5 mutation types) |
| `functionModifiesState(func, contract, varName)` | Function transitively modifies state via callgraph |
| `isInternalCall(call)` | Call is internal (not external/this/transfer) |
| `isExternalCall(call)` | Call crosses contract boundary |
| `isStateVarIdentifier(id, contract, varName)` | Identifier refers to state variable |
| `executesAfter(earlier, later, func)` | CFG reachability (`successor+`) within `func` |
| `functionMakesExternalCall(func)` | Function transitively performs an external call |
| `getModifierName(mod)` | Modifier name — the `Identifier` child, not `getValue()` |
| `hasReentrancyGuard(func)` | Function has reentrancy guard modifier |

## Query Metadata Reference

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `@name` | Human-readable name | `Reentrancy vulnerability` |
| `@description` | Issue description | `External call before state update` |
| `@id` | Unique identifier | `solidity/reentrancy` |
| `@kind` | Result type | `problem`, `path-problem`, `metric` |

### Optional Fields

| Field | Values | Description |
|-------|--------|-------------|
| `@problem.severity` | error, warning, recommendation | Issue severity |
| `@precision` | low, medium, high, very-high | False positive rate |
| `@security-severity` | 0.0-10.0 | CVSS-like score |
| `@tags` | space-separated | Categories, CWE refs |

### Tag Format

| Type | Format | Example |
|------|--------|---------|
| Category | lowercase | `security` |
| CWE | `external/cwe/cwe-NNN` | `external/cwe/cwe-841` |
| Domain | lowercase | `solidity` |

## CWE Mapping Table

| Vulnerability | CWE | Tag | Severity |
|--------------|-----|-----|----------|
| Reentrancy | 841 | `external/cwe/cwe-841` | High |
| Access Control | 284 | `external/cwe/cwe-284` | High |
| Integer Overflow | 190 | `external/cwe/cwe-190` | Medium |
| Integer Underflow | 191 | `external/cwe/cwe-191` | Medium |
| Unchecked Return | 252 | `external/cwe/cwe-252` | Medium |
| tx.origin Auth | 477 | `external/cwe/cwe-477` | High |
| Race Condition | 362 | `external/cwe/cwe-362` | Medium |
| Untrusted Input | 829 | `external/cwe/cwe-829` | High |
| Uninitialized Variable | 457 | `external/cwe/cwe-457` | High |
| Resource Consumption | 400 | `external/cwe/cwe-400` | Medium |
| Input Validation | 20 | `external/cwe/cwe-20` | High |
| Improper Auth | 287 | `external/cwe/cwe-287` | High |
| Denial of Service | 730 | `external/cwe/cwe-730` | Medium |
| Timestamp Dependence | 829 | `external/cwe/cwe-829` | Low |
| Weak Randomness | 330 | `external/cwe/cwe-330` | Medium |

## Predicate Naming Conventions

| Pattern | Usage | Example |
|---------|-------|---------|
| `is*` | Boolean check | `isPublic()` |
| `has*` | Existence check | `hasModifier()` |
| `get*` | Single result | `getName()` |
| `getA*` | Multiple results | `getAFunction()` |
| `getAn*` | Multiple (vowel) | `getAnArgument()` |

## Common Error Codes

| Error | Cause | Solution |
|-------|-------|----------|
| No results | Query too restrictive | Add debug selects |
| Cartesian product | Unconnected variables | Add binding constraints |
| Non-monotonic | Circular definitions | Use bounded recursion |
| Memory limit | Large result set | Add early filters |
| Timeout | Performance issue | Optimize predicate order |

## Troubleshooting

### No Results
1. Check database contents: `codeql database interpret db`
2. Verify imports are correct
3. Add intermediate `select` statements
4. Use Quick Eval on subexpressions

### Query Too Slow
1. Add strategic barriers in taint config
2. Use local flow before global
3. Filter before expensive predicates
4. Profile with `--evaluator-log`

### Compilation Errors
1. Check QL syntax (2-space indent, no tabs)
2. Verify module import paths
3. Check predicate signatures match
4. Validate newtype definitions

## Built-in Functions Reference

```ql
// Builtins recognized by CallResolution::isBuiltinCall
require, assert, revert,
keccak256, sha256, ripemd160,
ecrecover, addmod, mulmod,
selfdestruct, blockhash,
gasleft, address, payable

// Member builtins (abi.*, block.*, msg.*, tx.*, type.*)
abi.encode, abi.encodePacked, abi.decode,
block.timestamp, block.number, block.coinbase,
msg.sender, msg.value, msg.data, msg.sig,
tx.origin, tx.gasprice,
type(X).name, type(X).creationCode
```

## Library Stubs Reference

Supported OpenZeppelin libraries:
- **SafeMath**: add, sub, mul, div, mod
- **Address**: isContract, sendValue, functionCall
- **SafeERC20**: safeTransfer, safeTransferFrom, safeApprove
- **ECDSA**: recover, toEthSignedMessageHash
- **Strings**: toString, toHexString

## File Locations

| File | Purpose |
|------|---------|
| `ql/lib/codeql/solidity/ast/` | AST classes |
| `ql/lib/codeql/solidity/controlflow/` | CFG analysis |
| `ql/lib/codeql/solidity/dataflow/` | Data flow |
| `ql/lib/codeql/solidity/callgraph/` | Call resolution |
| `ql/lib/codeql/solidity/interprocedural/` | Cross-function |
| `queries/analysis/` | Example queries |
| `tests/fixtures/` | Test contracts |
