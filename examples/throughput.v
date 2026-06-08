import pg_query
import time
import runtime

#include <sys/resource.h>

// ru_maxrss offset within struct rusage on macOS arm64.
// timeval = 16 bytes × 2 (ru_utime, ru_stime) = 32 bytes.
const ru_maxrss_offset = 32

fn C.getrusage(who int, usage voidptr) int

const rusage_self = 0

const perf_iter = 5000

// Mixed query workload mimicking a real database proxy/router.
const workload = [
	'SELECT id, name, email FROM users WHERE id = $1',
	'INSERT INTO orders (user_id, total) VALUES ($1, $2) RETURNING id',
	'UPDATE users SET last_login = NOW() WHERE id = $1',
	'SELECT * FROM products WHERE sku = $1',
	'DELETE FROM sessions WHERE expires_at < NOW()',
	'SELECT d.name, COUNT(e.id) AS emp_count, ROUND(AVG(e.salary), 2) AS avg_salary ' +
		'FROM departments d JOIN employees e ON e.dept_id = d.id GROUP BY d.id, d.name ORDER BY avg_salary DESC',
	'SELECT DATE_TRUNC(\'month\', created_at) AS month, COUNT(*) AS signups ' +
		'FROM users WHERE created_at >= NOW() - INTERVAL \'6 months\' GROUP BY 1 ORDER BY 1',
	'CREATE TABLE IF NOT EXISTS archive_2025 (LIKE orders INCLUDING ALL)',
	'ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(20)',
	'VACUUM ANALYZE orders',
	'EXPLAIN ANALYZE SELECT * FROM users JOIN orders ON users.id = orders.user_id WHERE users.id = $1',
	'SELECT DISTINCT ON (e.department_id) e.id, e.name, e.salary, ' +
		'ROUND(AVG(e.salary) OVER (PARTITION BY e.department_id), 2) AS dept_avg, ' +
		'ROW_NUMBER() OVER (PARTITION BY e.department_id ORDER BY e.salary DESC) AS rank ' +
		'FROM employees e JOIN departments d ON e.department_id = d.id WHERE e.status = \'active\'',
]

fn main() {
	ncores := runtime.nr_cpus()
	println('=== pg_query.v — Real-World Throughput ===')
	println('  cpus: ${ncores}')
	println('')

	// Warmup
	print('Warming up (1s) ... ')
	mut warm_count := 0
	mut t := time.now()
	for time.since(t) < time.second {
		for q in workload {
			pg_query.parse_protobuf_ast(q) or { continue }
			warm_count++
		}
	}
	we := time.since(t)
	println('${warm_count} parse-only = ${f64(warm_count) / we.seconds():.0f} qps')
	println('')

	// Pooler: fingerprint + parse + normalize per query
	println('=== Pooler Workload (3s) ===')
	println('  fingerprint() + parse_protobuf_ast() + normalize() per query')
	println('')

	mut fprints := []u64{}
	mut total := 0

	r0_buf := []u8{len: 200}
	C.getrusage(rusage_self, r0_buf.data)

	wall_start := time.now()
	for time.since(wall_start) < 3 * time.second {
		for q in workload {
			fp := pg_query.fingerprint(q) or { continue }
			fprints << fp.fingerprint
			ast := pg_query.parse_protobuf_ast(q) or { continue }
			_ = ast
			n := pg_query.normalize(q) or { continue }
			_ = n.normalized_query.len
			total++
		}
	}
	wall_us := f64(time.since(wall_start).microseconds())
	qps := f64(total) / (wall_us / 1_000_000.0)

	r1_buf := []u8{len: 200}
	C.getrusage(rusage_self, r1_buf.data)

	maxrss1 := unsafe { *(&i64(&r1_buf[ru_maxrss_offset])) }
	cpu_us := cpu_delta(r0_buf, r1_buf)

	println('  queries:   ${total}')
	println('  throughput: ${qps:10.0f} qps')
	println('  per query: ${wall_us / f64(total):7.2f} us')
	println('  cpu time:  ${cpu_us / 1000.0:8.0f} ms (${cpu_us / wall_us * 100.0:5.1f}%)')
	println('  max RSS:   ${format_mem(u64(maxrss1))}')
	println('  fingerprints: ${unique_count(fprints)} unique')
	println('')

	// Per-path microbenchmarks
	total_ops := perf_iter * workload.len
	println('=== Per-Path (${workload.len} queries × ${perf_iter} iterations = ${total_ops} ops) ===')
	println('')

	microbench('fingerprint        ', perf_iter, total_ops, fn () {
		for _ in 0 .. perf_iter {
			for q in workload {
				pg_query.fingerprint(q) or { panic(err) }
			}
		}
	})
	microbench('normalize          ', perf_iter, total_ops, fn () {
		for _ in 0 .. perf_iter {
			for q in workload {
				pg_query.normalize(q) or { panic(err) }
			}
		}
	})
	microbench('parse() JSON       ', perf_iter, total_ops, fn () {
		for _ in 0 .. perf_iter {
			for q in workload {
				pg_query.parse(q) or { panic(err) }
			}
		}
	})
	microbench('parse_protobuf_ast ', perf_iter, total_ops, fn () {
		for _ in 0 .. perf_iter {
			for q in workload {
				pg_query.parse_protobuf_ast(q) or { panic(err) }
			}
		}
	})
	microbench('deparse_ast        ', perf_iter, total_ops, fn () {
		for _ in 0 .. perf_iter {
			for q in workload {
				s := pg_query.deparse_ast(pg_query.parse_protobuf_ast(q) or {
					panic(err)
				}) or { panic(err) }
				_ = s
			}
		}
	})
}

