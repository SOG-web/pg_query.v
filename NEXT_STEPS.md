# Next Steps — pg_query.v

## 1. Expose full PgQueryError struct ✅
- [x] Create V-side `PgError` struct with `message`, `funcname`, `filename`, `lineno`, `cursorpos`, `context`
- [x] Implement `IError` interface (`msg() string`, `code() int`) so it works with `!` returns
- [x] Update `check_error` to return `PgError` instead of `error(string)`
- [x] Update tests to assert on individual error fields

## 2. C bridge file ✅
- [x] Create `c_bridge.c` and `c_bridge.h` with helper C functions
- [x] Replace `&voidptr` pointer-array hacks with robust C helpers
- [x] Use `#flag @VMODROOT/pg_query/c_bridge.o` (compile once, link every time)
- [x] Covers: `PgQuerySplitStmt**`, `PostgresDeparseComment**` traversal

## 3. Protobuf helpers ✅
- [x] Binary-safe `[]u8` → `string` conversion (handles null bytes in protobuf data)
- [x] `hex()` method for hex dump debugging
- [x] `bytes()` accessor for raw byte array
- [x] Deparse roundtrip tests (protobuf → SQL) with and without opts
- [x] Protobuf parse, scan, and summary all properly handle binary data

## 4. Distribution polish ✅
- [x] Remove `main.v` placeholder
- [x] Write proper `README.md` with usage examples
- [x] GitHub Actions CI: `make -C libpg_query build` + `v test pg_query/`
- [x] Create `examples/parse_sql.v` with full demo
- [x] Update `.gitignore` for bridge `.o` file
- [x] Fix CI example step output path

## 5. Benchmark tests
- [ ] Parse throughput (queries/sec)
- [ ] Fingerprint throughput
- [ ] Normalize throughput

## ✅ Completed

### 1. Expose full PgQueryError struct ✅
- [x] Create V-side `PgError` struct with `message`, `funcname`, `filename`, `lineno`, `cursorpos`, `context`
- [x] Implement `IError` interface (`msg() string`, `code() int`) so it works with `!` returns
- [x] Update `check_error` to return `PgError` instead of `error(string)`
- [x] Update tests to assert on individual error fields

### 2. C bridge file ✅
- [x] Create `c_bridge.c` and `c_bridge.h` with helper C functions
- [x] Replace `&voidptr` pointer-array hacks with robust C helpers
- [x] Covers: `PgQuerySplitStmt**`, `PostgresDeparseComment**` traversal

### 3. Protobuf helpers ✅
- [x] Binary-safe `[]u8` → `string` conversion (handles null bytes)
- [x] `hex()` method for hex dump
- [x] `bytes()` accessor for raw `[]u8`
- [x] Deparse roundtrip tests with and without opts

### 4. Distribution polish ✅
- [x] Remove `main.v` placeholder
- [x] `README.md` with full API table and examples
- [x] `.github/workflows/ci.yml` (macOS + Linux)
- [x] `examples/parse_sql.v` runnable demo
- [x] `.gitignore` for bridge `.o`

### 5. Memory leak fix (audit-driven) ✅
- [x] Critical: every error path leaked (no `pg_query_free_*_result` on error)
- [x] New `pg_error_from()` helper returns `?PgError` Option
- [x] Every function now checks errors → frees → returns, no leak
- [x] Version constants now sourced from C library via bridge (not hardcoded)
- [x] All 20 tests pass (OK 320ms)
