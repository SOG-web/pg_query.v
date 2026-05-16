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

fn parse_proto(text string) ProtoFile {
	mut pf := ProtoFile{}
	lines := text.split('\n')
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		if line == '' || line.starts_with('//') || line.starts_with('/*') {
			i++
			continue
		}
		if line.starts_with('syntax ') || line.starts_with('package ') || line.starts_with('import ') {
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
				if cline.starts_with('enum ') {
					enum_parts := cline.split(' ')
					if enum_parts.len >= 2 {
						ename := enum_parts[1].trim_right(' {')
						mut en := ProtoEnum{name: ename}
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
					mut depth := 1
					i++
					for i < lines.len {
						tline := lines[i].trim_space()
						if tline == '{' { depth++ }
						if tline == '}' { depth--; if depth == 0 { break } }
						i++
					}
					i++
					continue
				}
				if in_oneof {
				if cline.contains('=') && !cline.starts_with('//') {
						eq_parts := cline.split('=')
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
					eq_parts := cline.split('=')
					if eq_parts.len < 2 { i++; continue }
					decl := eq_parts[0].trim_space()
					mut repeated := false
					mut ftype := ''
					mut fname := ''
					if decl.starts_with('repeated ') {
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
					msg.fields << ProtoField{
						name: fname
						typ: ftype
						field_num: fnum
						repeated: repeated
						json_name: jn
						is_oneof: false
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

fn c_safe_name(name string) string {
	if name == 'float' { return '_float' }
	return name
}

fn proto_c_field_name(name string) string {
	// protobuf-c renames C reserved keywords by appending '_'
	if name == 'float' { return 'float_' }
	return name
}

fn proto_v_param_name(name string) string {
	match name {
		'atomic' { return 'atomic_' }
		else { return name }
	}
}

fn is_enum_type(pf ProtoFile, type_name string) bool {
	for e in pf.enums {
		if e.name == type_name { return true }
	}
	return false
}

// Convert proto type name to C prototype name (PgQuery__Xxx)
// Convert proto message name to protobuf-c __init function suffix (snake_case)
// Matches protobuf-c's naming: insert '_' only at lowercase→uppercase transitions
// Examples:
//   "A_Const"       → "a__const"
//   "PLAssignStmt"  → "plassign_stmt"
//   "AlterTSDictionaryStmt" → "alter_tsdictionary_stmt"
fn proto_to_c_init_suffix(name string) string {
	segments := name.split('_')
	mut result := ''
	for si, segment in segments {
		if si > 0 { result += '__' }
		mut seg_out := ''
		for i, c in segment {
			if c >= u8(`A`) && c <= u8(`Z`) {
				if i > 0 {
					prev := segment[i - 1]
					if prev >= u8(`a`) && prev <= u8(`z`) {
						seg_out += '_'
					}
				}
				seg_out += (c + 32).ascii_str()
			} else {
				seg_out += c.ascii_str()
			}
		}
		result += seg_out
	}
	return result
}

fn proto_to_c_prototype(proto_name string) string {
	parts := proto_name.split('_')
	mut out := 'PgQuery__'
	for p in parts {
		out += p[0..1].to_upper() + p[1..]
	}
	return out
}

// Convert proto type to C field type (for V-compatible structs)
fn c_vtype_for_proto(ptype string, msg_name string, pf ProtoFile) string {
	match ptype {
		'int32', 'sint32', 'sfixed32' { return 'int' }
		'int64', 'sint64', 'sfixed64' { return 'int64_t' }
		'uint32', 'fixed32' { return 'uint32_t' }
		'uint64', 'fixed64' { return 'uint64_t' }
		'float' { return 'float' }
		'double' { return 'double' }
		'bool' { return 'int' }
		'string' { return 'VString' }
		'bytes' { return 'VArray' }
		'Node' { return 'VNode' }
		'Context' { return 'int' }
		else {
			if is_enum_type(pf, ptype) { return 'int' }
			vname := proto_field_to_v_type(ptype)
			if ptype == msg_name {
				return 'struct V_${vname}*'
			}
			return 'V_${vname}'
		}
	}
}

// Build V-compatible C struct name for a proto message
fn v_c_struct_name(proto_name string) string {
	vname := proto_field_to_v_type(proto_name)
	return 'V_${vname}'
}

fn proto_to_v_option_field_name(f ProtoField) string {
	// V's oneof field name in the struct
	return snake_case(f.name)
}

// ============================================================
// generate_code: main entry point
// ============================================================

fn generate_code(pf ProtoFile) {
	// Find Node oneof fields
	mut node_oneof_fields := []ProtoField{}
	mut aconst_oneof_fields := []ProtoField{}
	for m in pf.messages {
		if m.name == 'Node' {
			for f in m.fields {
				if f.is_oneof {
					node_oneof_fields << f
				}
			}
		}
		if m.name == 'A_Const' {
			for f in m.fields {
				if f.is_oneof {
					aconst_oneof_fields << f
				}
			}
		}
	}

	generate_v_ast(pf, node_oneof_fields)
	generate_c_header(pf, node_oneof_fields)
	generate_c_bridge(pf, node_oneof_fields)
	generate_v_pluck(pf, node_oneof_fields)
	generate_reverse_bridge(pf, node_oneof_fields)
	generate_c_builders(pf, node_oneof_fields)
	generate_v_serialize(pf, node_oneof_fields)
	generate_v_protobuf_decode(pf, node_oneof_fields)
	println('All files generated successfully.')
}

// ============================================================
// Generate pg_query/pg_query_ast.v (V struct definitions)
// ============================================================

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
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
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
		out += '}\n\n'
	}

	// Generate UnrecognizedNode (for unknown oneof variants)
	out += '// UnrecognizedNode holds raw data for an unknown Node variant.\n'
	out += '// This is returned by the protobuf decoder when the field number\n'
	out += '// does not match any known Node oneof branch.\n'
	out += 'pub struct UnrecognizedNode {\n'
	out += '\tfield_num int\n'
	out += '\tdata []u8\n'
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
	out += 'fn decode_node_json(jn JsonNode) !Node {\n'
	for f in node_oneof_fields {
		vfname := snake_case(f.name)
		out += '\tif n := jn.${vfname} {\n'
		out += '\t\treturn n\n'
		out += '\t}\n'
	}
	out += '\treturn error("unknown node type")\n'
	out += '}\n\n'

	// Generate AstRawStmt and ParseAstResult
	out += '// AstRawStmt is a typed version of RawStmt with a decoded Node tree.\n'
	out += 'pub struct AstRawStmt {\n'
	out += 'pub:\n'
	out += '\tstmt_location i64 @[json: \'stmtLocation\']\n'
	out += '\tstmt_len i64 @[json: \'stmtLen\']\n'
	out += '\tstmt Node @[json: \'stmt\']\n'
	out += '}\n\n'

	out += '// ParseAstResult is the typed AST equivalent of ParseResult.\n'
	out += 'pub struct ParseAstResult {\n'
	out += 'pub:\n'
	out += '\tversion int\n'
	out += '\tstmts []AstRawStmt @[json: \'stmts\']\n'
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
	out += 'pub fn parse_ast(input_sql string) !ParseAstResult {\n'
	out += '\tres := parse(input_sql) or { return err }\n'
	out += '\tjson_res := json.decode(JsonParseResult, res.parse_tree) or { return err }\n'
	out += '\tmut stmts := []AstRawStmt{}\n'
	out += '\tfor s in json_res.stmts {\n'
	out += '\t\tstmts << AstRawStmt{\n'
	out += '\t\t\tstmt_location: s.stmt_location\n'
	out += '\t\t\tstmt_len: s.stmt_len\n'
		out += '\t\t\tstmt: decode_node_json(s.stmt)!\n'
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
	skip_names['ScanResult'] = true
	skip_names['SummaryResult'] = true

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
		println('WARNING: topological sort incomplete (${sorted.len}/${msgs.len}), cycle detected')
		// Append remaining
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
// Generate pg_query/pg_query_ast_c.h (C header with V-compatible structs)
// ============================================================

fn generate_c_header(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += '#ifndef PG_QUERY_AST_C_H\n'
	out += '#define PG_QUERY_AST_C_H\n\n'
	out += '#include <stdint.h>\n'
	out += '#include <stddef.h>\n\n'

	// V ABI types
	out += '// V ABI compatible types for direct struct population\n'
	out += 'typedef struct { unsigned char* str; int len; int is_lit; } VString;\n'
	out += 'typedef struct { void* data; int offset; int len; int cap; int flags; int element_size; } VArray;\n\n'

	// Forward declarations
	out += '// Forward declarations\n'
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		vname := proto_field_to_v_type(m.name)
		out += 'typedef struct V_${vname} V_${vname};\n'
	}
	out += 'typedef struct VNode VNode;\n'
	out += 'typedef struct V_ParseAstResult V_ParseAstResult;\n\n'

	// VNode tagged union (matches V sum type layout)
	out += '// VNode tagged union (matches V sum type layout)\n'
	out += '// Tags matching V sum type tag order\n'
	mut tag_idx := 0
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		out += '#define VNODE_TAG_${vname.to_upper()} ${tag_idx}\n'
		tag_idx++
	}
	out += '\n'
	out += 'struct VNode {\n'
	out += '\tuint32_t _typ;\n'
	out += '\tunion {\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		out += '\t\tV_${vname}* ${c_safe_name(snake_case(f.name))};\n'
	}
	out += '\t};\n'
	out += '};\n\n'

	// Struct definitions in dependency order
	mut sorted := topological_sort_messages(pf)
	for m in sorted {
		vname := proto_field_to_v_type(m.name)
		out += 'struct V_${vname} {\n'
		for f in m.fields {
			if f.is_oneof { continue }
			ctype := c_vtype_for_proto(f.typ, m.name, pf)
			is_recursive := f.typ == m.name
			mut field_ctype := ctype
			if is_recursive {
				field_ctype = 'struct V_${vname}*'
			}
			if f.repeated {
				field_ctype = 'VArray'
			}
			vfname := c_safe_name(snake_case(f.name))
			out += '\t${field_ctype} ${vfname};\n'
		}
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					ctype := c_vtype_for_proto(f.typ, m.name, pf)
					vfname := c_safe_name(snake_case(f.name))
					out += '\tint ${vfname}_state;\n'
					out += '\t${ctype} ${vfname}_data;\n'
				}
			}
		}
		out += '};\n\n'
	}

	// V_ParseAstResult (skipped in the loop, defined here)
	out += 'struct V_ParseAstResult {\n'
	out += '\tint version;\n'
	out += '\tVArray stmts;\n'
	out += '};\n\n'

	out += '#endif /* PG_QUERY_AST_C_H */\n'

	os.write_file('pg_query/pg_query_ast_c.h', out) or {
		eprintln('Failed to write pg_query_ast_c.h: ${err}')
		return
	}
	println('Generated pg_query/pg_query_ast_c.h (${out.len} bytes)')
}

// ============================================================
// Generate pg_query/protobuf_bridge.c (C bridge converter functions)
// ============================================================

