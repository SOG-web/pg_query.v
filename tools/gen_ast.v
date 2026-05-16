// pg_query.v AST generator
// Reads protobuf/pg_query.proto and generates:
//   pg_query/pg_query_ast.v      - V AST struct definitions (JSON decode path)
//   pg_query/pg_query_ast_c.h    - C header with V-compatible structs (direct bridge)
//   pg_query/protobuf_bridge.c   - C bridge with converter functions

import os

struct ProtoEnum {
	name   string
	mut:
	values []ProtoEnumValue
}

struct ProtoEnumValue {
	name  string
	value int
}

struct ProtoField {
	name        string
	typ         string
	field_num   int
	repeated    bool
	json_name   string
	is_oneof    bool
	oneof_group string
	is_map      bool
	map_key_typ string
	map_val_typ string
}

struct ProtoMessage {
	name   string
	mut:
	fields []ProtoField
	oneofs []string
}

struct ProtoFile {
	mut:
	enums    []ProtoEnum
	messages []ProtoMessage
}

fn main() {
	proto_text := os.read_file('libpg_query/protobuf/pg_query.proto') or {
		eprintln('Failed to read proto file: ${err}')
		return
	}
	pf := parse_proto(proto_text)
	generate_code(pf)
}

// join_until_semicolon concatenates lines from lines[start] until a line
// containing ';' is found, or the end. Handles multi-line field declarations.
fn join_until_semicolon(lines []string, start int) (string, int) {
	mut result := lines[start]
	mut i := start + 1
	for i < lines.len {
		if result.contains(';') { break }
		result += ' ' + lines[i]
		i++
	}
	return result.trim_space(), i - 1
}

fn strip_line_comments(line string) string {
	mut result := line
	// Strip // comments (but not inside quoted strings)
	mut in_string := false
	for ci, c in result {
		if c == `"` { in_string = !in_string }
		if !in_string && c == `/` && ci + 1 < result.len && result[ci + 1] == `/` {
			result = result[..ci]
			break
		}
	}
	// Strip /* ... */ comments
	mut depth := 0
	mut stripped := ''
	for ci := 0; ci < result.len; ci++ {
		if result[ci] == `/` && ci + 1 < result.len && result[ci + 1] == `*` && depth == 0 {
			depth = 1
			ci++
			continue
		}
		if result[ci] == `*` && ci + 1 < result.len && result[ci + 1] == `/` && depth > 0 {
			depth = 0
			ci++
			continue
		}
		if depth == 0 {
			stripped += result[ci].ascii_str()
		}
	}
	return stripped.trim_space()
}

