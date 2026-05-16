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
	return typeof(n).name
}

fn target_info(t pg_query.ResTarget) string {
	name := if t.name != '' { ' AS ${t.name}' } else { '' }
	return '${column_ref_name(t.val)}${name}'
}

fn print_select(s pg_query.SelectStmt) {
	println('  columns:')
	for t in s.target_list {
		if t is pg_query.ResTarget {
			println('    - ${target_info(t)}')
		}
	}
	println('  tables:')
	for f in s.from_clause {
		if f is pg_query.RangeVar {
			println('    - ${f.relname}')
		}
	}
	if s.where_clause is pg_query.AExpr {
		w := s.where_clause as pg_query.AExpr
		mut parts := []string{}
		if w.lexpr is pg_query.ColumnRef {
			parts << column_ref_name(w.lexpr)
		}
		for n in w.name {
			if n is pg_query.String {
				parts << n.sval
			}
		}
		ac := w.rexpr
		if ac is pg_query.AConst {
			if ival := ac.ival {
				parts << ival.ival.str()
			}
		}
		println('  where: ${parts.join(' ')}')
	}
}

fn parse_single(input string) string {
	res := pg_query.parse_protobuf_ast(input) or { return 'ERROR: ${err}' }
	return '${input} -> ${res.stmts.len} statement(s)'
}

fn main() {
	// ── 1. Typed AST with tree traversal ──
	result := pg_query.parse_protobuf_ast('SELECT id, name FROM users WHERE age > 21') or {
		eprintln('Parse error: ${err}')
		return
	}
	println('=== Typed AST (traversed) ===')
	for stmt in result.stmts {
		match stmt.stmt {
			pg_query.SelectStmt { print_select(stmt.stmt) }
			else { println('  ${typeof(stmt.stmt).name}') }
		}
	}

	// ── 2. Parse SQL to JSON ──
	json_res := pg_query.parse('SELECT id, name FROM users WHERE age > 21') or {
		eprintln('Parse error: ${err}')
		return
	}
	println('\n=== Parse tree (JSON) ===')
	println(json_res.parse_tree)

	// ── 3. Normalize (anonymize literals) ──
	norm := pg_query.normalize('SELECT * FROM users WHERE id = 42') or {
		eprintln('Normalize error: ${err}')
		return
	}
	println('\n=== Normalized ===')
	println(norm.normalized_query)

	// ── 4. Fingerprint (consistent hash for same query structure) ──
	fp := pg_query.fingerprint('SELECT 1') or {
		eprintln('Fingerprint error: ${err}')
		return
	}
	println('\n=== Fingerprint ===')
	println('  hex: ${fp.fingerprint_str}')
	println('  int: ${fp.fingerprint}')

	// ── 5. Check if DDL ──
	util := pg_query.is_utility_stmt('CREATE TABLE t (id int)') or {
		eprintln('IsUtility error: ${err}')
		return
	}
	println('\n=== Utility check ===')
	println('  CREATE TABLE is utility: ${util.items[0]}')

	// ── 6. Parse to protobuf (compact binary) ──
	pb := pg_query.parse_protobuf('SELECT 1') or {
		eprintln('Protobuf error: ${err}')
		return
	}
	println('\n=== Protobuf ===')
	println('  bytes: ${pb.parse_tree.len}')
	println('  hex:   ${pb.parse_tree.hex()}')

	// ── 7. Split multi-statement SQL ──
	split := pg_query.split_with_scanner('SELECT 1; SELECT 2; SELECT 3') or {
		eprintln('Split error: ${err}')
		return
	}
	println('\n=== Split statements ===')
	for i, stmt in split.stmts {
		println('  ${i + 1}. location=${stmt.stmt_location}, len=${stmt.stmt_len}')
	}

	// ── 8. Protobuf roundtrip: parse -> deparse back to SQL ──
	deparsed := pg_query.deparse_protobuf(pb.parse_tree) or {
		eprintln('Deparse error: ${err}')
		return
	}
	println('\n=== Deparse roundtrip ===')
	println('  ${deparsed.query}')

	// ── 9. Concurrent parsing ──
	// The C parser uses thread-local memory contexts and is safe to
	// call from multiple OS threads simultaneously. Do NOT call exit()
	// while other threads may be actively parsing.
	println('\n=== Concurrent parsing ===')
	queries := ['SELECT 1', 'SELECT 2; SELECT 3', 'CREATE TABLE t (id int)',
		'DELETE FROM t WHERE id = 0', 'UPDATE t SET x = 1', 'SELECT count(*) FROM t', 'DROP TABLE t',
		'INSERT INTO t VALUES (1)']
	mut threads := []thread string{}
	for q in queries {
		threads << spawn parse_single(q)
	}
	results := threads.wait()
	for r in results {
		println('  ${r}')
	}
}
