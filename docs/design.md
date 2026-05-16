# pg_query.v — Design & Performance Tracking

## Overview

V bindings for [libpg_query](https://github.com/pganalyze/libpg_query): parse, fingerprint,
normalize, and deparse PostgreSQL SQL via a C bridge. Supports multiple API paths for different
use cases.

## API Paths

| Function | Returns | Use Case | Speed |
|---|---|---|---|
| `normalize()` | `string` | Anonymize query literals for logging | 6.4 us/op |
| `fingerprint()` | `u64` | Consistent hash for query structure | 16.4 us/op |
| `parse()` | JSON `string` | Full tree inspection, debugging | 11.5 us/op |
| `parse_protobuf()` | raw `[]byte` | Compact serialization, deparse roundtrip | 45.5 us/op |
| `parse_ast_direct()` | typed V AST structs | Shard key extraction, read-only analysis | 91.7 us/op |
| `parse_ast()` | typed V AST structs (JSON decode path) | Same as typed AST, slower | TBD |

## Benchmark (2026-05-16)

```
normalize() → anonymized SQL           6.40 us/op
parse() → JSON string                 11.45 us/op
fingerprint() → hash                  16.40 us/op
parse_protobuf() → raw bytes          45.47 us/op
parse_ast_direct() → typed AST        91.65 us/op
```

**Conditions**: 6 queries × 1000 iterations = 6000 ops per path, M2 MacBook Air.
All values stable ±3% across runs.

### Analysis

`parse_ast_direct` takes 91.7 us/op — 8× slower than `parse()` (JSON) and 2× slower than
`parse_protobuf()`. The overhead comes from the three-step pipeline:

```
parse_ast_direct pipeline:
  pg_query_parse_protobuf  →-1" protobuf bytes  (~45 us, shared with parse_protobuf)
  pg_query__parse_result__unpack →-2" protobuf-c C structs  (~10-15 us)
  convert_Node() + 272× convert_Xxx() →-3" V ABI C structs  (~20-25 us)
  c_to_node() + V pluck →-4" V structs  (~10-15 us)
```

Steps 2–4 are unique to `parse_ast_direct`. Go's typed AST avoids this entirely by unmarshaling
protobuf directly into Go structs via protoc-gen-go.

**Pooler hot path** (fingerprint/normalize) stays at 6–16 us/op — the typed AST is only hit
on cache misses for shard key extraction.

## Concurrency Stress Test

**Test** (examples/concurrent_parse.v): 10 workers, 1000 iterations, 12 queries per iteration
(120,000 total parses via `parse_ast_direct`).

**Result**: 0 errors, 0 crashes. Workers completed in ~1520–1550ms each (wall clock ~1.5s).

**Conclusion**: Thread safety is verified for the typed AST path. The C library uses
`__thread` TLS internally, which interoperates correctly with V's `spawn` (OS threads).

## Progress

### Complete

- [x] JSON parse path (`parse()`)
- [x] Protobuf parse path (`parse_protobuf()`)
- [x] Typed AST path via C bridge (`parse_ast_direct()`)
- [x] Typed AST path via JSON decode (`parse_ast()`)
- [x] Normalize (`normalize()`)
- [x] Fingerprint (`fingerprint()`)
- [x] Utility check (`is_utility_stmt()`)
- [x] Split (`split_with_scanner()`)
- [x] Deparse protobuf roundtrip (`deparse_protobuf()`)
- [x] Concurrency safety verified (120k ops, 10 workers, 0 errors)
- [x] Example: `examples/parse_sql.v` — all paths + typed AST traversal + concurrency
- [x] Example: `examples/concurrent_parse.v` — dedicated stress test
- [x] Example: `examples/bench.v` — performance comparison

### In Progress

- (none)

### In Progress

- (none — typed AST is in review for optimization; reverse bridge is the next feature gap)

### Known Gaps

- [ ] **Reverse bridge (V struct → protobuf)** — needed for query rewriting
  - Option A (C-direct): C function that accepts SQL + rewrite recipe, unpacks internally via
    protobuf-c, mutates C structs directly, repacks, deparses. Simpler to write one-at-a-time.
  - Option B (generated reverse serializer, **preferred**): `gen_ast.v` emits `to_protobuf()`
    on each V struct that converts back to protobuf-c format. The user modifies the V tree,
    serializes via `to_protobuf()`, then deparses the result. More code up-front but fully
    flexible — any tree mutation works. The generator already reads the proto schema and emits
    forward converters; the reverse is symmetric.
- [ ] `parse_ast()` (JSON-decode path) uses `json.decode` for the full tree — very slow for large queries. Prefer `parse_ast_direct()`.

## Optimization Roadmap: Typed AST

### Current Pipeline (3 conversion steps)

```
SQL → libpg_query → protobuf bytes
  → pg_query__parse_result__unpack()     [protobuf-c C structs]
  → convert_Node() + 272× convert_Xxx()  [V ABI C structs]
  → c_to_node() + V pluck layer          [V sum type structs]
```

Steps 2 (protobuf-c unpack) and 3 (C converters) are a wasted round-trip. protobuf-c deserializes
raw bytes into its own structs, then the converters immediately copy field-by-field into V ABI
structs. The same data is traversed twice.

### Proposal: Eliminate the V ABI Intermediate

**Goal**: Have the V pluck layer read protobuf-c structs directly, skipping the C converters
(step 3) and the ABI struct header (pg_query_ast_c.h):

```
SQL → libpg_query → protobuf bytes
  → pg_query__parse_result__unpack()     [protobuf-c C structs]
  → c_to_node() + V pluck                [V sum type structs]
```

**What changes**:
- `pg_query_bridge_parse_ast_direct()` returns the raw `PgQuery__ParseResult*` instead of
  converting to `V_ParseAstResult*`. Free via `pg_query__parse_result__free_unpacked()`.
- `pg_query_pluck.v` rewritten to read `&C.PgQuery__Xxx` fields directly:
  - Arrays via `c.n_target_list` / `c.target_list[i]` instead of `VArray` accessors
  - Strings via C `char*`+`size_t` instead of `VString`
  - Node oneof via `c.node_case` (protobuf-c enum) instead of `VNode._typ`
- Eliminates `pg_query_ast_c.h` (67 KB), `protobuf_bridge.h` (18 KB),
  and all `convert_Xxx()` functions in `protobuf_bridge.c` (300+ KB).
- The V pluck layer grows but operates on protobuf-c structs natively.

**Expected improvement**: ~50% reduction in `parse_ast_direct` latency
(~92 → ~45–55 us/op), putting it close to `parse_protobuf` since both share
the protobuf-c unpack cost and the remaining difference is just the V struct
construction.

**Risk**: protobuf-c struct layout is more complex (ProtobufCMessage base,
repeated fields with separate count), so the generated V code needs careful
casting. V's C interop must support the full protobuf-c struct hierarchy.

**V contains** the generated `pg_query.pb-c.h` header (already built in
`libpg_query/protobuf/`). V can `#include` it and access `C.PgQuery__Node`,
`C.PgQuery__SelectStmt`, etc. directly.

## Pooler / Proxy Use Case Assessment

### Recommendation for pgdog-style pooler

| Use Case | Path | Ready? |
|---|---|---|
| Fingerprint routing | `fingerprint()` | ✅ Production-ready (24 us/op) |
| Normalize for logging | `normalize()` | ✅ Production-ready (10 us/op) |
| Statement splitting | `split_with_scanner()` | ✅ Production-ready |
| DDL detection | `is_utility_stmt()` | ✅ Production-ready |
| Shard key extraction | `parse_ast_direct()` | ✅ Good for read-only tree analysis (135 us/op) |
| Query rewriting | needs reverse bridge | ❌ Not ready |

**Verdict**: Foundation is solid for a pooler's hot path (fingerprint/normalize at 10–24 us/op).
`parse_ast_direct` is overbuilt for routing/logging but valuable for shard key extraction.
The missing piece is a serialization bridge for query rewriting.

## Key Decisions

- **`msg->node_case` switch** over `short_name` strcmp for `convert_Node()` dispatch — protobuf-c's
  `descriptor->short_name` is always `"Node"`, never the variant name.
- **Return empty struct** for absent optional Node fields rather than panicking — maps to "not set"
  semantics and avoids ref-field issues.
- **Generate `protobuf_bridge.h`** from schema (not hand-written) — accessor declarations depend on
  Node oneof fields and would go stale.
- **C-direct rewrite path** for query rewriting (proposed) — avoids full reverse bridge complexity.

## Generated Files

| File | Size | Purpose |
|---|---|---|
| `pg_query_ast.v` | 84 KB | V struct definitions (273 messages, 72 enums) |
| `pg_query_ast_c.h` | 67 KB | C ABI structs for V_* types (VArray, VString, VNode, etc.) |
| `protobuf_bridge.c` | 344 KB | C bridge: convert_Xxx(), convert_Node(), accessor helpers |
| `protobuf_bridge.h` | 18 KB | Accessor declarations for V ABI |
| `pg_query_pluck.v` | 170 KB | V c_to_Xxx() functions + parse_ast_direct_opts() |

## Generator

- `tools/gen_ast.v` reads `libpg_query/protobuf/pg_query.proto` and emits all 5 files above.
- Run: `v run tools/gen_ast.v`
