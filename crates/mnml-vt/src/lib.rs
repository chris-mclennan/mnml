//! Placeholder for the ergonomic libghostty-vt wrapper.
//!
//! This crate is under construction — the sys crate [`mnml_vt_sys`] compiles
//! but the safe wrapper hasn't been written yet. Consumers should continue to
//! use `libghostty-vt` 0.2.0 from crates.io while this crate is built out.

#![allow(dead_code)]

pub use libghostty_vt_sys as sys;
