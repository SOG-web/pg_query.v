# pg_query.v

![V](https://img.shields.io/badge/V-0.5.1+-blue)
![Postgres](https://img.shields.io/badge/Postgres-17.7-336791)

V wrapper for [libpg_query](https://github.com/pganalyze/libpg_query) — a C library that parses, normalizes, fingerprints, and splits PostgreSQL SQL queries using the real Postgres parser (v17.7).

## Features

- ✅ **Parse** SQL to JSON, protobuf, or fully typed V AST structs
- ✅ **Normalize** queries (anonymize literals)
- ✅ **Fingerprint** queries (consistent hash for identical structure)
- ✅ **Split** multi-statement SQL into individual statements
- ✅ **Deparse** protobuf parse tree back to SQL
- ✅ **Scan** (tokenize) SQL queries
- ✅ **PL/pgSQL** parsing
- ✅ **Utility statement** detection
- ✅ **Summary** extraction
- ✅ Structured errors with full Postgres parser metadata
- ✅ **Typed AST** — V-native protobuf wire decoder converts every node to V sum types (no C bridge)
- ✅ **AST serialization** — `encode_parse_result()` produces protobuf bytes from V structs (pure V)
- ✅ **Query rewriting** — parse → modify V AST structs → serialize → deparse back to SQL
- ✅ **Debug printing** — every AST node has `str()` via generated methods; `println(node.stmt)` works on any Node
- ✅ **Forward-compatible decoding** — unknown node types produce `UnrecognizedNode{field_num, data}` instead of errors
- ✅ **JSON-to-AST** — `parse_json_ast()` decodes any JSON parse tree into typed V structs

## Requirements

- [V](https://vlang.io) ≥ 0.5.1
- C compiler (clang, gcc, etc.)
- macOS or Linux

## Installation

```bash
# Clone the repo
git clone https://github.com/rou/pg_query.v.git
cd pg_query.v

# Build the static C library (requires Internet — downloads Postgres 17.7 source)
make -C libpg_query build

# Build the C helper object
make build

# Verify everything works
v test pg_query/
```

## Usage

```v
import pg_query

fn main() {
    // Parse SQL to typed V AST (no JSON intermediates — pure protobuf decode)
    result := pg_query.parse_protobuf_ast('SELECT id, name FROM users WHERE age > 21') or {
        eprintln('Parse error: ${err}')
        return
    }
    // result.stmts is []AstRawStmt, result.stmts[0].stmt is a Node sum type
    for stmt in result.stmts {
        println('location=${stmt.stmt_location}, len=${stmt.stmt_len}')
    }
}
```

See [examples/parse_sql.v](examples/parse_sql.v) for a complete example covering JSON, protobuf, fingerprinting, typed AST traversal, query rewriting, and concurrent parsing.

A dedicated concurrency stress test is at [examples/concurrent_parse.v](examples/concurrent_parse.v) (10 workers, 120k parses, 0 errors).

## Query Rewriting

```v
import pg_query

fn main() {
    // 1. Parse SQL to typed AST
    result := pg_query.parse_protobuf_ast('SELECT id, name FROM users WHERE age > 21') or {
        eprintln('Parse error: ${err}')
        return
    }
    mut sel := result.stmts[0].stmt as pg_query.SelectStmt

    // 2. Modify AST in pure V — rename table
    sel.from_clause[0] = pg_query.RangeVar{relname: 'users_v2'}

    // 3. Deparse back to SQL
    sql := pg_query.deparse_ast(pg_query.ParseAstResult{
        version: result.version
        stmts: [pg_query.AstRawStmt{stmt: sel, stmt_location: 0, stmt_len: 0}]
    }) or { return }
    println(sql)  // SELECT id, name FROM users_v2 WHERE age > 21
}
```

See [examples/query_rewrite.v](examples/query_rewrite.v) for table rename, WHERE injection, and LIMIT addition.

## API Overview

### Parsing — raw output

| Function | Returns | Description |
|---|---|---|
| `parse(input)` | `!ParseResult` | Parse SQL → JSON string |
| `parse_opts(input, opts)` | `!ParseResult` | Parse with parser options |
| `parse_protobuf(input)` | `!ParseResultProtobuf` | Parse SQL → protobuf bytes |
| `parse_protobuf_opts(input, opts)` | `!ParseResultProtobuf` | Same with options |
| `parse_plpgsql(input)` | `!PlpgsqlParseResult` | Parse PL/pgSQL function |

### Parsing — typed AST

| Function | Returns | Description |
|---|---|---|
| `parse_protobuf_ast(input)` | `!ParseAstResult` | Parse SQL → typed V AST (protobuf decode path) |
| `parse_protobuf_ast_opts(input, opts)` | `!ParseAstResult` | Same with parser options |
| `parse_ast(input)` | `!ParseAstResult` | Deprecated: use `parse_protobuf_ast()` (~3× faster) |
| `parse_json_ast(json)` | `!ParseAstResult` | Decode any JSON parse tree → typed V AST |

The protobuf-ast functions call `pg_query_parse_protobuf()` from C and decode bytes entirely in V — no intermediate JSON, no C bridge structs. 270+ generated `decode_*` functions walk the wire format directly.

### Encode & Deparse

| Function | Returns | Description |
|---|---|---|
| `encode_parse_result(val)` | `[]u8` | Serialize AST to protobuf bytes (pure V) |
| `encode_ast(result)` | `Protobuf` | Wrapper returning a `Protobuf` for `deparse_protobuf` |
| `encode_scan(result)` | `Protobuf` | Serialize ScanResult to protobuf bytes (pure V) |
| `encode_summary(result)` | `Protobuf` | Serialize SummaryResult to protobuf bytes (pure V) |
| `deparse_ast(result)` | `!string` | Shortcut: encode + deparse in one call |
| `deparse_protobuf(pb)` | `!DeparseResult` | Protobuf → SQL string |
| `deparse_protobuf_opts(pb, opts)` | `!DeparseResult` | With formatting options |

### Normalize & Fingerprint

| Function | Returns | Description |
|---|---|---|
| `normalize(input)` | `!NormalizeResult` | Anonymize literals |
| `normalize_utility(input)` | `!NormalizeResult` | Normalize DDL only |
| `fingerprint(input)` | `!FingerprintResult` | Structure hash (u64 + hex) |
| `fingerprint_opts(input, opts)` | `!FingerprintResult` | Hash with options |

### Split & Scan

| Function | Returns | Description |
|---|---|---|
| `split_with_scanner(input)` | `!SplitResult` | Split using scanner |
| `split_with_parser(input)` | `!SplitResult` | Split using parser (more accurate) |
| `scan(input)` | `!ScanResult` | Tokenize to protobuf |

### Utility

| Function | Returns | Description |
|---|---|---|
| `is_utility_stmt(query)` | `!IsUtilityResult` | Check if DDL |
| `summary(input, opts, limit)` | `!SummaryParseResult` | Query summary |

### Protobuf & enum helpers

```v
pb := result.parse_tree
pb.hex()    // hex dump, e.g. "0897b00a121c..."
pb.bytes()  // raw []u8 bytes
pb.len      // byte count

// Validate decoded enum values
pg_query.valid_enum_int([0, 1, 2], val)    // coerces invalid → 0
pg_query.valid_enum_int_strict([0, 1, 2], val)! // returns error on invalid
```

### Structured errors

```v
parse('SELECT $$$') or {
    if err is pg_query.PgError {
        println(err.message)    // "syntax error at or near \"$\""
        println(err.funcname)   // "base_yyparse"
        println(err.filename)   // "scan.l"
        println(err.lineno)     // 1160
        println(err.cursorpos)  // 9
    }
}
```

## Development

```bash
# Build C library
make -C libpg_query build

# Build the C helper object
make build

# Run tests
v test pg_query/

# Run examples
v run examples/parse_sql.v
v run examples/query_rewrite.v
v run examples/perf_check.v

# Or pre-compile for faster startup:
v -o examples/parse_sql examples/parse_sql.v && ./examples/parse_sql
v -o examples/concurrent_parse examples/concurrent_parse.v && ./examples/concurrent_parse
v -o examples/bench examples/bench.v && ./examples/bench

# Rebuild C helper (after editing c_bridge.c)
cc -c -I libpg_query pg_query/c_bridge.c -o pg_query/c_bridge.o

# Regenerate AST structs and decoders (after changing proto schema)
v run tools/gen_ast.v
```

## How it works

The library bundles [libpg_query](https://github.com/pganalyze/libpg_query) (version 6.2.2, wrapping PostgreSQL 17.7), pre-built as a static archive (`libpg_query.a`). The V wrapper in `pg_query/` has these layers:

| Layer | Files | Role |
|---|---|---|
| **C bindings** | `pgquery.c.v` | `#flag` / `#include` declarations for the C ABI |
| **V wrapper** | `pgquery.v` | Safe `!` result types for all public APIs |
| **C helpers** | `c_bridge.c/h` | Thin C helpers for deparse opts, version strings |
| **Protobuf helpers** | `pg_query_protobuf.v` | V-native protobuf wire-format read/write helpers |
| **Generated decoders** | `pg_query_decode.v` (generated) | 270+ per-message `decode_*` functions |
| **Generated encoders** | `pg_query_encode.v` (generated) | 270+ per-message `encode_*` functions |
| **Proto → V generator** | `tools/gen_ast.v` | Reads `pg_query.proto`, emits all generated files |

All AST struct definitions (`pg_query_ast.v`), protobuf decoders (`pg_query_decode.v`), and protobuf encoders (`pg_query_encode.v`) are **code-generated** from the protobuf schema.

```
SQL → libpg_query → protobuf bytes → V-native wire decoder → typed Node
Typed Node → V-native wire encoder → protobuf bytes → libpg_query deparse → SQL
```

The decode path is entirely in V — no C bridge, no intermediate JSON, no protobuf-c structs. The encode path is also entirely in V; only the final deparse step calls the C library (and feeds it V-produced protobuf bytes).

## Building a PostgreSQL pooler / proxy

`pg_query.v` provides the SQL parsing and analysis engine for a Postgres connection pooler or proxy:

- **Route queries** — inspect `SelectStmt`, `InsertStmt`, etc. to decide read/write splitting
- **Extract table names** — walk `RangeVar` nodes for shard/key mapping
- **Fingerprint & cache** — `fingerprint()` (~16 us/op) as a prepared-statement cache key
- **Normalize before routing** — strip literals (~8 us/op) for consistent hash-based routing
- **Detect DDL vs DML** — `is_utility_stmt()` for schema-change blocking
- **Query rewriting** — parse → modify V AST → `deparse_ast()` → route rewritten SQL

Thread safety has been verified at 120k parses across 10 concurrent workers with 0 errors
(see [examples/concurrent_parse.v](examples/concurrent_parse.v) and [docs/design.md](docs/design.md)).

Performance comparison (6-query mix × 1000, M2 MacBook Air):

| Path | Latency | Use |
|---|---|---|
| `normalize()` | ~8 us/op | Anonymize for logging |
| `fingerprint()` | ~16 us/op | Route by query structure hash |
| `parse()` (JSON) | ~13 us/op | Full parse tree as string |
| `parse_protobuf_ast()` (typed) | ~62 us/op | Shard key / table extraction |
| `parse_json_ast()` (typed) | ~166 us/op | JSON → typed AST (externally-produced JSON) |
| `encode_parse_result()` | ~111 us/op | AST → protobuf bytes (pure V) |
| `deparse_ast()` | ~160 us/op | Query rewrite roundtrip |

You would still need to build the networking (TLS, PostgreSQL wire protocol), connection pooling, and load-balancing layers yourself — `pg_query.v` is the SQL parsing, analysis, and rewriting component.

A practical guide to building a full-featured pooler is at [docs/pooler_guide.md](docs/pooler_guide.md).

## License

MIT
