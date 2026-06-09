//! Core extractor that converts tree-sitter AST to TRAP.
//!
//! This module traverses the tree-sitter parse tree and emits
//! relational tuples for each node.

use anyhow::{Context, Result};
use std::path::Path;
use tracing::warn;
use tree_sitter::{Node, Parser, Tree};

use crate::extraction::constfold;
use crate::trap::{Compression, Label, TrapValue, TrapWriter};

/// Extractor for a single Solidity file.
pub struct Extractor {
    /// Path to the source file
    file_path: String,
    /// TRAP writer
    trap: TrapWriter,
    /// File label in the database
    file_label: Option<Label>,
    /// Count of tree-sitter ERROR/MISSING nodes dropped during this file's
    /// extraction (i.e. the file did not parse cleanly under the grammar).
    error_nodes_dropped: usize,
}

impl Extractor {
    /// Create a new extractor for the given file.
    pub fn new(file_path: &str) -> Self {
        Extractor {
            file_path: file_path.to_string(),
            trap: TrapWriter::new(file_path),
            file_label: None,
            error_nodes_dropped: 0,
        }
    }

    /// Extract the given source code.
    pub fn extract(&mut self, source: &str) -> Result<()> {
        // Initialize tree-sitter parser
        let mut parser = Parser::new();
        let language: tree_sitter::Language = tree_sitter_solidity::LANGUAGE.into();
        parser
            .set_language(&language)
            .map_err(|e| anyhow::anyhow!("Failed to set tree-sitter language: {:?}", e))?;

        // Parse source code
        let tree = parser
            .parse(source, None)
            .context("Failed to parse source code")?;

        // Emit file entry
        self.file_label = Some(self.trap.emit_file(&self.file_path));

        // Emit folder hierarchy
        self.emit_folder_hierarchy()?;

        // Extract AST
        self.extract_tree(&tree, source)?;

        // Surface files that did not parse cleanly: their ERROR/MISSING subtrees
        // were dropped, so extraction is partial for this file.
        if self.error_nodes_dropped > 0 {
            warn!(
                "{}: dropped {} unparseable AST node(s) (ERROR/MISSING); extraction is partial",
                self.file_path, self.error_nodes_dropped
            );
        }

        Ok(())
    }

    /// Write TRAP to file.
    pub fn write_trap(&self, path: &Path, compression: Compression) -> Result<()> {
        self.trap
            .write_to_file(path, compression)
            .context("Failed to write TRAP file")
    }

    /// Emit folder hierarchy for the file.
    fn emit_folder_hierarchy(&mut self) -> Result<()> {
        let path = Path::new(&self.file_path);
        let mut folders = Vec::new();

        // Collect all parent directories
        let mut current = path.parent();
        while let Some(dir) = current {
            if !dir.as_os_str().is_empty() {
                folders.push(dir.to_string_lossy().to_string());
            }
            current = dir.parent();
        }

        // Emit folders from root to leaf
        folders.reverse();
        let mut parent_label: Option<Label> = None;

        for folder in &folders {
            let folder_label = self.trap.emit_folder(folder);

            // Link to parent
            if let Some(parent) = &parent_label {
                self.trap.emit(
                    "containerparent",
                    vec![
                        TrapValue::Label(parent.clone()),
                        TrapValue::Label(folder_label.clone()),
                    ],
                );
            }

            parent_label = Some(folder_label);
        }

        // Link file to its parent folder
        if let (Some(parent), Some(file)) = (&parent_label, &self.file_label) {
            self.trap.emit(
                "containerparent",
                vec![
                    TrapValue::Label(parent.clone()),
                    TrapValue::Label(file.clone()),
                ],
            );
        }

        Ok(())
    }

    /// Extract the parse tree to TRAP.
    fn extract_tree(&mut self, tree: &Tree, source: &str) -> Result<()> {
        let root = tree.root_node();
        // Result ignored: returns None if the root itself is an ERROR node (a
        // catastrophically unparseable file), in which case nothing is emitted.
        self.extract_node(root, source, None)?;
        Ok(())
    }

