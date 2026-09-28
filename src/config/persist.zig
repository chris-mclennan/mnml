//! The config write path. The splice itself is `sdk.zon_edit` — the
//! host and every integration edit a hand-written ZON file the same
//! way, so a save from mnml's settings and a save from a pane leave the
//! same comments and the same ordering behind. This file is the host's
//! name for it; the behaviour and its tests live in the SDK.

const zon_edit = @import("mnml_sdk").zon_edit;

pub const max_backups = zon_edit.max_backups;
pub const backups_dir = zon_edit.backups_dir;
pub const SpliceError = zon_edit.SpliceError;
pub const splice = zon_edit.splice;
pub const isIndexKey = zon_edit.isIndexKey;
pub const append_key = zon_edit.append_key;
pub const lineStart = zon_edit.lineStart;
pub const lineIndent = zon_edit.lineIndent;
pub const serializeLiteral = zon_edit.serializeLiteral;
pub const listLiteral = zon_edit.listLiteral;
pub const Outcome = zon_edit.Outcome;
pub const PersistError = zon_edit.PersistError;
pub const persistScalar = zon_edit.persistScalar;
pub const persistText = zon_edit.persistText;
pub const prune = zon_edit.prune;
pub const formatStamp = zon_edit.formatStamp;
