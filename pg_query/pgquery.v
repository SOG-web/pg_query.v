module pg_query

import json

pub struct ParseResult {
pub:
	parse_tree    string
	stderr_buffer string
}

pub struct ParseResultProtobuf {
pub:
	parse_tree    Protobuf
	stderr_buffer string
}

pub struct Protobuf {
pub:
	len  usize
	data string
}

pub fn (pb Protobuf) hex() string {
	if pb.len == 0 {
		return ''
	}
	mut out := ''
	for i in 0 .. int(pb.len) {
		out += pb.data[i].hex()
	}
	return out
}

pub fn (pb Protobuf) bytes() []u8 {
	return pb.data.bytes()
}

// encode_ast serializes a ParseAstResult back to protobuf wire format.
// The returned Protobuf can be passed to deparse_protobuf() for SQL deparsing.
pub fn encode_ast(result ParseAstResult) Protobuf {
	buf := encode_parse_result(result)
	return protobuf_from_bytes(buf)
}

// encode_scan serializes a ScanResult back to protobuf wire format.
pub fn encode_scan(result ScanResult) Protobuf {
	return protobuf_from_bytes(encode_scan_result(result))
}

// encode_summary serializes a SummaryResult back to protobuf wire format.
pub fn encode_summary(result SummaryResult) Protobuf {
	return protobuf_from_bytes(encode_summary_result(result))
}

// deparse_ast encodes a ParseAstResult to protobuf and deparses it back to SQL.
// Returns the deparsed SQL string on success.
pub fn deparse_ast(result ParseAstResult) !string {
	pb := encode_ast(result)
	res := deparse_protobuf(pb) or { return err }
	return res.query
}

fn protobuf_from_bytes(buf []u8) Protobuf {
	return Protobuf{
		len: usize(buf.len)
		data: buf.bytestr()
	}
}

pub struct NormalizeResult {
pub:
	normalized_query string
}

pub struct FingerprintResult {
pub:
	fingerprint     u64
	fingerprint_str string
	stderr_buffer   string
}



pub struct SplitStmt {
pub:
	stmt_location int
	stmt_len      int
}

pub struct SplitResult {
pub:
	stmts         []SplitStmt
	n_stmts       int
	stderr_buffer string
}

pub struct DeparseResult {
pub:
	query string
}

pub struct DeparseComment {
pub:
	match_location          int
	newlines_before_comment int
	newlines_after_comment  int
	str                     string
}

pub struct DeparseOpts {
pub:
	comments             []DeparseComment
	pretty_print         bool
	indent_size          int
	max_line_length      int
	trailing_newline     bool
	commas_start_of_line bool
}

pub struct DeparseCommentsResult {
pub:
	comments []DeparseComment
}

pub struct PlpgsqlParseResult {
pub:
	plpgsql_funcs string
}

pub struct IsUtilityResult {
pub:
	length int
	items  []bool
}

pub struct PgError {
pub:
	message    string
	funcname   string
	filename   string
	lineno     int
	cursorpos  int
	context    string
}

pub fn (e PgError) msg() string {
	return e.message
}

pub fn (e PgError) code() int {
	return 0
}

fn cstring(s &char) string {
	if s == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(s) }
}

fn pg_error_from(err &C.PgQueryError) ?PgError {
	if err == unsafe { nil } {
		return none
	}
		return PgError{
		message:    cstring(err.message)
		funcname:   cstring(err.funcname)
		filename:   cstring(err.filename)
		lineno:     err.lineno
		cursorpos:  err.cursorpos
		context:    cstring(err.context)
	}
}

// Parse SQL and return JSON parse tree.
pub fn parse(input string) !ParseResult {
	res := C.pg_query_parse(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_parse_result(res)
		return pe
	}
	pt := cstring(res.parse_tree)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_parse_result(res)
	return ParseResult{
		parse_tree:    pt
		stderr_buffer: sb
	}
}

// Parse SQL with options and return JSON parse tree.
pub fn parse_opts(input string, parser_options int) !ParseResult {
	res := C.pg_query_parse_opts(input.str, parser_options)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_parse_result(res)
		return pe
	}
	pt := cstring(res.parse_tree)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_parse_result(res)
	return ParseResult{
		parse_tree:    pt
		stderr_buffer: sb
	}
}