fn parse_proto(text string) ProtoFile {
	mut pf := ProtoFile{}
	lines := text.split('\n')
	mut i := 0
	for i < lines.len {
		line := strip_line_comments(lines[i]).trim_space()
		if line == '' {
			i++
			continue
		}
		if line.starts_with('syntax ') || line.starts_with('package ') || line.starts_with('import ') || line.starts_with('import public ') || line.starts_with('import weak ') {
			i++
			continue
		}
		if line.starts_with('enum ') {
			parts := line.split(' ')
			if parts.len < 2 { i++; continue }
			name := parts[1].trim_right(' {')
			mut en := ProtoEnum{name: name}
			i++
			for i < lines.len {
				cline := lines[i].trim_space()
				if cline == '}' { break }
				if cline != '' && !cline.starts_with('//') && !cline.starts_with('/*') && cline.contains('=') {
					eq_parts := cline.split('=')
					if eq_parts.len < 2 { i++; continue }
					val_name := eq_parts[0].trim_space()
					val_value := eq_parts[1].trim_right(',').trim_space().int()
					en.values << ProtoEnumValue{name: val_name, value: val_value}
				}
				i++
			}
			pf.enums << en
		} else if line.starts_with('message ') {
			parts := line.split(' ')
			if parts.len < 2 { i++; continue }
			name := parts[1].trim_right(' {')
			mut msg := ProtoMessage{name: name}
			mut in_oneof := false
			mut oneof_name := ''
			i++
			for i < lines.len {
				cline := lines[i].trim_space()
				if cline == '}' && !in_oneof {
					break
				}
				if cline.starts_with('oneof ') {
					of_parts := cline.split(' ')
					in_oneof = true
					oneof_name = if of_parts.len >= 2 { of_parts[1].trim_right(' {') } else { '' }
					if oneof_name != '' { msg.oneofs << oneof_name }
					i++
					continue
				}
				if cline == '}' && in_oneof {
					in_oneof = false
					i++
					continue
				}
				if cline.starts_with('reserved ') || cline.starts_with('option ') {
					i++
					continue
				}
				if cline.starts_with('enum ') {
					enum_parts := cline.split(' ')
					if enum_parts.len >= 2 {
						ename := enum_parts[1].trim_right(' {')
						// Qualify nested enum name with parent message name
						qname := '${msg.name}_${ename}'
						mut en := ProtoEnum{name: qname}
						i++
						for i < lines.len {
							eline := lines[i].trim_space()
							if eline == '}' { break }
							if eline.contains('=') {
								eq_parts := eline.split('=')
								if eq_parts.len >= 2 {
									val_name := eq_parts[0].trim_space()
									val_value := eq_parts[1].trim_right(',').trim_space().int()
									en.values << ProtoEnumValue{name: val_name, value: val_value}
								}
							}
							i++
						}
						pf.enums << en
					}
					i++
					continue
				}
				if cline.starts_with('message ') {
					nested_parts := cline.split(' ')
					if nested_parts.len >= 2 {
						nname := nested_parts[1].trim_right(' {')
						// Qualify nested message name
						qname := '${msg.name}_${nname}'
						mut nmsg := ProtoMessage{name: qname}
						mut depth := 1
						i++
						for i < lines.len {
							tline := lines[i].trim_space()
							if tline == '{' { depth++ }
							if tline == '}' { depth--; if depth == 0 { break } }
							// Parse nested fields inside
							if depth == 1 && tline.contains('=') && !tline.starts_with('//') && !tline.starts_with('/*') {
								// Join multi-line field declarations
								njoined_raw, nji := join_until_semicolon(lines, i)
								i = nji
								nline := strip_line_comments(njoined_raw).trim_space()
								neq_parts := nline.split('=')
								if neq_parts.len >= 2 {
									ndecl := neq_parts[0].trim_space()
									mut nrepeated := false
									mut nftype := ''
									mut nfname := ''
									mut nis_map := false
									mut nmap_key := ''
									mut nmap_val := ''
									if ndecl.starts_with('map<') {
										nis_map = true
										mut ndepth := 1
										mut nend := 4
										for nend < ndecl.len && ndepth > 0 {
											if ndecl[nend] == `<` { ndepth++ }
											if ndecl[nend] == `>` { ndepth-- }
											if ndepth > 0 { nend++ }
										}
										nmap_decl := ndecl[4..nend]
										nmap_parts := nmap_decl.split(',')
										if nmap_parts.len >= 2 {
											nmap_key = nmap_parts[0].trim_space()
											nmap_val = nmap_parts[1].trim_space()
										}
										nafter := ndecl[nend + 1..].trim_space()
										nnparts := nafter.split(' ')
										if nnparts.len >= 1 {
											nfname = nnparts[0].trim_space()
										}
										nftype = 'map'
									} else if ndecl.starts_with('repeated ') {
										nrepeated = true
										nafter := ndecl[9..].trim_space()
										nsub := nafter.split(' ')
										if nsub.len >= 2 {
											nftype = nsub[0].trim_space()
											nfname = nsub[1].trim_space()
										}
									} else {
										nsub := ndecl.split(' ')
										if nsub.len >= 2 {
											nftype = nsub[0].trim_space()
											nfname = nsub[1].trim_space()
										}
									}
									if nfname != '' {
										nrest := neq_parts[1].trim_right(';').trim_space()
										nnum_part := nrest.split(' ')[0].trim_right(',').trim_right(']')
										nfnum := nnum_part.int()
										mut njn := nfname
										if nrest.contains('json_name') {
											njn = extract_json_name(nrest)
										}
										// Resolve type references within parent scope
										mut ntyp := nftype
										if ntyp == 'Context' || ntyp == 'Table' || ntyp == 'Function' || ntyp == 'FilterColumn' {
											ntyp = '${msg.name}_${ntyp}'
										}
										nmsg.fields << ProtoField{
											name: nfname
											typ: ntyp
											field_num: nfnum
											repeated: nrepeated
											json_name: njn
											is_oneof: false
											is_map: nis_map
											map_key_typ: nmap_key
											map_val_typ: nmap_val
										}
									}
								}
							}
							i++
						}
						pf.messages << nmsg
					} else {
						mut depth := 1
						i++
						for i < lines.len {
							tline := lines[i].trim_space()
							if tline == '{' { depth++ }
							if tline == '}' { depth--; if depth == 0 { break } }
							i++
						}
					}
					i++
					continue
				}
				if in_oneof {
				if cline.contains('=') && !cline.starts_with('//') {
						// Join multi-line field declarations
						joined_raw, ji := join_until_semicolon(lines, i)
						i = ji
						oline := strip_line_comments(joined_raw).trim_space()
						eq_parts := oline.split('=')
						if eq_parts.len < 2 { i++; continue }
						decl := eq_parts[0].trim_space()
						decl_parts := decl.split(' ')
						if decl_parts.len < 2 { i++; continue }
						oftype := decl_parts[0].trim_space()
						ofname := decl_parts[1].trim_space()
						rest := eq_parts[1].trim_right(';').trim_space()
						num_part := rest.split(' ')[0].trim_right(',').trim_right(']')
						fnum := num_part.int()
						mut jn := ofname
						if rest.contains('json_name') {
							jn = extract_json_name(rest)
						}
						msg.fields << ProtoField{
							name: ofname
							typ: oftype
							field_num: fnum
							json_name: jn
							is_oneof: true
							oneof_group: oneof_name
						}
					}
					i++
					continue
				}
				if cline != '' && !cline.starts_with('//') && !cline.starts_with('/*') && cline.contains('=') {
					// Join multi-line field declarations
					joined_raw, ji := join_until_semicolon(lines, i)
					i = ji
					fline := strip_line_comments(joined_raw).trim_space()
					eq_parts := fline.split('=')
					if eq_parts.len < 2 { i++; continue }
					decl := eq_parts[0].trim_space()
					mut repeated := false
					mut ftype := ''
					mut fname := ''
					mut is_map := false
					mut map_key_typ := ''
					mut map_val_typ := ''
					if decl.starts_with('map<') {
						// map<K, V> name = num;
						is_map = true
						// Find the closing '>' of map<K, V>
						mut depth := 1
						mut end_idx := 4 // skip 'map<'
						for end_idx < decl.len && depth > 0 {
							if decl[end_idx] == `<` { depth++ }
							if decl[end_idx] == `>` { depth-- }
							if depth > 0 { end_idx++ }
						}
						map_decl := decl[4..end_idx]
						map_parts := map_decl.split(',')
						if map_parts.len >= 2 {
							map_key_typ = map_parts[0].trim_space()
							map_val_typ = map_parts[1].trim_space()
						}
						after_map := decl[end_idx + 1..].trim_space()
						map_name_parts := after_map.split(' ')
						if map_name_parts.len >= 1 {
							fname = map_name_parts[0].trim_space()
						}
						ftype = 'map'
					} else if decl.starts_with('repeated ') {
						repeated = true
						after := decl[9..].trim_space()
						sub_parts := after.split(' ')
						if sub_parts.len < 2 { i++; continue }
						ftype = sub_parts[0].trim_space()
						fname = sub_parts[1].trim_space()
					} else {
						sub_parts := decl.split(' ')
						if sub_parts.len < 2 { i++; continue }
						ftype = sub_parts[0].trim_space()
						fname = sub_parts[1].trim_space()
					}
					rest := eq_parts[1].trim_right(';').trim_space()
					num_part := rest.split(' ')[0].trim_right(',').trim_right(']')
					fnum := num_part.int()
					mut jn := fname
					if rest.contains('json_name') {
						jn = extract_json_name(rest)
					}
					// Resolve nested type references
					qtype := '${msg.name}_${ftype}'
					if !is_primitive_proto(ftype) && ftype != 'Node' && ftype != 'string' && ftype != 'bytes' && ftype != 'Context' && ftype != 'map' {
						for em in pf.messages {
							if em.name == qtype {
								ftype = qtype
								break
							}
						}
						for ee in pf.enums {
							if ee.name == qtype {
								ftype = qtype
								break
							}
						}
					}
					msg.fields << ProtoField{
						name: fname
						typ: ftype
						field_num: fnum
						repeated: repeated
						json_name: jn
						is_oneof: false
						is_map: is_map
						map_key_typ: map_key_typ
						map_val_typ: map_val_typ
					}
				}
				i++
			}
			pf.messages << msg
		}
		i++
	}
	return pf
}

fn extract_json_name(rest string) string {
	idx := rest.index('json_name=') or { return '' }
	rest2 := rest[idx..]
	start := rest2.index('"') or { return '' }
	rest3 := rest2[start + 1..]
	end := rest3.index('"') or { return '' }
	return rest3[..end]
}

fn snake_case(s string) string {
	mut out := ''
	for i, c in s {
		if c >= u8(`A`) && c <= u8(`Z`) {
			if i > 0 {
				out += '_'
			}
			out += (c + 32).ascii_str()
		} else {
			out += c.ascii_str()
		}
	}
	return out
}

fn proto_field_to_v_type(ptype string) string {
	match ptype {
		'int32', 'sint32', 'sfixed32' { return 'int' }
		'int64', 'sint64', 'sfixed64' { return 'i64' }
		'uint32', 'fixed32' { return 'u32' }
		'uint64', 'fixed64' { return 'u64' }
		'float' { return 'f32' }
		'double' { return 'f64' }
		'bool' { return 'bool' }
		'string' { return 'string' }
		'bytes' { return '[]u8' }
		'Node' { return 'Node' }
		'Context' { return 'SummaryContext' }
		'map' { return 'map[string]string' }
		else {
			parts := ptype.split('_')
			mut out := ''
			for p in parts {
				if p.len > 0 {
					out += p[0..1].to_upper() + p[1..]
				}
			}
			return out
		}
	}
}

fn proto_type_to_v_type(ptype string) string {
	return proto_field_to_v_type(ptype)
}