fn generate_c_bridge(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += '#include <stdlib.h>\n'
	out += '#include <string.h>\n'
	out += '#include <stdio.h>\n'
	out += '#include "pg_query.h"\n'
	out += '#include "protobuf/pg_query.pb-c.h"\n'
	out += '#include "pg_query_ast_c.h"\n\n'

	out += '// --- Forward declarations for all converter functions ---\n'
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		vname := proto_field_to_v_type(m.name)
		cproto := proto_to_c_prototype(m.name)
		out += 'static V_${vname} convert_${vname}(${cproto} *msg);\n'
	}
	out += 'static VNode convert_Node(PgQuery__Node *msg);\n'
	out += 'static VNode convert_node_message(ProtobufCMessage *msg);\n\n'

	// Generate converter for each message type
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		vname := proto_field_to_v_type(m.name)
		cproto := proto_to_c_prototype(m.name)

		out += 'static V_${vname} convert_${vname}(${cproto} *msg) {\n'
		out += '\tV_${vname} r;\n'
		out += '\tmemset(&r, 0, sizeof(r));\n'
		out += '\tif (!msg) return r;\n\n'

		// Non-oneof fields
		for f in m.fields {
			if f.is_oneof { continue }
			cfname := f.name
			vfname := c_safe_name(snake_case(f.name))

			if f.repeated {
				out = gen_c_convert_repeated_field(out, f, vname, cfname, vfname, pf, m.name)
			} else {
				out = gen_c_convert_singular_field(out, f, vname, cfname, vfname, pf, m.name)
			}
		}

		// Oneof fields
		mut has_oneof := false
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					has_oneof = true
					// Default all oneof fields to none (state=2)
					vfname := c_safe_name(snake_case(f.name))
					out += '\tr.${vfname}_state = 2;\n'
				}
			}
		}
		if has_oneof {
			// Generate switch based on protobuf-c oneof case
			out += '\tswitch (msg->${m.oneofs[0]}_case) {\n'
			for of_name in m.oneofs {
				for f in m.fields {
					if f.is_oneof && f.oneof_group == of_name {
						vname_f := proto_field_to_v_type(f.typ)
						cfname := f.name
						vfname := c_safe_name(snake_case(f.name))

						// Build case constant: PG_QUERY__<MSG_PARTS_JOINED_WITH__>__<ONEOF>_<FIELD>
						mut case_const := 'PG_QUERY__'
						parts2 := m.name.split('_')
						for i2, p2 in parts2 {
							if i2 > 0 { case_const += '__' }
							case_const += p2.to_upper()
						}
						case_const += '__'
						case_const += of_name.to_upper()
						case_const += '_'
						parts3 := f.name.split('_')
						for i3, p3 in parts3 {
							if i3 > 0 { case_const += '_' }
							case_const += p3.to_upper()
						}

						out += '\t\tcase ${case_const}:\n'
						out += '\t\t\tr.${vfname}_state = 0;\n'
						// Handle the data conversion
						if f.typ == 'Node' {
							out += '\t\t\tr.${vfname}_data = convert_Node(msg->${cfname});\n'
						} else if is_primitive_proto(f.typ) || is_enum_type(pf, f.typ) || f.typ == 'Context' {
							out = gen_c_convert_scalar(out, f, 'r.${vfname}_data', 'msg->${cfname}', pf)
						} else {
							out += '\t\t\tr.${vfname}_data = convert_${vname_f}(msg->${cfname});\n'
						}
						out += '\t\t\tbreak;\n'
					}
				}
			}
			out += '\t\tdefault:\n'
			out += '\t\t\tbreak;\n'
			out += '\t}\n'
		}

		out += '\treturn r;\n'
		out += '}\n\n'
	}

	// Generate convert_Node dispatcher
	out += '// --- Node dispatcher ---\n\n'
	out += 'static VNode convert_Node(PgQuery__Node *msg) {\n'
	out += '\tVNode r;\n'
	out += '\tmemset(&r, 0, sizeof(r));\n'
	out += '\tif (!msg) { r._typ = UINT32_MAX; return r; }\n'
	out += '\tswitch (msg->node_case) {\n'
	for tag_idx, f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		case_name := 'PG_QUERY__NODE__NODE_' + f.name.to_upper()
		out += '\t\tcase ${case_name}:\n'
		out += '\t\t\tr._typ = ${tag_idx};\n'
		out += '\t\t\tV_${vname}* _tmp_${tag_idx} = malloc(sizeof(V_${vname}));\n'
		out += '\t\t\t*_tmp_${tag_idx} = convert_${vname}(msg->${proto_c_field_name(f.name)});\n'
		out += '\t\t\tr.${c_safe_name(snake_case(f.name))} = _tmp_${tag_idx};\n'
		out += '\t\t\tbreak;\n'
	}
	out += '\t\tdefault:\n'
	out += '\t\t\tbreak;\n'
	out += '\t}\n'
	out += '\treturn r;\n'
	out += '}\n\n'

	// Unused but keep for completeness
	out += 'static VNode convert_node_message(ProtobufCMessage *msg) {\n'
	out += '\tVNode r;\n'
	out += '\tmemset(&r, 0, sizeof(r));\n'
	out += '\tif (!msg) return r;\n'
	out += '\treturn convert_Node((PgQuery__Node *)msg);\n'
	out += '}\n\n'

	out += '// --- Helper accessor functions ---\n'
	out += '\n'
	out += 'int pg_query_varray_len(const void *va) { return ((const VArray*)va)->len; }\n'
	out += 'int pg_query_varray_element_size(const void *va) { return ((const VArray*)va)->element_size; }\n'
	out += 'const void* pg_query_varray_get(const void *va, int i) {\n'
	out += '    const VArray *a = (const VArray*)va;\n'
	out += '    return (const char*)a->data + i * a->element_size;\n'
	out += '}\n'
	out += '\n'
	out += 'const char* pg_query_vstring_str(const void *vs) { return (const char*)((const VString*)vs)->str; }\n'
	out += 'int pg_query_vstring_len(const void *vs) { return ((const VString*)vs)->len; }\n'
	out += '\n'
	out += 'int pg_query_vnode_tag(const void *vn) { return (int)((const VNode*)vn)->_typ; }\n'
	out += 'const void* pg_query_vnode_data(const void *vn) { return (const void*)((const char*)vn + sizeof(uint32_t)); }\n'
	out += '\n'
	out += 'int pg_query_raw_stmt_location(const void *rs) { return ((const V_RawStmt*)rs)->stmt_location; }\n'
	out += 'int pg_query_raw_stmt_len(const void *rs) { return ((const V_RawStmt*)rs)->stmt_len; }\n'
	out += 'const void* pg_query_raw_stmt_stmt(const void *rs) { return &((const V_RawStmt*)rs)->stmt; }\n'
	out += '\n'
	// VNode union member accessors for each Node variant
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		vfname := c_safe_name(snake_case(f.name))
		out += 'const void* pg_query_vnode_get_${vname}(const void *vn) { return (const void*)((const VNode*)vn)->${vfname}; }\n'
	}
	out += '\n'
	out += '// --- Top-level bridge function (heap-allocated result) ---\n'
	out += '\n'
	out += 'void* pg_query_bridge_parse_ast_direct(const char *input, int parser_options) {\n'
	out += '\tV_ParseAstResult *result = malloc(sizeof(V_ParseAstResult));\n'
	out += '\tmemset(result, 0, sizeof(*result));\n'
	out += '\tPgQueryProtobufParseResult res = pg_query_parse_protobuf_opts(input, parser_options);\n'
	out += '\tif (res.error) {\n'
	out += '\t\tpg_query_free_protobuf_parse_result(res);\n'
	out += '\t\treturn result;\n'
	out += '\t}\n'
	out += '\tPgQuery__ParseResult *parsed = pg_query__parse_result__unpack(NULL, res.parse_tree.len, (const uint8_t *)res.parse_tree.data);\n'
	out += '\tif (!parsed) {\n'
	out += '\t\tpg_query_free_protobuf_parse_result(res);\n'
	out += '\t\treturn result;\n'
	out += '\t}\n'
	out += '\tresult->version = parsed->version;\n'
	out += '\tresult->stmts.len = (int)parsed->n_stmts;\n'
	out += '\tresult->stmts.cap = (int)parsed->n_stmts;\n'
	out += '\tresult->stmts.element_size = (int)sizeof(V_RawStmt);\n'
	out += '\tif (parsed->n_stmts > 0) {\n'
	out += '\t\tresult->stmts.data = malloc(parsed->n_stmts * sizeof(V_RawStmt));\n'
	out += '\t\tfor (size_t i = 0; i < parsed->n_stmts; i++) {\n'
	out += '\t\t\tV_RawStmt *rs = &((V_RawStmt *)result->stmts.data)[i];\n'
	out += '\t\t\trs->stmt_location = parsed->stmts[i]->stmt_location;\n'
	out += '\t\t\trs->stmt_len = parsed->stmts[i]->stmt_len;\n'
	out += '\t\t\trs->stmt = convert_Node(parsed->stmts[i]->stmt);\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '\tpg_query__parse_result__free_unpacked(parsed, NULL);\n'
	out += '\tpg_query_free_protobuf_parse_result(res);\n'
	out += '\treturn result;\n'
	out += '}\n'
	out += '\n'
	out += 'void pg_query_bridge_free_ast_result(void *ptr) {\n'
	out += '\tif (!ptr) return;\n'
	out += '\tV_ParseAstResult *result = (V_ParseAstResult*)ptr;\n'
	out += '\tif (result->stmts.data) {\n'
	out += '\t\tfree(result->stmts.data);\n'
	out += '\t}\n'
	out += '\tfree(result);\n'
	out += '}\n'
	out += '\n'

	os.write_file('pg_query/protobuf_bridge.c', out) or {
		eprintln('Failed to write protobuf_bridge.c: ${err}')
		return
	}
	println('Generated pg_query/protobuf_bridge.c (${out.len} bytes)')

	// Generate header with accessor declarations
	mut hdr := ''
	hdr += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	hdr += '// DO NOT EDIT.\n'
	hdr += '#ifndef PROTOBUF_BRIDGE_H\n'
	hdr += '#define PROTOBUF_BRIDGE_H\n\n'
	hdr += '#include "pg_query.h"\n'
	hdr += '#include "pg_query_ast_c.h"\n\n'
	hdr += '// Parse SQL into heap-allocated V_ParseAstResult. Caller must free with pg_query_bridge_free_ast_result.\n'
	hdr += 'void* pg_query_bridge_parse_ast_direct(const char* input, int parser_options);\n\n'
	hdr += '// Free a V_ParseAstResult returned by the bridge.\n'
	hdr += 'void pg_query_bridge_free_ast_result(void* ptr);\n\n'
	hdr += '// --- V ABI accessor functions ---\n'
	hdr += 'int pg_query_varray_len(const void *va);\n'
	hdr += 'int pg_query_varray_element_size(const void *va);\n'
	hdr += 'const void* pg_query_varray_get(const void *va, int i);\n'
	hdr += 'const char* pg_query_vstring_str(const void *vs);\n'
	hdr += 'int pg_query_vstring_len(const void *vs);\n'
	hdr += 'int pg_query_vnode_tag(const void *vn);\n'
	hdr += 'const void* pg_query_vnode_data(const void *vn);\n'
	hdr += 'int pg_query_raw_stmt_location(const void *rs);\n'
	hdr += 'int pg_query_raw_stmt_len(const void *rs);\n'
	hdr += 'const void* pg_query_raw_stmt_stmt(const void *rs);\n'
	hdr += '\n// VNode union member accessors for each Node variant\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		hdr += 'const void* pg_query_vnode_get_${vname}(const void *vn);\n'
	}
	hdr += '\n#endif /* PROTOBUF_BRIDGE_H */\n'

	os.write_file('pg_query/protobuf_bridge.h', hdr) or {
		eprintln('Failed to write protobuf_bridge.h: ${err}')
		return
	}
	println('Generated pg_query/protobuf_bridge.h (${hdr.len} bytes)')
}

// ============================================================
// Generate pg_query/pg_query_pluck.v (V-side pluck layer)
// ============================================================

fn c_vtype_to_v_typedef(ctype string) string {
	if ctype.starts_with('struct V_') {
		return 'voidptr'
	}
	match ctype {
		'int' { return 'int' }
		'int64_t' { return 'i64' }
		'uint32_t' { return 'u32' }
		'uint64_t' { return 'u64' }
		'float' { return 'f32' }
		'double' { return 'f64' }
		'VString' { return 'C.VString' }
		'VArray' { return 'C.VArray' }
		'VNode' { return 'C.VNode' }
		else {
			if ctype.starts_with('V_') {
				return 'C.${ctype}'
			}
			if ctype == 'int' { return 'int' }
			return ctype
		}
	}
}

fn gen_v_pluck_field_value(f ProtoField, pf ProtoFile, msg_name string) string {
	vfname := snake_case(f.name)
	if f.repeated {
		if f.typ == 'Node' {
			return '${vfname}: c_to_node_array(c.${vfname})'
		} else if f.typ == 'string' {
			return '${vfname}: vstr_to_string_array(c.${vfname})'
		} else if is_primitive_proto(f.typ) {
			return '${vfname}: c_to_${f.typ}_array(c.${vfname})'
		} else if is_enum_type(pf, f.typ) {
			vtype := proto_field_to_v_type(f.typ)
			vfn := snake_case(vtype)
			return '${vfname}: c_to_${vfn}_array(c.${vfname})'
		} else {
			vname := proto_field_to_v_type(f.typ)
			vfn := snake_case(vname)
			return '${vfname}: c_to_${vfn}_array(c.${vfname})'
		}
	}
	if f.typ == 'string' {
		return '${vfname}: vstr_to_string(c.${vfname})'
	} else if f.typ == 'Node' {
		return '${vfname}: c_to_node(voidptr(&c.${vfname}))'
	} else if is_primitive_proto(f.typ) {
		if f.typ == 'bool' {
			return '${vfname}: c.${vfname} != 0'
		}
		return '${vfname}: c.${vfname}'
	} else if f.typ == 'Context' {
		vtype := proto_field_to_v_type(f.typ)
		return '${vfname}: unsafe { ${vtype}(c.${vfname}) }'
	} else if is_enum_type(pf, f.typ) {
		vtype := proto_field_to_v_type(f.typ)
		return '${vfname}: unsafe { ${vtype}(c.${vfname}) }'
	} else {
		vname := proto_field_to_v_type(f.typ)
		vfn := snake_case(vname)
		if f.typ == msg_name {
			// Recursive — C field is a pointer (voidptr in typedef)
			return '${vfname}: if c.${vfname} != unsafe { nil } { c_to_${vfn}(unsafe { &C.V_${vname}(c.${vfname}) }) } else { unsafe { nil } }'
		}
		return '${vfname}: c_to_${vfn}(c.${vfname})'
	}
}

