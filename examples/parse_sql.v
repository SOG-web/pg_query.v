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
	} else {
		println('  where: (complex expression)')
	}
	if s.distinct_clause.len > 0 {
		println('  distinct_on: true')
	}
}

fn parse_single(input string) string {
	res := pg_query.parse_protobuf_ast(input) or { return 'ERROR: ${err}' }
	mut preview := input
	if preview.len > 50 { preview = preview[..50] }
	return '${preview}... -> ${res.stmts.len} statement(s)'
}

// Heavy, multi-nested, complex queries
const heavy_select = 'SELECT DISTINCT ON (e.department_id) e.id, e.name, e.salary, ' +
	'e.department_id, d.name AS department_name, ' +
	'ROUND(AVG(e.salary) OVER (PARTITION BY e.department_id), 2) AS dept_avg_salary, ' +
	'ROW_NUMBER() OVER (PARTITION BY e.department_id ORDER BY e.salary DESC) AS rank_in_dept, ' +
	'CASE WHEN e.salary > AVG(e.salary) OVER (PARTITION BY e.department_id) * 1.5 ' +
	'THEN \'overpaid\' WHEN e.salary < AVG(e.salary) OVER (PARTITION BY e.department_id) * 0.5 ' +
	'THEN \'underpaid\' ELSE \'market_rate\' END AS comp_analysis, ' +
	'json_build_object(\'id\', e.id, \'name\', e.name, \'department\', d.name, ' +
	'\'peers\', (SELECT json_agg(peer.name) FROM employees peer ' +
	'WHERE peer.department_id = e.department_id AND peer.id != e.id ' +
	'AND ABS(peer.salary - e.salary) < e.salary * 0.1 ORDER BY peer.name)) AS employee_json, ' +
	'(SELECT COUNT(*) FROM tasks t WHERE t.assignee_id = e.id AND t.status = \'open\') AS open_tasks, ' +
	'(SELECT COUNT(*) FROM tasks t WHERE t.assignee_id = e.id AND t.status = \'overdue\') AS overdue_tasks ' +
	'FROM employees e JOIN departments d ON e.department_id = d.id ' +
	'WHERE e.status = \'active\' AND e.salary > 0 ORDER BY e.department_id, e.salary DESC'

const heavy_analytical = 'SELECT d.name AS department, e.role, ' +
	'COUNT(DISTINCT e.id) AS emp_count, ROUND(AVG(e.salary), 2) AS avg_salary, ' +
	'SUM(e.salary) AS total_salary_cost, ' +
	'COUNT(*) FILTER (WHERE e.status = \'active\') AS active_count, ' +
	'COUNT(*) FILTER (WHERE e.status = \'on_leave\') AS on_leave_count, ' +
	'json_build_array(json_build_object(\'status\', \'active\', \'count\', ' +
	'COUNT(*) FILTER (WHERE e.status = \'active\'))) AS status_breakdown, ' +
	'DENSE_RANK() OVER (ORDER BY SUM(e.salary) DESC) AS cost_rank, ' +
	'SUM(COUNT(*)) OVER (ORDER BY d.name ' +
	'ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_emp_count ' +
	'FROM departments d JOIN employees e ON e.dept_id = d.id ' +
	'WHERE d.active = true GROUP BY d.id, d.name, e.role ORDER BY d.name, cost_rank'

const heavy_update = 'UPDATE employees e SET salary = CASE ' +
	'WHEN e.performance_rating >= 4 AND e.status = \'active\' THEN e.salary * 1.15 + 2000 ' +
	'WHEN e.performance_rating >= 3 AND e.status = \'active\' THEN e.salary * 1.08 + 1000 ' +
	'WHEN e.performance_rating >= 2 AND e.status = \'active\' THEN e.salary * 1.03 ' +
	'ELSE e.salary END, updated_at = NOW(), ' +
	'status = CASE WHEN e.performance_rating < 2 AND EXISTS ' +
	'(SELECT 1 FROM performance_reviews pr WHERE pr.employee_id = e.id AND pr.score < 2 ' +
	'AND pr.review_date >= NOW() - INTERVAL \'90 days\') ' +
	'THEN \'at_risk\' ELSE e.status END, version = e.version + 1 ' +
	'FROM departments d WHERE e.dept_id = d.id ' +
	'AND d.name = ANY (ARRAY[\'Engineering\', \'Product\', \'Design\']) ' +
	'AND e.hire_date < \'2023-01-01\'::date ' +
	'AND e.id NOT IN (SELECT employee_id FROM exit_interviews WHERE scheduled = true) ' +
	'RETURNING e.id, e.name, e.salary AS new_salary, e.status, e.version'

