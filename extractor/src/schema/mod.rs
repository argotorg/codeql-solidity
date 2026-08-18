//! Schema generation module.
//!
//! Generates the CodeQL database schema (.dbscheme) from the tree-sitter grammar.

use anyhow::{Context, Result};
use serde::Deserialize;
// BTreeMap, not HashMap: field iteration order determines the order of the
// generated relations, and CodeQL keys database compatibility off the dbscheme
// text. Randomized iteration would invalidate every existing database on each
// regeneration.
use std::collections::{BTreeMap, HashSet};
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
    #[serde(rename = "multiple")]
    _multiple: bool,
    #[serde(rename = "required")]
    _required: bool,
    types: Vec<TypeRef>,
}

#[derive(Debug, Deserialize)]
struct ChildInfo {
    #[serde(rename = "multiple")]
    _multiple: bool,
    #[serde(rename = "required")]
    _required: bool,
    types: Vec<TypeRef>,
}

#[derive(Debug, Deserialize)]
struct TypeRef {
    #[serde(rename = "type")]
    type_name: String,
    named: bool,
}

#[derive(Debug, Deserialize)]
struct SubtypeInfo {
    #[serde(rename = "type")]
    _type_name: String,
    #[serde(rename = "named")]
    _named: bool,
}

/// Generate the database schema file.
pub fn generate(output_path: &Path) -> Result<()> {
    // Get node types from tree-sitter-solidity
    let node_types_json = tree_sitter_solidity::NODE_TYPES;
    let node_types: Vec<NodeType> =
        serde_json::from_str(node_types_json).context("Failed to parse node types JSON")?;

    let schema = generate_dbscheme(&node_types);

    // Ensure parent directory exists
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }

    fs::write(output_path, schema).context("Failed to write schema file")?;

    Ok(())
}

/// Generate the .dbscheme content.
fn generate_dbscheme(node_types: &[NodeType]) -> String {
    let mut schema = String::new();

    // Header
    schema.push_str("// CodeQL database schema for Solidity\n");
    schema.push_str("// Automatically generated from tree-sitter grammar; do not edit\n\n");

    // Standard CodeQL infrastructure tables
    schema.push_str(&generate_infrastructure_tables());
    schema.push('\n');

    // Collect all named node types
    let named_types: Vec<&NodeType> = node_types.iter().filter(|n| n.named).collect();

    // Collect all anonymous token types (operators, punctuation, keywords)
    let anon_types = collect_anonymous_types(node_types);

    // Generate union type for all AST nodes (named + anonymous tokens)
    schema.push_str(&generate_ast_node_union(&named_types, &anon_types));
    schema.push('\n');

    // Generate tables for each node type
    for node in &named_types {
        schema.push_str(&generate_node_tables(node));
        schema.push('\n');
    }

    // Generate location and parent tables
    schema.push_str(&generate_location_tables());
    schema.push('\n');

    // Generate token info table
    schema.push_str(&generate_token_tables());

    // Generate folded constant-value table
    schema.push_str(&generate_const_value_tables());

    // Generate declaration and type-shape tables
    schema.push_str(&generate_decl_info_tables());

    schema
}

/// Collect all anonymous token types referenced by fields.
fn collect_anonymous_types(node_types: &[NodeType]) -> HashSet<String> {
    let mut anon_types = HashSet::new();

    for node in node_types {
        // Check fields for anonymous types
        for field_info in node.fields.values() {
            for type_ref in &field_info.types {
                if !type_ref.named {
                    anon_types.insert(type_ref.type_name.clone());
                }
            }
        }
        // Check children for anonymous types
        if let Some(children) = &node.children {
            for type_ref in &children.types {
                if !type_ref.named {
                    anon_types.insert(type_ref.type_name.clone());
                }
            }
        }
    }

    anon_types
}

/// Generate standard CodeQL infrastructure tables.
fn generate_infrastructure_tables() -> String {
    r#"// ============================================================
// Standard CodeQL infrastructure
// ============================================================

// File and folder tracking
@container = @file | @folder

folders(
    unique int id: @folder,
    string name: string ref
);

files(
    unique int id: @file,
    string name: string ref
);

containerparent(
    int parent: @container ref,
    unique int child: @container ref
);

// Source locations
locations_default(
    unique int id: @location_default,
    int file: @file ref,
    int beginLine: int ref,
    int beginColumn: int ref,
    int endLine: int ref,
    int endColumn: int ref
);

@location = @location_default

// Diagnostics
diagnostics(
    unique int id: @diagnostic,
    int severity: int ref,
    string error_tag: string ref,
    string error_message: string ref,
    string full_error_message: string ref,
    int location: @location_default ref
);

// Source location prefix for URL generation
sourceLocationPrefix(
    string prefix: string ref
);

"#
    .to_string()
}

/// Generate the union type for all AST nodes.
fn generate_ast_node_union(node_types: &[&NodeType], _anon_types: &HashSet<String>) -> String {
    let mut result = String::new();

    result.push_str("// ============================================================\n");
    result.push_str("// AST Node Types\n");
    result.push_str("// ============================================================\n\n");

    // Generate individual type definitions for named types
    let mut type_names: Vec<String> = node_types
        .iter()
        .map(|n| format!("@solidity_{}", normalize_name(&n.type_name)))
        .collect();

    // Add generic token type for ALL anonymous tokens (operators, keywords, etc.)
    // This is simpler than trying to enumerate every possible token
    type_names.push("@solidity_token".to_string());

    // Generate the union
    result.push_str("@solidity_ast_node = ");
    result.push_str(&type_names.join("\n    | "));
    result.push_str("\n;\n\n");

    // Generate placeholder tables for named types
    for node in node_types {
        let name = normalize_name(&node.type_name);
        result.push_str(&format!(
            "solidity_{}_def(\n    unique int id: @solidity_{}\n);\n\n",
            name, name
        ));
    }

    // Generate placeholder table for the generic token type
    result.push_str("// Generic token type for all anonymous tokens (operators, keywords, punctuation)\nsolidity_token_def(\n    unique int id: @solidity_token\n);\n\n");

    result
}

