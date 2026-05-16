# Building a PostgreSQL Connection Pooler with pg_query.v

This guide covers the SQL parsing, analysis, and rewriting capabilities needed to build a
PostgreSQL connection pooler, proxy, or middleware. `pg_query.v` provides the engine; you
provide the networking, TLS, wire protocol, and connection management layers.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Query Routing (Read/Write Splitting)](#query-routing)
3. [Shard Key Extraction](#shard-key-extraction)
4. [Prepared Statement Caching](#prepared-statement-caching)
5. [Query Rewriting](#query-rewriting)
6. [DDL Detection & Blocking](#ddl-detection)
7. [Multi-Statement Splitting](#multi-statement-splitting)
8. [Concurrency & Thread Safety](#concurrency)
9. [Performance Checklist](#performance-checklist)

---

## Architecture Overview

A pooler built on `pg_query.v` follows this pipeline for each client query:

```
Client SQL
    │
    ▼
┌─────────────────────────┐
│  1. Parse               │  parse_protobuf_ast() or parse()
│     (C → protobuf → V)  │
└─────────┬───────────────┘
          ▼
┌─────────────────────────┐
│  2. Analyze             │  Inspect AST: statement type, tables,
│     (pure V)             │  WHERE conditions, parameters
└─────────┬───────────────┘
          ▼
┌─────────────────────────┐
│  3. Route / Rewrite     │  Pick shard/role, modify AST if needed
│     (pure V)             │
└─────────┬───────────────┘
          ▼
┌─────────────────────────┐
│  4. Deparse (optional)  │  If AST was modified: encode → deparse
│     (V encode + C)      │  to produce rewritten SQL string
└─────────┬───────────────┘
          ▼
    Execute on target

Hot path (no rewrite):  fingerpint + route    ~10–15 µs
Cold path (parse AST):  parse_protobuf_ast    ~33 µs
Rewrite path:          parse + modify + deparse  ~40–50 µs
```

---

## Query Routing

### Read/Write Splitting

Identify the statement type to decide which pool (primary vs replica) to route to:

```v
import pg_query

fn route_query(sql string) string {
    result := pg_query.parse_protobuf_ast(sql) or { return 'primary' }
    stmt := result.stmts[0].stmt

    match stmt {
        pg_query.SelectStmt {
            // Optionally check for FOR UPDATE, sequences, etc.
            return 'replica'
        }
        pg_query.InsertStmt, pg_query.UpdateStmt, pg_query.DeleteStmt {
            return 'primary'
        }
        pg_query.TransactionStmt {
            return 'primary'
        }
        else {
            return 'primary'
        }
    }
}
```

### Extract Table Names

For shard mapping or schema-based routing:

```v
fn extract_tables(stmt pg_query.Node) []string {
    mut tables := []string{}
    match stmt {
        pg_query.SelectStmt {
            for n in stmt.from_clause {
                if n is pg_query.RangeVar {
                    tables << n.relname
                }
                if n is pg_query.JoinExpr {
                    tables << extract_tables(n.larg)...
                    tables << extract_tables(n.rarg)...
                }
            }
        }
        pg_query.InsertStmt {
            if stmt.relation is pg_query.RangeVar {
                tables << stmt.relation.relname
            }
        }
        pg_query.UpdateStmt {
            if stmt.relation is pg_query.RangeVar {
                tables << stmt.relation.relname
            }
        }
        pg_query.DeleteStmt {
            if stmt.relation is pg_query.RangeVar {
                tables << stmt.relation.relname
            }
        }
        else {}
    }
    return tables
}
```

### Transaction-Aware Routing

Track transaction state so all statements within a `BEGIN` / `COMMIT` block go to the same
server:

```v
enum TxState {
    idle
    active
}

struct ClientSession {
    mut:
    tx_state TxState = .idle
    primary_conn int
}

fn (mut s ClientSession) route(sql string) int {
    result := pg_query.parse_protobuf_ast(sql) or { return s.primary_conn }

    for stmt in result.stmts {
        if stmt.stmt is pg_query.TransactionStmt {
            tx := stmt.stmt as pg_query.TransactionStmt
            match tx.kind {
                .trans_stmt_begin {
                    s.tx_state = .active
                    return s.primary_conn
                }
                .trans_stmt_commit, .trans_stmt_rollback {
                    s.tx_state = .idle
                }
                else {}
            }
        }
    }

    if s.tx_state == .active {
        return s.primary_conn
    }

    // Normal routing
    return route_query(sql) == 'primary' ? s.primary_conn : replica_conn()
}
```

---

## Shard Key Extraction

For sharded deployments, extract the shard key from WHERE clauses or INSERT values:

```v
fn extract_shard_key(stmt pg_query.Node) ?int {
    match stmt {
        pg_query.SelectStmt {
            return extract_where_shard_key(stmt.where_clause)
        }
        pg_query.InsertStmt {
            // Extract from VALUES or ON CONFLICT
            return extract_insert_shard_key(stmt)
        }
        else {
            return none
        }
    }
}

fn extract_where_shard_key(where_clause pg_query.Node) ?int {
    if where_clause is pg_query.AExpr {
        w := where_clause
        // Check for equality: shard_id = <value>
        if w.kind == .aexpr_op {
            for name_node in w.name {
                if name_node is pg_query.String && name_node.sval == '=' {
                    if w.lexpr is pg_query.ColumnRef {
                        col := column_ref_name(w.lexpr)
                        if col == 'tenant_id' || col == 'shard_id' {
                            if w.rexpr is pg_query.AConst {
                                if ival := w.rexpr.ival {
                                    return ival.ival
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return none
}

fn column_ref_name(n pg_query.Node) string {
    if n is pg_query.ColumnRef {
        mut parts := []string{}
        for f in n.fields {
            if f is pg_query.String {
                parts << f.sval
            }
        }
        return parts.join('.')
    }
    return ''
}
```

### Shard Routing

```v
fn shard_for_key(key int, n_shards int) int {
    return key % n_shards
}

fn route_to_shard(sql string) int {
    result := pg_query.parse_protobuf_ast(sql) or { return 0 }
    key := extract_shard_key(result.stmts[0].stmt) or { return 0 }
    return shard_for_key(key, 8)
}
```

---

## Prepared Statement Caching

Use `fingerprint()` as a cache key for prepared statements — identical query structures
produce the same hash regardless of literal values:

```v
struct PreparedStatement {
    query   string
    sql     string
    params  int
}

struct PrepCache {
    mut:
    m map[u64]PreparedStatement
}

fn (mut c PrepCache) get_or_prepare(sql string) !&PreparedStatement {
    fp := pg_query.fingerprint(sql) or { return error('parse failed') }

    if existing := c.m[fp.fingerprint] {
        return &existing
    }

    // Normalize for logging / routing
    norm := pg_query.normalize(sql) or { return error('normalize failed') }

    ps := PreparedStatement{
        query:  norm.normalized_query
        sql:    sql
        params: count_params(sql)
    }
    c.m[fp.fingerprint] = ps
    return &c.m[fp.fingerprint]
}

fn count_params(sql string) int {
    // Count $1, $2, ... style parameters
    mut n := 0
    for i := 0; i < sql.len; i++ {
        if sql[i] == `$` && i + 1 < sql.len && sql[i + 1] >= `0` && sql[i + 1] <= `9` {
            // Read number
            mut j := i + 1
            for j < sql.len && sql[j] >= `0` && sql[j] <= `9` { j++ }
            num := sql[i + 1..j].int()
            if num > n { n = num }
            i = j - 1
        }
    }
    return n
}
```

---

## Query Rewriting

### Inject Tenant Filter (Row-Level Security)

Rewrite `SELECT * FROM orders` to `SELECT * FROM orders WHERE tenant_id = 42`:

```v
fn inject_tenant_filter(result pg_query.ParseAstResult, tenant_id int) !pg_query.ParseAstResult {
    mut sel := result.stmts[0].stmt as pg_query.SelectStmt

    // Build: tenant_id = <value>
    col := pg_query.ColumnRef{
        fields: [pg_query.String{sval: 'tenant_id'}]
        location: 0
    }
    val := pg_query.AConst{
        ival: pg_query.Integer{ival: tenant_id}
        isnull: false
        location: 0
    }
    condition := pg_query.AExpr{
        kind: .aexpr_op
        name: [pg_query.String{sval: '='}]
        lexpr: col
        rexpr: val
        location: 0
    }

    if sel.where_clause is pg_query.AExpr {
        // AND with existing WHERE
        existing := sel.where_clause
        sel.where_clause = pg_query.AExpr{
            kind: .aexpr_op
            name: [pg_query.String{sval: 'AND'}]
            lexpr: existing
            rexpr: condition
            location: 0
        }
    } else {
        sel.where_clause = condition
    }

    return pg_query.ParseAstResult{
        version: result.version
        stmts: [pg_query.AstRawStmt{stmt: sel, stmt_location: 0, stmt_len: 0}]
    }
}
```

### Rewrite Table Name (Shard Mapping)

Rename `users` to `users_42` for shard routing:

```v
fn rewrite_table(result pg_query.ParseAstResult, old_name string, new_name string) pg_query.ParseAstResult {
    mut sel := result.stmts[0].stmt as pg_query.SelectStmt
    mut new_from := []pg_query.Node{}

    for n in sel.from_clause {
        if n is pg_query.RangeVar {
            mut rv := n
            if rv.relname == old_name {
                rv.relname = new_name
            }
            new_from << rv
        } else {
            new_from << n
        }
    }
    sel.from_clause = new_from

    return pg_query.ParseAstResult{
        version: result.version
        stmts: [pg_query.AstRawStmt{stmt: sel, stmt_location: 0, stmt_len: 0}]
    }
}

fn deparse_and_execute(result pg_query.ParseAstResult) !string {
    return pg_query.deparse_ast(result)
}
```

### Full Rewrite Pipeline

```v
fn rewrite_for_shard(sql string, tenant_id int, shard_suffix string) !string {
    // 1. Parse
    result := pg_query.parse_protobuf_ast(sql) or { return err }

    // 2. Inject tenant filter
    result = inject_tenant_filter(result, tenant_id)!

    // 3. Rewrite table names
    result = rewrite_table(result, 'orders', 'orders_${shard_suffix}')

    // 4. Deparse to SQL
    return pg_query.deparse_ast(result)
}
```

---

## DDL Detection

Block or warn on schema changes:

```v
fn handle_query(sql string) ! {
    util := pg_query.is_utility_stmt(sql) or { return err }

    if util.items.len > 0 && util.items[0] {
        // Check specific DDL types
        result := pg_query.parse_protobuf_ast(sql) or { return err }
        match result.stmts[0].stmt {
            pg_query.CreateStmt {
                return error('DDL not allowed: CREATE TABLE')
            }
            pg_query.AlterTableStmt {
                return error('DDL not allowed: ALTER TABLE')
            }
            pg_query.DropStmt {
                return error('DDL not allowed: DROP')
            }
            pg_query.IndexStmt {
                return error('DDL not allowed: CREATE INDEX')
            }
            else {}
        }
    }

    // Proceed with DML
    execute(sql)
}
```

---

## Multi-Statement Splitting

Split compound queries for per-statement routing:

```v
fn split_and_route(batch string) {
    split := pg_query.split_with_parser(batch) or { return }

    for s in split.stmts {
        stmt_sql := batch[s.stmt_location..s.stmt_location + s.stmt_len]
        route := route_query(stmt_sql)
        // Forward to appropriate connection
    }
}
```

---

## Concurrency & Thread Safety

The C parser uses thread-local memory contexts (`__thread` TLS). V's `spawn` creates OS threads,
so multiple parser calls from different goroutines are safe:

```v
fn worker(id int, queries []string) {
    for q in queries {
        pg_query.parse_protobuf_ast(q) or { continue }
    }
}

fn main() {
    mut threads := []thread void{}
    for i in 0 .. 10 {
        threads << spawn worker(i, queries)
    }
    threads.wait()
    // All done — 0 errors, verified up to 120k parses
}
```

**Important**: Do NOT call `pg_query.exit()` while other threads may be actively parsing.
`exit()` frees thread-local memory contexts shared across all threads.

---

## Performance Checklist

| Operation | Latency | Pure V? | C Bridge? |
|---|---|---|---|
| `fingerprint()` | ~9 µs | No | Yes (fastest C path) |
| `normalize()` | ~4 µs | No | Yes |
| `parse()` (JSON) | ~7 µs | No | Yes |
| `parse_protobuf_ast()` | ~33 µs | Partial | C for parse, V for decode |
| `parse_json_ast()` | ~94 µs | Yes | No (pure V JSON decode) |
| `encode_parse_result()` | ~111 µs | Yes | No |
| `deparse_ast()` | ~160 µs | Partial | V encode, C deparse |
| `is_utility_stmt()` | ~2 µs | No | Yes |

### Optimization Tips

1. **Hot path**: Use `fingerprint()` or `normalize()` for routing decisions — they're 3–10×
   faster than full parse.
2. **Cold path**: Cache `parse_protobuf_ast()` results keyed by fingerprint to avoid repeated
   parses for frequently-executed queries.
3. **Batch splitting**: Use `split_with_scanner()` instead of `split_with_parser()` when you
   only need statement boundaries, not full parse trees.
4. **Selective parse**: Only parse to AST when you need to inspect or rewrite. Use
   `is_utility_stmt()` for the common case of simple DDL detection.
5. **Rewrite sparingly**: Query rewriting (encode + deparse) adds ~10–20 µs. Cache rewritten
   SQL keyed by fingerprint + tenant_id or similar.

---

## Production Considerations

- **Connection pools**: Maintain separate pools for primary and replicas. Use query routing
  to select the pool.
- **Health checks**: Regularly ping replicas and remove unhealthy ones from rotation.
- **TLS termination**: Handle TLS at the proxy layer, then forward plaintext (or re-encrypt)
  to backends.
- **pg_hba.conf**: The proxy should authenticate clients and maintain its own connection
  credentials to backends.
- **Metrics**: Track parse times, cache hit rates, shard distribution, and pool utilization.