fn gen_v_pluck_oneof_assign(of_name string, oneof_fields []ProtoField, pf ProtoFile) string {
	mut out := ''
	for f in oneof_fields {
		vfname := snake_case(f.name)
		out += '\tresult.${vfname} = if c.${vfname}_state == 0 {\n'
		if f.typ == 'string' {
			out += '\t\tvstr_to_string(c.${vfname}_data)\n'
		} else if f.typ == 'Node' {
			out += '\t\tc_to_node(voidptr(&c.${vfname}_data))\n'
		} else if is_primitive_proto(f.typ) {
			if f.typ == 'bool' {
				out += '\t\tc.${vfname}_data != 0\n'
			} else {
				out += '\t\tc.${vfname}_data\n'
			}
		} else if f.typ == 'Context' {
			vtype := proto_field_to_v_type(f.typ)
			out += '\t\tunsafe { ${vtype}(c.${vfname}_data) }\n'
		} else if is_enum_type(pf, f.typ) {
			vtype := proto_field_to_v_type(f.typ)
			out += '\t\tunsafe { ${vtype}(c.${vfname}_data) }\n'
		} else {
			vname := proto_field_to_v_type(f.typ)
			vfn := snake_case(vname)
			out += '\t\tc_to_${vfn}(c.${vfname}_data)\n'
		}
		out += '\t} else {\n'
		out += '\t\tnone\n'
		out += '\t}\n'
	}
	return out
}

fn generate_v_pluck(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += 'module pg_query\n\n'

	// Base C ABI type declarations
	out += '// C ABI type declarations matching pg_query_ast_c.h\n'
	out += '@[typedef]\n'
	out += 'pub struct C.VString {\n'
	out += '\tstr &u8\n'
	out += '\tlen int\n'
	out += '\tis_lit int\n'
	out += '}\n\n'
	out += '@[typedef]\n'
	out += 'pub struct C.VArray {\n'
	out += '\tdata voidptr\n'
	out += '\toffset int\n'
	out += '\tlen int\n'
	out += '\tcap int\n'
	out += '\tflags int\n'
	out += '\telement_size int\n'
	out += '}\n\n'
	out += '@[typedef]\n'
	out += 'pub struct C.VNode {\n'
	out += '\t_typ u32\n'
	out += '}\n\n'

	// C message struct declarations in topological order
	mut sorted := topological_sort_messages(pf)
	for m in sorted {
		vname := proto_field_to_v_type(m.name)
		out += '@[typedef]\n'
		out += 'pub struct C.V_${vname} {\n'
		for f in m.fields {
			if f.is_oneof { continue }
			vfname := snake_case(f.name)
			ctype := c_vtype_for_proto(f.typ, m.name, pf)
			tdef := c_vtype_to_v_typedef(ctype)
			if f.repeated {
				out += '\t${vfname} C.VArray\n'
			} else {
				out += '\t${vfname} ${tdef}\n'
			}
		}
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					vfname := snake_case(f.name)
					ctype := c_vtype_for_proto(f.typ, m.name, pf)
					tdef := c_vtype_to_v_typedef(ctype)
					out += '\t${vfname}_state int\n'
					out += '\t${vfname}_data ${tdef}\n'
				}
			}
		}
		out += '}\n\n'
	}

	// V_RawStmt (note: matches C layout, NOT V AstRawStmt)
	out += '@[typedef]\n'
	out += 'pub struct C.V_RawStmt {\n'
	out += '\tstmt C.VNode\n'
	out += '\tstmt_location int\n'
	out += '\tstmt_len int\n'
	out += '}\n\n'

	// V_ParseAstResult
	out += '@[typedef]\n'
	out += 'pub struct C.V_ParseAstResult {\n'
	out += '\tversion int\n'
	out += '\tstmts C.VArray\n'
	out += '}\n\n'

	// C VNode union accessor declarations
	out += '// VNode union accessor declarations (defined in protobuf_bridge.c)\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		out += 'fn C.pg_query_vnode_get_${vname}(vn voidptr) voidptr\n'
	}
	out += 'fn C.pg_query_vnode_tag(vn voidptr) int\n\n'

	// vstr_to_string helper
	out += '// Helper: convert VString to V string\n'
	out += 'fn vstr_to_string(s C.VString) string {\n'
	out += '\tif s.str == unsafe { nil } { return \'\' }\n'
	out += '\treturn unsafe { cstring_to_vstring(s.str) }\n'
	out += '}\n\n'

	// Collect types used in repeated fields for array helpers
	mut repeated_types := map[string]bool{}
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		for f in m.fields {
			if f.repeated {
				if f.typ == 'Node' {
				} else if f.typ == 'string' {
					repeated_types['string'] = true
				} else if is_primitive_proto(f.typ) {
					repeated_types[f.typ] = true
				} else if is_enum_type(pf, f.typ) {
					repeated_types[f.typ] = true
				} else {
					repeated_types[f.typ] = true
				}
			}
		}
	}

	// Node array helper
	out += '// Helper: convert VNode array to []Node\n'
	out += 'fn c_to_node_array(a C.VArray) []Node {\n'
	out += '\tmut res := []Node{}\n'
	out += '\tfor i in 0 .. a.len {\n'
	out += '\t\telem_ptr := unsafe { voidptr(byteptr(a.data) + i * a.element_size) }\n'
	out += '\t\tres << c_to_node(elem_ptr)\n'
	out += '\t}\n'
	out += '\treturn res\n'
	out += '}\n\n'

	// String array helper
	if 'string' in repeated_types {
		out += 'fn vstr_to_string_array(a C.VArray) []string {\n'
		out += '\tmut res := []string{len: a.len}\n'
		out += '\tfor i in 0 .. a.len {\n'
		out += '\t\telem_ptr := unsafe { &C.VString(voidptr(byteptr(a.data) + i * a.element_size)) }\n'
		out += '\t\tres[i] = vstr_to_string(*elem_ptr)\n'
		out += '\t}\n'
		out += '\treturn res\n'
		out += '}\n\n'
	}

	// Primitive array helpers
	mut prim_array_helpers := map[string]bool{}
	for rt in repeated_types.keys() {
		if is_primitive_proto(rt) && rt != 'string' && rt != 'Node' {
			prim_array_helpers[rt] = true
		}
	}
	for rt in prim_array_helpers.keys() {
		vtype := proto_field_to_v_type(rt)
		out += 'fn c_to_${rt}_array(a C.VArray) []${vtype} {\n'
		out += '\tmut res := []${vtype}{len: a.len}\n'
		out += '\tfor i in 0 .. a.len {\n'
		out += '\t\tres[i] = ${vtype}(unsafe { &int(byteptr(a.data))[i] })\n'
		out += '\t}\n'
		out += '\treturn res\n'
		out += '}\n\n'
	}

	// Enum array helpers
	for rt in repeated_types.keys() {
		if is_enum_type(pf, rt) {
			vtype := proto_field_to_v_type(rt)
			vfn := snake_case(vtype)
			out += 'fn c_to_${vfn}_array(a C.VArray) []${vtype} {\n'
			out += '\tmut res := []${vtype}{len: a.len}\n'
			out += '\tfor i in 0 .. a.len {\n'
			out += '\t\tres[i] = ${vtype}(unsafe { &int(byteptr(a.data))[i] })\n'
			out += '\t}\n'
			out += '\treturn res\n'
			out += '}\n\n'
		}
	}

	// Message array helpers
	for rt in repeated_types.keys() {
		if !is_primitive_proto(rt) && rt != 'Node' && rt != 'string' && !is_enum_type(pf, rt) {
			vtype := proto_field_to_v_type(rt)
			vfn := snake_case(vtype)
			out += 'fn c_to_${vfn}_array(a C.VArray) []${vtype} {\n'
			out += '\tmut res := []${vtype}{len: a.len}\n'
			out += '\tfor i in 0 .. a.len {\n'
			out += '\t\telem_ptr := unsafe { &C.V_${vtype}(voidptr(byteptr(a.data) + i * a.element_size)) }\n'
			out += '\t\tres[i] = c_to_${vfn}(elem_ptr)\n'
			out += '\t}\n'
			out += '\treturn res\n'
			out += '}\n\n'
		}
	}

	// Message conversion functions in topological order
	for m in sorted {
		vname := proto_field_to_v_type(m.name)
		vfn := snake_case(vname)
		mut has_recursive := false
		for f in m.fields {
			if !f.is_oneof && f.typ == m.name { has_recursive = true; break }
		}
		has_oneof := m.oneofs.len > 0
		// Use multi-step pattern only when there are recursive or oneof fields
		use_multi := has_recursive || has_oneof
		out += 'fn c_to_${vfn}(c &C.V_${vname}) ${vname} {\n'
		if use_multi {
			out += '\tmut result := ${vname}{\n'
		} else {
			out += '\treturn ${vname}{\n'
		}
		// Non-oneof, non-recursive fields
		for f in m.fields {
			if f.is_oneof { continue }
			if f.typ == m.name { continue }
			out += '\t${gen_v_pluck_field_value(f, pf, m.name)},\n'
		}
		if use_multi {
			// Init recursive reference fields to nil
			for f in m.fields {
				if !f.is_oneof && f.typ == m.name {
					out += '\t${snake_case(f.name)}: unsafe { nil },\n'
				}
			}
			out += '\t}\n'
			// Handle oneof fields
			for of_name in m.oneofs {
				mut oneof_fields := []ProtoField{}
				for f in m.fields {
					if f.is_oneof && f.oneof_group == of_name {
						oneof_fields << f
					}
				}
				out += gen_v_pluck_oneof_assign(of_name, oneof_fields, pf)
			}
			// Handle recursive pointer fields
			for f in m.fields {
				if !f.is_oneof && f.typ == m.name {
					vfname := snake_case(f.name)
					out += '\tif c.${vfname} != unsafe { nil } {\n'
					out += '\t\tinner := c_to_${vfn}(unsafe { &C.V_${vname}(c.${vfname}) })\n'
					out += '\t\tresult.${vfname} = unsafe { &inner }\n'
					out += '\t}\n'
				}
			}
			out += '\treturn result\n'
		} else {
			// No oneof or recursive — close struct literal
			out += '\t}\n'
		}
		out += '}\n\n'
	}

	// Node dispatcher
	first_vname := proto_field_to_v_type(node_oneof_fields[0].typ)
	out += '// Node dispatcher: convert VNode (tagged union) to Node sum type\n'
	out += 'fn c_to_node(vn_ptr voidptr) Node {\n'
	out += '\ttag := C.pg_query_vnode_tag(vn_ptr)\n'
	out += '\tif tag == -1 { return ${first_vname}{} }\n'
	for idx, f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		vfn := snake_case(vname)
		out += '\tif tag == ${idx} {\n'
		out += '\t\tptr := C.pg_query_vnode_get_${vname}(vn_ptr)\n'
		if idx == 0 {
			out += '\t\tif ptr == unsafe { nil } { return ${vname}{} }\n'
		}
		out += '\t\treturn c_to_${vfn}(unsafe { &C.V_${vname}(ptr) })\n'
		out += '\t}\n'
	}
	out += '\tpanic(\"c_to_node: unknown node tag \${tag}\")\n'
	out += '}\n\n'

	// Top-level parse functions
	out += '// Parse SQL into typed V AST structs using C bridge + pluck layer.\n'
	out += 'pub fn parse_ast_direct(input_sql string) !ParseAstResult {\n'
	out += '\treturn parse_ast_direct_opts(input_sql, 0)\n'
	out += '}\n\n'
	out += 'pub fn parse_ast_direct_opts(input_sql string, parser_options int) !ParseAstResult {\n'
	out += '\tc_ptr := C.pg_query_bridge_parse_ast_direct(input_sql.str, parser_options)\n'
	out += '\tif c_ptr == unsafe { nil } {\n'
	out += '\t\treturn error(\"parse_ast_direct_opts: C bridge returned nil\")\n'
	out += '\t}\n'
	out += '\tc_res := unsafe { &C.V_ParseAstResult(c_ptr) }\n'
	out += '\tdefer { C.pg_query_bridge_free_ast_result(c_ptr) }\n'
	out += '\tmut stmts := []AstRawStmt{}\n'
	out += '\tfor i in 0 .. c_res.stmts.len {\n'
	out += '\t\trs_ptr := unsafe { &C.V_RawStmt(voidptr(byteptr(c_res.stmts.data) + i * c_res.stmts.element_size)) }\n'
	out += '\t\tstmts << AstRawStmt{\n'
	out += '\t\t\tstmt_location: i64(rs_ptr.stmt_location)\n'
	out += '\t\t\tstmt_len: i64(rs_ptr.stmt_len)\n'
	out += '\t\t\tstmt: c_to_node(voidptr(&rs_ptr.stmt))\n'
	out += '\t\t}\n'
	out += '\t}\n'
	out += '\treturn ParseAstResult{\n'
	out += '\t\tversion: c_res.version\n'
	out += '\t\tstmts: stmts\n'
	out += '\t}\n'
	out += '}\n'

	os.write_file('pg_query/pg_query_pluck.v', out) or {
		eprintln('Failed to write pg_query_pluck.v: ${err}')
		return
	}
	println('Generated pg_query/pg_query_pluck.v (${out.len} bytes)')
}