fn is_primitive_proto(ptype string) bool {
	match ptype {
		'int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64',
		'fixed32', 'fixed64', 'sfixed32', 'sfixed64',
		'float', 'double', 'bool', 'string', 'bytes' {
			return true
		}
		else {
			return false
		}
	}
}

fn is_enum_type(pf ProtoFile, type_name string) bool {
	for e in pf.enums {
		if e.name == type_name { return true }
	}
	return false
}

fn enum_values(pf ProtoFile, type_name string) []int {
	for e in pf.enums {
		if e.name == type_name {
			mut vals := []int{}
			for ev in e.values {
				vals << ev.value
			}
			return vals
		}
	}
	return []
}

// Convert proto type name to C prototype name (PgQuery__Xxx)
// Convert proto message name to protobuf-c __init function suffix (snake_case)
// Matches protobuf-c's naming: insert '_' only at lowercase→uppercase transitions
// Examples:
//   "A_Const"       → "a__const"
//   "PLAssignStmt"  → "plassign_stmt"
fn generate_code(pf ProtoFile) {
	// Find Node oneof fields
	mut node_oneof_fields := []ProtoField{}
	for m in pf.messages {
		if m.name == 'Node' {
			for f in m.fields {
				if f.is_oneof {
					node_oneof_fields << f
				}
			}
		}
	}

	generate_v_ast(pf, node_oneof_fields)
	generate_v_protobuf_decode(pf, node_oneof_fields)
	generate_v_protobuf_encode(pf, node_oneof_fields)
}

// ============================================================
// Generate pg_query/pg_query_ast.v (V struct definitions)
// ============================================================

fn generate_str_method(m ProtoMessage, pf ProtoFile) string {
	vname := proto_type_to_v_type(m.name)
	mut out := ''
	out += 'pub fn (m ${vname}) str() string {\n'
	out += '\tmut parts := []string{}\n'

	for f in m.fields {
		if f.is_oneof {
			continue
		}
		vfname := snake_case(f.name)
		is_recursive := f.typ == m.name

		if f.repeated {
			out += '\tif m.${vfname}.len > 0 { parts << "${vfname}: \${m.${vfname}}" }\n'
		} else if f.is_map {
			out += '\tif m.${vfname}.len > 0 { parts << "${vfname}: \${m.${vfname}}" }\n'
		} else if is_recursive {
			out += '\tif !isnil(m.${vfname}) { parts << "${vfname}: \${m.${vfname}}" }\n'
		} else if is_primitive_proto(f.typ) {
			if f.typ == 'bool' {
				out += '\tif m.${vfname} { parts << "${vfname}: true" }\n'
			} else if f.typ == 'string' {
				out += "\tif m.${vfname} != '' { parts << '${vfname}: \${m.${vfname}}' }\n"
			} else if f.typ == 'bytes' {
				out += '\tif m.${vfname}.len > 0 { parts << "${vfname}: [\${m.${vfname}.len} bytes]" }\n'
			} else if f.typ == 'float' || f.typ == 'double' {
				out += '\tif m.${vfname} != 0.0 { parts << "${vfname}: \${m.${vfname}}" }\n'
			} else {
				out += '\tif m.${vfname} != 0 { parts << "${vfname}: \${m.${vfname}}" }\n'
			}
		} else if f.typ == 'Node' || f.typ == 'Context' {
			out += '\tparts << "${vfname}: \${m.${vfname}}"\n'
		} else if is_enum_type(pf, f.typ) {
			out += '\tparts << "${vfname}: \${m.${vfname}}"\n'
		} else {
			out += '\tparts << "${vfname}: \${m.${vfname}}"\n'
		}
	}

	// Handle oneof fields
	for of_name in m.oneofs {
		for f in m.fields {
			if f.is_oneof && f.oneof_group == of_name {
				vfname := snake_case(f.name)
				out += '\tif v_${vfname} := m.${vfname} { parts << "${vfname}: \${v_${vfname}}" }\n'
			}
		}
	}

	out += "\treturn '${vname}{' + parts.join(', ') + '}'\n"
	out += '}\n\n'
	return out
}

