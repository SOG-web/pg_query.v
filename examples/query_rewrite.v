import pg_query

fn column_ref_name(n pg_query.Node) string {
	if n is pg_query.ColumnRef {
		mut parts := []string{}
		for f in n.fields {
			if f is pg_query.String {
				parts << f.sval
			} else if f is pg_query.AStar {
				parts << '*'
			}
		}
		return parts.join('.')
	}
	return '?'
}

fn rewrite_table_names(s pg_query.SelectStmt, old_name string, new_name string) pg_query.SelectStmt {
	mut s2 := s
	mut new_from := []pg_query.Node{}
	for n in s.from_clause {
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
	s2.from_clause = new_from
	return s2
}

fn add_limit(s pg_query.SelectStmt, limit int) pg_query.SelectStmt {
	mut s2 := s
	s2.limit_option = .limit_option_count
	s2.limit_count = pg_query.AConst{
		ival: pg_query.Integer{
			ival: limit
		}
		isnull: false
		location: 0
	}
	return s2
}

fn add_where_eq(s pg_query.SelectStmt, col_name string, val int) pg_query.SelectStmt {
	mut s2 := s
	col_parts := col_name.split('.')
	mut fields := []pg_query.Node{}
	for p in col_parts {
		fields << pg_query.String{sval: p}
	}
	cr := pg_query.ColumnRef{
		fields: fields
		location: 0
	}
	ac := pg_query.AConst{
		ival: pg_query.Integer{
			ival: val
		}
		isnull: false
		location: 0
	}
	op := pg_query.AExpr{
		kind: .aexpr_op
		name: [pg_query.String{sval: '='}]
		lexpr: cr
		rexpr: ac
		location: 0
	}
	s2.where_clause = op
	return s2
}

fn main() {
	// ── 1. Parse to typed AST ──
	result := pg_query.parse_protobuf_ast('SELECT id, name, email FROM users WHERE age > 21') or {
		eprintln('Parse error: ${err}')
		return
	}
	stmt := result.stmts[0]
	println('=== Original ===')
	println('  SQL: SELECT id, name, email FROM users WHERE age > 21')

	sel := stmt.stmt as pg_query.SelectStmt
	println('  from: users')
	println('  columns: id, name, email')
	println('  where: age > 21')

	// ── 2. Query rewrite: rename table ──
	sel2 := rewrite_table_names(sel, 'users', 'users_v2')
	deparsed2 := pg_query.deparse_ast(pg_query.ParseAstResult{
		version: result.version
		stmts: [pg_query.AstRawStmt{
			stmt_location: stmt.stmt_location
			stmt_len: stmt.stmt_len
			stmt: sel2
		}]
	}) or { eprintln('Deparse error: ${err}'); return }
	println('\n=== Table rename (users → users_v2) ===')
	println('  ${deparsed2}')

	// ── 3. Query rewrite: add WHERE clause ──
	sel3 := add_where_eq(sel, 'tenant_id', 42)
	deparsed3 := pg_query.deparse_ast(pg_query.ParseAstResult{
		version: result.version
		stmts: [pg_query.AstRawStmt{
			stmt_location: stmt.stmt_location
			stmt_len: stmt.stmt_len
			stmt: sel3
		}]
	}) or { eprintln('Deparse error: ${err}'); return }
	println('\n=== Add tenant filter (tenant_id = 42) ===')
	println('  ${deparsed3}')

	// ── 4. Query rewrite: add LIMIT ──
	sel4 := add_limit(sel, 100)
	deparsed4 := pg_query.deparse_ast(pg_query.ParseAstResult{
		version: result.version
		stmts: [pg_query.AstRawStmt{
			stmt_location: stmt.stmt_location
			stmt_len: stmt.stmt_len
			stmt: sel4
		}]
	}) or { eprintln('Deparse error: ${err}'); return }
	println('\n=== Add LIMIT 100 ===')
	println('  ${deparsed4}')

	// ── 5. Full pipeline: parse → rewrite → encode → deparse ──
	println('\n=== Pure-V pipeline summary ===')
	println('  1. parse_protobuf_ast()  → typed AST structs (pure V)')
	println('  2. modify structs        → AST manipulation (pure V)')
	println('  3. encode_parse_result() → protobuf bytes    (pure V)')
	println('  4. deparse_protobuf()    → SQL string        (C bridge)')
}
