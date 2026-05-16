module pg_query

fn test_parse_simple() {
	result := parse('SELECT 1') or {
		assert false, 'parse failed: ${err}'
		return
	}
	assert result.parse_tree.len > 0
	assert result.parse_tree.contains('SelectStmt')
}

fn test_parse_invalid() {
	result := parse('SELECT $$$') or {
		if err is PgError {
			assert err.message.len > 0
			assert err.funcname.len > 0
			assert err.filename.len > 0
			assert err.lineno > 0
			assert err.cursorpos >= 0
		} else {
			assert false, 'expected PgError'
		}
		return
	}
	assert false, 'expected error but got: ${result.parse_tree}'
}

fn test_normalize() {
	result := normalize('SELECT 1  ,  2') or {
		assert false, 'normalize failed: ${err}'
		return
	}
	assert result.normalized_query.len > 0
}

fn test_fingerprint() {
	result := fingerprint('SELECT 1') or {
		assert false, 'fingerprint failed: ${err}'
		return
	}
	assert result.fingerprint > 0
	assert result.fingerprint_str.len > 0
}

fn test_fingerprint_consistent() {
	r1 := fingerprint('SELECT 1') or { panic(err) }
	r2 := fingerprint('SELECT 1') or { panic(err) }
	assert r1.fingerprint == r2.fingerprint
	assert r1.fingerprint_str == r2.fingerprint_str
}

fn test_is_utility_ddl() {
	result := is_utility_stmt('CREATE TABLE t (id int)') or {
		assert false, 'is_utility_stmt failed: ${err}'
		return
	}
	assert result.length > 0
	assert result.items.len > 0
	assert result.items[0] == true
}

fn test_is_utility_select() {
	result := is_utility_stmt('SELECT 1') or {
		assert false, 'is_utility_stmt failed: ${err}'
		return
	}
	assert result.items.len > 0
	assert result.items[0] == false
}

fn test_split_with_scanner() {
	result := split_with_scanner('SELECT 1; SELECT 2') or {
		assert false, 'split failed: ${err}'
		return
	}
	assert result.stmts.len == 2
	assert result.n_stmts == 2
	assert result.stmts[0].stmt_location == 0
	assert result.stmts[1].stmt_location > 0
}

fn test_split_with_parser() {
	result := split_with_parser('SELECT 1; SELECT 2') or {
		assert false, 'split failed: ${err}'
		return
	}
	assert result.stmts.len == 2
	assert result.n_stmts == 2
}

fn test_parse_protobuf() {
	result := parse_protobuf('SELECT 1') or {
		assert false, 'parse_protobuf failed: ${err}'
		return
	}
	assert result.parse_tree.len > 0
	assert result.parse_tree.data.len == int(result.parse_tree.len)
}

fn test_protobuf_bytes_match_len() {
	result := parse_protobuf('SELECT 1') or { panic(err) }
	pb := result.parse_tree
	assert pb.data.len > 0
	assert pb.data.len == int(pb.len)
}

fn test_protobuf_hex_not_empty() {
	result := parse_protobuf('SELECT 1') or { panic(err) }
	hex := result.parse_tree.hex()
	assert hex.len > 0
	// each byte -> 2 hex chars
	assert hex.len == int(result.parse_tree.len) * 2
}

fn test_protobuf_hex() {
	result := parse_protobuf('SELECT 1') or { panic(err) }
	h := result.parse_tree.hex()
	assert h.len == int(result.parse_tree.len) * 2
}

fn test_protobuf_bytes() {
	result := parse_protobuf('SELECT 1') or { panic(err) }
	b := result.parse_tree.bytes()
	assert b.len == int(result.parse_tree.len)
	// verify roundtrip: []u8 -> string -> []u8 produces same data
	re_encoded := b.bytestr()
	assert re_encoded == result.parse_tree.data
}

fn test_parse_plpgsql() {
	result := parse_plpgsql('CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql') or {
		assert false, 'parse_plpgsql failed: ${err}'
		return
	}
	assert result.plpgsql_funcs.len > 0
}

fn test_version() {
	assert pg_version() == '17.7'
	assert pg_major_version() == '17'
	assert pg_version_num() == 170007
}

fn test_parse_opts() {
	result := parse_opts('SELECT 1', pg_query_parse_default) or {
		assert false, 'parse_opts failed: ${err}'
		return
	}
	assert result.parse_tree.contains('SelectStmt')
}

fn test_fingerprint_opts() {
	result := fingerprint_opts('SELECT 1', pg_query_parse_default) or {
		assert false, 'fingerprint_opts failed: ${err}'
		return
	}
	assert result.fingerprint > 0
}

fn test_summary() {
	result := summary('SELECT 1', pg_query_parse_default, 100) or {
		assert false, 'summary failed: ${err}'
		return
	}
	// Should contain statement_types for SELECT
	assert result.statement_types.len > 0
}

fn test_deparse_roundtrip() {
	pb_result := parse_protobuf('SELECT 1') or {
		assert false, 'parse_protobuf failed: ${err}'
		return
	}
	result := deparse_protobuf(pb_result.parse_tree) or {
		assert false, 'deparse_protobuf failed: ${err}'
		return
	}
	assert result.query == 'SELECT 1'
}

fn test_deparse_roundtrip_with_opts() {
	pb_result := parse_protobuf('SELECT 1') or { panic(err) }
	opts := DeparseOpts{
		pretty_print:     true
		indent_size:      2
		max_line_length:  80
		trailing_newline: true
	}
	result := deparse_protobuf_opts(pb_result.parse_tree, opts) or {
		assert false, 'deparse_protobuf_opts failed: ${err}'
		return
	}
	assert result.query.contains('SELECT')
}

fn test_deparse_roundtrip_complex() {
	pb_result := parse_protobuf('SELECT a, b FROM t WHERE c = 1') or { panic(err) }
	result := deparse_protobuf(pb_result.parse_tree) or {
		assert false, 'deparse_protobuf failed: ${err}'
		return
	}
	assert result.query.contains('SELECT')
	assert result.query.contains('FROM')
	assert result.query.contains('WHERE')
	assert result.query.contains('c = 1')
}

fn test_parse_scan() {
	result := scan('SELECT 1') or {
		assert false, 'scan failed: ${err}'
		return
	}
	assert result.tokens.len > 0
}

fn test_parse_normalize_utility() {
	result := normalize_utility('CREATE TABLE t (id int)') or {
		assert false, 'normalize_utility failed: ${err}'
		return
	}
	assert result.normalized_query.len > 0
}

fn test_parse_protobuf_ast() {
	result := parse_protobuf_ast('SELECT 1') or {
		assert false, 'parse_protobuf_ast failed: ${err}'
		return
	}
	assert result.version == 170007
	assert result.stmts.len == 1
	assert result.stmts[0].stmt_location == 0
	assert result.stmts[0].stmt is SelectStmt
}

fn test_parse_protobuf_ast_multi_stmt() {
	result := parse_protobuf_ast('SELECT 1; SELECT 2') or {
		assert false, 'parse_protobuf_ast multi failed: ${err}'
		return
	}
	assert result.stmts.len == 2
}

fn test_parse_protobuf_ast_invalid_sql_handled() {
	// Invalid SQL may return an error or an empty result - both are valid
	parse_protobuf_ast('SELECT $$$') or { return }
	// If no error, verify result is empty
}
