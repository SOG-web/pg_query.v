# Codebase Analysis — Undocumented Findings

> Items discovered during development that need attention. Ordered roughly by impact.

## ✅ 6. No `String()` / debug printing for AST nodes

**Status: Fixed** — Generator now emits `str()` for all 276 message types, `UnrecognizedNode`, and `Node` sum type.

Every generated struct has a `pub fn (m TypeName) str() string` method that shows non-zero fields as `TypeName{field1: val1, field2: val2}`. Zero-valued primitives, empty strings, nil pointers, and empty repeated fields are omitted. Sub-messages and enums are always included (their `str()` shows `TypeName{}` when all zero).

Node sum type dispatches to the variant's `str()`. `println(stmt.stmt)` now works on any AST node.

---

## ✅ 7. `parse_json_ast()` panics on unknown node types

**Status: Fixed** — `decode_node_json` now returns `Node` (not `!Node`) and returns `UnrecognizedNode{field_num: 0, data: []u8{}}` when no known JSON field matches, instead of `error("unknown node type")`.

The JSON path cannot fully preserve unknown data (no raw JSON capture) but no longer panics/errors on future PG node types.

---

## ✅ 8. Repeated primitives use non-packed encoding

**Status: Fixed** — Encoder now uses packed encoding for repeated scalar fields (int32, int64, uint32, uint64, sint32, sint64, fixed32, fixed64, sfixed32, sfixed64, float, double, bool) and enum types. Instead of individual `tag + value` pairs, writes `tag(2) + length + concatenated values`. String/bytes/Node/submessage repeats remain non-packed.

---

## ✅ 9. `parse_ast()` is a dead-end codepath

**Status: Fixed** — Added deprecation comment: "Deprecated: use parse_protobuf_ast() instead (~3x faster, pure V decode)." The function remains for backward compatibility.

---

## ✅ 10. Encoded zero-value variants still get a tag

**Status: Verified as intentional** — Only `Alias` (the zero-value default for the `Node` sum type) is skipped when all fields are zero. All other variants are explicitly constructed by the user and should always encode. The check now uses `vname == 'Alias'` instead of relying on field ordering.

---

## ✅ 11. No public wrappers for `encode_scan_result` / `encode_summary_result`

**Status: Fixed** — All generated encode functions are now `pub fn`. Added `encode_scan(ScanResult) Protobuf` and `encode_summary(SummaryResult) Protobuf` wrappers in `pgquery.v`.

---

## 12. Hardcoded version strings in tests

**Status: Unchanged** — The test asserts `pg_version() == '17.7'` which is correct for the bundled Postgres 17.7. This is intentional: failing tests alert the maintainer when `libpg_query` is upgraded. Update `test_version` when upgrading the bundled library.

---

## 13. `PostgresDeparseOpts` struct layout is implicitly coupled

**Status: Mitigated** — Added a C `typedef char static_assert_deparse_opts_size[sizeof(PostgresDeparseOpts) == 32 ? 1 : -1]` in `c_bridge.c` that fails to compile if the struct size changes. The V struct (`pgquery.c.v:91-99`) should be updated when this fires.

---

## ✅ 14. `valid_enum_int` silently coerces invalid values to 0

**Status: Fixed** — Added `valid_enum_int_strict(valid_values []int, v u64) !int` that returns an error on out-of-range values. The original `valid_enum_int` remains as the decode default (security hardening).

---

## 15. No tree-manipulation utilities

**Status: Unchanged** — `deep_copy()`, `walk()`, and convenience constructors are valuable but require generator-level support for all 276 variants. These should be implemented as generated functions in `gen_ast.v` in a future pass. For now, V's value-type struct semantics make simple `copy := original` sufficient for most use cases (maps and `&T` pointers are the exceptions).
