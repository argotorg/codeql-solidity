//! Code generation module for QL libraries.
//!
//! Generates TreeSitter.qll from the tree-sitter grammar.

use anyhow::{Context, Result};
use serde::Deserialize;
// BTreeMap, not HashMap: see the note in schema/mod.rs — generated output must
// be byte-stable across runs.
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// A node type from tree-sitter's node-types.json.
#[derive(Debug, Deserialize)]
struct NodeType {
    #[serde(rename = "type")]
    type_name: String,
    named: bool,
    #[serde(default)]
    fields: BTreeMap<String, FieldInfo>,
    #[serde(default)]
    children: Option<ChildInfo>,
    #[serde(default)]
    _subtypes: Vec<SubtypeInfo>,
}

#[derive(Debug, Deserialize)]
struct FieldInfo {
    multiple: bool,
    #[serde(rename = "required")]
    _required: bool,
    #[serde(rename = "types")]
    _types: Vec<TypeRef>,
}

#[derive(Debug, Deserialize)]
struct ChildInfo {
    #[serde(rename = "multiple")]
    _multiple: bool,
    #[serde(rename = "required")]
    _required: bool,
    #[serde(rename = "types")]
    _types: Vec<TypeRef>,
}

#[derive(Debug, Deserialize)]
struct TypeRef {
    #[serde(rename = "type")]
    _type_name: String,
    #[serde(rename = "named")]
    _named: bool,
}

#[derive(Debug, Deserialize)]
struct SubtypeInfo {
    #[serde(rename = "type")]
    _type_name: String,
    #[serde(rename = "named")]
    _named: bool,
}

/// Generate the TreeSitter.qll file.
pub fn generate(output_path: &Path) -> Result<()> {
    // Get node types from tree-sitter-solidity
    let node_types_json = tree_sitter_solidity::NODE_TYPES;
    let node_types: Vec<NodeType> =
        serde_json::from_str(node_types_json).context("Failed to parse node types JSON")?;

    let qll = generate_treesitter_qll(&node_types);

    // Ensure parent directory exists
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(output_path, qll).context("Failed to write QLL file")?;

    Ok(())
}

/// Generate the TreeSitter.qll content.
fn generate_treesitter_qll(node_types: &[NodeType]) -> String {
    let mut qll = String::new();

    // Header
    qll.push_str("/**\n");
    qll.push_str(" * CodeQL library for Solidity AST (tree-sitter wrapper classes)\n");
    qll.push_str(" * Automatically generated from tree-sitter grammar; do not edit\n");
    qll.push_str(" */\n\n");

    // Basic type definitions for locations and files
    qll.push_str(&generate_basic_types());

    // Module
    qll.push_str("/** Module containing tree-sitter wrapper classes */\n");
    qll.push_str("module Solidity {\n");

    // Base AstNode class
    qll.push_str(&generate_base_class());

    // Generate class for each named node type
    let named_types: Vec<&NodeType> = node_types.iter().filter(|n| n.named).collect();

    for node in named_types {
        qll.push_str(&generate_node_class(node));
    }

    qll.push_str("}\n");

    qll
}

/// Generate basic infrastructure types (Location, File, etc.)
fn generate_basic_types() -> String {
    r#"// Basic infrastructure types

/** A source file */
class File extends @file {
    /** Gets the name/path of this file */
    string getName() { files(this, result) }

    /** Gets a string representation */
    string toString() { result = this.getName() }

    /** Holds if this file is at `filepath`. */
    predicate hasLocationInfo(string filepath, int startline, int startcolumn, int endline, int endcolumn) {
        filepath = this.getName() and
        startline = 0 and startcolumn = 0 and endline = 0 and endcolumn = 0
    }
}

/** A source location */
class Location extends @location_default {
    /** Gets the file containing this location */
    File getFile() { locations_default(this, result, _, _, _, _) }

    /** Gets the start line (1-based) */
    int getStartLine() { locations_default(this, _, result, _, _, _) }

    /** Gets the start column (1-based) */
    int getStartColumn() { locations_default(this, _, _, result, _, _) }

    /** Gets the end line (1-based) */
    int getEndLine() { locations_default(this, _, _, _, result, _) }

    /** Gets the end column (1-based) */
    int getEndColumn() { locations_default(this, _, _, _, _, result) }

    /** Gets a string representation */
    string toString() {
        result = this.getFile().getName() + ":" + this.getStartLine().toString()
    }

    /**
     * Holds if this location spans the given lines and columns of `filepath`.
     * `codeql database analyze` drops any alert whose entity does not resolve
     * through this predicate, so every selectable class needs it.
     */
    predicate hasLocationInfo(string filepath, int startline, int startcolumn, int endline, int endcolumn) {
        exists(File f |
            locations_default(this, f, startline, startcolumn, endline, endcolumn) and
            filepath = f.getName()
        )
    }
}

"#
    .to_string()
}

