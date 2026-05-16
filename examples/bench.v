import pg_query
import time

const queries = [
	'SELECT id, name FROM users WHERE age > 21',
	'SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id WHERE c.status = \'active\' ORDER BY o.created_at DESC LIMIT 10',
	'INSERT INTO users (name, email, age) VALUES (\'Alice\', \'alice@example.com\', 30)',
	'UPDATE users SET name = \'Bob\' WHERE id = 42',
	'DELETE FROM sessions WHERE expires_at < NOW()',
	'CREATE TABLE t (id serial PRIMARY KEY, name text NOT NULL, created_at timestamptz DEFAULT NOW())',
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
	println('  parse() → JSON string              ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Protobuf path ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.parse_protobuf(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  parse_protobuf() → raw bytes       ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

		// --- Typed AST path (V-native protobuf decode) ---
		start = time.now()
		for _ in 0 .. n {
			for q in queries {
				pg_query.parse_protobuf_ast(q) or { panic(err) }
			}
		}
		elapsed = time.since(start)
		println('  parse_protobuf_ast() → typed AST    ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Fingerprint (fastest path) ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.fingerprint(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  fingerprint() → hash               ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')

	// --- Normalize ---
	start = time.now()
	for _ in 0 .. n {
		for q in queries {
			pg_query.normalize(q) or { panic(err) }
		}
	}
	elapsed = time.since(start)
	println('  normalize() → anonymized SQL       ${f64(elapsed.microseconds()) / f64(total_ops):8.2f} us/op  (${elapsed.milliseconds()} ms)')
}