// Generate conversion code for a singular (non-repeated, non-oneof) field
fn gen_c_convert_singular_field(out string, f ProtoField, vname string, cfname string, vfname string, pf ProtoFile, msg_name string) string {
	mut result := out
	if is_primitive_proto(f.typ) {
		result = gen_c_convert_scalar(result, f, 'r.${vfname}', 'msg->${cfname}', pf)
	} else if f.typ == 'Node' {
		result += '\tif (msg->${cfname}) {\n'
		result += '\t\tr.${vfname} = convert_Node(msg->${cfname});\n'
		result += '\t} else {\n'
		result += '\t\tr.${vfname}._typ = UINT32_MAX;\n'
		result += '\t}\n'
	} else if f.typ == 'Context' {
		result += '\tr.${vfname} = (int)msg->${cfname};\n'
	} else if is_enum_type(pf, f.typ) {
		result += '\tr.${vfname} = (int)msg->${cfname};\n'
	} else {
		vname_f := proto_field_to_v_type(f.typ)
		if f.typ == msg_name {
			result += '\tif (msg->${cfname}) {\n'
			result += '\t\tr.${vfname} = (struct V_${vname}*)malloc(sizeof(struct V_${vname}));\n'
			result += '\t\t*(r.${vfname}) = convert_${vname_f}(msg->${cfname});\n'
			result += '\t}\n'
		} else {
			result += '\tr.${vfname} = convert_${vname_f}(msg->${cfname});\n'
		}
	}
	return result
}

// Generate conversion code for a repeated field
fn gen_c_convert_repeated_field(out string, f ProtoField, vname string, cfname string, vfname string, pf ProtoFile, msg_name string) string {
	mut result := out
	result += '\tif (msg->n_${cfname} > 0) {\n'
	result += '\t\tr.${vfname}.len = (int)msg->n_${cfname};\n'
	result += '\t\tr.${vfname}.cap = (int)msg->n_${cfname};\n'
	if f.typ == 'Node' {
		result += '\t\tr.${vfname}.element_size = (int)sizeof(VNode);\n'
		result += '\t\tr.${vfname}.data = malloc(msg->n_${cfname} * sizeof(VNode));\n'
		result += '\t\tfor (size_t _i = 0; _i < msg->n_${cfname}; _i++) {\n'
		result += '\t\t\t((VNode*)r.${vfname}.data)[_i] = convert_Node(msg->${cfname}[_i]);\n'
		result += '\t\t}\n'
	} else if is_primitive_proto(f.typ) {
		result += '\t\t// Repeated primitive\n'
	} else if is_enum_type(pf, f.typ) {
		result += '\t\tr.${vfname}.element_size = sizeof(int);\n'
		result += '\t\tr.${vfname}.data = malloc(msg->n_${cfname} * sizeof(int));\n'
		result += '\t\tfor (size_t _i = 0; _i < msg->n_${cfname}; _i++) {\n'
		result += '\t\t\t((int*)r.${vfname}.data)[_i] = (int)msg->${cfname}[_i];\n'
		result += '\t\t}\n'
	} else {
		vname_f := proto_field_to_v_type(f.typ)
		result += '\t\tr.${vfname}.element_size = (int)sizeof(V_${vname_f});\n'
		result += '\t\tr.${vfname}.data = malloc(msg->n_${cfname} * sizeof(V_${vname_f}));\n'
		result += '\t\tfor (size_t _i = 0; _i < msg->n_${cfname}; _i++) {\n'
		result += '\t\t\t((V_${vname_f}*)r.${vfname}.data)[_i] = convert_${vname_f}(msg->${cfname}[_i]);\n'
		result += '\t\t}\n'
	}
	result += '\t}\n'
	return result
}

// Generate conversion for scalar types
// ============================================================
// Generate pg_query/reverse_bridge.c + .h (V_* → protobuf-c)
// ============================================================

fn generate_reverse_bridge(pf ProtoFile, node_oneof_fields []ProtoField) {
	generate_reverse_bridge_c(pf, node_oneof_fields)
	generate_reverse_bridge_h(pf, node_oneof_fields)
}

fn generate_reverse_bridge_c(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += '#include <stdlib.h>\n'
	out += '#include <string.h>\n'
	out += '#include <stdio.h>\n'
	out += '#include "pg_query.h"\n'
	out += '#include "protobuf/pg_query.pb-c.h"\n'
	out += '#include "pg_query_ast_c.h"\n\n'

	out += '// --- Forward declarations for all to_xxx functions ---\n'
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		vname := proto_field_to_v_type(m.name)
		cproto := proto_to_c_prototype(m.name)
		out += 'static ${cproto}* to_${vname}(V_${vname} *v);\n'
	}
	out += 'static PgQuery__Node* to_Node(VNode *v);\n'
	out += 'static void free_pb_message(ProtobufCMessage *msg);\n\n'

	// Generate to_xxx for each message type
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		vname := proto_field_to_v_type(m.name)
		cproto := proto_to_c_prototype(m.name)
		c_init := 'pg_query__${proto_to_c_init_suffix(m.name)}__init'

		out += 'static ${cproto}* to_${vname}(V_${vname} *v) {\n'
		out += '\t${cproto} *msg = calloc(1, sizeof(${cproto}));\n'
		out += '\t${c_init}(msg);\n'
		out += '\tif (!v) return msg;\n\n'

		// Non-oneof fields
		for f in m.fields {
			if f.is_oneof { continue }
			vfname := c_safe_name(snake_case(f.name))

			if f.repeated {
				out = gen_rev_repeated_field(out, f, vname, vfname, pf, m.name)
			} else {
				out = gen_rev_singular_field(out, f, vname, vfname, pf, m.name)
			}
		}

		// Oneof fields
		mut has_oneof := false
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					has_oneof = true
				}
			}
		}
		if has_oneof {
			out = gen_rev_oneof_switch(out, m, pf)
		}

		out += '\treturn msg;\n'
		out += '}\n\n'
	}

	// Generate to_Node dispatcher (for internal use: VNode → PgQuery__Node)
	out += '// --- to_Node dispatcher (VNode → PgQuery__Node) ---\n\n'
	out += 'static PgQuery__Node* to_Node(VNode *v) {\n'
	out += '\tif (!v || v->_typ == UINT32_MAX) return NULL;\n'
	out += '\tPgQuery__Node *msg = calloc(1, sizeof(PgQuery__Node));\n'
	out += '\tpg_query__node__init(msg);\n'
	out += '\tswitch (v->_typ) {\n'
	for tag_idx, f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		vfname := c_safe_name(snake_case(f.name))
		pb_name := proto_c_field_name(f.name)
		case_name := 'PG_QUERY__NODE__NODE_' + f.name.to_upper()
		out += '\t\tcase ${tag_idx}:\n'
		out += '\t\t\tmsg->node_case = ${case_name};\n'
		out += '\t\t\tmsg->${pb_name} = to_${vname}(v->${vfname});\n'
		out += '\t\t\tbreak;\n'
	}
	out += '\t\tdefault:\n'
	out += '\t\t\tbreak;\n'
	out += '\t}\n'
	out += '\treturn msg;\n'
	out += '}\n\n'

	// Generate vstruct_to_protobuf: takes tag + V_* pointer, produces protobuf bytes
	out += '// --- vstruct_to_protobuf (tag + V_* pointer → packed protobuf) ---\n\n'
	out += 'PgQueryProtobuf pg_query_bridge_vstruct_to_protobuf(void *vstruct, int tag) {\n'
	out += '\tPgQueryProtobuf result;\n'
	out += '\tmemset(&result, 0, sizeof(result));\n'
	out += '\tif (!vstruct || tag < 0) return result;\n\n'
	out += '\tPgQuery__Node *node_msg = calloc(1, sizeof(PgQuery__Node));\n'
	out += '\tpg_query__node__init(node_msg);\n\n'
	out += '\tswitch (tag) {\n'
	for tag_idx, f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		pb_name := proto_c_field_name(f.name)
		case_name := 'PG_QUERY__NODE__NODE_' + f.name.to_upper()
		out += '\t\tcase ${tag_idx}:\n'
		out += '\t\t\tnode_msg->node_case = ${case_name};\n'
		out += '\t\t\tnode_msg->${pb_name} = to_${vname}((V_${vname}*)vstruct);\n'
		out += '\t\t\tbreak;\n'
	}
	out += '\t\tdefault:\n'
	out += '\t\t\tfree(node_msg);\n'
	out += '\t\t\treturn result;\n'
	out += '\t}\n\n'
	out += '\t// Wrap in RawStmt → ParseResult → pack\n'
	out += '\tPgQuery__RawStmt *raw_stmt = calloc(1, sizeof(PgQuery__RawStmt));\n'
	out += '\tpg_query__raw_stmt__init(raw_stmt);\n'
	out += '\traw_stmt->stmt = node_msg;\n\n'
	out += '\tPgQuery__ParseResult *parse_result = calloc(1, sizeof(PgQuery__ParseResult));\n'
	out += '\tpg_query__parse_result__init(parse_result);\n'
	out += '\tparse_result->version = 170000;\n'
	out += '\tparse_result->n_stmts = 1;\n'
	out += '\tparse_result->stmts = calloc(1, sizeof(PgQuery__RawStmt*));\n'
	out += '\tparse_result->stmts[0] = raw_stmt;\n\n'
	out += '\tsize_t packed_size = pg_query__parse_result__get_packed_size(parse_result);\n'
	out += '\tuint8_t *packed = malloc(packed_size);\n'
	out += '\tpg_query__parse_result__pack(parse_result, packed);\n\n'
	out += '\tresult.len = packed_size;\n'
	out += '\tresult.data = (char*)packed;\n\n'
	out += '\tpg_query__parse_result__free_unpacked(parse_result, NULL);\n'
	out += '\treturn result;\n'
	out += '}\n\n'

	// Free helper
	out += '// Free a protobuf-c message tree\n'
	out += 'static void free_pb_message(ProtobufCMessage *msg) {\n'
	out += '\tif (!msg) return;\n'
	out += '\tconst ProtobufCMessageDescriptor *desc = msg->descriptor;\n'
	out += '\tif (!desc) { free(msg); return; }\n'
	out += '\t// Use protobuf-c free_unpacked which handles the full tree\n'
	out += '\t// We use the system allocator (NULL)\n'
	out += '\tprotobuf_c_message_free_unpacked(msg, NULL);\n'
	out += '}\n\n'

	// Free the result
	out += 'void pg_query_bridge_free_protobuf(PgQueryProtobuf pb) {\n'
	out += '\tif (pb.data) free(pb.data);\n'
	out += '}\n'

	os.write_file('pg_query/reverse_bridge.c', out) or {
		eprintln('Failed to write reverse_bridge.c: ${err}')
		return
	}
	println('Generated pg_query/reverse_bridge.c (${out.len} bytes)')
}

fn generate_reverse_bridge_h(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut hdr := ''
	hdr += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	hdr += '// DO NOT EDIT.\n'
	hdr += '#ifndef REVERSE_BRIDGE_H\n'
	hdr += '#define REVERSE_BRIDGE_H\n\n'
	hdr += '#include "pg_query.h"\n'
	hdr += '#include "pg_query_ast_c.h"\n\n'
	hdr += '// Serialize a V_* struct to packed protobuf bytes.\n'
	hdr += '// Takes a pointer to a V_Xxx struct and its VNode tag (from VNODE_TAG_*).\n'
	hdr += '// The caller is responsible for freeing the V_Xxx struct.\n'
	hdr += 'PgQueryProtobuf pg_query_bridge_vstruct_to_protobuf(void *vstruct, int tag);\n\n'
	hdr += '// Free the protobuf data returned by pg_query_bridge_vstruct_to_protobuf.\n'
	hdr += 'void pg_query_bridge_free_protobuf(PgQueryProtobuf pb);\n\n'
	hdr += '#endif /* REVERSE_BRIDGE_H */\n'

	os.write_file('pg_query/reverse_bridge.h', hdr) or {
		eprintln('Failed to write reverse_bridge.h: ${err}')
		return
	}
	println('Generated pg_query/reverse_bridge.h (${hdr.len} bytes)')
}

// ============================================================
// Generate pg_query/pg_query_builders.c + .h (C builder functions)
// V calls these with individual field values to construct PgQuery__Xxx* messages directly,
// avoiding V_* intermediate structs which have sizeof mismatch for VNode fields.
// ============================================================

fn generate_c_builders(pf ProtoFile, node_oneof_fields []ProtoField) {
	generate_c_builders_c(pf, node_oneof_fields)
	generate_c_builders_h(pf, node_oneof_fields)
}