/// Generate the base AstNode class.
fn generate_base_class() -> String {
    r#"
    /** Base class for all Solidity AST nodes */
    class AstNode extends @solidity_ast_node {
        /** Gets a string representation of this node */
        string toString() { result = this.getAPrimaryQlClass() }

        /** Gets the primary QL class name for this node */
        string getAPrimaryQlClass() { result = "AstNode" }

        /** Gets the location of this node */
        Location getLocation() {
            solidity_ast_node_location(this, result)
        }

        /** Gets the token text value of this node (for leaf nodes like identifiers) */
        string getValue() {
            solidity_tokeninfo(this, _, result)
        }

        /**
         * Gets the folded compile-time integer value of this expression, as a
         * canonical decimal string, if it is a constant literal-arithmetic
         * expression. Values may exceed 64 bits (e.g. a `layout at` slot base near
         * 2**256), hence the string representation. Use `BigIntComparison` (in the
         * AST library) to compare such values numerically.
         */
        string getConstantValue() {
            solidity_const_value(this, result)
        }

        /**
         * Gets the base type this `type_name` ultimately names, after peeling any
         * array levels: a primitive name (`bytes`, `uint256`) or a dotted
         * user-defined name. Has no result for mapping and function types, which
         * name no single base — check `getTypeKind()` to tell those apart from a
         * node that is not a type at all.
         */
        string getBaseType() {
            solidity_type_info(this, result, _, _) and result != ""
        }

        /**
         * Gets the kind of type this `type_name` names: one of `primitive`,
         * `userdefined`, `mapping`, `function` or `other`.
         */
        string getTypeKind() {
            solidity_type_info(this, _, result, _)
        }

        /**
         * Gets the number of `[]` levels this `type_name` applies to its base
         * type; 0 for a non-array type. `bytes[][]` yields 2.
         */
        int getArrayDims() {
            solidity_type_info(this, _, _, result)
        }

        /**
         * Gets the name this declaration binds. Has no result for an unnamed
         * return parameter, or for a node that is not a declaration.
         */
        string getDeclarationName() {
            solidity_declaration(this, result, _, _) and result != ""
        }

        /**
         * Gets the kind of declaration this node is: one of `local`, `parameter`,
         * `returnparameter`, `statevar`, `constant`, `structmember`,
         * `eventparameter` or `errorparameter`.
         */
        string getDeclarationKind() {
            solidity_declaration(this, _, result, _)
        }

        /**
         * Gets the data location that applies to this declaration — `memory`,
         * `storage`, `calldata` or `transient`. This is the effective location,
         * not merely the written one: a state variable is `storage` with no
         * `storage` token in the source. Has no result where none applies (a value
         * type, a `constant`/`immutable`, or a struct member, whose location comes
         * from the value it belongs to).
         */
        string getDataLocation() {
            solidity_declaration(this, _, _, result) and result != ""
        }

        /** Gets the parent of this node, if any */
        AstNode getParent() {
            solidity_ast_node_parent(this, result, _)
        }

        /** Gets the index of this node in its parent's children */
        int getParentIndex() {
            solidity_ast_node_parent(this, _, result)
        }

        /** Gets a child of this node */
        AstNode getAChild() {
            solidity_ast_node_parent(result, this, _)
        }

        /**
         * Gets the i-th semantic child of this node.
         *
         * Semantic children are the named, non-extra children that are not
         * reachable through a field accessor, numbered contiguously in source
         * order — so index 0 of a block is its first statement, not its `{`.
         * Use `getParentIndex()` for a node's raw position among all children.
         */
        AstNode getChild(int i) {
            solidity_ast_node_child(this, i, result)
        }

        /** Gets the number of children */
        int getNumChildren() {
            result = count(this.getAChild())
        }

        /** Gets any descendant of this node (including itself) */
        AstNode getADescendant() {
            result = this
            or
            result = this.getAChild().getADescendant()
        }

        /** Gets any field or child of this node */
        AstNode getAFieldOrChild() {
            result = this.getAChild()
        }

        /** Gets the file containing this node */
        File getFile() {
            result = this.getLocation().getFile()
        }

        /** Holds if this node is at the given position in `filepath`. */
        predicate hasLocationInfo(string filepath, int startline, int startcolumn, int endline, int endcolumn) {
            this.getLocation().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
        }
    }

"#
    .to_string()
}

/// Generate a class for a specific node type.
fn generate_node_class(node: &NodeType) -> String {
    let mut class = String::new();

    let class_name = to_pascal_case(&node.type_name);
    let db_type = format!("@solidity_{}", normalize_name(&node.type_name));

    // Class documentation
    class.push_str(&format!(
        "    /** A `{}` node in the AST */\n",
        node.type_name
    ));

    // Class definition
    class.push_str(&format!(
        "    class {} extends {}, AstNode {{\n",
        class_name, db_type
    ));

    // Override toString and getAPrimaryQlClass
    class.push_str(&format!(
        "        override string getAPrimaryQlClass() {{ result = \"{}\" }}\n\n",
        class_name
    ));

    // Generate field accessors
    for (field_name, field_info) in &node.fields {
        class.push_str(&generate_field_accessor(
            &node.type_name,
            field_name,
            field_info,
        ));
    }

    // Override getAFieldOrChild
    if !node.fields.is_empty() || node.children.is_some() {
        class.push_str(&generate_get_a_field_or_child(node));
    }

    class.push_str("    }\n\n");

    class
}