    /// Extract a single node and its children recursively.
    ///
    /// Returns `None` if the node is a tree-sitter synthetic ERROR / MISSING node
    /// (and is therefore skipped along with its whole subtree), otherwise
    /// `Some(label)` for the emitted node.
    fn extract_node(
        &mut self,
        node: Node,
        source: &str,
        parent_info: Option<(Label, usize)>,
    ) -> Result<Option<Label>> {
        // Never emit tree-sitter's synthetic ERROR / zero-width MISSING nodes.
        // Their kind is "ERROR", which normalize_kind lowercases to "error" and
        // emits as `solidity_error_def` — a relation absent from the dbscheme
        // (generated from the grammar's node-types.json, which has no synthetic
        // ERROR node), which aborts the entire TRAP import. They can appear
        // anywhere, including as the parse-tree ROOT of a badly-broken file (which
        // bypasses the child loop below), so the guard lives here in the single
        // path every node flows through. Dropping the node drops its whole subtree;
        // the rest of the file still extracts.
        if node.is_error() || node.is_missing() {
            self.error_nodes_dropped += 1;
            return Ok(None);
        }

        // Generate label for this node
        let label = self.trap.fresh_label();

        // Get node kind (type)
        let kind = node.kind();
        let kind_id = node.kind_id();

        // Emit _def table for this node
        // Named nodes use their specific type, anonymous tokens use generic token type
        let table_name = if node.is_named() {
            format!("solidity_{}_def", normalize_kind(kind))
        } else {
            // All anonymous tokens (operators, keywords, punctuation) use generic token type
            "solidity_token_def".to_string()
        };
        self.trap
            .emit(&table_name, vec![TrapValue::Label(label.clone())]);

        // Emit AST node info (for all nodes including anonymous)
        self.emit_ast_node_info(&label, kind_id)?;

        // Emit location
        self.emit_node_location(&label, &node)?;

        // Emit parent relationship
        if let Some((parent_label, index)) = parent_info {
            self.trap.emit(
                "solidity_ast_node_parent",
                vec![
                    TrapValue::Label(label.clone()),
                    TrapValue::Label(parent_label),
                    TrapValue::UInt(index as u64),
                ],
            );
        }

        // Emit token info for terminal nodes (both named and anonymous)
        if node.child_count() == 0 {
            let text = node.utf8_text(source.as_bytes()).unwrap_or("");
            self.emit_token_info(&label, kind_id as u32, text)?;
        }

        // Emit the folded constant value for literal arithmetic expressions, so
        // queries can compare values (e.g. a `layout at <expr>` slot base) without
        // re-implementing 256-bit arithmetic in QL. `node` is already the
        // wrapper-resolved node, so `label` is exactly what queries observe.
        if let Some(value) = constfold::fold(node, source) {
            self.emit_const_value(&label, &value.to_string())?;
        }

        // Process all children and emit field relationships
        self.extract_children_and_fields(&label, node, source)?;

        Ok(Some(label))
    }

    /// Extract all children and emit field relationships.
    fn extract_children_and_fields(
        &mut self,
        parent_label: &Label,
        node: Node,
        source: &str,
    ) -> Result<()> {
        use std::collections::HashMap;
        let mut field_indices: HashMap<String, usize> = HashMap::new();
        // Sequence number for `solidity_ast_node_child`, which holds only the
        // semantic children: named, non-extra, and not already reachable through a
        // field accessor.
        let mut child_seq: usize = 0;

        let mut cursor = node.walk();

        for (child_index, child) in node.children(&mut cursor).enumerate() {
            // Collapse generic `expression` wrapper nodes: the tree-sitter grammar
            // wraps every expression in an `expression` choice node, so e.g.
            // `call_expression.function` points at a wrapper rather than the real
            // callee. Skip the wrapper and attach its inner node directly, keeping
            // the wrapper's position (`child_index`) and field name so parent/field
            // relations point at the real expression. See `resolve_wrapper`.
            let child = resolve_wrapper(child);

            // Extract the child. `extract_node` returns None for ERROR / MISSING
            // nodes (see its guard); skip those entirely so no field relation
            // points at a dropped node.
            let child_label = match self.extract_node(
                child,
                source,
                Some((parent_label.clone(), child_index)),
            )? {
                Some(label) => label,
                None => continue,
            };

            // If this child has a field name, emit the field relationship.
            // Otherwise it is a generic child: record it in the child relation so
            // `getChild(i)` indexes the semantic children in source order.
            // Anonymous tokens (`{`, `;`, keywords) are unnamed and extras
            // (comments) are `is_extra`, so neither takes up an index.
            if let Some(field_name) = node.field_name_for_child(child_index as u32) {
                let field_idx = *field_indices.get(field_name).unwrap_or(&0);
                field_indices.insert(field_name.to_string(), field_idx + 1);

                let kind = normalize_kind(node.kind());
                let table_name = format!("solidity_{}_{}", kind, field_name);

                self.trap.emit(
                    &table_name,
                    vec![
                        TrapValue::Label(parent_label.clone()),
                        TrapValue::UInt(field_idx as u64),
                        TrapValue::Label(child_label),
                    ],
                );
            } else if child.is_named() && !child.is_extra() {
                self.trap.emit(
                    "solidity_ast_node_child",
                    vec![
                        TrapValue::Label(parent_label.clone()),
                        TrapValue::UInt(child_seq as u64),
                        TrapValue::Label(child_label),
                    ],
                );
                child_seq += 1;
            }
        }

        Ok(())
    }