// Parse SQL and return Protobuf parse tree.
pub fn parse_protobuf(input string) !ParseResultProtobuf {
	res := C.pg_query_parse_protobuf(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_protobuf_parse_result(res)
		return pe
	}
	pb := protobuf_from_c(res.parse_tree)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_protobuf_parse_result(res)
	return ParseResultProtobuf{
		parse_tree:    pb
		stderr_buffer: sb
	}
}

// Parse a JSON parse tree string into typed V AST structs.
// Unlike parse_ast() (which calls parse() internally), this accepts
// any JSON string produced by pg_query.parse() or an external source.
pub fn parse_json_ast(json_string string) !ParseAstResult {
	json_res := json.decode(JsonParseResult, json_string) or { return err }
	mut stmts := []AstRawStmt{}
	for s in json_res.stmts {
		stmts << AstRawStmt{
			stmt_location: s.stmt_location
			stmt_len: s.stmt_len
			stmt: decode_node_json(s.stmt)
		}
	}
	return ParseAstResult{
		version: json_res.version
		stmts: stmts
	}
}

// Parse SQL and return a typed V AST (protobuf decode path, no JSON).
pub fn parse_protobuf_ast(input string) !ParseAstResult {
	res := C.pg_query_parse_protobuf(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_protobuf_parse_result(res)
		return pe
	}
	buf := protobuf_to_bytes(res.parse_tree)
	C.pg_query_free_protobuf_parse_result(res)
	return decode_parse_result(buf)
}

// Parse SQL with options and return a typed V AST (protobuf decode path, no JSON).
pub fn parse_protobuf_ast_opts(input string, parser_options int) !ParseAstResult {
	res := C.pg_query_parse_protobuf_opts(input.str, parser_options)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_protobuf_parse_result(res)
		return pe
	}
	buf := protobuf_to_bytes(res.parse_tree)
	C.pg_query_free_protobuf_parse_result(res)
	return decode_parse_result(buf)
}

// Parse SQL with options and return Protobuf parse tree.
pub fn parse_protobuf_opts(input string, parser_options int) !ParseResultProtobuf {
	res := C.pg_query_parse_protobuf_opts(input.str, parser_options)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_protobuf_parse_result(res)
		return pe
	}
	pb := protobuf_from_c(res.parse_tree)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_protobuf_parse_result(res)
	return ParseResultProtobuf{
		parse_tree:    pb
		stderr_buffer: sb
	}
}

// Parse PL/pgSQL and return function list.
pub fn parse_plpgsql(input string) !PlpgsqlParseResult {
	res := C.pg_query_parse_plpgsql(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_plpgsql_parse_result(res)
		return pe
	}
	pf := cstring(res.plpgsql_funcs)
	C.pg_query_free_plpgsql_parse_result(res)
	return PlpgsqlParseResult{
		plpgsql_funcs: pf
	}
}

// Normalize a SQL query.
pub fn normalize(input string) !NormalizeResult {
	res := C.pg_query_normalize(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_normalize_result(res)
		return pe
	}
	nq := cstring(res.normalized_query)
	C.pg_query_free_normalize_result(res)
	return NormalizeResult{
		normalized_query: nq
	}
}

// Normalize a utility SQL query.
pub fn normalize_utility(input string) !NormalizeResult {
	res := C.pg_query_normalize_utility(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_normalize_result(res)
		return pe
	}
	nq := cstring(res.normalized_query)
	C.pg_query_free_normalize_result(res)
	return NormalizeResult{
		normalized_query: nq
	}
}

// Scan (tokenize) a SQL query.
pub fn scan(input string) !ScanResult {
	res := C.pg_query_scan(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_scan_result(res)
		return pe
	}
	bytes := protobuf_to_bytes(res.pbuf)
	C.pg_query_free_scan_result(res)
	val, _ := decode_scan_result(bytes, max_decode_depth)
	return val
}

// Fingerprint a SQL query.
pub fn fingerprint(input string) !FingerprintResult {
	res := C.pg_query_fingerprint(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_fingerprint_result(res)
		return pe
	}
	fp := res.fingerprint
	fps := cstring(res.fingerprint_str)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_fingerprint_result(res)
	return FingerprintResult{
		fingerprint:     fp
		fingerprint_str: fps
		stderr_buffer:   sb
	}
}