fn builder_param_type(f ProtoField, pf ProtoFile) string {
	match f.typ {
		'int32', 'sint32', 'sfixed32' { return 'int32_t' }
		'int64', 'sint64', 'sfixed64' { return 'int64_t' }
		'uint32', 'fixed32' { return 'uint32_t' }
		'uint64', 'fixed64' { return 'uint64_t' }
		'float' { return 'float' }
		'double' { return 'double' }
		'bool' { return 'int' }
		'string' { return 'const char*' }
		'Node' { return 'PgQuery__Node*' }
		'Context' { return 'int' }
		else {
			if is_enum_type(pf, f.typ) { return 'int' }
			return 'PgQuery__${proto_field_to_v_type(f.typ)}*'
		}
	}
}

fn generate_c_builders_c(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += '#include <stdlib.h>\n'
	out += '#include <string.h>\n'
	out += '#include "pg_query.h"\n'
	out += '#include "protobuf/pg_query.pb-c.h"\n'
	out += '#include "pg_query_ast_c.h"\n\n'

	mut msgs := []ProtoMessage{}
	for m in pf.messages {
		if m.name == 'Node' || m.name == 'ParseResult' || m.name == 'ScanResult' || m.name == 'SummaryResult' { continue }
		msgs << m
	}

	// Helper functions for array construction
	out += '// --- Array helper functions ---\n\n'
	out += 'void** pg_query_builder_alloc_ptr_array(size_t n) {\n'
	out += '\treturn (void**)calloc(n, sizeof(void*));\n'
	out += '}\n\n'
	out += 'void pg_query_builder_ptr_array_set(void** arr, size_t i, void* ptr) {\n'
	out += '\tarr[i] = ptr;\n'
	out += '}\n\n'

	out += 'void pg_query_builder_free_ptr_array(void** arr) {\n'
	out += '\tfree(arr);\n'
	out += '}\n\n'

	// Forward declarations
	out += '// --- Forward declarations ---\n'
	for m in msgs {
		vname := proto_field_to_v_type(m.name)
		out += 'PgQuery__${vname}* pg_query_build_${vname}('
		mut params := []string{}
		for f in m.fields {
			if f.is_oneof {
				// oneof: state + data per variant
				pname := snake_case(f.name)
				mut ptype := builder_param_type(f, pf)
				if f.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if f.typ == 'string' {
					ptype = 'const char*'
				}
				params << 'int ${pname}_state'
				params << '${ptype} ${pname}_data'
			} else if f.repeated {
				pname := snake_case(f.name)
				ptype := builder_param_type(f, pf)
				if f.typ == 'string' {
					params << 'size_t n_${pname}'
					params << 'char** ${pname}'
				} else if f.typ == 'Node' {
					params << 'size_t n_${pname}'
					params << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(f.typ) {
					params << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params << '${ptype}* ${pname}'
					} else {
						params << 'const ${ptype}* ${pname}'
					}
				} else if is_enum_type(pf, f.typ) {
					params << 'size_t n_${pname}'
					params << 'const int* ${pname}'
				} else {
					// Repeated message (non-Node)
					params << 'size_t n_${pname}'
					params << '${ptype}* ${pname}'
				}
			} else {
				// Singular field
				pname := snake_case(f.name)
				ptype := builder_param_type(f, pf)
				if f.typ == 'string' {
					params << 'const char* ${pname}'
				} else {
					params << '${ptype} ${pname}'
				}
			}
		}
		out += params.join(', ')
		out += ');\n'
	}

	// Node variant function declarations
	out += '\n// --- Node variant builder functions ---\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		// Find the message definition for this type
		mut msg := ProtoMessage{}
		for m in pf.messages {
			if m.name == f.typ { msg = m; break }
		}
		out += 'PgQuery__Node* pg_query_build_${vname}_node('
		mut params := []string{}
		for fld in msg.fields {
			if fld.is_oneof {
				pname := snake_case(fld.name)
				mut ptype := builder_param_type(fld, pf)
				if fld.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if fld.typ == 'string' {
					ptype = 'const char*'
				}
				params << 'int ${pname}_state'
				params << '${ptype} ${pname}_data'
			} else if fld.repeated {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'size_t n_${pname}'
					params << 'char** ${pname}'
				} else if fld.typ == 'Node' {
					params << 'size_t n_${pname}'
					params << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) {
					params << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params << '${ptype}* ${pname}'
					} else {
						params << 'const ${ptype}* ${pname}'
					}
				} else {
					params << 'size_t n_${pname}'
					params << '${ptype}* ${pname}'
				}
			} else {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'const char* ${pname}'
				} else {
					params << '${ptype} ${pname}'
				}
			}
		}
		out += params.join(', ')
		out += ');\n'
	}

	out += '\nPgQueryProtobuf pg_query_bridge_pack_node(PgQuery__Node *node);\n\n'

	// Generate builder for each message type
	out += '// --- Builder functions ---\n\n'
	_ = topological_sort_messages(pf)
	for m in msgs {
		vname := proto_field_to_v_type(m.name)
		cproto := 'PgQuery__${vname}'
		c_init := 'pg_query__${proto_to_c_init_suffix(m.name)}__init'

		out += '${cproto}* pg_query_build_${vname}('
		mut params := []string{}
		for f in m.fields {
			if f.is_oneof {
				pname := snake_case(f.name)
				mut ptype := builder_param_type(f, pf)
				if f.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if f.typ == 'string' {
					ptype = 'const char*'
				}
				params << 'int ${pname}_state'
				params << '${ptype} ${pname}_data'
			} else if f.repeated {
				pname := snake_case(f.name)
				ptype := builder_param_type(f, pf)
				if f.typ == 'string' {
					params << 'size_t n_${pname}'
					params << 'char** ${pname}'
				} else if f.typ == 'Node' {
					params << 'size_t n_${pname}'
					params << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(f.typ) {
					params << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params << '${ptype}* ${pname}'
					} else {
						params << 'const ${ptype}* ${pname}'
					}
				} else if is_enum_type(pf, f.typ) {
					params << 'size_t n_${pname}'
					params << 'const int* ${pname}'
				} else {
					params << 'size_t n_${pname}'
					params << '${ptype}* ${pname}'
				}
			} else {
				pname := snake_case(f.name)
				ptype := builder_param_type(f, pf)
				if f.typ == 'string' {
					params << 'const char* ${pname}'
				} else {
					params << '${ptype} ${pname}'
				}
			}
		}
		out += params.join(', ')
		out += ') {\n'
		out += '\t${cproto} *msg = ($cproto*)calloc(1, sizeof(${cproto}));\n'
		out += '\t${c_init}(msg);\n\n'

		// Non-oneof fields
		for f in m.fields {
			if f.is_oneof { continue }
			pname := snake_case(f.name)
			pb_name := proto_c_field_name(f.name)
			if f.repeated {
				if f.typ == 'string' {
					out += '\tmsg->n_${pb_name} = n_${pname};\n'
					out += '\tmsg->${pb_name} = ${pname};\n'
				} else if f.typ == 'Node' {
					out += '\tmsg->n_${pb_name} = n_${pname};\n'
					out += '\tmsg->${pb_name} = (PgQuery__Node**)${pname};\n'
				} else if is_primitive_proto(f.typ) {
					out += '\tmsg->n_${pb_name} = n_${pname};\n'
					mut ctype := 'int32_t'
					match f.typ {
						'int32', 'sint32', 'sfixed32' { ctype = 'int32_t' }
						'int64', 'sint64', 'sfixed64' { ctype = 'int64_t' }
						'uint32', 'fixed32' { ctype = 'uint32_t' }
						'uint64', 'fixed64' { ctype = 'uint64_t' }
						'float' { ctype = 'float' }
						'double' { ctype = 'double' }
						'bool' { ctype = 'protobuf_c_boolean' }
						else {}
					}
					out += '\tmsg->${pb_name} = (${ctype}*)${pname};\n'
				} else if is_enum_type(pf, f.typ) {
					out += '\tmsg->n_${pb_name} = n_${pname};\n'
					out += '\tmsg->${pb_name} = (int*)${pname};\n'
				} else {
					// Repeated message
					vname_f := proto_field_to_v_type(f.typ)
					out += '\tmsg->n_${pb_name} = n_${pname};\n'
					out += '\tmsg->${pb_name} = (PgQuery__${vname_f}**)${pname};\n'
				}
			} else {
				// Singular field
				if f.typ == 'string' {
					out += '\tif (${pname}) {\n'
					out += '\t\tmsg->${pb_name} = strdup(${pname});\n'
					out += '\t}\n'
				} else if f.typ == 'Node' {
					out += '\tmsg->${pb_name} = ${pname};\n'
				} else if f.typ == 'bool' {
					out += '\tmsg->${pb_name} = ${pname} ? 1 : 0;\n'
				} else if f.typ == 'Context' {
					out += '\tmsg->${pb_name} = (PgQuery__SummaryContext)${pname};\n'
				} else if is_enum_type(pf, f.typ) {
					out += '\tmsg->${pb_name} = (PgQuery__${proto_field_to_v_type(f.typ)})${pname};\n'
				} else if is_primitive_proto(f.typ) {
					out += '\tmsg->${pb_name} = ${pname};\n'
				} else if f.typ == m.name {
					// Self-referential (pointer in protobuf-c)
					out += '\tmsg->${pb_name} = ${pname};\n'
				} else {
					// Embedded message type
					out += '\tmsg->${pb_name} = ${pname};\n'
				}
			}
		}

		// Oneof fields
		mut has_oneof := false
		for of_name in m.oneofs {
			for f in m.fields {
				if f.is_oneof && f.oneof_group == of_name {
					has_oneof = true
				}
			}
		}
		if has_oneof {
			for of_name in m.oneofs {
				// Build case constant prefix
				mut case_prefix := 'PG_QUERY__'
				parts2 := m.name.split('_')
				for i2, p2 in parts2 {
					if i2 > 0 { case_prefix += '__' }
					case_prefix += p2.to_upper()
				}
				case_prefix += '__'
				case_prefix += of_name.to_upper()
				case_prefix += '_'

				for f in m.fields {
					if !f.is_oneof || f.oneof_group != of_name { continue }
					pname := snake_case(f.name)
					case_name := case_prefix + f.name.to_upper()
					pb_name := proto_c_field_name(f.name)
					out += '\tif (${pname}_state == 0) {\n'
					out += '\t\tmsg->${of_name}_case = ${case_name};\n'
					if f.typ == 'string' {
						out += '\t\tmsg->${pb_name} = ${pname}_data ? strdup(${pname}_data) : NULL;\n'
					} else if f.typ == 'Node' {
						out += '\t\tmsg->${pb_name} = ${pname}_data;\n'
					} else if is_primitive_proto(f.typ) || is_enum_type(pf, f.typ) || f.typ == 'Context' {
						if f.typ == 'bool' {
							out += '\t\tmsg->${pb_name} = ${pname}_data ? 1 : 0;\n'
						} else {
							out += '\t\tmsg->${pb_name} = ${pname}_data;\n'
						}
					} else {
						out += '\t\tmsg->${pb_name} = ${pname}_data;\n'
					}
					out += '\t}\n'
				}
			}
		}

		out += '\treturn msg;\n'
		out += '}\n\n'
	}

	// Generate Node variant wrapper functions
	out += '// --- Node variant wrapper functions ---\n\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		mut msg := ProtoMessage{}
		for m in pf.messages {
			if m.name == f.typ { msg = m; break }
		}
		pb_name := proto_c_field_name(f.name)
		case_name := 'PG_QUERY__NODE__NODE_' + f.name.to_upper()

		out += 'PgQuery__Node* pg_query_build_${vname}_node('
		mut params := []string{}
		for fld in msg.fields {
			if fld.is_oneof {
				pname := snake_case(fld.name)
				mut ptype := builder_param_type(fld, pf)
				if fld.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if fld.typ == 'string' {
					ptype = 'const char*'
				}
				params << 'int ${pname}_state'
				params << '${ptype} ${pname}_data'
			} else if fld.repeated {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'size_t n_${pname}'
					params << 'char** ${pname}'
				} else if fld.typ == 'Node' {
					params << 'size_t n_${pname}'
					params << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) {
					params << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params << '${ptype}* ${pname}'
					} else {
						params << 'const ${ptype}* ${pname}'
					}
				} else {
					params << 'size_t n_${pname}'
					params << '${ptype}* ${pname}'
				}
			} else {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'const char* ${pname}'
				} else {
					params << '${ptype} ${pname}'
				}
			}
		}
		out += params.join(', ')
		out += ') {\n'
		out += '\tPgQuery__${vname} *inner = pg_query_build_${vname}('
		mut arg_names := []string{}
		for fld in msg.fields {
			pname := snake_case(fld.name)
			if fld.repeated {
				if fld.typ == 'string' {
					arg_names << 'n_${pname}'
					arg_names << '${pname}'
				} else if fld.typ == 'Node' || is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) {
					arg_names << 'n_${pname}'
					arg_names << '${pname}'
				} else {
					arg_names << 'n_${pname}'
					arg_names << '${pname}'
				}
			} else {
				if fld.is_oneof {
					arg_names << '${pname}_state'
					arg_names << '${pname}_data'
				} else {
					arg_names << '${pname}'
				}
			}
		}
		out += arg_names.join(', ')
		out += ');\n'
		out += '\tPgQuery__Node *wrap_node = (PgQuery__Node*)calloc(1, sizeof(PgQuery__Node));\n'
		out += '\tpg_query__node__init(wrap_node);\n'
		out += '\twrap_node->node_case = ${case_name};\n'
		out += '\twrap_node->${pb_name} = inner;\n'
		out += '\treturn wrap_node;\n'
		out += '}\n\n'
	}

	// Pack function
	out += '// --- Pack node to protobuf bytes ---\n\n'
	out += 'PgQueryProtobuf pg_query_bridge_pack_node(PgQuery__Node *node) {\n'
	out += '\tPgQueryProtobuf result;\n'
	out += '\tmemset(&result, 0, sizeof(result));\n'
	out += '\tif (!node) return result;\n\n'
	out += '\tPgQuery__RawStmt *raw_stmt = (PgQuery__RawStmt*)calloc(1, sizeof(PgQuery__RawStmt));\n'
	out += '\tpg_query__raw_stmt__init(raw_stmt);\n'
	out += '\traw_stmt->stmt = node;\n\n'
	out += '\tPgQuery__ParseResult *parse_result = (PgQuery__ParseResult*)calloc(1, sizeof(PgQuery__ParseResult));\n'
	out += '\tpg_query__parse_result__init(parse_result);\n'
	out += '\tparse_result->version = 170000;\n'
	out += '\tparse_result->n_stmts = 1;\n'
	out += '\tparse_result->stmts = (PgQuery__RawStmt**)calloc(1, sizeof(PgQuery__RawStmt*));\n'
	out += '\tparse_result->stmts[0] = raw_stmt;\n\n'
	out += '\tsize_t packed_size = pg_query__parse_result__get_packed_size(parse_result);\n'
	out += '\tuint8_t *packed = (uint8_t*)malloc(packed_size);\n'
	out += '\tpg_query__parse_result__pack(parse_result, packed);\n\n'
	out += '\tresult.len = packed_size;\n'
	out += '\tresult.data = (char*)packed;\n\n'
	out += '\tpg_query__parse_result__free_unpacked(parse_result, NULL);\n'
	out += '\treturn result;\n'
	out += '}\n\n'

	os.write_file('pg_query/pg_query_builders.c', out) or {
		eprintln('Failed to write pg_query_builders.c: ${err}')
		return
	}
	println('Generated pg_query/pg_query_builders.c (${out.len} bytes)')
}

