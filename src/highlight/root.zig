//! Syntax highlighting: the tree-sitter language table and the embedded queries.
pub const ts = @import("tree_sitter");
pub const queries = @import("ts_queries");

test {
    _ = queries;
}
