# pg_query.v — Design & Performance Tracking

## Overview

V bindings for [libpg_query](https://github.com/pganalyze/libpg_query): parse, fingerprint,
normalize, deparse, and rewrite PostgreSQL SQL. Supports multiple API paths for different
use cases.

## API Paths

| Function | Returns | Use Case | Speed |
|---|---|---|---|
| `normalize()` | `string` | Anonymize query literals for logging | ~3 us/op |
| `fingerprint()` | `u64` | Consistent hash for query structure | ~6 us/op |
| `parse()` | JSON `string` | Full tree inspection, debugging | ~4 us/op |
| `parse_protobuf_ast()` | typed V AST structs | Shard key / table extraction | ~19 us/op |
| `parse_json_ast()` | typed V AST structs | JSON → typed AST (external JSON) | ~54 us/op |
| `encode_parse_result()` | `[]u8` protobuf | Serialize AST back to wire format | 111 µs |
| `deparse_ast()` | `!string` | Query rewrite pipeline | encode + C deparse (160 µs) |

## Benchmark (2026-05-25)

```
normalize() → anonymized SQL               2.6 us/op
parse() → JSON string                      3.2 us/op
fingerprint() → hash                       5.6 us/op
parse_protobuf_ast() → typed AST          18.6 us/op
parse_json_ast() → typed AST              53.7 us/op
encode_parse_result() → protobuf         111.0 us/op
deparse_ast() → SQL (encode+deparse)     159.7 us/op
```

**Conditions**: 2 queries × 10000 iterations = 20000 ops per path, M2 MacBook Air.
(encode & deparse from 6q × 1000i bench.v — unchanged).
**Note**: Parse-path numbers halved versus prior run (scheduler variance resolved).
Bridge elimination reduced C call overhead for parse paths. Encode is ~1.8× slower than
decode because it dynamically grows output arrays and walks the sum-type dispatch table.
Deparse overhead over encode is ~49 µs (C library call).

## Concurrency Stress Test

**Test** (examples/concurrent_parse.v): 10 workers, 1000 iterations, 12 queries per iteration
(120,000 total parses via `parse_protobuf_ast`).

**Result**: 0 errors, 0 crashes.

**Conclusion**: Thread safety is verified for the typed AST path. The C library uses
`__thread` TLS internally, which interoperates correctly with V's `spawn` (OS threads).

## Progress

### Complete

- [x] JSON parse path (`parse()`)
- [x] Protobuf parse path (`parse_protobuf()`)
- [x] Typed AST via V-native protobuf decode (`parse_protobuf_ast()`)
- [x] Typed AST via JSON decode (`parse_ast()`, `parse_json_ast()`)
- [x] Normalize (`normalize()`)
- [x] Fingerprint (`fingerprint()`)
- [x] Utility check (`is_utility_stmt()`)
- [x] Split (`split_with_scanner()`, `split_with_parser()`)
- [x] Scan (`scan()`)
- [x] Summary extraction (`summary()`)
- [x] Deparse protobuf roundtrip (`deparse_protobuf()`)
- [x] V-native protobuf serialization (`encode_parse_result()`, `encode_ast()`, `encode_scan()`, `encode_summary()`)
- [x] Query rewriting (`deparse_ast()`)
- [x] Concurrency safety verified (120k ops, 10 workers, 0 errors)
- [x] Debug printing (`str()` for all AST nodes)
- [x] Forward-compatible decode (`UnrecognizedNode` fallback)
- [x] Packed encoding for repeated scalar/enum fields
- [x] `parse_ast()` deprecated in favor of `parse_protobuf_ast()` (~3× faster)
- [x] `PostgresDeparseOpts` ABI decoupled (opaque voidptr, bridge layer eliminated)
- [x] `valid_enum_int_strict()` for rejecting invalid enum values
- [x] Self-validating version tests (no hardcoded PG version strings)
- [x] Example: `examples/parse_sql.v` — all paths + typed AST traversal + rewriting + concurrency
- [x] Example: `examples/concurrent_parse.v` — dedicated stress test
- [x] Example: `examples/bench.v` — performance comparison
- [x] Example: `examples/query_rewrite.v` — table rename, WHERE injection, LIMIT addition
- [x] Example: `examples/perf_check.v` — quick one-shot benchmark

## Generated Files

| File | Size | Purpose |
|---|---|---|
| `pg_query_ast.v` | 202 KB | V struct definitions + `str()` for all 276 messages, 72 enums, Node sum type |
| `pg_query_decode.v` | 290 KB | 270+ per-message `decode_*` protobuf wire decoders |
| `pg_query_encode.v` | 241 KB | 270+ per-message `encode_*` protobuf wire encoders (packed scalar/enum repeats) |

## Generator

- `tools/gen_ast.v` reads `libpg_query/protobuf/pg_query.proto` and emits all 3 files above.
- Run: `v run tools/gen_ast.v`

## Pooler / Proxy Use Case Assessment

| Use Case | Path | Ready? |
|---|---|---|
| Fingerprint routing | `fingerprint()` | ✅ ~6 us/op |
| Normalize for logging | `normalize()` | ✅ ~3 us/op |
| Statement splitting | `split_with_scanner()` | ✅ |
| DDL detection | `is_utility_stmt()` | ✅ |
| Shard key extraction | `parse_protobuf_ast()` | ✅ ~19 us/op |
| Query rewriting | `deparse_ast()` | ✅ parse → modify V AST → reserialize |

## Key Decisions

- **No protobuf-c intermediates** in the decode/encode path — the V-native decoder reads the wire format directly and the V-native encoder writes it, eliminating any C struct copies.
- **Zero-value fields omitted** on encode — conformant to protobuf spec and avoids crashing the C deparser on fields marked absent by the parser.
- **All generated from schema** — `gen_ast.v` reads `pg_query.proto` and emits structs, decoders, encoders, and `str()` methods. Adding new messages requires only a proto change and a generator run.
- **Node sum type with `UnrecognizedNode` fallback** — forward-compatible: unknown field numbers produce `UnrecognizedNode{field_num, data}` instead of errors or silent data loss.
- **Packed encoding for scalar/enum repeats** — repeated int32/int64/uint32/uint64/sint32/sint64/fixed32/fixed64/sfixed32/sfixed64/float/double/bool and enum fields use packed wire format (`tag + length + concatenated values`), matching C library output. String/bytes/Node/submessage repeats remain non-packed.
- **`str()` generated for all types** — every generated struct has a `str()` method showing non-zero fields. Node sum type dispatches to the variant's `str()`. Zero-valued primitives/empty strings/nil pointers/empty repeats are omitted; sub-messages and enums always included.
- **`PostgresDeparseOpts` is opaque on the V side** — all field access goes through C bridge setters (`void*` parameters). The V type is `voidptr`. This prevents ABI breakage when the C struct layout changes.
- **Version tests are self-validating** — instead of hardcoding `'17.7'`, tests derive expected values from the library's own version macros, surviving libpg_query upgrades without modification.
