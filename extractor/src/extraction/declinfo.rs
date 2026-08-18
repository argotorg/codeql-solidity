//! Declaration and type-shape facts.
//!
//! The AST records the *syntax* of a declaration, so a query that wants to know
//! "is this a `bytes memory`?" has to peel `type_name(type_name(primitive_type),
//! [, ])` by hand, know that a mapping's first `primitive_type` child is its
//! *key*, and know that a state variable is in storage even though no `storage`
//! token appears. Every query that reasons about types re-derives all of that,
//! and gets it subtly wrong.
//!
//! So the walk happens here instead, emitted as two relations:
//!
//!   - `solidity_type_info` on each `type_name`: the base type after peeling
//!     array levels, which kind of type it is, and how many levels were peeled.
//!   - `solidity_declaration` on each named value declaration: its name, which
//!     kind of declaration it is, and the data location that *applies* to it —
//!     not merely the one that was written.

use tree_sitter::Node;

/// What a `type_name` ultimately names.
pub struct TypeInfo {
    /// Primitive name (`bytes`, `uint256`), dotted user-defined name (`L.Box`),
    /// or empty for mapping and function types, which name no single base.
    pub base: String,
    pub kind: &'static str,
    /// Number of `[]` levels peeled to reach `base`; 0 for a non-array type.
    pub array_dims: i64,
}

/// Describes the `type_name` rooted at `node`, or `None` if it is not one.
pub fn type_info(node: Node, source: &str) -> Option<TypeInfo> {
    if node.kind() != "type_name" {
        return None;
    }
    Some(describe_type(node, source))
}

fn describe_type(node: Node, source: &str) -> TypeInfo {
    // Checked before the array case: a mapping names no base type, and its key
    // is a `primitive_type` child that would otherwise be mistaken for one.
    if node.child_by_field_name("key_type").is_some()
        || node.child_by_field_name("key_identifier").is_some()
    {
        return TypeInfo {
            base: String::new(),
            kind: "mapping",
            array_dims: 0,
        };
    }
    if node.child_by_field_name("parameters").is_some() {
        return TypeInfo {
            base: String::new(),
            kind: "function",
            array_dims: 0,
        };
    }

    // `bytes[][]` is `type_name(type_name(type_name(bytes), [, ]), [, ])`, so an
    // array level is an inner `type_name` alongside a literal `[`.
    if has_child_kind(node, "[") {
        if let Some(inner) = named_child_of_kind(node, "type_name") {
            let inner = describe_type(inner, source);
            return TypeInfo {
                base: inner.base,
                kind: inner.kind,
                array_dims: inner.array_dims + 1,
            };
        }
    }

    if let Some(prim) = named_child_of_kind(node, "primitive_type") {
        return TypeInfo {
            base: text_of(prim, source),
            kind: "primitive",
            array_dims: 0,
        };
    }
    if let Some(udt) = named_child_of_kind(node, "user_defined_type") {
        return TypeInfo {
            base: text_of(udt, source),
            kind: "userdefined",
            array_dims: 0,
        };
    }

    TypeInfo {
        base: String::new(),
        kind: "other",
        array_dims: 0,
    }
}

/// A named value declaration.
pub struct DeclInfo {
    /// Empty for an unnamed `return_parameter`.
    pub name: String,
    pub kind: &'static str,
    /// `memory`, `storage`, `calldata`, `transient`, or empty when the
    /// declaration has no data location (a value type, or a compile-time
    /// constant that occupies no slot).
    pub data_location: String,
}

/// Describes the declaration rooted at `node`, or `None` if it is not one.
pub fn decl_info(node: Node, source: &str) -> Option<DeclInfo> {
    let kind = match node.kind() {
        "variable_declaration" => "local",
        "parameter" => "parameter",
        "return_parameter" => "returnparameter",
        "state_variable_declaration" => "statevar",
        "constant_variable_declaration" => "constant",
        "struct_member" => "structmember",
        "event_parameter" => "eventparameter",
        "error_parameter" => "errorparameter",
        _ => return None,
    };

    let name = node
        .child_by_field_name("name")
        .map(|n| text_of(n, source))
        .unwrap_or_default();

    Some(DeclInfo {
        name,
        kind,
        data_location: data_location(node, kind, source),
    })
}

/// Gets the data location that applies to `node`, which is often not written.
fn data_location(node: Node, kind: &str, source: &str) -> String {
    match kind {
        // A state variable is in storage with no `storage` token in sight. Its
        // `location` field holds a `state_location` (`transient`), not one of the
        // memory/storage/calldata keywords. `constant` and `immutable` occupy no
        // slot at all, so they get no location.
        "statevar" => {
            if has_named_child_kind(node, "immutable") || has_child_kind(node, "constant") {
                String::new()
            } else if let Some(loc) = node.child_by_field_name("location") {
                text_of(loc, source)
            } else {
                "storage".to_string()
            }
        }
        // Struct members follow the location of the struct value they belong to,
        // which is a property of the use, not of the declaration.
        "structmember" => String::new(),
        // Event and error parameters are ABI-encoded, never stored.
        "eventparameter" | "errorparameter" | "constant" => String::new(),
        _ => node
            .child_by_field_name("location")
            .map(|loc| text_of(loc, source))
            .unwrap_or_default(),
    }
}

