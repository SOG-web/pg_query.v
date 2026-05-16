#include <stddef.h>
#include "pg_query.h"

void* pg_query_bridge_split_stmts_get(void *stmts, int index);
void* pg_query_bridge_deparse_comments_get(void *comments, size_t index);

const char* pg_query_bridge_pg_version(void);
const char* pg_query_bridge_pg_major_version(void);

PostgresDeparseOpts* pg_query_bridge_deparse_opts_new(void);
void pg_query_bridge_deparse_opts_init_comments(PostgresDeparseOpts *opts, size_t count);
void pg_query_bridge_deparse_opts_set_comment(PostgresDeparseOpts *opts, size_t index,
	int location, int newlines_before, int newlines_after, const char *str);
void pg_query_bridge_deparse_opts_free(PostgresDeparseOpts *opts);
PgQueryDeparseResult pg_query_bridge_deparse_protobuf_opts(PgQueryProtobuf parse_tree, PostgresDeparseOpts *opts);