/// Generate tables for a specific node type.
fn generate_node_tables(node: &NodeType) -> String {
    let mut result = String::new();
    let name = normalize_name(&node.type_name);

    // Generate field tables
    for field_name in node.fields.keys() {
        let field_normalized = normalize_name(field_name);

        // Always use indexed table (3 columns) for consistency with extractor
        // Even singular fields get index 0
        result.push_str(&format!(
            "#keyset[id, index]\nsolidity_{name}_{field}(\n    int id: @solidity_{name} ref,\n    int index: int ref,\n    int child: @solidity_ast_node ref\n);\n\n",
            name = name,
            field = field_normalized
        ));
    }

    // No per-type child table: generic children live in the single
    // `solidity_ast_node_child` relation (see generate_location_tables), so
    // `getChild(i)` has one definition and one indexing rule for every node type.

    result
}

/// Generate location and parent relationship tables.
fn generate_location_tables() -> String {
    r#"// ============================================================
// AST Node Relationships
// ============================================================

// Location mapping for AST nodes
solidity_ast_node_location(
    unique int node: @solidity_ast_node ref,
    int loc: @location_default ref
);

// Parent-child relationships with index. `index` counts *every* child, including
// anonymous tokens and comments, and is what `getParentIndex()` reports.
#keyset[parent, index]
solidity_ast_node_parent(
    int child: @solidity_ast_node ref,
    int parent: @solidity_ast_node ref,
    int index: int ref
);

// Semantic children: named, non-extra, and not reachable through a field
// accessor, numbered contiguously in source order. This is what `getChild(i)`
// reads, so index 0 of a block is its first statement rather than its `{`.
#keyset[id, index]
solidity_ast_node_child(
    int id: @solidity_ast_node ref,
    int index: int ref,
    int child: @solidity_ast_node ref
);

// AST node type info (kind_id from tree-sitter)
solidity_ast_node_info(
    unique int node: @solidity_ast_node ref,
    int kind_id: int ref
);

"#
    .to_string()
}

/// Generate token info tables.
fn generate_token_tables() -> String {
    r#"// ============================================================
// Token Information
// ============================================================

// Token value and kind for terminal nodes
solidity_tokeninfo(
    unique int id: @solidity_ast_node ref,
    int kind: int ref,
    string value: string ref
);

"#
    .to_string()
}

/// Generate the folded constant-value table.
fn generate_const_value_tables() -> String {
    r#"// ============================================================
// Folded Constant Values
// ============================================================

// Compile-time integer value of a constant expression, as a canonical decimal
// string (may be negative). Values can exceed 64 bits (e.g. a `layout at` slot
// base near 2**256), so they are stored as strings rather than ints. Only
// emitted for expressions the extractor can fold from literals.
solidity_const_value(
    unique int node: @solidity_ast_node ref,
    string value: string ref
);

"#
    .to_string()
}

/// Generate the declaration and type-shape tables.
fn generate_decl_info_tables() -> String {
    r#"// ============================================================
// Declarations and Type Shapes
// ============================================================

// What a `type_name` ultimately names, after peeling any array levels.
// `base` is a primitive name (`bytes`, `uint256`) or a dotted user-defined name,
// and is empty for mapping and function types, which name no single base.
// `kind` is one of primitive | userdefined | mapping | function | other.
// Emitted so queries need not peel `type_name(type_name(primitive_type), [, ])`
// by hand, nor know that a mapping's first `primitive_type` child is its *key*.
solidity_type_info(
    unique int node: @solidity_ast_node ref,
    string base: string ref,
    string kind: string ref,
    int array_dims: int ref
);

// A named value declaration. `kind` is one of local | parameter |
// returnparameter | statevar | constant | structmember | eventparameter |
// errorparameter. `data_location` is the location that *applies* to the
// declaration rather than the one that was written: a state variable is
// `storage` with no `storage` token in the source, and a `constant` or
// `immutable` occupies no slot and so has none. `name` is empty for an unnamed
// return parameter.
solidity_declaration(
    unique int node: @solidity_ast_node ref,
    string name: string ref,
    string kind: string ref,
    string data_location: string ref
);

"#
    .to_string()
}

/// Normalize a name for use in the schema.
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
    fn test_normalize_name() {
        assert_eq!(normalize_name("source_file"), "source_file");
        assert_eq!(normalize_name("binary-expression"), "binary_expression");
        assert_eq!(normalize_name("+="), "pluseq");
    }

    #[test]
    fn test_generate_schema() {
        let node_types_json = tree_sitter_solidity::NODE_TYPES;
        let node_types: Vec<NodeType> = serde_json::from_str(node_types_json).unwrap();
        let schema = generate_dbscheme(&node_types);

        // Check that basic structure is present
        assert!(schema.contains("@solidity_ast_node"));
        assert!(schema.contains("locations_default"));
        assert!(schema.contains("files"));
        assert!(schema.contains("folders"));
    }
}
