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
- ✅ **Typed AST** — walks the full protobuf tree and converts every node to V sum types

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

# Build C bridge objects
make build

# Verify everything works
v test pg_query/
```

## Usage

```v
import pg_query

fn main() {
    // Parse SQL to typed V AST (no JSON/protobuf intermediates)
    result := pg_query.parse_ast_direct('SELECT id, name FROM users WHERE age > 21') or {
        eprintln('Parse error: ${err}')
        return
    }
    // result.stmts is []AstRawStmt, result.stmts[0].stmt is a Node sum type
    for stmt in result.stmts {
        println('location=${stmt.stmt_location}, len=${stmt.stmt_len}')
    }
}
```

See [examples/parse_sql.v](examples/parse_sql.v) for a complete example covering JSON, protobuf, fingerprinting, typed AST traversal, and concurrent parsing.

A dedicated concurrency stress test is at [examples/concurrent_parse.v](examples/concurrent_parse.v) (10 workers, 120k parses, 0 errors).

## API Overview

### Parsing — raw output

| Function | Returns | Description |
|---|---|---|
| `parse(input)` | `!ParseResult` | Parse SQL → JSON string |
| `parse_opts(input, opts)` | `!ParseResult` | Parse with parser options |
| `parse_protobuf(input)` | `!ParseResultProtobuf` | Parse SQL → protobuf bytes |
| `parse_protobuf_opts(input, opts)` | `!ParseResultProtobuf` | Same with options |
| `parse_plpgsql(input)` | `!PlpgsqlParseResult` | Parse PL/pgSQL function |

### Parsing — typed AST (new)

| Function | Returns | Description |
|---|---|---|
| `parse_ast_direct(input)` | `!ParseAstResult` | Parse SQL → typed V AST structs |
| `parse_ast_direct_opts(input, opts)` | `!ParseAstResult` | Same with parser options |

These skip JSON/protobuf entirely — the C bridge converts directly to V-compatible C structs, and the V pluck layer wraps them into typed `Node` sum types. Every node in the Postgres grammar (272 message types) is converted.

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

### Deparse

| Function | Returns | Description |
|---|---|---|
| `deparse_protobuf(pb)` | `!DeparseResult` | Protobuf → SQL string |
| `deparse_protobuf_opts(pb, opts)` | `!DeparseResult` | With formatting options |
| `deparse_comments_for_query(query)` | `!DeparseCommentsResult` | Extract comments |

### Utility

| Function | Returns | Description |
|---|---|---|
| `is_utility_stmt(query)` | `!IsUtilityResult` | Check if DDL |
| `summary(input, opts, limit)` | `!SummaryParseResult` | Query summary |

### Protobuf helpers

```v
pb := result.parse_tree
pb.hex()    // hex dump, e.g. "0897b00a121c..."
pb.bytes()  // raw []u8 bytes
pb.len      // byte count
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

# Build C bridge objects
make build

# Run tests
v test pg_query/

# Run examples
v run examples/parse_sql.v

# Or for faster builds, compile once with -o (avoids recompiling the large generated C bridge):
v -o examples/parse_sql examples/parse_sql.v && ./examples/parse_sql
v -o examples/concurrent_parse examples/concurrent_parse.v && ./examples/concurrent_parse
v -o examples/bench examples/bench.v && ./examples/bench

# Rebuild C bridge (after editing c_bridge.c or protobuf_bridge.c)
cc -c -I libpg_query pg_query/c_bridge.c -o pg_query/c_bridge.o
cc -c -I libpg_query -I libpg_query/vendor pg_query/protobuf_bridge.c -o pg_query/protobuf_bridge.o
```

## How it works

The library bundles [libpg_query](https://github.com/pganalyze/libpg_query) (version 6.2.2, wrapping PostgreSQL 17.7), pre-built as a static archive (`libpg_query.a`). The V wrapper in `pg_query/` has four layers:

| Layer | Files | Role |
|---|---|---|
| **C bindings** | `pgquery.c.v` | `#flag` / `#include` declarations for the C ABI |
| **V wrapper** | `pgquery.v` | Safe `!` result types for JSON, protobuf, normalise, fingerprint, etc. |
| **C bridge** | `c_bridge.c`, `protobuf_bridge.c` | Unpack protobuf into V-compatible C structs |
| **V pluck layer** | `pg_query_pluck.v` (generated) | 272 `c_to_*` functions converting C structs → typed `Node` sum types |

All AST struct definitions, the C header, the C bridge, and the V pluck layer are **code-generated** from the protobuf schema by `tools/gen_ast.v`.

```
SQL → libpg_query → protobuf → C bridge → V-compatible C structs → V pluck → typed Node
```

See [v-and-c-integration.md](v-and-c-integration.md) for more on V/C interop patterns used.

## Building a PostgreSQL pooler / proxy

`pg_query.v` provides the SQL parsing and analysis engine you would need for a tool like [pgdog](https://github.com/levkk/pgdog). The typed AST can be used to:

- **Route queries** — inspect `SelectStmt`, `InsertStmt`, etc. to decide read/write splitting
- **Extract table names** — walk `RangeVar` nodes for shard/key mapping
- **Fingerprint & cache** — use `fingerprint()` (~24 us/op) as a prepared-statement cache key
- **Normalize before routing** — strip literals (~10 us/op) for consistent hash-based routing
- **Detect DDL vs DML** — `is_utility_stmt()` for schema-change blocking

Thread safety has been verified at 120k parses across 10 concurrent workers with 0 errors
(see [examples/concurrent_parse.v](examples/concurrent_parse.v) and [docs/design.md](docs/design.md)).

Performance comparison (6-query mix, M2 MacBook Air):

| Path | Latency | Use |
|---|---|---|
| `normalize()` | 10 us/op | Anonymize for logging |
| `fingerprint()` | 24 us/op | Route by query structure hash |
| `parse_ast_direct()` | 135 us/op | Shard key / table extraction |

You would still need to build the networking (TLS, PostgreSQL wire protocol), connection pooling, and load-balancing layers yourself — `pg_query.v` is the parser component, not a proxy.

## License

MIT
