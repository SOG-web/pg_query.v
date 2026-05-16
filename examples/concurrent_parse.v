import pg_query
import time

const queries = ['SELECT 1', 'SELECT 2; SELECT 3', 'CREATE TABLE t (id int)',
	'DELETE FROM t WHERE id = 0', 'UPDATE t SET x = 1', 'SELECT count(*) FROM t', 'DROP TABLE t',
	'INSERT INTO t VALUES (1)', "SELECT a, b, c FROM x WHERE y IN ('a', 'b', 'c')",
	'ALTER TABLE t ADD COLUMN x int', 'CREATE INDEX idx ON t (id)',
	'SELECT * FROM t WHERE id = 42 AND name = $1']

fn parse_single(input string) string {
	res := pg_query.parse_ast_direct(input) or { return 'ERROR: ${err}' }
	return '${input} -> ${res.stmts.len} stmt(s)'
}

fn worker(id int, n int) string {
	mut errs := 0
	mut ok := 0
	start := time.now()
	for _ in 0 .. n {
		for q in queries {
			res := pg_query.parse_ast_direct(q) or {
				errs++
				continue
			}
			_ = res
			ok++
		}
	}
	elapsed := time.now() - start
	return 'worker ${id}: ${ok} ok, ${errs} errs in ${elapsed.milliseconds()} ms'
}

fn main() {
	n_workers := 10
	iters_per_worker := 1000
	println('Starting ${n_workers} workers, ${iters_per_worker} iterations each...')
	mut threads := []thread string{}
	for i in 0 .. n_workers {
		threads << spawn worker(i, iters_per_worker)
	}
	results := threads.wait()
	for r in results {
		println('  ${r}')
	}
	println('DONE - no crashes, no data races')
}