fn generate_c_builders_h(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut hdr := ''
	hdr += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	hdr += '// DO NOT EDIT.\n'
	hdr += '#ifndef PG_QUERY_BUILDERS_H\n'
	hdr += '#define PG_QUERY_BUILDERS_H\n\n'
	hdr += '#include "pg_query.h"\n'
	hdr += '#include "pg_query_ast_c.h"\n\n'

	hdr += '// Array helper functions\n'
	hdr += 'void** pg_query_builder_alloc_ptr_array(size_t n);\n'
	hdr += 'void pg_query_builder_ptr_array_set(void** arr, size_t i, void* ptr);\n'
	hdr += 'void pg_query_builder_free_ptr_array(void** arr);\n\n'

	// Bare builder declarations for all message types
	hdr += '// Message type builder functions\n'
	mut bare_msgs := []ProtoMessage{}
	for m2 in pf.messages {
		if m2.name == 'Node' || m2.name == 'ParseResult' || m2.name == 'ScanResult' || m2.name == 'SummaryResult' { continue }
		bare_msgs << m2
	}
	for m2 in bare_msgs {
		vname := proto_field_to_v_type(m2.name)
		hdr += 'PgQuery__${vname}* pg_query_build_${vname}('
		mut params2 := []string{}
		for fld in m2.fields {
			if fld.is_oneof {
				pname := snake_case(fld.name)
				mut ptype := builder_param_type(fld, pf)
				if fld.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if fld.typ == 'string' {
					ptype = 'const char*'
				}
				params2 << 'int ${pname}_state'
				params2 << '${ptype} ${pname}_data'
			} else if fld.repeated {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params2 << 'size_t n_${pname}'
					params2 << 'char** ${pname}'
				} else if fld.typ == 'Node' {
					params2 << 'size_t n_${pname}'
					params2 << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) {
					params2 << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params2 << '${ptype}* ${pname}'
					} else {
						params2 << 'const ${ptype}* ${pname}'
					}
				} else {
					params2 << 'size_t n_${pname}'
					params2 << '${ptype}* ${pname}'
				}
			} else {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params2 << 'const char* ${pname}'
				} else {
					params2 << '${ptype} ${pname}'
				}
			}
		}
		hdr += params2.join(', ')
		hdr += ');\n'
	}

	hdr += '\n// Node variant builder functions (wrap a built message in PgQuery__Node)\n'
	for f in node_oneof_fields {
		vname := proto_field_to_v_type(f.typ)
		mut msg := ProtoMessage{}
		for m in pf.messages {
			if m.name == f.typ { msg = m; break }
		}
		hdr += 'PgQuery__Node* pg_query_build_${vname}_node('
		mut params := []string{}
		for fld in msg.fields {
			if fld.is_oneof {
				pname := snake_case(fld.name)
				mut ptype := builder_param_type(fld, pf)
				if fld.typ == 'Node' {
					ptype = 'PgQuery__Node*'
				} else if fld.typ == 'string' {
					ptype = 'const char*'
				}
				params << 'int ${pname}_state'
				params << '${ptype} ${pname}_data'
			} else if fld.repeated {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'size_t n_${pname}'
					params << 'char** ${pname}'
				} else if fld.typ == 'Node' {
					params << 'size_t n_${pname}'
					params << 'PgQuery__Node** ${pname}'
				} else if is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) {
					params << 'size_t n_${pname}'
					if ptype.starts_with('PgQuery__') {
						params << '${ptype}* ${pname}'
					} else {
						params << 'const ${ptype}* ${pname}'
					}
				} else {
					params << 'size_t n_${pname}'
					params << '${ptype}* ${pname}'
				}
			} else {
				pname := snake_case(fld.name)
				ptype := builder_param_type(fld, pf)
				if fld.typ == 'string' {
					params << 'const char* ${pname}'
				} else {
					params << '${ptype} ${pname}'
				}
			}
		}
		hdr += params.join(', ')
		hdr += ');\n'
	}

	hdr += '\n// Pack a PgQuery__Node* to protobuf bytes\n'
	hdr += 'PgQueryProtobuf pg_query_bridge_pack_node(PgQuery__Node *node);\n\n'

	hdr += '#endif /* PG_QUERY_BUILDERS_H */\n'

	os.write_file('pg_query/pg_query_builders.h', hdr) or {
		eprintln('Failed to write pg_query_builders.h: ${err}')
		return
	}
	println('Generated pg_query/pg_query_builders.h (${hdr.len} bytes)')
}

// Generate conversion for a singular (non-repeated, non-oneof) field in the reverse direction
fn gen_rev_singular_field(out string, f ProtoField, vname string, vfname string, pf ProtoFile, msg_name string) string {
	mut result := out
	if is_primitive_proto(f.typ) {
		result = gen_rev_scalar(result, f, 'msg->${f.name}', 'v->${vfname}', pf)
	} else if f.typ == 'Node' {
		result += '\tif (v->${vfname}._typ != UINT32_MAX) {\n'
		result += '\t\tmsg->${f.name} = to_Node(&v->${vfname});\n'
		result += '\t}\n'
	} else if f.typ == 'Context' {
		result += '\tmsg->${f.name} = (PgQuery__SummaryContext)v->${vfname};\n'
	} else if is_enum_type(pf, f.typ) {
		result += '\tmsg->${f.name} = v->${vfname};\n'
	} else {
		vname_f := proto_field_to_v_type(f.typ)
		if f.typ == msg_name {
			// Recursive field - pointer type in V_*
			result += '\tif (v->${vfname}) {\n'
			result += '\t\tmsg->${f.name} = to_${vname_f}(v->${vfname});\n'
			result += '\t}\n'
		} else {
			// Embedded message field - value type in V_*, pointer in protobuf-c
			result += '\t{\n'
			result += '\t\tPgQuery__${proto_field_to_v_type(f.typ)} *_sub = to_${vname_f}(&v->${vfname});\n'
			result += '\t\tmsg->${f.name} = _sub;\n'
			result += '\t}\n'
		}
	}
	return result
}

// Generate conversion for a repeated field in the reverse direction
fn gen_rev_repeated_field(out string, f ProtoField, vname string, vfname string, pf ProtoFile, msg_name string) string {
	mut result := out
	pb_name := f.name
	if f.typ == 'Node' {
		result += '\tif (v->${vfname}.len > 0) {\n'
		result += '\t\tmsg->n_${pb_name} = v->${vfname}.len;\n'
		result += '\t\tmsg->${pb_name} = calloc(v->${vfname}.len, sizeof(PgQuery__Node*));\n'
		result += '\t\tfor (size_t _i = 0; _i < v->${vfname}.len; _i++) {\n'
		result += '\t\t\tVNode *_vn = &((VNode*)v->${vfname}.data)[_i];\n'
		result += '\t\t\tmsg->${pb_name}[_i] = to_Node(_vn);\n'
		result += '\t\t}\n'
		result += '\t}\n'
	} else if is_primitive_proto(f.typ) {
		if f.typ == 'string' {
			result += '\tif (v->${vfname}.len > 0) {\n'
			result += '\t\tmsg->n_${pb_name} = v->${vfname}.len;\n'
			result += '\t\tmsg->${pb_name} = calloc(v->${vfname}.len, sizeof(char*));\n'
			result += '\t\tfor (size_t _i = 0; _i < v->${vfname}.len; _i++) {\n'
			result += '\t\t\tVString *_vs = &((VString*)v->${vfname}.data)[_i];\n'
			result += '\t\t\tif (_vs->str && _vs->len > 0) {\n'
			result += '\t\t\t\tmsg->${pb_name}[_i] = strndup((const char*)_vs->str, _vs->len);\n'
			result += '\t\t\t}\n'
			result += '\t\t}\n'
			result += '\t}\n'
		} else if f.typ == 'bytes' {
			result += '\t// repeated bytes field - skipping\n'
		} else {
			// Numeric primitives
			result += '\tif (v->${vfname}.len > 0) {\n'
			result += '\t\tmsg->n_${pb_name} = v->${vfname}.len;\n'
			mut pb_type := 'int32_t'
			match f.typ {
				'int32', 'sint32', 'sfixed32' { pb_type = 'int32_t' }
				'int64', 'sint64', 'sfixed64' { pb_type = 'int64_t' }
				'uint32', 'fixed32' { pb_type = 'uint32_t' }
				'uint64', 'fixed64' { pb_type = 'uint64_t' }
				'float' { pb_type = 'float' }
				'double' { pb_type = 'double' }
				'bool' { pb_type = 'protobuf_c_boolean' }
				else {}
			}
			result += '\t\tmsg->${pb_name} = calloc(v->${vfname}.len, sizeof(${pb_type}));\n'
			result += '\t\tmemcpy(msg->${pb_name}, v->${vfname}.data, v->${vfname}.len * sizeof(${pb_type}));\n'
			result += '\t}\n'
		}
	} else if is_enum_type(pf, f.typ) {
		result += '\tif (v->${vfname}.len > 0) {\n'
		result += '\t\tmsg->n_${pb_name} = v->${vfname}.len;\n'
		result += '\t\tmsg->${pb_name} = calloc(v->${vfname}.len, sizeof(int));\n'
		result += '\t\tmemcpy(msg->${pb_name}, v->${vfname}.data, v->${vfname}.len * sizeof(int));\n'
		result += '\t}\n'
	} else {
		// Repeated message fields
		vname_f := proto_field_to_v_type(f.typ)
		result += '\tif (v->${vfname}.len > 0) {\n'
		result += '\t\tmsg->n_${pb_name} = v->${vfname}.len;\n'
		result += '\t\tmsg->${pb_name} = calloc(v->${vfname}.len, sizeof(PgQuery__${vname_f}*));\n'
		result += '\t\tfor (size_t _i = 0; _i < v->${vfname}.len; _i++) {\n'
		// VArray of V_xxx structs
		result += '\t\t\tV_${vname_f} *_elem = &((V_${vname_f}*)v->${vfname}.data)[_i];\n'
		result += '\t\t\tmsg->${pb_name}[_i] = to_${vname_f}(_elem);\n'
		result += '\t\t}\n'
		result += '\t}\n'
	}
	return result
}

