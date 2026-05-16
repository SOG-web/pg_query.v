# Limitations

## 1. DeparseOpts.comments — ✅ Fixed
`deparse_opts_to_c` now properly converts `[]DeparseComment` to `PostgresDeparseComment**` via the C bridge, allocating C arrays of pointers and `strdup`'ing comment strings.

## 2. Protobuf is opaque — ✅ Fixed
The V-native protobuf decoder (`pg_query_decode.v`) converts the raw protobuf wire format directly into typed V AST structs — no JSON, no C bridge, no protobuf-c. All 270+ message types are decoded in pure V.

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

---

## V-Native Protobuf Decoder Limitations

### 10. Truncated buffer: `read_length_buf` returns partial data — ✅ Fixed
`read_length_buf` in `pg_query_protobuf.v` now returns an empty slice and a zero consumed count when the remaining buffer is shorter than the declared length. Callers treat an empty submessage / string / bytes as a zero value.

### 11. No recursion depth limit — ✅ Fixed
All `decode_*` functions now accept a `depth int` parameter. `decode_parse_result` passes `max_decode_depth` (64) to the top-level call, and each recursive invocation passes `depth - 1`. When `depth <= 0`, the function immediately returns zero values. Structs with reference fields use proper `unsafe { nil }` initialization in the depth-zero return.

### 12. Unknown Node variants silently discarded — ✅ Fixed
`decode_node()` returns `UnrecognizedNode{field_num, data}` for unknown field numbers instead of silently returning the first variant. `UnrecognizedNode` is a new struct added to the `Node` sum type, preserving the raw field number and submessage data for forward-compat.

### 13. Enum values not validated — ✅ Fixed
Added `valid_enum_int(valid_values, v)` helper that checks the varint against the enum's known valid integer set before casting. All 116 generated enum casts use this helper with the enum-specific valid values list. Invalid values silently become 0.

### 14. No pure-V protobuf serialization — ✅ Fixed
Generated `encode_*` functions for all 276 message types in `pg_query_encode.v` (240KB) that serialize V structs back to protobuf wire format. The `encode_parse_result()` entry point produces bytes compatible with the C `pg_query_deparse_protobuf` bridge. The `encode_ast()` and `deparse_ast()` convenience functions enable a complete "parse → modify → deparse" round-trip in pure V (deparse still uses the C bridge, but the protobuf is V-produced).

Zero-value fields are omitted per protobuf spec. The first Node sum type variant (`Alias`) is skipped when all fields are zero ("not set"); all other variants are always encoded.

### 15. No typed decoding for ScanResult / SummaryResult — ✅ Fixed
`ScanResult` and `SummaryResult` are no longer in `skip_names`. Their V struct types and protobuf decode functions are generated. `scan()` and `summary()` now return fully decoded typed results (`ScanResult{version, tokens}` and `SummaryResult{tables, aliases, cte_names, functions, filter_columns, statement_types, truncated_query}`).

### 16. Map fields not supported — ✅ Fixed
The proto parser now handles `map<K, V>` field syntax, storing key/value type info. A `read_map_string_entry` helper decodes protobuf map entry submessages. The generated decode builds V `map[string]string` fields lazily.

### 17. Nested type definitions not supported — ✅ Fixed
The proto parser now handles nested `enum` and `message` definitions inside messages. Nested types are qualified with the parent message name (e.g. `SummaryResult_Context`, `SummaryResult_Table`). Field type references within the parent scope are automatically resolved to qualified names.

### 18. Proto parser is minimal — ✅ Fixed
The proto parser now handles:
- Multi-line field declarations (accumulates lines until `;`)
- Inline `//` and `/* */` comments within field lines
- `reserved` and `option` lines inside messages (skipped)
- `import public` / `import weak` variants (skipped)
