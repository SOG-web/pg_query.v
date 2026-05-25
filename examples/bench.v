import pg_query
import time

// Heavy, multi-nested, complex queries exercising all parser/AST paths
const queries = [
	// 1. 4-level nested SELECT with LATERAL, window functions, FILTER aggregates, CASE
	'SELECT sub3.region, sub3.product_category, sub3.total_revenue, sub3.rank_in_region, ' +
		"CASE WHEN sub3.rank_in_region <= 3 THEN 'top_3' " +
		"WHEN sub3.rank_in_region <= 10 THEN 'top_10' ELSE 'other' END AS tier, " +
		"COALESCE(lat.top_product, 'none') AS top_product_in_region " +
		'FROM (SELECT sub2.region, sub2.product_category, sub2.total_revenue, ' +
		'ROW_NUMBER() OVER (PARTITION BY sub2.region ORDER BY sub2.total_revenue DESC) AS rank_in_region ' +
		'FROM (SELECT r.name AS region, pc.name AS product_category, SUM(s.amount) AS total_revenue, ' +
		"COUNT(*) FILTER (WHERE s.status = 'completed') AS completed_count " +
		'FROM sales s JOIN products p ON s.product_id = p.id ' +
		'JOIN product_categories pc ON p.category_id = pc.id ' +
		'JOIN stores st ON s.store_id = st.id JOIN regions r ON st.region_id = r.id ' +
		"WHERE s.sale_date >= '2024-01-01'::date AND s.sale_date < '2025-01-01'::date " +
		"AND s.amount > 0 AND s.status IN ('completed', 'refunded') " +
		'GROUP BY r.id, r.name, pc.id, pc.name HAVING SUM(s.amount) > 10000) sub2) sub3 ' +
		'LEFT JOIN LATERAL (SELECT p2.name AS top_product FROM sales s2 ' +
		'JOIN products p2 ON s2.product_id = p2.id JOIN stores st2 ON s2.store_id = st2.id ' +
		'WHERE st2.region_id = (SELECT id FROM regions WHERE name = sub3.region) ' +
		"AND s2.sale_date >= '2024-01-01'::date " +
		'GROUP BY p2.id, p2.name ORDER BY SUM(s2.amount) DESC LIMIT 1) lat ON true ' +
		'ORDER BY sub3.region, sub3.rank_in_region',
	// 2. Complex analytical with JSON aggregation, window functions, FILTER, correlated subqueries
	'SELECT d.name AS department, e.role, ' +
		'COUNT(DISTINCT e.id) AS emp_count, ROUND(AVG(e.salary), 2) AS avg_salary, ' +
		'SUM(e.salary) AS total_salary_cost, ' +
		"COUNT(*) FILTER (WHERE e.status = 'active') AS active_count, " +
		"COUNT(*) FILTER (WHERE e.status = 'on_leave') AS on_leave_count, " +
		"COUNT(*) FILTER (WHERE e.status = 'terminated') AS terminated_count, " +
		"ROUND(AVG(e.salary) FILTER (WHERE e.status = 'active'), 2) AS avg_active_salary, " +
		"json_build_array(json_build_object('status', 'active', 'count', " +
		"COUNT(*) FILTER (WHERE e.status = 'active')), " +
		"json_build_object('status', 'on_leave', 'count', " +
		"COUNT(*) FILTER (WHERE e.status = 'on_leave')), " +
		"json_build_object('status', 'terminated', 'count', " +
		"COUNT(*) FILTER (WHERE e.status = 'terminated'))) AS status_breakdown, " +
		'(SELECT json_agg(sub) FROM (SELECT e2.name, e2.salary, e2.status FROM employees e2 ' +
		'WHERE e2.dept_id = d.id AND e2.salary > AVG(e.salary) ' +
		'ORDER BY e2.salary DESC LIMIT 5) sub) AS top_above_avg, ' +
		'DENSE_RANK() OVER (ORDER BY SUM(e.salary) DESC) AS cost_rank, ' +
		'SUM(COUNT(*)) OVER (ORDER BY d.name ' +
		'ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_emp_count, ' +
		'FIRST_VALUE(e.role) OVER (PARTITION BY d.id ORDER BY e.salary DESC) AS highest_paid_role ' +
		'FROM departments d JOIN employees e ON e.dept_id = d.id ' +
		'WHERE d.active = true GROUP BY d.id, d.name, e.role ORDER BY d.name, cost_rank',
	// 3. Multi-table UPDATE with CASE expressions, correlated subquery, RETURNING
	'UPDATE employees e SET salary = CASE ' +
		"WHEN e.performance_rating >= 4 AND e.status = 'active' THEN e.salary * 1.15 + 2000 " +
		"WHEN e.performance_rating >= 3 AND e.status = 'active' THEN e.salary * 1.08 + 1000 " +
		"WHEN e.performance_rating >= 2 AND e.status = 'active' THEN e.salary * 1.03 " +
		'ELSE e.salary END, updated_at = NOW(), ' +
		'status = CASE WHEN e.performance_rating < 2 AND EXISTS ' +
		'(SELECT 1 FROM performance_reviews pr WHERE pr.employee_id = e.id AND pr.score < 2 ' +
		"AND pr.review_date >= NOW() - INTERVAL '90 days') " +
		"THEN 'at_risk' ELSE e.status END, version = e.version + 1 " +
		'FROM departments d WHERE e.dept_id = d.id ' +
		"AND d.name = ANY (ARRAY['Engineering', 'Product', 'Design']) " +
		"AND e.hire_date < '2023-01-01'::date " +
		'AND e.id NOT IN (SELECT employee_id FROM exit_interviews WHERE scheduled = true) ' +
		'RETURNING e.id, e.name, e.salary AS new_salary, e.status, e.version',
	// 4. Complex INSERT with LATERAL, multi-level subqueries, CASE, RETURNING
	'INSERT INTO order_summary (customer_id, customer_name, order_count, total_spent, ' +
		'avg_order_value, last_order_date, categories) ' +
		'SELECT c.id, c.name, COALESCE(ord.order_count, 0), COALESCE(ord.total_spent, 0.00), ' +
		'CASE WHEN ord.order_count > 0 THEN ROUND(ord.total_spent / ord.order_count, 2) ' +
		'ELSE 0.00 END, COALESCE(ord.last_order_date, NOW()), ' +
		"COALESCE(lat.categories, '[]'::json) FROM customers c " +
		'LEFT JOIN LATERAL (SELECT COUNT(o.id) AS order_count, SUM(o.total) AS total_spent, ' +
		'MAX(o.created_at) AS last_order_date FROM orders o ' +
		"WHERE o.customer_id = c.id AND o.status != 'cancelled' " +
		"AND o.created_at >= NOW() - INTERVAL '365 days') ord ON true " +
		'LEFT JOIN LATERAL (SELECT json_agg(DISTINCT p.category) AS categories ' +
		'FROM orders o2 JOIN order_items oi ON o2.id = oi.order_id ' +
		'JOIN products p ON oi.product_id = p.id ' +
		"WHERE o2.customer_id = c.id AND o2.created_at >= NOW() - INTERVAL '365 days') lat ON true " +
		"WHERE c.status = 'active' AND ord.order_count IS NOT NULL AND ord.order_count > 0 " +
		'ORDER BY ord.total_spent DESC LIMIT 100 ' +
		'RETURNING id, customer_id, order_count, total_spent',
	// 5. Complex DELETE with multi-level EXISTS, NOT IN, boolean OR, RETURNING
	"DELETE FROM sessions s WHERE s.expires_at < NOW() - INTERVAL '30 days' " +
		'AND s.id NOT IN (SELECT session_id FROM active_connections ' +
		"WHERE last_heartbeat > NOW() - INTERVAL '5 minutes') " +
		"AND (s.user_id NOT IN (SELECT id FROM users WHERE status = 'locked') " +
		"OR s.created_at < NOW() - INTERVAL '90 days') " +
		'AND EXISTS (SELECT 1 FROM session_logs sl ' +
		"WHERE sl.session_id = s.id AND sl.event = 'expire_warning') " +
		'RETURNING s.id, s.user_id, s.created_at, s.expires_at',
	// 6. Complex SELECT with DISTINCT ON, window functions, JSON, nested CASE, multi-level subqueries
	'SELECT DISTINCT ON (e.department_id) e.id, e.name, e.salary, e.department_id, ' +
		'd.name AS department_name, ' +
		'ROUND(AVG(e.salary) OVER (PARTITION BY e.department_id), 2) AS dept_avg_salary, ' +
		'ROW_NUMBER() OVER (PARTITION BY e.department_id ORDER BY e.salary DESC) AS rank_in_dept, ' +
		'CASE WHEN e.salary > AVG(e.salary) OVER (PARTITION BY e.department_id) * 1.5 ' +
		"THEN 'overpaid' " +
		'WHEN e.salary < AVG(e.salary) OVER (PARTITION BY e.department_id) * 0.5 ' +
		"THEN 'underpaid' ELSE 'market_rate' END AS comp_analysis, " +
		"json_build_object('id', e.id, 'name', e.name, 'department', d.name, " +
		"'peers', (SELECT json_agg(peer.name) FROM employees peer " +
		'WHERE peer.department_id = e.department_id AND peer.id != e.id ' +
		'AND ABS(peer.salary - e.salary) < e.salary * 0.1 ' +
		'ORDER BY peer.name)) AS employee_json, ' +
		"(SELECT COUNT(*) FROM tasks t WHERE t.assignee_id = e.id AND t.status = 'open') AS open_tasks, " +
		"(SELECT COUNT(*) FROM tasks t WHERE t.assignee_id = e.id AND t.status = 'overdue') AS overdue_tasks " +
		'FROM employees e JOIN departments d ON e.department_id = d.id ' +
		"WHERE e.status = 'active' AND e.salary > 0 " + 'ORDER BY e.department_id, e.salary DESC',
]

