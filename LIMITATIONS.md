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

### 10. Truncated buffer: `read_length_buf` returns partial data
`read_length_buf` in `pg_query_protobuf.v` returns a truncated slice when the remaining buffer is shorter than the declared length. For example, if a length-delimited field claims 100 bytes but only 20 remain, it returns the 20 bytes plus a zero consumed count. Downstream decoders then decode from this partial data, producing garbage field values rather than signalling an error.

**Fix needed:** Return an empty slice and a zero consumed count on bounds failure, and have callers treat an empty submessage / string / bytes as a zero value.

### 11. No recursion depth limit
The decoder uses recursive function calls for nested submessages. A deeply crafted protobuf input could cause stack overflow. The Postgres AST is typically 5–15 levels deep, but an attacker or bug in the C parser could produce deeper nesting.

**Fix needed:** Add a `depth` parameter to all `decode_*` functions, capped at a reasonable maximum (e.g. 64). Return zero values when the limit is exceeded.

### 12. Unknown Node variants silently discarded
`decode_node()` dispatches on the oneof field number. If the field number doesn't match any known variant, it returns the first variant type (e.g. `Alias{}`) with no error or warning. This means an unrecognized node type from a future version of the proto silently becomes an empty `Alias`.

**Fix needed:** Return a typed `Node` variant that represents an "unknown" node, or include a bail-out mechanism. Since `Node` is a sum type defined by the oneof, adding an `Unknown` variant requires changing the generated `Node` sum type.

### 13. Enum values not validated
All integer-to-enum casts in the generated decoder use `unsafe { EnumType(int(v)) }`. If the protobuf wire contains an integer that doesn't correspond to any enum variant, it's silently cast to an invalid enum value. Downstream code comparing against named variants will silently miss.

**Fix needed:** Add a helper function that validates the integer is within the enum's known range before casting. Return a default (zero value) and signal the issue when out of range.

### 14. No pure-V protobuf serialization
Only decode (protobuf → V AST) is implemented in pure V. The reverse direction (V AST → protobuf) still uses the C library via `deparse_protobuf()`. There is no pure-V encoder generated from the proto schema.

**Fix needed:** Generate `encode_*` functions parallel to `decode_*` that serialize each message back to protobuf wire format.

### 15. No typed decoding for ScanResult / SummaryResult
`ScanResult` and `SummaryResult` message types are excluded from auto-generation (`skip_names`). The `scan()` and `summary()` functions return raw `Protobuf` bytes. Users who want typed `ScanToken` or `SummaryResult.Table` data must decode the bytes manually.

**Fix needed:** Remove these from `skip_names` and generate proper decode functions. Requires handling `SummaryResult`'s nested enum/message types and `map<string, string>` field.

### 16. Map fields not supported
The proto parser cannot parse `map<K, V>` field syntax. Only one field in the entire schema uses this (`SummaryResult.aliases`), but it blocks typed decoding of `SummaryResult`. The parser sees `map<string,` as the field type and fails to parse subsequent fields correctly.

**Fix needed:** Extend the proto parser to handle `map<K, V>` syntax, either by treating it as a special field type or by expanding it to the equivalent `repeated MapEntry` pattern.

### 17. Nested type definitions not supported
The proto parser expects flat message and enum definitions. `SummaryResult` contains embedded types (`enum Context`, `message Table`) which the parser cannot handle. These types are skipped entirely.

**Fix needed:** Extend the proto parser to collect nested types and flatten them with qualified names (e.g. `SummaryResult_Context`, `SummaryResult_Table`).

### 18. Proto parser is minimal
The hand-written proto parser in `tools/gen_ast.v` handles the pg_query.proto schema but doesn't support:
- Multi-line field options
- Certain comment placements
- `import` with non-file references
- `package` declarations with dots
- Group syntax (deprecated but valid)
- Extensions and `Any`

These aren't used by pg_query.proto but limit reuse with other proto schemas.

**Fix needed:** Replace with a more robust proto parser, or extend the current one to handle edge cases.