/// Generate accessor for a field.
fn generate_field_accessor(node_type: &str, field_name: &str, field_info: &FieldInfo) -> String {
    let node_normalized = normalize_name(node_type);
    let field_normalized = normalize_name(field_name);

    // Rename fields that conflict with base class methods
    let accessor_name = if field_name == "location" {
        "storage_location".to_string() // Avoid conflict with getLocation()
    } else if field_name == "value" {
        "field_value".to_string() // Avoid conflict with getValue()
    } else {
        field_name.to_string()
    };
    let getter_name = format!("get{}", to_pascal_case(&accessor_name));
    let table = format!("solidity_{}_{}", node_normalized, field_normalized);

    if field_info.multiple {
        format!(
            "        /** Gets the {field} at index `i` */\n        AstNode {getter}(int i) {{ {table}(this, i, result) }}\n\n        /** Gets any {field} */\n        AstNode getA{pascal}() {{ {table}(this, _, result) }}\n\n        /** Gets the number of {field}s */\n        int getNum{pascal}s() {{ result = count(this.getA{pascal}()) }}\n\n",
            field = accessor_name,
            getter = getter_name,
            pascal = to_pascal_case(&accessor_name),
            table = table
        )
    } else {
        // Singular fields also use indexed tables now (with index 0)
        format!(
            "        /** Gets the {field} */\n        AstNode {getter}() {{ {table}(this, 0, result) }}\n\n",
            field = accessor_name,
            getter = getter_name,
            table = table
        )
    }
}

/// Generate getAFieldOrChild override.
fn generate_get_a_field_or_child(node: &NodeType) -> String {
    let mut result = String::new();
    result.push_str("        override AstNode getAFieldOrChild() {\n");
    result.push_str("            result = super.getAFieldOrChild()");

    for (field_name, field_info) in &node.fields {
        // Use renamed accessors for fields that conflict with base class methods
        let accessor_name = if field_name == "location" {
            "storage_location".to_string()
        } else if field_name == "value" {
            "field_value".to_string()
        } else {
            field_name.to_string()
        };

        if field_info.multiple {
            result.push_str(&format!(
                "\n            or result = this.getA{}()",
                to_pascal_case(&accessor_name)
            ));
        } else {
            result.push_str(&format!(
                "\n            or result = this.get{}()",
                to_pascal_case(&accessor_name)
            ));
        }
    }

    result.push_str("\n        }\n\n");
    result
}

/// Convert a name to PascalCase.
fn to_pascal_case(name: &str) -> String {
    name.split(['_', '-'])
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => first.to_uppercase().chain(chars).collect(),
            }
        })
        .collect()
}

/// Normalize a name for use in identifiers.
fn normalize_name(name: &str) -> String {
    name.replace('-', "_")
        .replace('+', "plus")
        .replace('*', "star")
        .replace('/', "slash")
        .replace('%', "percent")
        .replace('&', "amp")
        .replace('|', "pipe")
        .replace('^', "caret")
        .replace('!', "bang")
        .replace('=', "eq")
        .replace('<', "lt")
        .replace('>', "gt")
        .replace('.', "dot")
        .replace(',', "comma")
        .replace(';', "semi")
        .replace(':', "colon")
        .replace('(', "lparen")
        .replace(')', "rparen")
        .replace('[', "lbracket")
        .replace(']', "rbracket")
        .replace('{', "lbrace")
        .replace('}', "rbrace")
        .replace('?', "question")
        .replace('~', "tilde")
        .replace('@', "at")
        .replace('#', "hash")
        .replace('$', "dollar")
        .replace('`', "backtick")
        .replace('\'', "squote")
        .replace('"', "dquote")
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_to_pascal_case() {
        assert_eq!(to_pascal_case("source_file"), "SourceFile");
        assert_eq!(to_pascal_case("binary-expression"), "BinaryExpression");
        assert_eq!(to_pascal_case("contract"), "Contract");
    }

    #[test]
    fn test_normalize_name() {
        assert_eq!(normalize_name("source_file"), "source_file");
        assert_eq!(normalize_name("binary-expression"), "binary_expression");
    }

    #[test]
    fn test_generate_qll() {
        let node_types_json = tree_sitter_solidity::NODE_TYPES;
        let node_types: Vec<NodeType> = serde_json::from_str(node_types_json).unwrap();
        let qll = generate_treesitter_qll(&node_types);

        // Check that basic structure is present
        assert!(qll.contains("module Solidity"));
        assert!(qll.contains("class AstNode"));
        assert!(qll.contains("getLocation()"));
        assert!(qll.contains("getParent()"));
    }
}
