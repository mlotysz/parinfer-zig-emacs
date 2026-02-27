# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

parinfer-zig-emacs is a Zig rewrite of [eraserhd/parinfer-rust](https://github.com/eraserhd/parinfer-rust), stripped down to Emacs-only and Clojure-only. It implements [Parinfer](https://shaunlebron.github.io/parinfer/) (parenthesis inference) as a native Emacs dynamic module. Drop-in compatible with [parinfer-rust-mode.el](https://github.com/justinbarclay/parinfer-rust-mode).

## Build Commands

```bash
zig build                    # Build shared library (zig-out/lib/libparinfer_rust.so or .dylib)
zig build test               # Run unit tests (143 JSON test cases + unicode + changes)
zig build test-emacs         # Run Emacs integration tests (requires emacs in PATH)
```

Requires Zig >= 0.14.0.

## Architecture

### Source files (all in `src/`)

- **`parinfer.zig`** (~1600 lines) — Core algorithm. Three modes: indent, paren, smart. Entry point: `process(allocator, &request) -> Answer`. Clojure-only: 3 context states (Code, Comment, String), hardcoded `;` comment char and `"` string delimiter.
- **`types.zig`** — Data structures: `Request`, `Options`, `Change`, `Answer`, `Error`, `Paren`.
- **`emacs_wrapper.zig`** (~500 lines) — Emacs native module. Exports 16 elisp functions (all prefixed `parinfer-rust-` for parinfer-rust-mode compatibility). Keyword-based API (`:cursor-x`, `:force-balance`, etc.). Memory managed via Emacs user pointers with C-callable finalizers.
- **`emacs.zig`** — Pure-Zig bindings for the Emacs module C API. The `Runtime` and `Env` extern structs must match the exact Emacs 25+ ABI layout, including the `private_members: ?*anyopaque` field between `size` and function pointers.
- **`unicode.zig`** — Grapheme iteration and display width calculation.
- **`changes.zig`** — Single-change text diff computation between two strings.
- **`test_parinfer.zig`** — JSON test case runner. Test data is embedded via the build system (WriteFiles + addAnonymousImport pattern, since JSON files live outside `src/`).
- **`main.zig`** — Entry point. Re-exports `emacs_module_init` and `plugin_is_GPL_compatible`.

### Data flow

`Request` (mode + text + options) → `parinfer.process()` → `Answer` (processed text + cursor + errors + paren trails)

### Tests

- `tests/cases/` — 143 JSON test cases across 3 modes (indent, paren, smart)
- `tests/emacs-integration.el` — Emacs batch-mode integration tests covering the full API

### Build system (`build.zig`)

Produces `libparinfer_rust.so` (or `.dylib`) as a dynamic library linked to libc. Test JSON files from `tests/cases/` are embedded into the test binary via a generated Zig module using the WriteFiles + addCopyFile + addAnonymousImport pattern.
