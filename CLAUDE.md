# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

`webzocket` is a Zig WebSocket library (server + client), exposed as a single module named `webzocket` (root: `src/websocket.zig`). It is a fork of `karlseguin/websocket.zig` renamed for use as a Zig package dependency. Zig version: **0.17.0** (see `build.zig.zon`, `minimum_zig_version`). No external dependencies.

## Common Commands

Build / test use the Makefile or raw `zig build`:

- `make tn` — run tests in non-blocking (kqueue/epoll) mode.
- `make tb` — run tests in blocking (one-thread-per-conn) mode.
- `make t` — run both modes.
- `make F=<name> tn` — filter tests by substring (Makefile forwards `TEST_FILTER` env var consumed by `test_runner.zig`).
- `zig build test -Dforce_blocking=true|false -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` — direct invocation.
- `zig fmt --check src/` — formatter check (CI enforces this; run `zig fmt src/` to fix).
- `make abs` / `make abc` — run the Autobahn fuzzing suite against the server / client (requires Docker; scripts in `support/autobahn/`).

CI (`.github/workflows/ci.yml`) runs build + both-mode tests on Linux/macOS/Windows across all optimize modes, plus `zig fmt --check` and a package-consumer smoke build. Releases are cut explicitly with `tools/release.sh <semver>`; PRs do not bump the version.

## Architecture

Public surface is re-exported from `src/websocket.zig`. Reading that file first gives the full API map.

### Module layout
- `src/websocket.zig` — root module, public re-exports, `Compression` config type, `frameText`/`frameBin` comptime helpers.
- `src/proto.zig` — WebSocket wire protocol: `OpCode`, `Message`, the `Reader` state machine that parses frames out of a possibly-overread buffer, frame construction.
- `src/buffer.zig` — `buffer.Provider`: pooled small/large buffers with dynamic fallback, shared across connections.
- `src/server/server.zig` — `Server(H)`, `Conn`, `Config`. Contains both non-blocking (kqueue/epoll) and blocking implementations, selected at comptime via `blockingMode()`.
- `src/server/handshake.zig` — HTTP upgrade parsing and response.
- `src/server/thread_pool.zig` — worker pool that dispatches parsed messages to `Handler.clientMessage` and friends.
- `src/server/fallback_allocator.zig` — the thread-local fast allocator (static buffer → arena fallback) passed into the `clientMessage` overload that takes an `Allocator`.
- `src/client/client.zig` — standalone WebSocket `Client`.
- `src/testing.zig` — `Testing` harness that gives handler tests a real socket pair + in-memory `Reader`.
- `src/t.zig` — internal test utilities (not public).
- `test_runner.zig` — custom simple-mode test runner (honours `TEST_FILTER` env var, scoped log level set to `.warn`).

### The Handler contract (server)
`Server(H)` is generic over a user-defined `H`. `H` must provide `init(*Handshake, *Conn, Ctx) !H` and `clientMessage(...)`. `clientMessage` has four overloads (simple; `+MessageTextType` to distinguish text/binary; `+Allocator`; both). Optional hooks: `afterInit`, `close`, `clientClose`, `clientPing`, `clientPong`. See `readme.md` for precise signatures.

Thread-safety invariant: the library guarantees at most one `clientXxx` call per connection runs at a time; concurrent calls to `Conn` methods (`write`, `close`) from other threads are allowed.

### Blocking vs non-blocking mode
`server.blockingMode()` is a comptime function. It returns `true` on non-Unix targets, or when `-Dforce_blocking=true` is passed (which sets the `websocket_blocking` option in the generated `build` module — see `build.zig` lines 14–17 and 26–29). This flag gates large comptime branches in `server.zig`, so **both modes must be tested** (CI does this; `make t` does this locally). A change that compiles in one mode can easily break the other.

### Buffer / message-size model
Reader uses a static per-connection buffer (over-reading into it is expected) and asks `buffer.Provider` for a right-sized large buffer only when a message exceeds the static size. The large buffer is sized exactly to the message so it is never pinned across messages — `proto.zig`'s comments describe this contract and any changes to reader buffer management must preserve it.

### Package consumer expectations
The CI `package` job constructs a downstream project that imports this lib as `.webzocket` and uses `b.dependency("webzocket", ...).module("webzocket")`. The module name, root source file, and exported symbols (`Client`, `Server`, `Conn`, etc.) are all part of the package's public contract — renaming any of them is a breaking change.

## Notes
- `migrate_from_152_to_160.md` (untracked, root) is a working doc for migrating the library from Zig 0.15.2 to 0.16.0. It is not yet committed.
- Compression is currently disabled; `Config.compression != null` returns `error.InvalidConfiguraion` (note the typo in the error name is intentional / load-bearing for any existing callers). See `server.zig` around the `init` call.
- The `Dockerfile` pins an old Zig dev build and is not used by CI — don't rely on it for reproducible builds.

## Versioning
`build.zig.zon` `.version` is the single source of truth; code reads `webzocket.version` (from `build_options`). Never write a version literal elsewhere, never bump it in a feature PR. Releases are cut explicitly with `tools/release.sh <semver>`. See [`docs/VERSIONING.md`](docs/VERSIONING.md).