// Fingerprint a SQL query with options.
pub fn fingerprint_opts(input string, parser_options int) !FingerprintResult {
	res := C.pg_query_fingerprint_opts(input.str, parser_options)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_fingerprint_result(res)
		return pe
	}
	fp := res.fingerprint
	fps := cstring(res.fingerprint_str)
	sb := cstring(res.stderr_buffer)
	C.pg_query_free_fingerprint_result(res)
	return FingerprintResult{
		fingerprint:     fp
		fingerprint_str: fps
		stderr_buffer:   sb
	}
}

// Split SQL into statements using the scanner.
pub fn split_with_scanner(input string) !SplitResult {
	res := C.pg_query_split_with_scanner(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_split_result(res)
		return pe
	}
	stmts := split_stmts_from_c(res)
	sb := cstring(res.stderr_buffer)
	n := res.n_stmts
	C.pg_query_free_split_result(res)
	return SplitResult{
		stmts:         stmts
		n_stmts:       n
		stderr_buffer: sb
	}
}

// Split SQL into statements using the parser.
pub fn split_with_parser(input string) !SplitResult {
	res := C.pg_query_split_with_parser(input.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_split_result(res)
		return pe
	}
	stmts := split_stmts_from_c(res)
	sb := cstring(res.stderr_buffer)
	n := res.n_stmts
	C.pg_query_free_split_result(res)
	return SplitResult{
		stmts:         stmts
		n_stmts:       n
		stderr_buffer: sb
	}
}

// Deparse a Protobuf parse tree back to SQL.
pub fn deparse_protobuf(pb Protobuf) !DeparseResult {
	c_pb := protobuf_to_c(pb)
	res := C.pg_query_deparse_protobuf(c_pb)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_deparse_result(res)
		return pe
	}
	q := cstring(res.query)
	C.pg_query_free_deparse_result(res)
	return DeparseResult{
		query: q
	}
}

// Deparse a Protobuf parse tree with options back to SQL.
pub fn deparse_protobuf_opts(pb Protobuf, opts DeparseOpts) !DeparseResult {
	c_pb := protobuf_to_c(pb)
	c_opts := deparse_opts_to_c(opts)
	defer {
		C.pg_query_bridge_deparse_opts_free(c_opts)
	}
	res := C.pg_query_bridge_deparse_protobuf_opts(c_pb, c_opts)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_deparse_result(res)
		return pe
	}
	q := cstring(res.query)
	C.pg_query_free_deparse_result(res)
	return DeparseResult{
		query: q
	}
}

// Deparse comments for a query.
pub fn deparse_comments_for_query(query string) !DeparseCommentsResult {
	res := C.pg_query_deparse_comments_for_query(query.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_deparse_comments_result(res)
		return pe
	}
	comments := deparse_comments_from_c(res)
	C.pg_query_free_deparse_comments_result(res)
	return DeparseCommentsResult{
		comments: comments
	}
}

// Check if a query is a utility statement.
pub fn is_utility_stmt(query string) !IsUtilityResult {
	res := C.pg_query_is_utility_stmt(query.str)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_is_utility_result(res)
		return pe
	}
	items := is_utility_items_from_c(res)
	C.pg_query_free_is_utility_result(res)
	return IsUtilityResult{
		length: res.length
		items:  items
	}
}

// Get a summary of a SQL query.
pub fn summary(input string, parser_options int, truncate_limit int) !SummaryResult {
	res := C.pg_query_summary(input.str, parser_options, truncate_limit)
	if pe := pg_error_from(res.error) {
		C.pg_query_free_summary_parse_result(res)
		return pe
	}
	bytes := protobuf_to_bytes(res.summary)
	C.pg_query_free_summary_parse_result(res)
	val, _ := decode_summary_result(bytes, max_decode_depth)
	return val
}

// Clean up global memory contexts used by the C parser.
//
// The parser uses thread-local memory contexts internally and is
// safe to call concurrently from multiple threads. Do NOT call
// pg_query_exit() while other goroutines may be actively parsing,
// as it frees the memory context used by the current thread.
pub fn exit() {
	C.pg_query_exit()
}

// Postgres version information.
pub fn pg_version() string {
	return cstring(C.pg_query_bridge_pg_version())
}

