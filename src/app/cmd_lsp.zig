//! The `lsp.*` runners: one line each, over `app/lsp.zig`.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const lsp = @import("lsp.zig");

pub const table = .{
    .@"lsp.goto_definition" = &lsp.gotoDefinition,
    .@"lsp.goto_declaration" = &lsp.gotoDeclaration,
    .@"lsp.goto_type_definition" = &lsp.gotoTypeDefinition,
    .@"lsp.goto_implementation" = &lsp.gotoImplementation,
    .@"lsp.references" = &lsp.references,
    .@"lsp.peek_definition" = &lsp.peekDefinition,
    .@"lsp.peek_definition_overlay" = &lsp.peekDefinitionOverlay,
    .@"lsp.hover" = &lsp.hover,
    .@"lsp.signature_help" = &lsp.signatureHelp,
    .@"lsp.signature_next" = &signatureNext,
    .@"lsp.signature_prev" = &signaturePrev,
    .@"lsp.completion" = &lsp.completion,
    .@"lsp.rename" = &lsp.rename,
    .@"lsp.format" = &lsp.format,
    .@"lsp.code_action" = &lsp.codeAction,
    .@"lsp.quick_fix" = &lsp.quickFix,
    .@"lsp.organize_imports" = &lsp.organizeImports,
    .@"lsp.symbols" = &lsp.symbols,
    .@"lsp.workspace_symbols" = &lsp.workspaceSymbols,
    .@"lsp.diagnostics" = &lsp.showDiagnostics,
    .@"lsp.diagnostics_filter" = &lsp.cycleFilter,
    .@"lsp.next_diagnostic" = &nextDiagnostic,
    .@"lsp.prev_diagnostic" = &prevDiagnostic,
    .@"lsp.highlight_symbol" = &lsp.highlightSymbol,
    .@"lsp.clear_highlights" = &lsp.clearHighlights,
    .@"lsp.selection_expand" = &lsp.selectionExpand,
    .@"lsp.selection_shrink" = &lsp.selectionShrink,
    .@"lsp.fold_all" = &lsp.foldAll,
    .@"lsp.inlay_hints_toggle" = &lsp.inlayHintsToggle,
    .@"lsp.incoming_calls" = &lsp.incomingCalls,
    .@"lsp.outgoing_calls" = &lsp.outgoingCalls,
    .@"lsp.supertypes" = &lsp.supertypes,
    .@"lsp.subtypes" = &lsp.subtypes,
};

fn signatureNext(app: *App) CommandError!void {
    return lsp.signatureStep(app, 1);
}

fn signaturePrev(app: *App) CommandError!void {
    return lsp.signatureStep(app, -1);
}

fn nextDiagnostic(app: *App) CommandError!void {
    return lsp.gotoDiagnostic(app, true);
}

fn prevDiagnostic(app: *App) CommandError!void {
    return lsp.gotoDiagnostic(app, false);
}

test {
    _ = std;
}