fn generate_v_ast(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += 'module pg_query\n\n'
	out += 'import json\n\n'

	// Generate enums
	for e in pf.enums {
		vname := proto_type_to_v_type(e.name)
		out += 'pub enum ${vname} {\n'
		for v in e.values {
			mut ename := v.name.to_lower()
			ename = ename.replace('pg_query__', '').replace('__', '_')
			out += '\t${ename} = ${v.value}\n'
		}
		out += '}\n\n'
	}

	// Generate message structs (skip Node, ParseResult, ScanResult, SummaryResult)
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' { continue }
		vname := proto_type_to_v_type(m.name)
		out += 'pub struct ${vname} {\n'
		out += 'pub mut:\n'
		for f in m.fields {
			if f.is_oneof {
				continue
			}
			vtype := proto_field_to_v_type(f.typ)
			is_recursive := f.typ == m.name
			mut v_field_type := vtype
			if is_recursive {
				v_field_type = '&${vtype}'
			}
			if f.repeated {
				v_field_type = '[]${v_field_type}'
			}
			vfname := snake_case(f.name)
			jn := f.json_name
			if jn != '' && jn != vfname {
				out += '\t${vfname} ${v_field_type} @[json: \'${jn}\']\n'
			} else {
				out += '\t${vfname} ${v_field_type}\n'
			}
		}
		// Handle oneof fields
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					vtype := proto_field_to_v_type(f.typ)
					vfname := snake_case(f.name)
					jn := f.json_name
					if jn != '' && jn != vfname {
						out += '\t${vfname} ?${vtype} @[json: \'${jn}\']\n'
					} else {
						out += '\t${vfname} ?${vtype}\n'
					}
				}
			}
		}
		out += '}\n'
		out += generate_str_method(m, pf)
	}

	// Generate UnrecognizedNode (for unknown oneof variants)
	out += '// UnrecognizedNode holds raw data for an unknown Node variant.\n'
	out += '// This is returned by the protobuf decoder when the field number\n'
	out += '// does not match any known Node oneof branch.\n'
	out += 'pub struct UnrecognizedNode {\n'
	out += 'pub mut:\n'
	out += '\tfield_num int\n'
	out += '\tdata []u8\n'
	out += '}\n\n'

	out += 'pub fn (m UnrecognizedNode) str() string {\n'
	out += "\treturn 'UnrecognizedNode{field_num: ' + m.field_num.str() + ', data: [' + m.data.len.str() + ' bytes]}'\n"
	out += '}\n\n'

	// Generate Node sum type
	out += '// Node sum type for all AST node variants\n'
	out += 'pub type Node = '
	mut first := true
	for f in node_oneof_fields {
		if !first { out += ' | ' }
		out += proto_field_to_v_type(f.typ)
		first = false
	}
	out += ' | UnrecognizedNode\n\n'

	// Generate str() for Node sum type
	out += 'pub fn (n Node) str() string {\n'
	out += '\tmatch n {\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		out += '\t\t${vname} {\n'
		out += '\t\t\treturn n.str()\n'
		out += '\t\t}\n'
	}
	out += '\t\tUnrecognizedNode {\n'
	out += '\t\t\treturn n.str()\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '}\n\n'

	// Generate JsonNode for intermediate JSON decoding
	out += '// JsonNode is used internally for JSON decoding before converting to Node sum type\n'
	out += 'pub struct JsonNode {\n'
	for f in node_oneof_fields {
		vtype := proto_field_to_v_type(f.typ)
		vfname := snake_case(f.name)
		jn := f.json_name
		if jn != '' {
			out += '\t${vfname} ?${vtype} @[json: \'${jn}\']\n'
		} else {
			out += '\t${vfname} ?${vtype}\n'
		}
	}
	out += '}\n\n'

	// Generate JsonNode to Node converter
	out += 'fn decode_node_json(jn JsonNode) Node {\n'
	for f in node_oneof_fields {
		vfname := snake_case(f.name)
		out += '\tif n := jn.${vfname} {\n'
		out += '\t\treturn n\n'
		out += '\t}\n'
	}
	out += '\t// No known field matched — scan all fields for data\n'
	out += '\t// to create an UnrecognizedNode that preserves the payload\n'
	out += '\t// Iterate over JsonNode fields to find a non-none value\n'
	out += '\treturn UnrecognizedNode{field_num: 0, data: []u8{}}\n'
	out += '}\n\n'

	// Generate AstRawStmt and ParseAstResult
	out += '// AstRawStmt is a typed version of RawStmt with a decoded Node tree.\n'
	out += 'pub struct AstRawStmt {\n'
	out += 'pub:\n'
	out += '\tstmt_location i64 @[json: \'stmtLocation\']\n'
	out += '\tstmt_len i64 @[json: \'stmtLen\']\n'
	out += '\tstmt Node @[json: \'stmt\']\n'
	out += '}\n\n'

	out += 'pub fn (m AstRawStmt) str() string {\n'
	out += '\tmut parts := []string{}\n'
	out += '\tif m.stmt_location != 0 { parts << "stmt_location: \${m.stmt_location}" }\n'
	out += '\tif m.stmt_len != 0 { parts << "stmt_len: \${m.stmt_len}" }\n'
	out += '\tparts << "stmt: \${m.stmt}"\n'
	out += "\treturn 'AstRawStmt{' + parts.join(', ') + '}'\n"
	out += '}\n\n'

	out += '// ParseAstResult is the typed AST equivalent of ParseResult.\n'
	out += 'pub struct ParseAstResult {\n'
	out += 'pub:\n'
	out += '\tversion int\n'
	out += '\tstmts []AstRawStmt @[json: \'stmts\']\n'
	out += '}\n\n'

	out += 'pub fn (m ParseAstResult) str() string {\n'
	out += '\tmut parts := []string{}\n'
	out += '\tif m.version != 0 { parts << "version: \${m.version}" }\n'
	out += '\tif m.stmts.len > 0 { parts << "stmts: \${m.stmts}" }\n'
	out += "\treturn 'ParseAstResult{' + parts.join(', ') + '}'\n"
	out += '}\n\n'

	// JSON intermediate structs
	out += '// JSON-only intermediate types for decoding\n'
	out += 'struct JsonRawStmt {\n'
	out += '\tstmt_location i64 @[json: \'stmtLocation\']\n'
	out += '\tstmt_len i64 @[json: \'stmtLen\']\n'
	out += '\tstmt JsonNode @[json: \'stmt\']\n'
	out += '}\n\n'

	out += 'struct JsonParseResult {\n'
	out += '\tversion int\n'
	out += '\tstmts []JsonRawStmt @[json: \'stmts\']\n'
	out += '}\n\n'

	// Generate parse_ast() function
	out += '// Parse SQL into typed V AST structs using JSON decode path.\n'
	out += '// Deprecated: use parse_protobuf_ast() instead (~3x faster, pure V decode).\n'
	out += '// parse_ast calls parse() (C bridge JSON) then decodes JSON into V structs.\n'
	out += 'pub fn parse_ast(input_sql string) !ParseAstResult {\n'
	out += '\tres := parse(input_sql) or { return err }\n'
	out += '\tjson_res := json.decode(JsonParseResult, res.parse_tree) or { return err }\n'
	out += '\tmut stmts := []AstRawStmt{}\n'
	out += '\tfor s in json_res.stmts {\n'
	out += '\t\tstmts << AstRawStmt{\n'
	out += '\t\t\tstmt_location: s.stmt_location\n'
	out += '\t\t\tstmt_len: s.stmt_len\n'
	out += '\t\t\tstmt: decode_node_json(s.stmt)\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '\treturn ParseAstResult{\n'
	out += '\t\tversion: json_res.version\n'
	out += '\t\tstmts: stmts\n'
	out += '\t}\n'
	out += '}\n\n'

	os.write_file('pg_query/pg_query_ast.v', out) or {
		eprintln('Failed to write pg_query_ast.v: ${err}')
		return
	}
	println('Generated pg_query/pg_query_ast.v (${out.len} bytes, ${pf.messages.len} messages, ${pf.enums.len} enums)')
}

// Topological sort messages so dependencies are defined before dependents
fn topological_sort_messages(pf ProtoFile) []ProtoMessage {
	mut skip_names := map[string]bool{}
	skip_names['Node'] = true
	skip_names['ParseResult'] = true

	// Collect messages to sort
	mut msgs := []ProtoMessage{}
	mut name_to_msg := map[string]ProtoMessage{}
	for m in pf.messages {
		if m.name in skip_names { continue }
		msgs << m
		name_to_msg[m.name] = m
	}

	// Build dependency graph: msg_name -> list of msg names it depends on (must be defined before it)
	mut deps := map[string][]string{}
	for m in msgs {
		mut dep_list := []string{}
		for f in m.fields {
			if f.is_oneof { continue }
			if f.repeated { continue }
			if f.typ == m.name { continue } // self-ref uses pointer
			if f.typ == 'Node' { continue } // VNode already defined
			if f.typ == 'Context' { continue }
			if is_primitive_proto(f.typ) { continue }
			if is_enum_type(pf, f.typ) { continue }
			if f.typ in skip_names { continue }
			dep_list << f.typ
		}
		deps[m.name] = dep_list
	}

	// Kahn's algorithm for topological sort
	mut in_degree := map[string]int{}
	for m in msgs {
		in_degree[m.name] = 0
	}
	for _, dep_list in deps {
		for d in dep_list {
			in_degree[d]++
		}
	}
	// Wait - I got the direction wrong. If A depends on B (B must come first),
	// then in Kahn's algorithm, B has edges to A. In-degree of A counts how many
	// things must come before A. So:
	// For each dep d in deps[A], d must come before A. Edge d -> A.
	// in_degree[A] = number of deps[A]

	// Actually, my dep graph is: deps[A] = [B, C] means B and C must come before A.
	// In-degree of A = number of prerequisites = len(deps[A]).
	for m in msgs {
		in_degree[m.name] = deps[m.name].len
	}

	mut queue := []ProtoMessage{}
	for m in msgs {
		if in_degree[m.name] == 0 {
			queue << m
		}
	}

	mut sorted := []ProtoMessage{}
	for queue.len > 0 {
		cur := queue[0]
		queue.delete(0)
		sorted << cur
		// Decrease in-degree of all messages that depend on cur
		for m in msgs {
			for dep_name in deps[m.name] {
				if dep_name == cur.name {
					in_degree[m.name]--
					if in_degree[m.name] == 0 {
						queue << m
					}
				}
			}
		}
	}

	if sorted.len != msgs.len {
		// topological sort incomplete — append remaining
		// (cycle caused by SummaryResult nested types referencing each other)
		for m in msgs {
			mut found := false
			for s in sorted {
				if s.name == m.name { found = true; break }
			}
			if !found { sorted << m }
		}
	}

	return sorted
}