const heavy_insert = 'INSERT INTO order_summary (customer_id, customer_name, ' +
	'order_count, total_spent, avg_order_value, last_order_date, categories) ' +
	'SELECT c.id, c.name, COALESCE(ord.order_count, 0), COALESCE(ord.total_spent, 0.00), ' +
	'CASE WHEN ord.order_count > 0 THEN ROUND(ord.total_spent / ord.order_count, 2) ELSE 0.00 END, ' +
	'COALESCE(ord.last_order_date, NOW()), COALESCE(lat.categories, \'[]\'::json) ' +
	'FROM customers c LEFT JOIN LATERAL (SELECT COUNT(o.id) AS order_count, ' +
	'SUM(o.total) AS total_spent, MAX(o.created_at) AS last_order_date ' +
	'FROM orders o WHERE o.customer_id = c.id AND o.status != \'cancelled\' ' +
	'AND o.created_at >= NOW() - INTERVAL \'365 days\') ord ON true ' +
	'LEFT JOIN LATERAL (SELECT json_agg(DISTINCT p.category) AS categories ' +
	'FROM orders o2 JOIN order_items oi ON o2.id = oi.order_id ' +
	'JOIN products p ON oi.product_id = p.id ' +
	'WHERE o2.customer_id = c.id AND o2.created_at >= NOW() - INTERVAL \'365 days\') lat ON true ' +
	'WHERE c.status = \'active\' AND ord.order_count IS NOT NULL AND ord.order_count > 0 ' +
	'ORDER BY ord.total_spent DESC LIMIT 100 RETURNING id, customer_id, order_count, total_spent'

const heavy_delete = 'DELETE FROM sessions s WHERE s.expires_at < NOW() - INTERVAL \'30 days\' ' +
	'AND s.id NOT IN (SELECT session_id FROM active_connections ' +
	'WHERE last_heartbeat > NOW() - INTERVAL \'5 minutes\') ' +
	'AND (s.user_id NOT IN (SELECT id FROM users WHERE status = \'locked\') ' +
	'OR s.created_at < NOW() - INTERVAL \'90 days\') ' +
	'AND EXISTS (SELECT 1 FROM session_logs sl ' +
	'WHERE sl.session_id = s.id AND sl.event = \'expire_warning\') ' +
	'RETURNING s.id, s.user_id, s.created_at, s.expires_at'

const heavy_nested = 'SELECT sub3.region, sub3.product_category, sub3.total_revenue, ' +
	'sub3.rank_in_region, CASE WHEN sub3.rank_in_region <= 3 THEN \'top_3\' ' +
	'WHEN sub3.rank_in_region <= 10 THEN \'top_10\' ELSE \'other\' END AS tier, ' +
	'COALESCE(lat.top_product, \'none\') AS top_product_in_region FROM ' +
	'(SELECT sub2.region, sub2.product_category, sub2.total_revenue, ' +
	'ROW_NUMBER() OVER (PARTITION BY sub2.region ORDER BY sub2.total_revenue DESC) AS rank_in_region ' +
	'FROM (SELECT r.name AS region, pc.name AS product_category, SUM(s.amount) AS total_revenue, ' +
	'COUNT(*) FILTER (WHERE s.status = \'completed\') AS completed_count ' +
	'FROM sales s JOIN products p ON s.product_id = p.id ' +
	'JOIN product_categories pc ON p.category_id = pc.id ' +
	'JOIN stores st ON s.store_id = st.id JOIN regions r ON st.region_id = r.id ' +
	'WHERE s.sale_date >= \'2024-01-01\'::date AND s.sale_date < \'2025-01-01\'::date ' +
	'AND s.amount > 0 AND s.status IN (\'completed\', \'refunded\') ' +
	'GROUP BY r.id, r.name, pc.id, pc.name HAVING SUM(s.amount) > 10000) sub2) sub3 ' +
	'LEFT JOIN LATERAL (SELECT p2.name AS top_product FROM sales s2 ' +
	'JOIN products p2 ON s2.product_id = p2.id JOIN stores st2 ON s2.store_id = st2.id ' +
	'WHERE st2.region_id = (SELECT id FROM regions WHERE name = sub3.region) ' +
	'AND s2.sale_date >= \'2024-01-01\'::date ' +
	'GROUP BY p2.id, p2.name ORDER BY SUM(s2.amount) DESC LIMIT 1) lat ON true ' +
	'ORDER BY sub3.region, sub3.rank_in_region'