pub fn pg_major_version() string {
	return cstring(C.pg_query_bridge_pg_major_version())
}

pub fn pg_version_num() int {
	return C.PG_VERSION_NUM
}

// --- internal helpers ---

fn protobuf_to_bytes(cpb C.PgQueryProtobuf) []u8 {
	if cpb.len == 0 || cpb.data == unsafe { nil } {
		return []
	}
	mut bytes := []u8{len: int(cpb.len)}
	unsafe { C.memcpy(bytes.data, voidptr(cpb.data), usize(cpb.len)) }
	return bytes
}

fn protobuf_from_c(cpb C.PgQueryProtobuf) Protobuf {
	if cpb.len == 0 || cpb.data == unsafe { nil } {
		return Protobuf{
			len:  0
			data: ''
		}
	}
	mut bytes := []u8{len: int(cpb.len)}
	unsafe { C.memcpy(bytes.data, voidptr(cpb.data), usize(cpb.len)) }
	return Protobuf{
		len:  cpb.len
		data: bytes.bytestr()
	}
}

fn protobuf_to_c(pb Protobuf) C.PgQueryProtobuf {
	if pb.data.len == 0 {
		return C.PgQueryProtobuf{
			len:  0
			data: unsafe { nil }
		}
	}
	return C.PgQueryProtobuf{
		len:  usize(pb.data.len)
		data: pb.data.str
	}
}

fn split_stmts_from_c(res C.PgQuerySplitResult) []SplitStmt {
	if res.n_stmts == 0 || res.stmts == unsafe { nil } {
		return []
	}
	mut stmts := []SplitStmt{len: res.n_stmts}
	for i in 0 .. res.n_stmts {
		stmt_ptr := C.pg_query_bridge_split_stmts_get(res.stmts, i)
		c_stmt := unsafe { &C.PgQuerySplitStmt(stmt_ptr) }
		stmts[i] = SplitStmt{
			stmt_location: c_stmt.stmt_location
			stmt_len:      c_stmt.stmt_len
		}
	}
	return stmts
}

fn deparse_opts_to_c(opts DeparseOpts) voidptr {
	mut c_opts := C.pg_query_bridge_deparse_opts_new()
	C.pg_query_bridge_deparse_opts_set_comment_count(c_opts, usize(opts.comments.len))
	C.pg_query_bridge_deparse_opts_set_pretty_print(c_opts, opts.pretty_print)
	C.pg_query_bridge_deparse_opts_set_indent_size(c_opts, opts.indent_size)
	C.pg_query_bridge_deparse_opts_set_max_line_length(c_opts, opts.max_line_length)
	C.pg_query_bridge_deparse_opts_set_trailing_newline(c_opts, opts.trailing_newline)
	C.pg_query_bridge_deparse_opts_set_commas_start_of_line(c_opts, opts.commas_start_of_line)
	if opts.comments.len > 0 {
		C.pg_query_bridge_deparse_opts_init_comments(c_opts, usize(opts.comments.len))
		for i, comment in opts.comments {
			C.pg_query_bridge_deparse_opts_set_comment(c_opts, usize(i), comment.match_location,
				comment.newlines_before_comment, comment.newlines_after_comment, comment.str.str)
		}
	}
	return c_opts
}

fn deparse_comments_from_c(res C.PgQueryDeparseCommentsResult) []DeparseComment {
	if res.comment_count == 0 || res.comments == unsafe { nil } {
		return []
	}
	mut comments := []DeparseComment{len: int(res.comment_count)}
	for i in 0 .. res.comment_count {
		comment_ptr := C.pg_query_bridge_deparse_comments_get(res.comments, i)
		c := unsafe { &C.PostgresDeparseComment(comment_ptr) }
		comments[i] = DeparseComment{
			match_location:          c.match_location
			newlines_before_comment: c.newlines_before_comment
			newlines_after_comment:  c.newlines_after_comment
			str:                     cstring(c.str)
		}
	}
	return comments
}

fn is_utility_items_from_c(res C.PgQueryIsUtilityResult) []bool {
	if res.length == 0 || res.items == unsafe { nil } {
		return []
	}
	mut items := []bool{len: res.length}
	ptr := unsafe { &u8(res.items) }
	for i in 0 .. res.length {
		items[i] = unsafe { ptr[i] } != 0
	}
	return items
}