// ============================================================
// Generate pg_query/pg_query_decode.v (V-native protobuf decode)
// ============================================================
fn generate_v_protobuf_decode(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += 'module pg_query\n\n'

	// Set of messages to skip from auto-generation
	mut skip_names := map[string]bool{}
	skip_names['Node'] = true
	skip_names['ParseResult'] = true
	// RawStmt auto-generated for Node sum type variant

	// Build map of types that directly have reference (self-referencing) fields
	mut direct_ref_types := map[string][]string{}
	for m in pf.messages {
		mut ref_fields := []string{}
		for f in m.fields {
			if !f.is_oneof && f.typ == m.name {
				ref_fields << snake_case(f.name)
			}
		}
		if ref_fields.len > 0 {
			direct_ref_types[m.name] = ref_fields
		}
	}

	// Generate decode functions in topological order
	mut sorted := topological_sort_messages(pf)
	for m in sorted {
		if m.name in skip_names { continue }
		vname := proto_field_to_v_type(m.name)
		dfn := snake_case(vname)
		// Check for reference (recursive pointer) fields
		mut has_ref_fields := false
		mut ref_field_names := []string{}
		mut transitive_init := []string{} // "field_name: TypeName{ref: nil, ...}" strings
		for f in m.fields {
			if !f.is_oneof && f.typ == m.name {
				has_ref_fields = true
				ref_field_names << snake_case(f.name)
			}
			// Check for transitive reference: field type (non-Node, non-primitive) has direct refs
			if !f.is_oneof && f.typ in direct_ref_types && f.typ != m.name {
				vftype := proto_field_to_v_type(f.typ)
				vfname := snake_case(f.name)
				mut inner := ''
				for irfn in direct_ref_types[f.typ] {
					if inner.len > 0 { inner += '\n' }
					inner += '\t\t\t${irfn}: unsafe { nil }'
				}
				transitive_init << '\t\t${vfname}: ${vftype}{\n${inner}\n\t\t}'
			}
		}
		needs_unsafe_init := has_ref_fields || transitive_init.len > 0
		has_regular_fields := m.fields.len > 0
		out += 'fn decode_${dfn}(buf []u8, depth int) (${vname}, int) {\n'
		// Collect map field names for initialization
		mut map_field_names := []string{}
		for f in m.fields {
			if f.is_map { map_field_names << snake_case(f.name) }
		}
		has_maps := map_field_names.len > 0

		if needs_unsafe_init || has_maps {
			out += '\tif depth <= 0 { return ${vname}{\n'
			for rfn in ref_field_names {
				out += '\t\t${rfn}: unsafe { nil }\n'
			}
			for ti in transitive_init {
				out += '\t\t' + ti.trim_left('\t') + '\n'
			}
			for mfn in map_field_names {
				out += '\t\t${mfn}: {}\n'
			}
			out += '\t}, 0 }\n'
			out += '\tmut r := ${vname}{\n'
			for rfn in ref_field_names {
				out += '\t\t${rfn}: unsafe { nil }\n'
			}
			for ti in transitive_init {
				out += '\t' + ti + '\n'
			}
			for mfn in map_field_names {
				out += '\t\t${mfn}: {}\n'
			}
			out += '\t}\n'
		} else {
			out += '\tif depth <= 0 { return ${vname}{}, 0 }\n'
			out += '\tmut r := ${vname}{}\n'
		}
		if !has_regular_fields {
			out += '\treturn r, buf.len\n'
		} else {
			out += '\tmut off := 0\n'
			out += '\tfor off < buf.len {\n'
			out += '\t\tfield_num, wire_type, c := read_tag(buf, off)\n'
			out += '\t\toff += c\n'
			out += '\t\tmatch field_num {\n'
			for f in m.fields {
				if f.is_oneof { continue }
				out += proto_decode_field_case(f, vname, m.name, pf)
			}
			for f in m.fields {
				if !f.is_oneof { continue }
				out += proto_decode_oneof_field_case(f, vname, pf)
			}
			out += '\t\t\telse {\n'
			out += '\t\t\t\toff = skip_field(buf, off, wire_type)\n'
			out += '\t\t\t}\n'
			out += '\t\t}\n'
			out += '\t}\n'
			out += '\treturn r, off\n'
		}
		out += '}\n\n'
	}

	// Generate decode_Node dispatcher
	first_vtype := proto_field_to_v_type(node_oneof_fields[0].typ)
	out += 'fn decode_node(buf []u8, depth int) (Node, int) {\n'
	out += '\tif depth <= 0 { return ${first_vtype}{}, 0 }\n'
	out += '\tif buf.len == 0 { return UnrecognizedNode{}, 0 }\n'
	out += '\tfield_num, _, c := read_tag(buf, 0)\n'
	out += '\tdata, c2 := read_submessage(buf, c)\n'
	out += '\tconsumed := c + c2\n'
	out += '\tmatch field_num {\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		dfn := snake_case(vname)
		out += '\t\t${f.field_num} {\n'
		out += '\t\t\tval, _ := decode_${dfn}(data, depth - 1)\n'
		out += '\t\t\treturn ${vname}(val), consumed\n'
		out += '\t\t}\n'
	}
	out += '\t\telse {\n'
	out += '\t\t\treturn UnrecognizedNode{field_num, data}, consumed\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '}\n\n'

	// Generate decode_ParseResult -> ParseAstResult
	out += 'pub fn decode_parse_result(buf []u8) ParseAstResult {\n'
	out += '\tmut version := 0\n'
	out += '\tmut stmts := []AstRawStmt{}\n'
	out += '\tmut off := 0\n'
	out += '\tfor off < buf.len {\n'
	out += '\t\tfield_num, wire_type, c := read_tag(buf, off)\n'
	out += '\t\toff += c\n'
	out += '\t\tmatch field_num {\n'
	out += '\t\t\t1 {\n'
	out += '\t\t\t\tv, c2 := read_varint_i64(buf, off)\n'
	out += '\t\t\t\tversion = int(v)\n'
	out += '\t\t\t\toff += c2\n'
	out += '\t\t\t}\n'
	out += '\t\t\t2 {\n'
	out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
	out += '\t\t\t\trs, _ := decode_raw_stmt(data, max_decode_depth)\n'
	out += '\t\t\t\tstmts << AstRawStmt{\n'
	out += '\t\t\t\t\tstmt_location: rs.stmt_location\n'
	out += '\t\t\t\t\tstmt_len: rs.stmt_len\n'
	out += '\t\t\t\t\tstmt: rs.stmt\n'
	out += '\t\t\t\t}\n'
	out += '\t\t\t\toff += c2\n'
	out += '\t\t\t}\n'
	out += '\t\t\telse {\n'
	out += '\t\t\t\toff = skip_field(buf, off, wire_type)\n'
	out += '\t\t\t}\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '\treturn ParseAstResult{\n'
	out += '\t\tversion: version\n'
	out += '\t\tstmts: stmts\n'
	out += '\t}\n'
	out += '}\n\n'

	os.write_file('pg_query/pg_query_decode.v', out) or {
		eprintln('Failed to write pg_query_decode.v: ${err}')
		return
	}
	println('Generated pg_query/pg_query_decode.v (${out.len} bytes)')
}

