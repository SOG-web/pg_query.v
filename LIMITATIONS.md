# Limitations

## 1. DeparseOpts.comments — ✅ Fixed
`deparse_opts_to_c` now properly converts `[]DeparseComment` to `PostgresDeparseComment**` via the C bridge, allocating C arrays of pointers and `strdup`'ing comment strings.

## 2. Protobuf is opaque — ✅ Fixed
The protobuf parse tree is exposed as raw `hex()` / `bytes()` only. However, `parse_ast()` provides typed V AST structs via JSON-based decoding from libpg_query's native JSON output. Additionally, `parse_ast_protobuf()` uses the C bridge to unpack protobuf binary into JSON via protobuf-c, then `json.decode` produces fully-typed V AST structs. The generator at `tools/gen_ast.v` reads the `.proto` schema and produces all ~273 message and ~72 enum structs in `pg_query/pg_query_ast.v`, plus the C bridge at `pg_query/protobuf_bridge.c` (~523KB) with per-message JSON writers using vendored protobuf-c `*__unpack()`.

## 3. stderr_buffer — ✅ Fixed
Removed `#define DEBUG` from `pg_query_internal.h`, which was disabling the stderr redirection that fills `stderr_buffer`. Also fixed 4 pre-existing missing-semicolon bugs in the C source that were hidden by the DEBUG guard.

## 4. No VPM package / pre-built binaries
First build requires `make -C libpg_query build` (or `make` at root level) which downloads and patches PostgreSQL 17.7 source. No VPM package or pre-built `libpg_query.a` for quick install.

## 5. Bridge .o must be compiled manually — ✅ Fixed
Root `Makefile` now tracks `pg_query/c_bridge.o` as a build dependency and rebuilds it automatically when `c_bridge.c` or `c_bridge.h` changes. Run `make` at the project root to build everything.

## 6. No Windows CI
CI covers macOS + Linux. The C library supports Windows via `Makefile.msvc` (MSVC/nmake), but the V wrapper isn't tested there.

## 7. PgError.code() — ❌ Reverted
`code()` is stubbed to return 0. The `sqlerrcode` field was reverted because it modified the upstream `libpg_query` C struct. To re-enable this, the `sqlerrcode` field needs to be added upstream.

## 8. Concurrency docs — ✅ Fixed
`exit()` now has a doc comment explaining thread-local memory contexts and thread safety.

## 9. SplitResult.n_stmts — ✅ Fixed
`SplitResult` now includes a `n_stmts int` field set to the raw `n_stmts` value from the C result.