fn text_of(node: Node, source: &str) -> String {
    node.utf8_text(source.as_bytes())
        .unwrap_or("")
        .trim()
        .to_string()
}

fn has_child_kind(node: Node, kind: &str) -> bool {
    let mut cursor = node.walk();
    let found = node.children(&mut cursor).any(|c| c.kind() == kind);
    found
}

fn has_named_child_kind(node: Node, kind: &str) -> bool {
    named_child_of_kind(node, kind).is_some()
}

fn named_child_of_kind<'a>(node: Node<'a>, kind: &str) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    let found = node.named_children(&mut cursor).find(|c| c.kind() == kind);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    fn parse(source: &str) -> (tree_sitter::Tree, String) {
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_solidity::LANGUAGE.into())
            .expect("language");
        let tree = parser.parse(source, None).expect("parse");
        (tree, source.to_string())
    }

    /// Walks the tree and applies `f` to the first node `f` accepts.
    fn find<'a, T>(node: Node<'a>, f: &dyn Fn(Node<'a>) -> Option<T>) -> Option<T> {
        if let Some(v) = f(node) {
            return Some(v);
        }
        let mut cursor = node.walk();
        let children: Vec<_> = node.children(&mut cursor).collect();
        children.into_iter().find_map(|c| find(c, f))
    }

    fn first_type(source: &str) -> TypeInfo {
        let (tree, src) = parse(source);
        find(tree.root_node(), &|n| type_info(n, &src)).expect("a type_name")
    }

    fn decl_named(source: &str, want: &str) -> DeclInfo {
        let (tree, src) = parse(source);
        find(tree.root_node(), &|n| {
            decl_info(n, &src).filter(|d| d.name == want)
        })
        .unwrap_or_else(|| panic!("no declaration named {want}"))
    }

    #[test]
    fn plain_primitive() {
        let t = first_type("contract C { function f(bytes memory b) public {} }");
        assert_eq!(
            (t.base.as_str(), t.kind, t.array_dims),
            ("bytes", "primitive", 0)
        );
    }

    #[test]
    fn array_levels_are_counted() {
        let t = first_type("contract C { function f(bytes[][] memory b) public {} }");
        assert_eq!(
            (t.base.as_str(), t.kind, t.array_dims),
            ("bytes", "primitive", 2)
        );
    }

    #[test]
    fn fixed_size_array_counts_as_a_level() {
        let t = first_type("contract C { function f(uint256[3] memory b) public {} }");
        assert_eq!(
            (t.base.as_str(), t.kind, t.array_dims),
            ("uint256", "primitive", 1)
        );
    }

    /// The bug this relation exists to prevent: a mapping's first
    /// `primitive_type` child is its key, not an element type.
    #[test]
    fn mapping_does_not_report_its_key_type() {
        let t = first_type("contract C { mapping(uint256 => bytes) m; }");
        assert_eq!((t.base.as_str(), t.kind, t.array_dims), ("", "mapping", 0));
    }

    #[test]
    fn user_defined_type() {
        let t = first_type("contract C { function f(Box memory b) public {} }");
        assert_eq!(
            (t.base.as_str(), t.kind, t.array_dims),
            ("Box", "userdefined", 0)
        );
    }

    #[test]
    fn local_keeps_its_written_location() {
        let d = decl_named(
            "contract C { function f() public { bytes memory b = hex\"01\"; } }",
            "b",
        );
        assert_eq!((d.kind, d.data_location.as_str()), ("local", "memory"));
    }

    #[test]
    fn parameter_without_a_location_has_none() {
        let d = decl_named("contract C { function f(uint256 i) public {} }", "i");
        assert_eq!((d.kind, d.data_location.as_str()), ("parameter", ""));
    }

    /// No `storage` token appears in the source, but the location is storage.
    #[test]
    fn state_variable_is_storage_without_saying_so() {
        let d = decl_named("contract C { bytes internal buf; }", "buf");
        assert_eq!((d.kind, d.data_location.as_str()), ("statevar", "storage"));
    }

    #[test]
    fn constant_state_variable_occupies_no_slot() {
        let d = decl_named("contract C { uint256 constant X = 1; }", "X");
        assert_eq!(d.data_location.as_str(), "");
    }

    #[test]
    fn immutable_state_variable_occupies_no_slot() {
        let d = decl_named("contract C { uint256 immutable x; }", "x");
        assert_eq!((d.kind, d.data_location.as_str()), ("statevar", ""));
    }

    #[test]
    fn struct_member_location_comes_from_the_use() {
        let d = decl_named("contract C { struct Box { bytes payload; } }", "payload");
        assert_eq!((d.kind, d.data_location.as_str()), ("structmember", ""));
    }
}
