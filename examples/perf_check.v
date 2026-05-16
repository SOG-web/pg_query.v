import time
import pg_query

const sql_select1 = 'SELECT 1'
const n_iter = 10_000

fn bench(label string, n int, fn_name string) {
	// Cache JSON parse tree for json_ast paths to avoid measuring C parse twice
	mut cached_json := ''
	mut cached_json2 := ''
	mut ok := 0
	start := time.now()
	for _ in 0 .. n {
		match fn_name {
			'fingerprint' {
				pg_query.fingerprint(sql_select1) or { continue }
			}
			'normalize' {
				pg_query.normalize(sql_select1) or { continue }
			}
			'parse_json' {
				pg_query.parse(sql_select1) or { continue }
			}
			'parse_json_ast' {
				if cached_json == '' {
					res := pg_query.parse(sql_select1) or { continue }
					cached_json = res.parse_tree
				}
				pg_query.parse_json_ast(cached_json) or { continue }
			}
			'parse_protobuf_ast' {
				pg_query.parse_protobuf_ast(sql_select1) or { continue }
			}
			'fingerprint_select2' {
				pg_query.fingerprint("SELECT 1 FROM x WHERE y IN ('a', 'b', 'c')") or { continue }
			}
			'normalize_select2' {
				pg_query.normalize("SELECT 1 FROM x WHERE y IN ('a', 'b', 'c')") or { continue }
			}
			'parse_json_select2' {
				pg_query.parse("SELECT 1 FROM x WHERE y IN ('a', 'b', 'c')") or { continue }
			}
			'parse_json_ast_select2' {
				if cached_json2 == '' {
					res := pg_query.parse("SELECT 1 FROM x WHERE y IN ('a', 'b', 'c')") or { continue }
					cached_json2 = res.parse_tree
				}
				pg_query.parse_json_ast(cached_json2) or { continue }
			}
			'parse_protobuf_ast_select2' {
				pg_query.parse_protobuf_ast("SELECT 1 FROM x WHERE y IN ('a', 'b', 'c')") or { continue }
			}
			else {}
		}
		ok++
	}
	elapsed := time.now() - start
	micros := elapsed.microseconds()
	us := f64(micros) / f64(ok)
	per_sec := f64(ok) / (f64(micros) / 1_000_000.0)
	println('${label}: ${ok} ops, ${us:.1f} us/op, ${per_sec:.0f} ops/sec')
}

fn main() {
	println('=== Simple SELECT 1 ===')
	bench('fingerprint        ', n_iter, 'fingerprint')
	bench('normalize          ', n_iter, 'normalize')
	bench('parse (JSON)       ', n_iter, 'parse_json')
	bench('parse_json_ast     ', n_iter, 'parse_json_ast')
	bench('parse_protobuf_ast ', n_iter, 'parse_protobuf_ast')

	println('\n=== SELECT with WHERE+IN ===')
	bench('fingerprint        ', n_iter, 'fingerprint_select2')
	bench('normalize          ', n_iter, 'normalize_select2')
	bench('parse (JSON)       ', n_iter, 'parse_json_select2')
	bench('parse_json_ast     ', n_iter, 'parse_json_ast_select2')
	bench('parse_protobuf_ast ', n_iter, 'parse_protobuf_ast_select2')
}