    /// Emit AST node type info.
    fn emit_ast_node_info(&mut self, label: &Label, kind_id: u16) -> Result<()> {
        self.trap.emit(
            "solidity_ast_node_info",
            vec![
                TrapValue::Label(label.clone()),
                TrapValue::UInt(kind_id as u64),
            ],
        );
        Ok(())
    }

    /// Emit location for a node.
    fn emit_node_location(&mut self, label: &Label, node: &Node) -> Result<()> {
        let file_label = self.file_label.as_ref().expect("File label not set");

        let start = node.start_position();
        let end = node.end_position();

        // tree-sitter uses 0-based lines and columns, CodeQL uses 1-based
        let loc_label = self.trap.emit_location(
            file_label,
            start.row as u32 + 1,
            start.column as u32 + 1,
            end.row as u32 + 1,
            end.column as u32 + 1,
        );

        self.trap.emit(
            "solidity_ast_node_location",
            vec![TrapValue::Label(label.clone()), TrapValue::Label(loc_label)],
        );

        Ok(())
    }

    /// Emit token info for terminal nodes.
    fn emit_token_info(&mut self, label: &Label, kind: u32, value: &str) -> Result<()> {
        self.trap.emit(
            "solidity_tokeninfo",
            vec![
                TrapValue::Label(label.clone()),
                TrapValue::UInt(kind as u64),
                TrapValue::String(value.to_string()),
            ],
        );
        Ok(())
    }

    /// Emit the folded constant value of an expression node, as a decimal string.
    fn emit_const_value(&mut self, label: &Label, value: &str) -> Result<()> {
        self.trap.emit(
            "solidity_const_value",
            vec![
                TrapValue::Label(label.clone()),
                TrapValue::String(value.to_string()),
            ],
        );
        Ok(())
    }
}

/// Holds if `node` is a transparent single-child wrapper that should be
/// collapsed during extraction.
///
/// The pinned tree-sitter-solidity grammar exposes `expression` and `statement`
/// as visible choice rules (they are not tree-sitter supertypes), so every
/// expression sits inside a generic `expression` node and every statement inside
/// a generic `statement` node, each with exactly one child. Those wrappers carry
/// no information of their own and break naive AST queries (`getFunction()`,
/// `getLeft()`, argument access, block statement lists, ...), so we drop them and
/// promote the child. Only these two kinds are collapsed, and only when they have
/// exactly one child, so re-parenting cannot collide on `#keyset[parent, index]`.
fn is_collapsible_wrapper(node: &Node) -> bool {
    node.is_named() && matches!(node.kind(), "expression" | "statement") && node.child_count() == 1
}

/// Follows a chain of collapsible wrappers down to the first meaningful node.
fn resolve_wrapper(node: Node) -> Node {
    let mut current = node;
    while is_collapsible_wrapper(&current) {
        // Safe: `is_collapsible_wrapper` guarantees exactly one child.
        current = current
            .child(0)
            .expect("wrapper guaranteed to have one child");
    }
    current
}

/// Normalize a tree-sitter kind name for use in table names.
fn normalize_kind(kind: &str) -> String {
    kind.replace('-', "_")
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
    fn test_normalize_kind() {
        assert_eq!(normalize_kind("binary_expression"), "binary_expression");
        assert_eq!(normalize_kind("source-file"), "source_file");
        assert_eq!(normalize_kind("+="), "pluseq");
    }

    #[test]
    fn test_extract_simple_contract() {
        let source = r#"
            // SPDX-License-Identifier: MIT
            pragma solidity ^0.8.0;

            contract SimpleToken {
                uint256 public totalSupply;

                function transfer(address to, uint256 amount) public {
                    // Transfer logic
                }
            }
        "#;

        let mut extractor = Extractor::new("/test/SimpleToken.sol");
        let result = extractor.extract(source);
        assert!(result.is_ok(), "Extraction failed: {:?}", result.err());
    }

    #[test]
    fn test_extract_with_inline_assembly() {
        let source = r#"
            pragma solidity ^0.8.0;

            contract Assembly {
                function getChainId() public view returns (uint256 id) {
                    assembly {
                        id := chainid()
                    }
                }
            }
        "#;

        let mut extractor = Extractor::new("/test/Assembly.sol");
        let result = extractor.extract(source);
        assert!(result.is_ok(), "Extraction failed: {:?}", result.err());
    }
}
