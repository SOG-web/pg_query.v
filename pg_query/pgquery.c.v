module pg_query

#flag -I @VMODROOT/libpg_query
#flag -I @VMODROOT/pg_query
#flag -I @VMODROOT/libpg_query/vendor
#flag @VMODROOT/libpg_query/libpg_query.a
#flag @VMODROOT/pg_query/c_bridge.o
#flag @VMODROOT/pg_query/protobuf_bridge.o
#include "pg_query.h"
#include "pg_query_ast_c.h"
#include "c_bridge.h"
#include "protobuf_bridge.h"

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
	stmts         voidptr
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
	comments      voidptr
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
	items  voidptr
	error  &C.PgQueryError
}

@[typedef]
pub struct C.PgQuerySummaryParseResult {
	summary       C.PgQueryProtobuf
	stderr_buffer &char
	error         &C.PgQueryError
}

// Parse mode enum
pub const pg_query_parse_default = C.PG_QUERY_PARSE_DEFAULT
pub const pg_query_parse_type_name = C.PG_QUERY_PARSE_TYPE_NAME
pub const pg_query_parse_plpgsql_expr = C.PG_QUERY_PARSE_PLPGSQL_EXPR
pub const pg_query_parse_plpgsql_assign1 = C.PG_QUERY_PARSE_PLPGSQL_ASSIGN1
pub const pg_query_parse_plpgsql_assign2 = C.PG_QUERY_PARSE_PLPGSQL_ASSIGN2
pub const pg_query_parse_plpgsql_assign3 = C.PG_QUERY_PARSE_PLPGSQL_ASSIGN3

// Parse option flags
pub const pg_query_disable_backslash_quote = C.PG_QUERY_DISABLE_BACKSLASH_QUOTE
pub const pg_query_disable_standard_conforming_strings = C.PG_QUERY_DISABLE_STANDARD_CONFORMING_STRINGS
pub const pg_query_disable_escape_string_warning = C.PG_QUERY_DISABLE_ESCAPE_STRING_WARNING

// Parse functions
fn C.pg_query_parse(input &char) C.PgQueryParseResult
fn C.pg_query_parse_opts(input &char, parser_options int) C.PgQueryParseResult
fn C.pg_query_parse_protobuf(input &char) C.PgQueryProtobufParseResult
fn C.pg_query_parse_protobuf_opts(input &char, parser_options int) C.PgQueryProtobufParseResult
fn C.pg_query_parse_plpgsql(input &char) C.PgQueryPlpgsqlParseResult

// Normalize functions
fn C.pg_query_normalize(input &char) C.PgQueryNormalizeResult
fn C.pg_query_normalize_utility(input &char) C.PgQueryNormalizeResult

// Scan function
fn C.pg_query_scan(input &char) C.PgQueryScanResult

// Fingerprint functions
fn C.pg_query_fingerprint(input &char) C.PgQueryFingerprintResult
fn C.pg_query_fingerprint_opts(input &char, parser_options int) C.PgQueryFingerprintResult

// Split functions
fn C.pg_query_split_with_scanner(input &char) C.PgQuerySplitResult
fn C.pg_query_split_with_parser(input &char) C.PgQuerySplitResult

// Deparse functions
fn C.pg_query_deparse_protobuf(parse_tree C.PgQueryProtobuf) C.PgQueryDeparseResult
fn C.pg_query_deparse_protobuf_opts(parse_tree C.PgQueryProtobuf, opts C.PostgresDeparseOpts) C.PgQueryDeparseResult
fn C.pg_query_deparse_comments_for_query(query &char) C.PgQueryDeparseCommentsResult

// Utility
fn C.pg_query_is_utility_stmt(query &char) C.PgQueryIsUtilityResult

// Summary
fn C.pg_query_summary(input &char, parser_options int, truncate_limit int) C.PgQuerySummaryParseResult

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

// Bridge helpers
fn C.pg_query_bridge_split_stmts_get(stmts voidptr, index int) voidptr
fn C.pg_query_bridge_deparse_comments_get(comments voidptr, index usize) voidptr
fn C.pg_query_bridge_pg_version() &char
fn C.pg_query_bridge_pg_major_version() &char
fn C.pg_query_bridge_deparse_opts_new() &C.PostgresDeparseOpts
fn C.pg_query_bridge_deparse_opts_init_comments(opts &C.PostgresDeparseOpts, count usize)
fn C.pg_query_bridge_deparse_opts_set_comment(opts &C.PostgresDeparseOpts, index usize, location int, newlines_before int, newlines_after int, str &char)
fn C.pg_query_bridge_deparse_opts_free(opts &C.PostgresDeparseOpts)
fn C.pg_query_bridge_deparse_protobuf_opts(parse_tree C.PgQueryProtobuf, opts &C.PostgresDeparseOpts) C.PgQueryDeparseResult

// Protobuf bridge functions
fn C.pg_query_bridge_parse_ast_direct(input &char, parser_options int) voidptr
fn C.pg_query_bridge_free_ast_result(ptr voidptr)