// Generate oneof switch for reverse direction
fn gen_rev_oneof_switch(out string, m ProtoMessage, pf ProtoFile) string {
	mut result := out
	for of_name in m.oneofs {
		mut oneof_fields := []ProtoField{}
		for f in m.fields {
			if f.is_oneof && f.oneof_group == of_name {
				oneof_fields << f
			}
		}
		if oneof_fields.len == 0 { continue }

		// Build the case constant pattern
		mut case_prefix := 'PG_QUERY__'
		parts2 := m.name.split('_')
		for i2, p2 in parts2 {
			if i2 > 0 { case_prefix += '__' }
			case_prefix += p2.to_upper()
		}
		case_prefix += '__'
		case_prefix += of_name.to_upper()
		case_prefix += '_'

		result += '\t// oneof ${of_name}\n'
		for f in oneof_fields {
			vfname := c_safe_name(snake_case(f.name))
			vname_f := proto_field_to_v_type(f.typ)
			case_name := case_prefix + f.name.to_upper()

			// Build field value
			mut field_val := ''
			if f.typ == 'Node' {
				field_val = 'to_Node(&v->${vfname}_data)'
			} else if is_primitive_proto(f.typ) || is_enum_type(pf, f.typ) || f.typ == 'Context' {
				field_val = 'v->${vfname}_data'
			} else if f.typ == 'string' {
				field_val = '(v->${vfname}_data.str && v->${vfname}_data.len > 0) ? strndup((const char*)v->${vfname}_data.str, v->${vfname}_data.len) : NULL'
			} else {
				field_val = 'to_${vname_f}(&v->${vfname}_data)'
			}

			result += '\tif (v->${vfname}_state == 0) {\n'
			result += '\t\tmsg->${of_name}_case = ${case_name};\n'
			result += '\t\tmsg->${proto_c_field_name(f.name)} = ${field_val};\n'
			result += '\t}\n'
		}
	}
	return result
}

// Generate scalar assignment for reverse direction
fn gen_rev_scalar(out string, f ProtoField, dest string, src string, pf ProtoFile) string {
	mut result := out
	match f.typ {
		'int32', 'sint32', 'sfixed32' {
			result += '\t${dest} = ${src};\n'
		}
		'int64', 'sint64', 'sfixed64' {
			result += '\t${dest} = ${src};\n'
		}
		'uint32', 'fixed32' {
			result += '\t${dest} = ${src};\n'
		}
		'uint64', 'fixed64' {
			result += '\t${dest} = ${src};\n'
		}
		'float' {
			result += '\t${dest} = ${src};\n'
		}
		'double' {
			result += '\t${dest} = ${src};\n'
		}
		'bool' {
			result += '\t${dest} = ${src} ? 1 : 0;\n'
		}
		'string' {
			result += '\tif (${src}.str && ${src}.len > 0) {\n'
			result += '\t\t${dest} = strndup((const char*)${src}.str, ${src}.len);\n'
			result += '\t}\n'
		}
		'bytes' {
			result += '\t// bytes field\n'
		}
		else {}
	}
	return result
}

// ============================================================
// Generate pg_query/pg_query_serialize.v (V serialization API)
// ============================================================

fn generate_v_serialize(pf ProtoFile, node_oneof_fields []ProtoField) {
	mut out := ''
	out += '// Code generated by tools/gen_ast.v from libpg_query/protobuf/pg_query.proto\n'
	out += '// DO NOT EDIT.\n'
	out += 'module pg_query\n\n'

	out += '// --- C FFI declarations for builders ---\n'

	// C builder FFI declarations for each Node variant
	for f in node_oneof_fields {
		mut msg := ProtoMessage{}
		for m in pf.messages {
			if m.name == f.typ { msg = m; break }
		}
		vname := proto_field_to_v_type(f.typ)
		out += 'fn C.pg_query_build_${vname}_node('
		mut params := []string{}
		for fld in msg.fields {
			if fld.is_oneof {
				params << 'int'
				if fld.typ == 'string' {
					params << '&char'
				} else if fld.typ == 'Node' || !is_primitive_proto(fld.typ) {
					params << 'voidptr'
				} else {
					mut vtype := proto_field_to_v_type(fld.typ)
					if vtype == 'bool' { vtype = 'int' }
					params << '${vtype}'
				}
			} else if fld.repeated {
				params << 'usize'
				params << 'voidptr'
			} else {
				if fld.typ == 'string' {
					params << '&char'
				} else if fld.typ == 'Node' || (!is_primitive_proto(fld.typ) && !is_enum_type(pf, fld.typ) && fld.typ != 'Context') {
					params << 'voidptr'
				} else {
					mut vtype := proto_field_to_v_type(fld.typ)
					if vtype == 'bool' { vtype = 'int' }
					params << '${vtype}'
				}
			}
		}
		out += params.join(', ')
		out += ') voidptr\n'
	}

	out += '\nfn C.pg_query_bridge_pack_node(node voidptr) C.PgQueryProtobuf\n'
	out += 'fn C.pg_query_builder_alloc_ptr_array(n usize) voidptr\n'
	out += 'fn C.pg_query_builder_ptr_array_set(arr voidptr, i usize, ptr voidptr)\n'
	out += 'fn C.pg_query_builder_free_ptr_array(arr voidptr)\n\n'

	// Build a C string pointer from a V string
	out += '// Get C &char pointer from V string, empty string returns nil\n'
	out += 'fn str_to_c(s string) &char {\n'
	out += '\tif s == \'\' { return &char(0) }\n'
	out += '\treturn s.str\n'
	out += '}\n\n'

	// Build a Node variant and return a PgQuery__Node* (as voidptr)
	out += '// Convert a V Node sum type to a PgQuery__Node* tree by calling C builders.\n'
	out += 'fn build_node(n Node) voidptr {\n'
	out += '\tunsafe {\n'
	out += '\t\tmatch n {\n'
	for idx, f in node_oneof_fields {
		mut msg := ProtoMessage{}
		for m in pf.messages {
			if m.name == f.typ { msg = m; break }
		}
		vname := proto_field_to_v_type(f.typ)
		out += '\t\t${vname} {\n'

		// Build arguments for the C builder call
		mut arg_exprs := []string{}

		// First, emit temporary variables for sub-expressions
		for fld in msg.fields {
			pname := snake_case(fld.name)
			if fld.repeated && fld.typ == 'Node' {
				// Build array of Nodes
				out += '\t\t\tarr_${pname}_n := usize(n.${pname}.len)\n'
				out += '\t\t\tmut arr_${pname}_ptr := voidptr(0)\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tarr_${pname}_ptr = C.pg_query_builder_alloc_ptr_array(arr_${pname}_n)\n'
				out += '\t\t\t}\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tfor arr_${pname}_i in 0 .. n.${pname}.len {\n'
				out += '\t\t\t\t\tC.pg_query_builder_ptr_array_set(arr_${pname}_ptr, usize(arr_${pname}_i), build_node(n.${pname}[arr_${pname}_i]))\n'
				out += '\t\t\t\t}\n'
				out += '\t\t\t}\n'
			} else if fld.repeated && fld.typ == 'string' {
				out += '\t\t\tarr_${pname}_n := usize(n.${pname}.len)\n'
				out += '\t\t\tmut arr_${pname}_ptr := voidptr(0)\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tarr_${pname}_ptr = C.calloc(arr_${pname}_n, sizeof(voidptr))\n'
				out += '\t\t\t}\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tfor arr_${pname}_i in 0 .. n.${pname}.len {\n'
				out += '\t\t\t\t\tarr_${pname}_s := n.${pname}[arr_${pname}_i]\n'
				out += '\t\t\t\t\tif arr_${pname}_s != \'\' {\n'
				out += '\t\t\t\t\t\tC.pg_query_builder_ptr_array_set(arr_${pname}_ptr, usize(arr_${pname}_i), voidptr(C.strdup(arr_${pname}_s.str)))\n'
				out += '\t\t\t\t\t}\n'
				out += '\t\t\t\t}\n'
				out += '\t\t\t}\n'
			} else if fld.repeated && is_primitive_proto(fld.typ) {
				vtype := proto_field_to_v_type(fld.typ)
				out += '\t\t\tarr_${pname}_n := usize(n.${pname}.len)\n'
				// Allocate a C array of the primitive type
				mut ctype := 'int'
				match fld.typ {
					'int32', 'sint32', 'sfixed32' { ctype = 'int' }
					'int64', 'sint64', 'sfixed64' { ctype = 'i64' }
					'uint32', 'fixed32' { ctype = 'u32' }
					'uint64', 'fixed64' { ctype = 'u64' }
					'float' { ctype = 'f32' }
					'double' { ctype = 'f64' }
					'bool' { ctype = 'int' }
					else {}
				}
				out += '\t\t\tmut arr_${pname}_ptr := voidptr(0)\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tarr_${pname}_ptr = C.malloc(arr_${pname}_n * sizeof(${ctype}))\n'
				out += '\t\t\t}\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tfor arr_${pname}_i in 0 .. n.${pname}.len {\n'
				out += '\t\t\t\t\tset_${pname}_arr := &${ctype}(arr_${pname}_ptr)\n'
				out += '\t\t\t\t\tset_${pname}_arr[arr_${pname}_i] = ${ctype}(n.${pname}[arr_${pname}_i])\n'
				out += '\t\t\t\t}\n'
				out += '\t\t\t}\n'
			} else if fld.repeated && is_enum_type(pf, fld.typ) {
				vtype := proto_field_to_v_type(fld.typ)
				out += '\t\t\tarr_${pname}_n := usize(n.${pname}.len)\n'
				out += '\t\t\tmut arr_${pname}_ptr := voidptr(0)\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tarr_${pname}_ptr = C.malloc(arr_${pname}_n * sizeof(int))\n'
				out += '\t\t\t}\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tfor arr_${pname}_i in 0 .. n.${pname}.len {\n'
				out += '\t\t\t\t\tset_${pname}_arr := &int(arr_${pname}_ptr)\n'
				out += '\t\t\t\t\tset_${pname}_arr[arr_${pname}_i] = int(n.${pname}[arr_${pname}_i])\n'
				out += '\t\t\t\t}\n'
				out += '\t\t\t}\n'
			} else if fld.repeated {
				// Repeated non-Node message type
				vtype := proto_field_to_v_type(fld.typ)
				out += '\t\t\tarr_${pname}_n := usize(n.${pname}.len)\n'
				out += '\t\t\tmut arr_${pname}_ptr := voidptr(0)\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tarr_${pname}_ptr = C.pg_query_builder_alloc_ptr_array(arr_${pname}_n)\n'
				out += '\t\t\t}\n'
				out += '\t\t\tif arr_${pname}_n > 0 {\n'
				out += '\t\t\t\tfor arr_${pname}_i in 0 .. n.${pname}.len {\n'
				out += '\t\t\t\t\t// Build each element - V needs to call the non-node builder\n'
				out += '\t\t\t\t\t// For now, skip repeated message fields\n'
				out += '\t\t\t\t}\n'
				out += '\t\t\t}\n'
			} else if !fld.is_oneof && fld.typ == 'Node' {
				// Singular Node field
				out += '\t\t\t${pname}_node := build_node(n.${pname})\n'
			} else if !fld.is_oneof && !is_primitive_proto(fld.typ) && !is_enum_type(pf, fld.typ) && fld.typ != 'string' && fld.typ != 'Context' {
				// Non-Node message field - call its builder
				vname_f := proto_field_to_v_type(fld.typ)
				// Need to build this message from individual fields: but we don't have a build_node for non-Node types
				// This case occurs e.g. when a Node variant has a non-Node message field (like TypeCast.type_name)
				// For now, we can't build non-Node messages from V individually. We'll need to add non-node builders.
				// For the initial implementation, skip these - they'll be added later.
				out += '\t\t\t// TODO: build ${vname_f} sub-message for field ${pname}\n'
				out += '\t\t\t${pname}_msg := voidptr(0)\n'
			} else if fld.is_oneof && (fld.typ == 'Node' || (!is_primitive_proto(fld.typ) && !is_enum_type(pf, fld.typ) && fld.typ != 'string' && fld.typ != 'Context')) {
				// Oneof Node or message field - use mut temp variable to avoid voidptr if-expr bug
				pname_oneof := snake_case(fld.name)
				out += '\t\t\tmut ${pname_oneof}_val := voidptr(0)\n'
				out += '\t\t\tif v := n.${pname_oneof} {\n'
				if fld.typ == 'Node' {
					out += '\t\t\t\t${pname_oneof}_val = build_node(v)\n'
				} else {
					out += '\t\t\t\t// TODO: non-Node message oneof field - needs dedicated builder\n'
					out += '\t\t\t\t${pname_oneof}_val = voidptr(0)\n'
				}
				out += '\t\t\t}\n'
			}
		}

		// Now build the C function call arguments
		for fld in msg.fields {
			pname := snake_case(fld.name)
			if fld.is_oneof {
				arg_exprs << 'if _ := n.${pname} { 0 } else { 1 }'
				vtype_name := proto_field_to_v_type(fld.typ)
				if fld.typ == 'string' {
					arg_exprs << 'if v := n.${pname} { str_to_c(v) } else { &char(0) }'
				} else if fld.typ == 'bool' {
					arg_exprs << 'if v := n.${pname} { int(v) } else { int(0) }'
				} else if fld.typ == 'Node' || (!is_primitive_proto(fld.typ) && !is_enum_type(pf, fld.typ) && fld.typ != 'Context' && fld.typ != 'string') {
					// Message type in oneof (like Integer in A_Const) or Node - use temp var set above
					arg_exprs << '${pname}_val'
				} else if is_primitive_proto(fld.typ) || is_enum_type(pf, fld.typ) || fld.typ == 'Context' {
					arg_exprs << 'if v := n.${pname} { v } else { ${proto_field_to_v_type(fld.typ)}(0) }'
				} else {
					arg_exprs << 'voidptr(0)'
				}
			} else if fld.repeated {
				arg_exprs << 'arr_${pname}_n'
				arg_exprs << 'arr_${pname}_ptr'
			} else if fld.typ == 'string' {
				arg_exprs << 'str_to_c(n.${pname})'
			} else if fld.typ == 'Node' {
				arg_exprs << '${pname}_node'
			} else if fld.typ == 'bool' {
				arg_exprs << 'int(n.${pname})'
			} else if fld.typ == 'Context' {
				arg_exprs << 'n.${pname}'
			} else if is_enum_type(pf, fld.typ) {
				arg_exprs << 'n.${pname}'
			} else if is_primitive_proto(fld.typ) {
				arg_exprs << 'n.${pname}'
			} else {
				// Non-Node message field
				arg_exprs << '${pname}_msg'
			}
		}
		out += '\t\t\treturn C.pg_query_build_${vname}_node(${arg_exprs.join(', ')})\n'
		out += '\t\t}\n'
	}
	out += '\t\t}\n'
	out += '\t}\n'
	out += '\treturn voidptr(0)\n'
	out += '}\n\n'

	// Top-level pack function
	out += 'fn serialize_node_to_protobuf(n Node) C.PgQueryProtobuf {\n'
	out += '\tnode_ptr := build_node(n)\n'
	out += '\treturn C.pg_query_bridge_pack_node(node_ptr)\n'
	out += '}\n\n'

	out += '// Serialize a Node to packed protobuf bytes.\n'
	out += 'pub fn node_to_protobuf(n Node) !Protobuf {\n'
	out += '\tpb := serialize_node_to_protobuf(n)\n'
	out += '\tif pb.len == 0 || pb.data == unsafe { nil } {\n'
	out += '\t\treturn error("node_to_protobuf: serialization failed")\n'
	out += '\t}\n'
	out += '\tmut bytes := []u8{len: int(pb.len)}\n'
	out += '\tfor i in 0 .. pb.len {\n'
	out += '\t\tbytes[i] = u8(pb.data[i])\n'
	out += '\t}\n'
	out += '\tC.pg_query_bridge_free_protobuf(pb)\n'
	out += '\treturn Protobuf{\n'
	out += '\t\tlen: pb.len\n'
	out += '\t\tdata: bytes.bytestr()\n'
	out += '\t}\n'
	out += '}\n\n'

	out += '// Serialize a Node to protobuf bytes, then deparse to SQL.\n'
	out += 'pub fn deparse_node(n Node) !string {\n'
	out += '\tpb := serialize_node_to_protobuf(n)\n'
	out += '\tif pb.len == 0 || pb.data == unsafe { nil } {\n'
	out += '\t\treturn error("deparse_node: serialization failed")\n'
	out += '\t}\n'
	out += '\tmut bytes := []u8{len: int(pb.len)}\n'
	out += '\tfor i in 0 .. pb.len {\n'
	out += '\t\tbytes[i] = u8(pb.data[i])\n'
	out += '\t}\n'
	out += '\tC.pg_query_bridge_free_protobuf(pb)\n'
	out += '\tres := deparse_protobuf(Protobuf{\n'
	out += '\t\tlen: pb.len\n'
	out += '\t\tdata: bytes.bytestr()\n'
	out += '\t}) or { return err }\n'
	out += '\treturn res.query\n'
	out += '}\n\n'

	out += '// Serialize a Node to protobuf with options, then deparse to SQL.\n'
	out += 'pub fn deparse_node_opts(n Node, opts DeparseOpts) !string {\n'
	out += '\tpb := serialize_node_to_protobuf(n)\n'
	out += '\tif pb.len == 0 || pb.data == unsafe { nil } {\n'
	out += '\t\treturn error("deparse_node_opts: serialization failed")\n'
	out += '\t}\n'
	out += '\tmut bytes := []u8{len: int(pb.len)}\n'
	out += '\tfor i in 0 .. pb.len {\n'
	out += '\t\tbytes[i] = u8(pb.data[i])\n'
	out += '\t}\n'
	out += '\tC.pg_query_bridge_free_protobuf(pb)\n'
	out += '\tres := deparse_protobuf_opts(Protobuf{\n'
	out += '\t\tlen: pb.len\n'
	out += '\t\tdata: bytes.bytestr()\n'
	out += '\t}, opts) or { return err }\n'
	out += '\treturn res.query\n'
	out += '}\n'

	os.write_file('pg_query/pg_query_serialize.v', out) or {
		eprintln('Failed to write pg_query_serialize.v: ${err}')
		return
	}
	println('Generated pg_query/pg_query_serialize.v (${out.len} bytes)')
}