fn main() {
	n := 1000
	total_ops := n * queries.len
	println('Benchmark: pg_query.v parsing paths')
	println('  iterations: ${n} per query × ${queries.len} queries = ${total_ops} total')
	println('')

	// Warmup
	for _ in 0 .. 10 {
		pg_query.parse('SELECT 1') or { panic(err) }
		pg_query.parse_protobuf('SELECT 1') or { panic(err) }
		pg_query.parse_protobuf_ast('SELECT 1') or { panic(err) }
	}

	// --- JSON path ---
	mut start := time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.parse(q) or { panic(err) }
		}
	}
	mut elapsed := time.since(start)
	println('  parse() JSON string              ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Protobuf path ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.parse_protobuf(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  parse_protobuf() raw bytes       ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Typed AST path (V-native protobuf decode) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.parse_protobuf_ast(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  parse_protobuf_ast() typed AST   ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- JSON-to-AST path (JSON decode + sum-type conversion) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			res := pg_query.parse(q) or { panic(err) }
			pg_query.parse_json_ast(res.parse_tree) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  parse_json_ast()  typed AST      ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Fingerprint (fastest path) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.fingerprint(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  fingerprint() hash              ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Normalize ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.normalize(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  normalize() anonymized SQL      ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- V-native protobuf encode (pure V, no C) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			res := pg_query.parse_protobuf_ast(q) or { panic(err) }
			pb := pg_query.encode_parse_result(res)
			_ = pb
		}
	}
	elapsed = time.since(start)
	println('  encode_parse_result() protobuf  ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Deparse roundtrip (V encode + C deparse) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			s := pg_query.deparse_ast(pg_query.parse_protobuf_ast(q) or { panic(err) }) or {
				panic(err)
			}
			_ = s
		}
	}
	elapsed = time.since(start)
	println('  deparse_ast() SQL (encode+deparse) ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	println('')
	println('Note: deparse_ast() calls encode_parse_result() internally,')
	println('so deparse_ast latency = encode + C deparse overhead.')
}