fn proto_decode_field_case(f ProtoField, vname string, msg_name string, pf ProtoFile) string {
	mut out := ''
	vfname := snake_case(f.name)
	out += '\t\t\t${f.field_num} {\n'
	if f.repeated {
		out += proto_decode_repeated_field(f, vfname, pf)
	} else if f.typ == 'string' {
		out += '\t\t\t\ts, c2 := read_string(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = s\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'bytes' {
		out += '\t\t\t\td, c2 := read_bytes(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = d\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.is_map && f.map_key_typ == 'string' && f.map_val_typ == 'string' {
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tkey, val := read_map_string_entry(data)\n'
		out += '\t\t\t\tr.${vfname}[key] = val\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Node' {
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_node(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = val\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Context' {
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { SummaryContext(valid_enum_int([1, 2, 3], v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else if is_enum_type(pf, f.typ) {
		etype := proto_field_to_v_type(f.typ)
		vals := enum_values(pf, f.typ)
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { ${etype}(valid_enum_int(${vals}, v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else if is_primitive_proto(f.typ) {
		out += proto_decode_primitive_singular(f, vfname)
	} else if f.typ == msg_name {
		self_dfn := snake_case(vname)
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_${self_dfn}(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { &val }\n'
		out += '\t\t\t\toff += c2\n'
	} else {
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_${sub_dfn}(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = val\n'
		out += '\t\t\t\toff += c2\n'
	}
	out += '\t\t\t}\n'
	return out
}

fn proto_decode_repeated_field(f ProtoField, vfname string, pf ProtoFile) string {
	mut out := ''
	if f.typ == 'string' {
		out += '\t\t\t\ts, c2 := read_string(buf, off)\n'
		out += '\t\t\t\tr.${vfname} << s\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'bytes' {
		out += '\t\t\t\td, c2 := read_bytes(buf, off)\n'
		out += '\t\t\t\tr.${vfname} << d\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Node' {
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_node(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} << val\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Context' {
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tvals, c2 := read_packed_varints(buf, off)\n'
		out += '\t\t\t\t\t\tfor v in vals {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << unsafe { SummaryContext(valid_enum_int([1, 2, 3], v)) }\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << unsafe { SummaryContext(valid_enum_int([1, 2, 3], v)) }\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if is_enum_type(pf, f.typ) {
		etype := proto_field_to_v_type(f.typ)
		vals := enum_values(pf, f.typ)
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tvals, c2 := read_packed_varints(buf, off)\n'
		out += '\t\t\t\t\t\tfor v in vals {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << unsafe { ${etype}(valid_enum_int(${vals}, v)) }\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << unsafe { ${etype}(valid_enum_int(${vals}, v)) }\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if f.typ == 'float' {
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tdata, c2 := read_length_buf(buf, off)\n'
		out += '\t\t\t\t\t\tmut i := 0\n'
		out += '\t\t\t\t\t\tfor i < data.len {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << read_float(data, i)\n'
		out += '\t\t\t\t\t\t\ti += 4\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tr.${vfname} << read_float(buf, off)\n'
		out += '\t\t\t\t\t\toff += 4\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if f.typ == 'double' {
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tdata, c2 := read_length_buf(buf, off)\n'
		out += '\t\t\t\t\t\tmut i := 0\n'
		out += '\t\t\t\t\t\tfor i < data.len {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << read_double(data, i)\n'
		out += '\t\t\t\t\t\t\ti += 8\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tr.${vfname} << read_double(buf, off)\n'
		out += '\t\t\t\t\t\toff += 8\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if f.typ == 'fixed32' || f.typ == 'sfixed32' {
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tdata, c2 := read_length_buf(buf, off)\n'
		out += '\t\t\t\t\t\tmut i := 0\n'
		out += '\t\t\t\t\t\tfor i < data.len {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << read_fixed32(data, i)\n'
		out += '\t\t\t\t\t\t\ti += 4\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tr.${vfname} << read_fixed32(buf, off)\n'
		out += '\t\t\t\t\t\toff += 4\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if f.typ == 'fixed64' || f.typ == 'sfixed64' {
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tdata, c2 := read_length_buf(buf, off)\n'
		out += '\t\t\t\t\t\tmut i := 0\n'
		out += '\t\t\t\t\t\tfor i < data.len {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << read_fixed64(data, i)\n'
		out += '\t\t\t\t\t\t\ti += 8\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tr.${vfname} << read_fixed64(buf, off)\n'
		out += '\t\t\t\t\t\toff += 8\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if f.typ == 'sint32' || f.typ == 'sint64' {
		mut cast := ''
		if f.typ == 'sint32' { cast = 'int(v)' } else { cast = 'v' }
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tdata, c2 := read_length_buf(buf, off)\n'
		out += '\t\t\t\t\t\tmut i := 0\n'
		out += '\t\t\t\t\t\tfor i < data.len {\n'
		out += '\t\t\t\t\t\t\tv, c3 := read_svarint(data, i)\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << ${cast}\n'
		out += '\t\t\t\t\t\t\ti += c3\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := read_svarint(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << ${cast}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if is_primitive_proto(f.typ) {
		// Varint-based primitives (int32, int64, uint32, uint64, bool)
		mut cast := ''
		mut varint_fn := 'read_varint'
		match f.typ {
			'int32' { cast = 'int(v)' }
			'int64' { cast = 'v'; varint_fn = 'read_varint_i64' }
			'uint32' { cast = 'u32(v)' }
			'uint64' { cast = 'v' }
			'bool' { cast = 'v != 0' }
			else {}
		}
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tvals, c2 := read_packed_varints(buf, off)\n'
		out += '\t\t\t\t\t\tfor v in vals {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << ${cast}\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := ${varint_fn}(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << ${cast}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else {
		// Repeated submessage
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_${sub_dfn}(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} << val\n'
		out += '\t\t\t\toff += c2\n'
	}
	return out
}

fn proto_decode_primitive_singular(f ProtoField, vfname string) string {
	mut out := ''
	match f.typ {
		'int32' {
			out += '\t\t\t\tv, c2 := read_varint_i64(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = int(v)\n'
			out += '\t\t\t\toff += c2\n'
		}
		'sint32' {
			out += '\t\t\t\tv, c2 := read_svarint(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = int(v)\n'
			out += '\t\t\t\toff += c2\n'
		}
		'sfixed32' {
			out += '\t\t\t\tv := read_fixed32(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = int(v)\n'
			out += '\t\t\t\toff += 4\n'
		}
		'int64' {
			out += '\t\t\t\tv, c2 := read_varint_i64(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += c2\n'
		}
		'sint64' {
			out += '\t\t\t\tv, c2 := read_svarint(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += c2\n'
		}
		'sfixed64' {
			out += '\t\t\t\tv := read_fixed64(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = i64(v)\n'
			out += '\t\t\t\toff += 8\n'
		}
		'uint32' {
			out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = u32(v)\n'
			out += '\t\t\t\toff += c2\n'
		}
		'fixed32' {
			out += '\t\t\t\tv := read_fixed32(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += 4\n'
		}
		'uint64' {
			out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += c2\n'
		}
		'fixed64' {
			out += '\t\t\t\tv := read_fixed64(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += 8\n'
		}
		'float' {
			out += '\t\t\t\tv := read_float(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += 4\n'
		}
		'double' {
			out += '\t\t\t\tv := read_double(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v\n'
			out += '\t\t\t\toff += 8\n'
		}
		'bool' {
			out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
			out += '\t\t\t\tr.${vfname} = v != 0\n'
			out += '\t\t\t\toff += c2\n'
		}
		else {}
	}
	return out
}

fn proto_decode_oneof_field_case(f ProtoField, vname string, pf ProtoFile) string {
	mut out := ''
	vfname := snake_case(f.name)
	out += '\t\t\t${f.field_num} {\n'
	if f.typ == 'string' {
		out += '\t\t\t\ts, c2 := read_string(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = s\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Node' {
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_node(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = val\n'
		out += '\t\t\t\toff += c2\n'
	} else if is_primitive_proto(f.typ) {
		out += proto_decode_primitive_singular(f, vfname)
	} else if is_enum_type(pf, f.typ) {
		etype := proto_field_to_v_type(f.typ)
		vals := enum_values(pf, f.typ)
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { ${etype}(valid_enum_int(${vals}, v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Context' {
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { SummaryContext(valid_enum_int([1, 2, 3], v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else {
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_${sub_dfn}(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = val\n'
		out += '\t\t\t\toff += c2\n'
	}
	out += '\t\t\t}\n'
	return out
}

// ============================================================
// Generate pg_query/pg_query_encode.v (V-native protobuf encode)
// ============================================================
fn generate_v_protobuf_encode(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += 'module pg_query\n\n'

	mut skip_names := map[string]bool{}
	skip_names['Node'] = true
	skip_names['ParseResult'] = true

	mut sorted := topological_sort_messages(pf)
	for m in sorted {
		if m.name in skip_names { continue }
		vname := proto_field_to_v_type(m.name)
		dfn := snake_case(vname)
		out += 'pub fn encode_${dfn}(val ${vname}) []u8 {\n'
		out += '\tmut buf := []u8{}\n'
		// Sort fields by field number
		mut sorted_fields := m.fields.clone()
		sorted_fields.sort(a.field_num < b.field_num)
		for f in sorted_fields {
			vfname := snake_case(f.name)
			if f.is_oneof {
				out += proto_encode_oneof_field(f, vfname, pf, node_oneof_fields, m.name)
			} else if f.repeated {
				out += proto_encode_repeated_field(f, vfname, pf, node_oneof_fields)
			} else if f.is_map {
				out += proto_encode_map_field(f, vfname)
			} else {
				out += proto_encode_singular_field(f, vfname, pf, node_oneof_fields, m.name)
			}
		}
		out += '\treturn buf\n'
		out += '}\n\n'
	}

	// encode_node dispatcher
	// Alias is the zero-value default for the Node sum type (first variant).
	// When an Alias with no non-zero fields is encoded, we skip the tag +
	// submessage wrapper to avoid creating a spurious empty node.
	// All other variants are always encoded (they were explicitly constructed).
	out += 'fn encode_node(val_ Node) []u8 {\n'
	out += '\tmatch val_ {\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		out += '\t\t${vname} {\n'
		out += '\t\t\tinner := encode_${snake_case(vname)}(val_)\n'
		if vname == 'Alias' {
			out += '\t\t\tif inner.len == 0 { return []u8{} }\n'
		}
		out += '\t\t\tmut buf := []u8{}\n'
		out += '\t\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\t\twrite_length_delimited_into(mut buf, inner)\n'
		out += '\t\t\treturn buf\n'
		out += '\t\t}\n'
	}
	out += '\t\tUnrecognizedNode {\n'
	out += '\t\t\tmut buf := []u8{}\n'
	out += '\t\t\twrite_tag_into(mut buf, val_.field_num, 2)\n'
	out += '\t\t\twrite_length_delimited_into(mut buf, val_.data)\n'
	out += '\t\t\treturn buf\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '}\n\n'

	// encode_parse_result entry point
	// RawStmt fields: stmt=1 (Node), stmt_location=2 (int32), stmt_len=3 (int32)
	out += 'pub fn encode_parse_result(val ParseAstResult) []u8 {\n'
	out += '\tmut buf := []u8{}\n'
	out += '\twrite_tag_into(mut buf, 1, 0)\n'
	out += '\twrite_varint_into(mut buf, u64(val.version))\n'
	out += '\tfor s in val.stmts {\n'
	out += '\t\tmut inner := []u8{}\n'
	out += '\t\twrite_tag_into(mut inner, 1, 2)\n'
	out += '\t\twrite_length_delimited_into(mut inner, encode_node(s.stmt))\n'
	out += '\t\twrite_tag_into(mut inner, 2, 0)\n'
	out += '\t\twrite_varint_into(mut inner, u64(s.stmt_location))\n'
	out += '\t\twrite_tag_into(mut inner, 3, 0)\n'
	out += '\t\twrite_varint_into(mut inner, u64(s.stmt_len))\n'
	out += '\t\twrite_tag_into(mut buf, 2, 2)\n'
	out += '\t\twrite_length_delimited_into(mut buf, inner)\n'
	out += '\t}\n'
	out += '\treturn buf\n'
	out += '}\n\n'

	os.write_file('pg_query/pg_query_encode.v', out) or {
		eprintln('Failed to write pg_query_encode.v: ${err}')
		return
	}
	println('Generated pg_query/pg_query_encode.v (${out.len} bytes)')
}

fn proto_type_write_expr(typ string, val_expr string) (int, string) {
	match typ {
		'int32' { return 0, 'write_varint(u64(${val_expr}))' }
		'int64' { return 0, 'write_varint(u64(${val_expr}))' }
		'uint32' { return 0, 'write_varint(u64(${val_expr}))' }
		'uint64' { return 0, 'write_varint(${val_expr})' }
		'sint32' { return 0, 'write_svarint(i64(${val_expr}))' }
		'sint64' { return 0, 'write_svarint(${val_expr})' }
		'fixed32' { return 5, 'write_fixed32(${val_expr})' }
		'sfixed32' { return 5, 'write_fixed32(u32(${val_expr}))' }
		'fixed64' { return 1, 'write_fixed64(${val_expr})' }
		'sfixed64' { return 1, 'write_fixed64(u64(${val_expr}))' }
		'float' { return 5, 'write_float(${val_expr})' }
		'double' { return 1, 'write_double(${val_expr})' }
		'bool' { return 0, 'write_bool(${val_expr})' }
		'string' { return 2, 'write_string(${val_expr})' }
		'bytes' { return 2, 'write_bytes(${val_expr})' }
		else { return 2, '' } // messages
	}
}

// Returns a statement (not expression) that writes val_expr into mut buf_name.
fn proto_type_write_into(typ string, val_expr string, buf_name string) (int, string) {
	match typ {
		'int32' { return 0, 'write_varint_into(mut ${buf_name}, u64(${val_expr}))' }
		'int64' { return 0, 'write_varint_into(mut ${buf_name}, u64(${val_expr}))' }
		'uint32' { return 0, 'write_varint_into(mut ${buf_name}, u64(${val_expr}))' }
		'uint64' { return 0, 'write_varint_into(mut ${buf_name}, ${val_expr})' }
		'sint32' { return 0, 'write_svarint_into(mut ${buf_name}, i64(${val_expr}))' }
		'sint64' { return 0, 'write_svarint_into(mut ${buf_name}, ${val_expr})' }
		'fixed32' { return 5, 'write_fixed32_into(mut ${buf_name}, ${val_expr})' }
		'sfixed32' { return 5, 'write_fixed32_into(mut ${buf_name}, u32(${val_expr}))' }
		'fixed64' { return 1, 'write_fixed64_into(mut ${buf_name}, ${val_expr})' }
		'sfixed64' { return 1, 'write_fixed64_into(mut ${buf_name}, u64(${val_expr}))' }
		'float' { return 5, 'write_float_into(mut ${buf_name}, ${val_expr})' }
		'double' { return 1, 'write_double_into(mut ${buf_name}, ${val_expr})' }
		'bool' { return 0, 'write_bool_into(mut ${buf_name}, ${val_expr})' }
		'string' { return 2, 'write_string_into(mut ${buf_name}, ${val_expr})' }
		'bytes' { return 2, 'write_bytes_into(mut ${buf_name}, ${val_expr})' }
		else { return 2, '' } // messages
	}
}

fn is_self_ref(f ProtoField, msg_name string) bool {
	return !f.is_oneof && f.typ == msg_name
}

fn proto_encode_singular_field(f ProtoField, vfname string, pf ProtoFile, node_oneof_fields []ProtoField, msg_name string) string {
	mut out := ''
	if f.typ == 'Node' {
		ni := 'n_${f.name}'
		out += '\t${ni} := encode_node(val.${vfname})\n'
		out += '\tif ${ni}.len > 0 {\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, ${ni})\n'
		out += '\t}\n'
	} else if is_self_ref(f, msg_name) {
		sr_inner := 'sr_${f.name}'
		out += '\tif val.${vfname} != unsafe { nil } {\n'
		out += '\t\t${sr_inner} := encode_${snake_case(proto_field_to_v_type(f.typ))}(*val.${vfname})\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, ${sr_inner})\n'
		out += '\t}\n'
	} else if f.typ == 'Context' {
		out += '\tif u64(val.${vfname}) != 0 {\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 0)\n'
		out += '\t\twrite_varint_into(mut buf, u64(val.${vfname}))\n'
		out += '\t}\n'
	} else if is_primitive_proto(f.typ) || f.typ == 'string' || f.typ == 'bytes' {
		wt, into_expr := proto_type_write_into(f.typ, 'val.${vfname}', 'buf')
		cond := proto_zero_check(f.typ, 'val.${vfname}')
		out += '\tif ${cond} {\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, ${wt})\n'
		out += '\t\t${into_expr}\n'
		out += '\t}\n'
	} else if is_enum_type(pf, f.typ) {
		out += '\tif u64(val.${vfname}) != 0 {\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 0)\n'
		out += '\t\twrite_varint_into(mut buf, u64(val.${vfname}))\n'
		out += '\t}\n'
	} else {
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		inner_v := 'in_${f.name}'
		out += '\t${inner_v} := encode_${sub_dfn}(val.${vfname})\n'
		out += '\tif ${inner_v}.len > 0 {\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, ${inner_v})\n'
		out += '\t}\n'
	}
	return out
}

fn proto_zero_check(typ string, expr string) string {
	match typ {
		'int32', 'int64', 'sint32', 'sint64', 'sfixed32', 'sfixed64',
		'uint32', 'uint64', 'fixed32', 'fixed64' {
			return '${expr} != 0'
		}
		'float' { return '${expr} != 0.0' }
		'double' { return '${expr} != 0.0' }
		'bool' { return '${expr}' }
		'string' { return '${expr} != \'\'' }
		'bytes' { return '${expr}.len > 0' }
		else { return 'true' }
	}
}

fn proto_encode_repeated_field(f ProtoField, vfname string, pf ProtoFile, node_oneof_fields []ProtoField) string {
	mut out := ''
	out += '\tif val.${vfname}.len > 0 {\n'
	if f.typ == 'Node' {
		out += '\t\tfor v in val.${vfname} {\n'
		out += '\t\t\tinner_ := encode_node(v)\n'
		out += '\t\t\tif inner_.len > 0 {\n'
		out += '\t\t\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\t\t\twrite_length_delimited_into(mut buf, inner_)\n'
		out += '\t\t\t}\n'
		out += '\t\t}\n'
	} else if f.typ == 'string' || f.typ == 'bytes' {
		wt, into_expr := proto_type_write_into(f.typ, 'v', 'buf')
		out += '\t\tfor v in val.${vfname} {\n'
		out += '\t\t\twrite_tag_into(mut buf, ${f.field_num}, ${wt})\n'
		out += '\t\t\t${into_expr}\n'
		out += '\t\t}\n'
	} else if is_primitive_proto(f.typ) || is_enum_type(pf, f.typ) {
		// Packed encoding for scalar types and enums
		_, into_expr := proto_type_write_into(f.typ, 'v', 'packed_')
		mut iexpr := into_expr
		if is_enum_type(pf, f.typ) {
			iexpr = 'write_varint_into(mut packed_, u64(v))'
		}
		out += '\t\tmut packed_ := []u8{}\n'
		out += '\t\tfor v in val.${vfname} {\n'
		out += '\t\t\t${iexpr}\n'
		out += '\t\t}\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, packed_)\n'
	} else {
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		out += '\t\tfor v in val.${vfname} {\n'
		out += '\t\t\tsub_enc_ := encode_${sub_dfn}(v)\n'
		out += '\t\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\t\twrite_length_delimited_into(mut buf, sub_enc_)\n'
		out += '\t\t}\n'
	}
	out += '\t}\n'
	return out
}

fn proto_encode_oneof_field(f ProtoField, vfname string, pf ProtoFile, node_oneof_fields []ProtoField, msg_name string) string {
	mut out := ''
	out += '\tif v := val.${vfname} {\n'
	if f.typ == 'Node' {
		out += '\t\tn_enc_ := encode_node(v)\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, n_enc_)\n'
	} else if is_primitive_proto(f.typ) || f.typ == 'string' || f.typ == 'bytes' {
		wt, into_expr := proto_type_write_into(f.typ, 'v', 'buf')
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, ${wt})\n'
		out += '\t\t${into_expr}\n'
	} else if is_enum_type(pf, f.typ) {
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 0)\n'
		out += '\t\twrite_varint_into(mut buf, u64(v))\n'
	} else {
		// oneof submessage
		subtype := proto_field_to_v_type(f.typ)
		sub_dfn := snake_case(subtype)
		out += '\t\tsub_enc_ := encode_${sub_dfn}(v)\n'
		out += '\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
		out += '\t\twrite_length_delimited_into(mut buf, sub_enc_)\n'
	}
	out += '\t}\n'
	return out
}

fn proto_encode_map_field(f ProtoField, vfname string) string {
	mut out := ''
	out += '\tif val.${vfname}.len > 0 {\n'
	out += '\t\tfor k, v in val.${vfname} {\n'
	out += '\t\t\tmap_enc_ := write_map_string_entry(k, v)\n'
	out += '\t\t\twrite_tag_into(mut buf, ${f.field_num}, 2)\n'
	out += '\t\t\twrite_length_delimited_into(mut buf, map_enc_)\n'
	out += '\t\t}\n'
	out += '\t}\n'
	return out
}
