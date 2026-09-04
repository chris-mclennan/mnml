; Minimal HCL / Terraform highlights. The upstream tree-sitter-hcl
; crate doesn't ship a highlights query, so we vendor a short one.
; Captures stick to node types confirmed via node-types.json.

(comment) @comment

(string_lit) @string

(bool_lit) @constant.builtin

; Block keyword: the first identifier in a block (resource / data /
; variable / module / provider / output / locals / terraform).
(block (identifier) @keyword.directive
  (#match? @keyword.directive "^(resource|data|variable|module|provider|output|locals|terraform|backend|required_providers|required_version|moved|removed|check|import)$"))

; Attribute names on the left of `=` inside a body.
(attribute (identifier) @property)

; Block labels that follow the block keyword (the "aws_instance" /
; "main" string-ish labels for resources).
(block (string_lit) @type)

; Numeric literals inside a literal_value.
(literal_value (numeric_lit) @number)

; Function calls (length(...), file(...), etc.).
(function_call (identifier) @function)

; Standalone identifiers in expressions (variable references).
(variable_expr (identifier) @variable)

; Conditional / for-expression keywords (HCL has `for`, `in`, `if`,
; `else` as part of the expression grammar; they show up as anonymous
; tokens inside for_expr / conditional / template_expr nodes).
[
  "for"
  "in"
  "if"
  "else"
  "endfor"
  "endif"
] @keyword.control

[
  "="
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "+"
  "-"
  "*"
  "/"
  "%"
  "&&"
  "||"
  "!"
  "?"
  ":"
  "=>"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  "."
] @punctuation.delimiter