fn main() {
	// ── 1. Typed AST with tree traversal (heavy SELECT) ──
	result := pg_query.parse_protobuf_ast(heavy_select) or {
		eprintln('Parse error: ${err}')
		return
	}
	println('=== Typed AST (traversed): ${heavy_select[..60]}... ===')
	for stmt in result.stmts {
		match stmt.stmt {
			pg_query.SelectStmt { print_select(stmt.stmt) }
			else { println('  ${typeof(stmt.stmt).name}') }
		}
	}

	// ── 2. Parse heavy SELECT to JSON ──
	json_res := pg_query.parse(heavy_nested) or {
		eprintln('Parse error: ${err}')
		return
	}
	println('\n=== Parse tree (JSON): 4-level nested SELECT ===')
	mut tree := json_res.parse_tree
	if tree.len > 500 { tree = tree[..500] }
	println('${tree}...')
	println('  (${json_res.parse_tree.len} chars total)')

	// ── 3. Normalize (anonymize literals) heavy query ──
	norm := pg_query.normalize(heavy_update) or {
		eprintln('Normalize error: ${err}')
		return
	}
	println('\n=== Normalized (heavy UPDATE with CASE) ===')
	println(norm.normalized_query)

	// ── 4. Fingerprint (consistent hash for same query structure) ──
	fp := pg_query.fingerprint(heavy_analytical) or {
		eprintln('Fingerprint error: ${err}')
		return
	}
	println('\n=== Fingerprint (analytical query) ===')
	println('  hex: ${fp.fingerprint_str}')
	println('  int: ${fp.fingerprint}')

	// ── 5. Check if DDL ──
	util := pg_query.is_utility_stmt('CREATE TABLE IF NOT EXISTS measurements_y2024m12 (' +
		'CHECK (measured_at >= \'2024-12-01\'::date AND measured_at < \'2025-01-01\'::date), ' +
		'FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE' +
		') INHERITS (measurements)') or {
		eprintln('IsUtility error: ${err}')
		return
	}
	println('\n=== Utility check (CREATE TABLE ... INHERITS) ===')
	println('  is utility: ${util.items[0]}')

	// ── 6. Parse to protobuf (compact binary) heavy query ──
	pb := pg_query.parse_protobuf(heavy_delete) or {
		eprintln('Protobuf error: ${err}')
		return
	}
	println('\n=== Protobuf (heavy DELETE with EXISTS) ===')
	println('  bytes: ${pb.parse_tree.len}')
	println('  hex:   ${pb.parse_tree.hex().substr(0, 80)}...')

	// ── 7. Split multi-statement SQL (heavy queries) ──
	multi_sql := heavy_select + '; ' + heavy_analytical + '; ' + heavy_nested
	split := pg_query.split_with_scanner(multi_sql) or {
		eprintln('Split error: ${err}')
		return
	}
	println('\n=== Split statements (3 heavy queries) ===')
	for i, stmt in split.stmts {
		println('  ${i + 1}. location=${stmt.stmt_location}, len=${stmt.stmt_len}')
	}

	// ── 8. Protobuf roundtrip: parse -> deparse back to SQL ──
	deparsed := pg_query.deparse_protobuf(pb.parse_tree) or {
		eprintln('Deparse error: ${err}')
		return
	}
	println('\n=== Deparse roundtrip (heavy DELETE) ===')
	mut dq := deparsed.query
	if dq.len > 200 { dq = dq[..200] }
	println('  ${dq}...')

	// ── 9. Pure-V AST roundtrip: parse -> typed AST -> encode -> deparse ──
	ast := pg_query.parse_protobuf_ast(heavy_insert) or {
		eprintln('Parse error: ${err}')
		return
	}
	encoded := pg_query.encode_ast(ast)
	deparsed2 := pg_query.deparse_protobuf(encoded) or {
		eprintln('Deparse error: ${err}')
		return
	}
	println('\n=== Pure-V AST roundtrip (heavy INSERT + LATERAL) ===')
	mut dq2 := deparsed2.query
	if dq2.len > 200 { dq2 = dq2[..200] }
	println('  input:  ${heavy_insert[..60]}...')
	println('  output: ${dq2}...')
	println('  V decode + V encode + C deparse')

	// ── 10. Query rewrite: modify AST in pure V (rename table in a heavy query) ──
	ast2 := pg_query.parse_protobuf_ast(heavy_select) or { panic(err) }
	mut sel := ast2.stmts[0].stmt as pg_query.SelectStmt
	mut new_from := []pg_query.Node{}
	for n in sel.from_clause {
		if n is pg_query.RangeVar {
			mut rv := n
			if rv.relname == 'employees' {
				rv.relname = 'employees_v2'
			}
			new_from << rv
		} else {
			new_from << n
		}
	}
	sel.from_clause = new_from
	rewritten := pg_query.deparse_ast(pg_query.ParseAstResult{
		version: ast2.version
		stmts: [pg_query.AstRawStmt{
			stmt_location: ast2.stmts[0].stmt_location
			stmt_len: ast2.stmts[0].stmt_len
			stmt: sel
		}]
	}) or { eprintln('Rewrite deparse error: ${err}'); return }
	println('\n=== Query rewrite (employees -> employees_v2) ===')
	mut rw := rewritten
	if rw.len > 200 { rw = rw[..200] }
	println('  ${rw}...')

	// ── 11. Concurrent parsing (heavy queries) ──
	println('\n=== Concurrent parsing (heavy queries) ===')
	queries := [heavy_select, heavy_analytical + '; ' + heavy_nested,
		heavy_delete, heavy_update, heavy_insert,
		'DROP TABLE IF EXISTS measurements_y2024m12']
	mut threads := []thread string{}
	for q in queries {
		threads << spawn parse_single(q)
	}
	results := threads.wait()
	for r in results {
		println('  ${r}')
	}

	// ── 12. Comment extraction and roundtrip ──
	commented_sql := 'SELECT 1; -- first statement\nSELECT 2 /* block */; SELECT 3 -- trailing'
	comments_res := pg_query.deparse_comments_for_query(commented_sql) or {
		eprintln('Comment extraction error: ${err}')
		return
	}
	println('\n=== Comment extraction ===')
	println('  SQL: ${commented_sql.replace('\n', '\\n')}')
	println('  Comments found: ${comments_res.comments.len}')
	for i, c in comments_res.comments {
		println('    ${i + 1}. loc=${c.match_location} before=${c.newlines_before_comment} after=${c.newlines_after_comment}')
		println('       text: ${c.str.replace('\n', '\\n')}')
	}

	// Roundtrip: parse a query with inline comment, then deparse with comments preserved.
	// Note: comments between AST nodes are preserved; trailing end-of-statement comments
	// are not preserved (C library limitation).
	comment_roundtrip_sql := 'SELECT a, /* my comment */ b FROM t'
	pb_com := pg_query.parse_protobuf(comment_roundtrip_sql) or {
		eprintln('Parse error: ${err}')
		return
	}
	com_res := pg_query.deparse_comments_for_query(comment_roundtrip_sql) or {
		eprintln('Comment extraction error: ${err}')
		return
	}
	dep_with_comments := pg_query.deparse_protobuf_opts(pb_com.parse_tree, pg_query.DeparseOpts{
		comments: com_res.comments
	}) or {
		eprintln('Deparse error: ${err}')
		return
	}
	println('\n=== Comment roundtrip (parse → deparse with comments) ===')
	println('  input:  ${comment_roundtrip_sql}')
	println('  output: ${dep_with_comments.query}')

	// Without comments (default deparse — comment is stripped)
	dep_no_comments := pg_query.deparse_protobuf(pb_com.parse_tree) or {
		eprintln('Deparse error: ${err}')
		return
	}
	println('  default: ${dep_no_comments.query}')
}
