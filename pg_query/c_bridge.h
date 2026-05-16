#include <stddef.h>
#include "pg_query.h"

void* pg_query_bridge_split_stmts_get(void *stmts, int index);
void* pg_query_bridge_deparse_comments_get(void *comments, size_t index);

const char* pg_query_bridge_pg_version(void);
const char* pg_query_bridge_pg_major_version(void);

void* pg_query_bridge_deparse_opts_new(void);
void pg_query_bridge_deparse_opts_set_pretty_print(void *opts, int val);
void pg_query_bridge_deparse_opts_set_indent_size(void *opts, int val);
void pg_query_bridge_deparse_opts_set_max_line_length(void *opts, int val);
void pg_query_bridge_deparse_opts_set_trailing_newline(void *opts, int val);
void pg_query_bridge_deparse_opts_set_commas_start_of_line(void *opts, int val);
void pg_query_bridge_deparse_opts_set_comment_count(void *opts, size_t count);
void pg_query_bridge_deparse_opts_init_comments(void *opts, size_t count);
void pg_query_bridge_deparse_opts_set_comment(void *opts, size_t index,
	int location, int newlines_before, int newlines_after, const char *str);
void pg_query_bridge_deparse_opts_free(void *opts);
PgQueryDeparseResult pg_query_bridge_deparse_protobuf_opts(PgQueryProtobuf parse_tree, void *opts);
