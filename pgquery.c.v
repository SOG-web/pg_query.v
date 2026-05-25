module pg_query

#flag -I @VMODROOT/c
#flag -I @VMODROOT/c/vendor
#flag @VMODROOT/c/libpg_query.a
#flag linux -pthread
#include "pg_query.h"
@[typedef]
pub struct C.PgQueryError {
	message   &char
	funcname  &char
	filename  &char
	lineno    int
	cursorpos int
	context   &char
}

@[typedef]
pub struct C.PgQueryProtobuf {
	len  usize
	data &char
}

@[typedef]
pub struct C.PgQueryParseResult {
	parse_tree    &char
	stderr_buffer &char
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryProtobufParseResult {
	parse_tree    C.PgQueryProtobuf
	stderr_buffer &char
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryNormalizeResult {
	normalized_query &char
	error            &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryFingerprintResult {
	fingerprint     u64
	fingerprint_str &char
	stderr_buffer   &char
	error           &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryScanResult {
	pbuf          C.PgQueryProtobuf
	stderr_buffer &char
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQuerySplitStmt {
	stmt_location int
	stmt_len      int
}

@[typedef]
pub struct C.PgQuerySplitResult {
	stmts         &&C.PgQuerySplitStmt
	n_stmts       int
	stderr_buffer &char
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryDeparseResult {
	query &char
	error &C.PgQueryError
}

@[typedef]
pub struct C.PostgresDeparseComment {
	match_location          int
	newlines_before_comment int
	newlines_after_comment  int
	str                     &char
}

// PostgresDeparseOpts is fully visible now — constructed directly in V.
// comments is voidptr to avoid V `&&T` cast issues; binary layout is identical.
@[typedef]
pub struct C.PostgresDeparseOpts {
	comments             voidptr
	comment_count        usize
	pretty_print         bool
	indent_size          int
	max_line_length      int
	trailing_newline     bool
	commas_start_of_line bool
}

@[typedef]
pub struct C.PgQueryDeparseCommentsResult {
	comments      &&C.PostgresDeparseComment
	comment_count usize
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryPlpgsqlParseResult {
	plpgsql_funcs &char
	error         &C.PgQueryError
}

@[typedef]
pub struct C.PgQueryIsUtilityResult {
	length int
	items  &bool
	error  &C.PgQueryError
}

@[typedef]
pub struct C.PgQuerySummaryParseResult {
	summary       C.PgQueryProtobuf
	stderr_buffer &char
	error         &C.PgQueryError
}

// C macros hardcoded as V consts (only change on PG version bumps)
pub const pg_query_parse_default = 0
pub const pg_query_parse_type_name = 1
pub const pg_query_parse_plpgsql_expr = 2
pub const pg_query_parse_plpgsql_assign1 = 3
pub const pg_query_parse_plpgsql_assign2 = 4
pub const pg_query_parse_plpgsql_assign3 = 5
pub const pg_query_disable_backslash_quote = 16
pub const pg_query_disable_standard_conforming_strings = 32
pub const pg_query_disable_escape_string_warning = 64
pub const pg_version_num = 170007
pub const pg_version_str = '17.7'
pub const pg_major_version_str = '17'

// Parse functions
fn C.pg_query_parse(const_input &char) C.PgQueryParseResult
fn C.pg_query_parse_opts(const_input &char, parser_options int) C.PgQueryParseResult
fn C.pg_query_parse_protobuf(const_input &char) C.PgQueryProtobufParseResult
fn C.pg_query_parse_protobuf_opts(const_input &char, parser_options int) C.PgQueryProtobufParseResult
fn C.pg_query_parse_plpgsql(const_input &char) C.PgQueryPlpgsqlParseResult

// Normalize functions
fn C.pg_query_normalize(const_input &char) C.PgQueryNormalizeResult
fn C.pg_query_normalize_utility(const_input &char) C.PgQueryNormalizeResult

// Scan function
fn C.pg_query_scan(const_input &char) C.PgQueryScanResult

// Fingerprint functions
fn C.pg_query_fingerprint(const_input &char) C.PgQueryFingerprintResult
fn C.pg_query_fingerprint_opts(const_input &char, parser_options int) C.PgQueryFingerprintResult

// Split functions
fn C.pg_query_split_with_scanner(const_input &char) C.PgQuerySplitResult
fn C.pg_query_split_with_parser(const_input &char) C.PgQuerySplitResult

// Deparse functions
fn C.pg_query_deparse_protobuf(parse_tree C.PgQueryProtobuf) C.PgQueryDeparseResult
fn C.pg_query_deparse_protobuf_opts(parse_tree C.PgQueryProtobuf, opts C.PostgresDeparseOpts) C.PgQueryDeparseResult
fn C.pg_query_is_utility_stmt(const_query &char) C.PgQueryIsUtilityResult
fn C.pg_query_deparse_comments_for_query(const_query &char) C.PgQueryDeparseCommentsResult

// Summary
fn C.pg_query_summary(const_input &char, parser_options int, truncate_limit int) C.PgQuerySummaryParseResult

// Free functions
fn C.pg_query_free_normalize_result(result C.PgQueryNormalizeResult)
fn C.pg_query_free_scan_result(result C.PgQueryScanResult)
fn C.pg_query_free_parse_result(result C.PgQueryParseResult)
fn C.pg_query_free_split_result(result C.PgQuerySplitResult)
fn C.pg_query_free_deparse_result(result C.PgQueryDeparseResult)
fn C.pg_query_free_deparse_comments_result(result C.PgQueryDeparseCommentsResult)
fn C.pg_query_free_protobuf_parse_result(result C.PgQueryProtobufParseResult)
fn C.pg_query_free_plpgsql_parse_result(result C.PgQueryPlpgsqlParseResult)
fn C.pg_query_free_fingerprint_result(result C.PgQueryFingerprintResult)
fn C.pg_query_free_is_utility_result(result C.PgQueryIsUtilityResult)
fn C.pg_query_free_summary_parse_result(result C.PgQuerySummaryParseResult)

// Lifecycle
fn C.pg_query_exit()


