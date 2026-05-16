#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "pg_query.h"

/*
 * Bridge setters for PostgresDeparseOpts fields.
 * V code must never access C.PostgresDeparseOpts fields directly —
 * all field access goes through these bridge functions. This decouples
 * the V declaration from the C struct layout entirely.
 */
void pg_query_bridge_deparse_opts_set_pretty_print(void *opts, int val) {
    ((PostgresDeparseOpts*)opts)->pretty_print = val;
}

void pg_query_bridge_deparse_opts_set_indent_size(void *opts, int val) {
    ((PostgresDeparseOpts*)opts)->indent_size = val;
}

void pg_query_bridge_deparse_opts_set_max_line_length(void *opts, int val) {
    ((PostgresDeparseOpts*)opts)->max_line_length = val;
}

void pg_query_bridge_deparse_opts_set_trailing_newline(void *opts, int val) {
    ((PostgresDeparseOpts*)opts)->trailing_newline = val;
}

void pg_query_bridge_deparse_opts_set_commas_start_of_line(void *opts, int val) {
    ((PostgresDeparseOpts*)opts)->commas_start_of_line = val;
}

void pg_query_bridge_deparse_opts_set_comment_count(void *opts, size_t val) {
    ((PostgresDeparseOpts*)opts)->comment_count = val;
}

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

void* pg_query_bridge_deparse_opts_new(void) {
	return calloc(1, sizeof(PostgresDeparseOpts));
}

void pg_query_bridge_deparse_opts_init_comments(void *opts, size_t count) {
	((PostgresDeparseOpts*)opts)->comments = calloc(count, sizeof(PostgresDeparseComment*));
	((PostgresDeparseOpts*)opts)->comment_count = count;
}

void pg_query_bridge_deparse_opts_set_comment(void *opts, size_t index,
	int location, int newlines_before, int newlines_after, const char *str)
{
	PostgresDeparseOpts *o = (PostgresDeparseOpts*)opts;
	o->comments[index] = calloc(1, sizeof(PostgresDeparseComment));
	o->comments[index]->match_location = location;
	o->comments[index]->newlines_before_comment = newlines_before;
	o->comments[index]->newlines_after_comment = newlines_after;
	o->comments[index]->str = str ? strdup(str) : NULL;
}

void pg_query_bridge_deparse_opts_free(void *opts) {
	if (!opts) return;
	PostgresDeparseOpts *o = (PostgresDeparseOpts*)opts;
	if (o->comments) {
		for (size_t i = 0; i < o->comment_count; i++) {
			if (o->comments[i]) {
				free(o->comments[i]->str);
				free(o->comments[i]);
			}
		}
		free(o->comments);
	}
	free(o);
}

PgQueryDeparseResult pg_query_bridge_deparse_protobuf_opts(PgQueryProtobuf parse_tree, void *opts) {
	return pg_query_deparse_protobuf_opts(parse_tree, *(PostgresDeparseOpts*)opts);
}