// Generate conversion of a repeated field from V struct to C V_*
fn gen_to_c_repeated_field(vname string, vfname string, f ProtoField, pf ProtoFile) string {
	mut out := ''
	if f.typ == 'Node' {
		out += '\tc.${vfname} = vnode_array_to_c(n.${vfname})\n'
	} else if f.typ == 'string' {
		out += '\tc.${vfname} = vstring_array_to_c(n.${vfname})\n'
    } else if is_primitive_proto(f.typ) {
        // For primitive repeated fields, we need to create a VArray pointing to a C-allocated array
        mut ctype := 'int'
		match f.typ {
			'int32', 'sint32', 'sfixed32' { ctype = 'int' }
			'int64', 'sint64', 'sfixed64' { ctype = 'int64_t' }
			'uint32', 'fixed32' { ctype = 'u32' }
			'uint64', 'fixed64' { ctype = 'u64' }
			'float' { ctype = 'f32' }
			'double' { ctype = 'f64' }
			'bool' { ctype = 'int' }
			else {}
		}
		out += '\tif n.${vfname}.len > 0 {\n'
		out += '\t\tsz${vfname} := int(sizeof(${ctype}))\n'
		out += '\t\tarr${vfname} := C.malloc(n.${vfname}.len * sz${vfname})\n'
		out += '\t\tfor _i${vfname} in 0 .. n.${vfname}.len {\n'
		out += '\t\t\tunsafe { (${ctype}(byteptr(arr${vfname})))[_i${vfname}] = n.${vfname}[_i${vfname}] }\n'
		out += '\t\t}\n'
		out += '\t\tc.${vfname} = C.VArray{\n'
		out += '\t\t\tdata: arr${vfname}\n'
		out += '\t\t\tlen: n.${vfname}.len\n'
		out += '\t\t\tcap: n.${vfname}.len\n'
		out += '\t\t\telement_size: sz${vfname}\n'
		out += '\t\t}\n'
		out += '\t}\n'
	} else if is_enum_type(pf, f.typ) {
		out += '\tif n.${vfname}.len > 0 {\n'
		out += '\t\tsz${vfname} := int(sizeof(int))\n'
		out += '\t\tarr${vfname} := C.malloc(n.${vfname}.len * sz${vfname})\n'
		out += '\t\tfor _i${vfname} in 0 .. n.${vfname}.len {\n'
		out += '\t\t\tunsafe { (int(byteptr(arr${vfname})))[_i${vfname}] = int(n.${vfname}[_i${vfname}]) }\n'
		out += '\t\t}\n'
		out += '\t\tc.${vfname} = C.VArray{\n'
		out += '\t\t\tdata: arr${vfname}\n'
		out += '\t\t\tlen: n.${vfname}.len\n'
		out += '\t\t\tcap: n.${vfname}.len\n'
		out += '\t\t\telement_size: sz${vfname}\n'
		out += '\t\t}\n'
		out += '\t}\n'
	} else {
		// Repeated message types
		ft := proto_field_to_v_type(f.typ)
		ffn := snake_case(ft)
		out += '\tif n.${vfname}.len > 0 {\n'
		out += '\t\tsz${vfname} := int(sizeof(C.V_${ft}))\n'
		out += '\t\tarr${vfname} := C.malloc(n.${vfname}.len * sz${vfname})\n'
		out += '\t\tfor _i${vfname} in 0 .. n.${vfname}.len {\n'
		out += '\t\t\tinner${vfname} := to_c_${ffn}(n.${vfname}[_i${vfname}])\n'
		out += '\t\t\tunsafe { C.memcpy(voidptr(byteptr(arr${vfname}) + _i${vfname} * sz${vfname}), voidptr(inner${vfname}), sz${vfname}) }\n'
		out += '\t\t\tC.free(voidptr(inner${vfname}))\n'
		out += '\t\t}\n'
		out += '\t\tc.${vfname} = C.VArray{\n'
		out += '\t\t\tdata: arr${vfname}\n'
		out += '\t\t\tlen: n.${vfname}.len\n'
		out += '\t\t\tcap: n.${vfname}.len\n'
		out += '\t\t\telement_size: sz${vfname}\n'
		out += '\t\t}\n'
		out += '\t}\n'
	}
	return out
}

fn gen_c_convert_scalar(out string, f ProtoField, dest string, src string, pf ProtoFile) string {
	mut result := out
	match f.typ {
		'int32', 'sint32', 'sfixed32' {
			result += '\t${dest} = ${src};\n'
		}
		'int64', 'sint64', 'sfixed64' {
			result += '\t${dest} = ${src};\n'
		}
		'uint32', 'fixed32' {
			result += '\t${dest} = ${src};\n'
		}
		'uint64', 'fixed64' {
			result += '\t${dest} = ${src};\n'
		}
		'float' {
			result += '\t${dest} = ${src};\n'
		}
		'double' {
			result += '\t${dest} = ${src};\n'
		}
		'bool' {
			result += '\t${dest} = ${src} ? 1 : 0;\n'
		}
		'string' {
			result += '\tif (${src} && ${src}[0]) {\n'
			result += '\t\t${dest}.str = (unsigned char*)strdup(${src});\n'
			result += '\t\t${dest}.len = (int)strlen(${src});\n'
			result += '\t}\n'
		}
		'bytes' {
			result += '\t// bytes field\n'
		}
		else {}
	}
	return result
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
	skip_names['ScanResult'] = true
	skip_names['SummaryResult'] = true
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
		if needs_unsafe_init {
			out += '\tif depth <= 0 { return ${vname}{\n'
			for rfn in ref_field_names {
				out += '\t\t${rfn}: unsafe { nil }\n'
			}
			for ti in transitive_init {
				out += '\t\t' + ti.trim_left('\t') + '\n'
			}
			out += '\t}, 0 }\n'
			out += '\tmut r := ${vname}{\n'
			for rfn in ref_field_names {
				out += '\t\t${rfn}: unsafe { nil }\n'
			}
			for ti in transitive_init {
				out += '\t' + ti + '\n'
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
	} else if f.typ == 'Node' {
		out += '\t\t\t\tdata, c2 := read_submessage(buf, off)\n'
		out += '\t\t\t\tval, _ := decode_node(data, depth - 1)\n'
		out += '\t\t\t\tr.${vfname} = val\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Context' {
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { SummaryContext(int(v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else if is_enum_type(pf, f.typ) {
		etype := proto_field_to_v_type(f.typ)
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { ${etype}(int(v)) }\n'
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
		out += '\t\t\t\t\t\t\tr.${vfname} << unsafe { SummaryContext(int(v)) }\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << unsafe { SummaryContext(int(v)) }\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t}\n'
	} else if is_enum_type(pf, f.typ) {
		etype := proto_field_to_v_type(f.typ)
		out += '\t\t\t\tmatch wire_type {\n'
		out += '\t\t\t\t\twt_len {\n'
		out += '\t\t\t\t\t\tvals, c2 := read_packed_varints(buf, off)\n'
		out += '\t\t\t\t\t\tfor v in vals {\n'
		out += '\t\t\t\t\t\t\tr.${vfname} << unsafe { ${etype}(int(v)) }\n'
		out += '\t\t\t\t\t\t}\n'
		out += '\t\t\t\t\t\toff += c2\n'
		out += '\t\t\t\t\t}\n'
		out += '\t\t\t\t\telse {\n'
		out += '\t\t\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\t\t\tr.${vfname} << unsafe { ${etype}(int(v)) }\n'
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
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { ${etype}(int(v)) }\n'
		out += '\t\t\t\toff += c2\n'
	} else if f.typ == 'Context' {
		out += '\t\t\t\tv, c2 := read_varint(buf, off)\n'
		out += '\t\t\t\tr.${vfname} = unsafe { SummaryContext(int(v)) }\n'
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