fn microbench(label string, n int, total_ops int, cb fn ()) {
	b0 := []u8{len: 200}
	C.getrusage(rusage_self, b0.data)
	start := time.now()
	cb()
	b1 := []u8{len: 200}
	C.getrusage(rusage_self, b1.data)

	wall_us := f64(time.since(start).microseconds())
	us_per := wall_us / f64(total_ops)
	qps_core := if us_per > 0 { 1_000_000.0 / us_per } else { 0.0 }
	cpu := cpu_delta(b0, b1)
	rss := unsafe { *(&i64(&b1[ru_maxrss_offset])) }
	println('  ${label} ${us_per:7.2f} us/op  ${qps_core:9.0f} qps/core  cpu:${f64(cpu) / wall_us * 100.0:4.0f}%  rss:${format_mem(u64(rss))}')
}

fn cpu_delta(b0 []u8, b1 []u8) f64 {
	utime0 := unsafe { *(&i64(&b0[0])) }
	utime1 := unsafe { *(&i64(&b1[0])) }
	utime_usec0 := unsafe { *(&i32(&b0[8])) }
	utime_usec1 := unsafe { *(&i32(&b1[8])) }
	stime0 := unsafe { *(&i64(&b0[16])) }
	stime1 := unsafe { *(&i64(&b1[16])) }
	stime_usec0 := unsafe { *(&i32(&b0[24])) }
	stime_usec1 := unsafe { *(&i32(&b1[24])) }
	return f64((utime1 - utime0) * 1_000_000 + (utime_usec1 - utime_usec0) +
		(stime1 - stime0) * 1_000_000 + (stime_usec1 - stime_usec0))
}

fn unique_count(arr []u64) int {
	mut seen := map[u64]bool{}
	for v in arr {
		seen[v] = true
	}
	return seen.len
}

fn format_mem(b u64) string {
	if b >= 1_000_000_000 {
		return '${f64(b) / 1_000_000_000.0:.2f} GB'
	} else if b >= 1_000_000 {
		return '${f64(b) / 1_000_000.0:.2f} MB'
	} else if b >= 1_000 {
		return '${f64(b) / 1_000.0:.2f} KB'
	} else {
		return '${b} B'
	}
}
