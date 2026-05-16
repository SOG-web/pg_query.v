#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "pg_query.h"

/*
 * Verify V's C.PostgresDeparseOpts redeclaration matches the actual C struct.
 * The expected size is fields: voidptr(8) + usize(8) + bool(1) + int(4) +
 * int(4) + bool(1) + bool(1) = 27 + 5 padding = 32 on LP64.
 * Update this when PostgresDeparseOpts changes.
 * If this assert fails, update pgquery.c.v's C.PostgresDeparseOpts.
 */
typedef char static_assert_deparse_opts_size[
    sizeof(PostgresDeparseOpts) == 32 ? 1 : -1
];

void* pg_query_bridge_split_stmts_get(void *stmts, int index) {
	return ((void**)stmts)[index];
}

void* pg_query_bridge_deparse_comments_get(void *comments, size_t index) {
	return ((void**)comments)[index];
}

const char* pg_query_bridge_pg_version(void) {
	return PG_VERSION;
}

const char* pg_query_bridge_pg_major_version(void) {
	return PG_MAJORVERSION;
}

PostgresDeparseOpts* pg_query_bridge_deparse_opts_new(void) {
	return calloc(1, sizeof(PostgresDeparseOpts));
}

void pg_query_bridge_deparse_opts_init_comments(PostgresDeparseOpts *opts, size_t count) {
	opts->comments = calloc(count, sizeof(PostgresDeparseComment*));
	opts->comment_count = count;
}

void pg_query_bridge_deparse_opts_set_comment(PostgresDeparseOpts *opts, size_t index,
	int location, int newlines_before, int newlines_after, const char *str)
{
	opts->comments[index] = calloc(1, sizeof(PostgresDeparseComment));
	opts->comments[index]->match_location = location;
	opts->comments[index]->newlines_before_comment = newlines_before;
	opts->comments[index]->newlines_after_comment = newlines_after;
	opts->comments[index]->str = str ? strdup(str) : NULL;
}

void pg_query_bridge_deparse_opts_free(PostgresDeparseOpts *opts) {
	if (!opts) return;
	if (opts->comments) {
		for (size_t i = 0; i < opts->comment_count; i++) {
			if (opts->comments[i]) {
				free(opts->comments[i]->str);
				free(opts->comments[i]);
			}
		}
		free(opts->comments);
	}
	free(opts);
}

PgQueryDeparseResult pg_query_bridge_deparse_protobuf_opts(PgQueryProtobuf parse_tree, PostgresDeparseOpts *opts) {
	return pg_query_deparse_protobuf_opts(parse_tree, *opts);
}
