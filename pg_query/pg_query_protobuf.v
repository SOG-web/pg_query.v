module pg_query

// Max recursion depth for nested protobuf message decoding.
// Postgres AST is typically 5–15 levels deep; 64 is generous.
pub const max_decode_depth = 64

// valid_enum_int returns v cast to int if it is one of the valid_values,
// or 0 if it is out of range. This prevents silently accepting invalid
// enum values from malformed protobuf input.
pub fn valid_enum_int(valid_values []int, v u64) int {
	iv := int(v)
	for vv in valid_values {
		if iv == vv {
			return iv
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Protobuf wire format helpers (used by generated pg_query_decode.v)
// ---------------------------------------------------------------------------

// Wire types
const wt_varint = 0
const wt_fixed64 = 1
const wt_len = 2
const wt_fixed32 = 5

// Decode a varint from buf starting at offset.
// Returns (value, bytes_consumed).
fn read_varint(buf []u8, offset int) (u64, int) {
	mut val := u64(0)
	mut shift := 0
	mut i := offset
	for i < buf.len {
		b := buf[i]
		val |= u64(b & 0x7F) << u32(shift)
		i++
		if b & 0x80 == 0 {
			return val, i - offset
		}
		shift += 7
		if shift > 63 {
			return 0, i - offset
		}
	}
	return 0, i - offset
}

// Decode a varint as i64 (sign-extended for negative int32 values)
fn read_varint_i64(buf []u8, offset int) (i64, int) {
	val, consumed := read_varint(buf, offset)
	return i64(val), consumed
}

// Decode a signed varint using zigzag encoding (sint32/sint64)
fn read_svarint(buf []u8, offset int) (i64, int) {
	val, consumed := read_varint(buf, offset)
	// zigzag decode: (val >> 1) ^ -(val & 1)
	decoded := i64(val >> 1) ^ -(i64(val & 1))
	return decoded, consumed
}

// Decode a tag: returns (field_number, wire_type, bytes_consumed)
fn read_tag(buf []u8, offset int) (int, int, int) {
	val, consumed := read_varint(buf, offset)
	return int(val >> 3), int(val & 0x07), consumed
}

// Decode a fixed32 little-endian value
fn read_fixed32(buf []u8, offset int) u32 {
	if offset + 4 > buf.len {
		return 0
	}
	return u32(buf[offset]) | (u32(buf[offset + 1]) << 8) | (u32(buf[offset + 2]) << 16) | (u32(buf[offset + 3]) << 24)
}

// Decode a fixed64 little-endian value
fn read_fixed64(buf []u8, offset int) u64 {
	if offset + 8 > buf.len {
		return 0
	}
	lo := u64(buf[offset]) | (u64(buf[offset + 1]) << 8) | (u64(buf[offset + 2]) << 16) | (u64(buf[offset + 3]) << 24)
	hi := u64(buf[offset + 4]) | (u64(buf[offset + 5]) << 8) | (u64(buf[offset + 6]) << 16) | (u64(buf[offset + 7]) << 24)
	return lo | (hi << 32)
}

// Decode a length-delimited value: returns (slice of bytes, bytes_consumed including length varint)
fn read_length_buf(buf []u8, offset int) ([]u8, int) {
	len_val, lc := read_varint(buf, offset)
	byte_len := int(len_val)
	if offset + lc + byte_len > buf.len {
		return []u8{}, 0
	}
	return buf[offset + lc..offset + lc + byte_len], lc + byte_len
}

// Decode a string field
fn read_string(buf []u8, offset int) (string, int) {
	data, consumed := read_length_buf(buf, offset)
	return data.bytestr(), consumed
}

// Decode a bytes field
fn read_bytes(buf []u8, offset int) ([]u8, int) {
	return read_length_buf(buf, offset)
}

// Decode a submessage: returns the raw bytes of the submessage and total consumed
fn read_submessage(buf []u8, offset int) ([]u8, int) {
	return read_length_buf(buf, offset)
}

// Skip over a field based on wire type. Returns new offset.
fn skip_field(buf []u8, offset int, wire_type int) int {
	match wire_type {
		wt_varint {
			_, c := read_varint(buf, offset)
			return offset + c
		}
		wt_fixed64 {
			return offset + 8
		}
		wt_len {
			_, c := read_length_buf(buf, offset)
			return offset + c
		}
		wt_fixed32 {
			return offset + 4
		}
		else {
			return offset + 1
		}
	}
}

// Read a fixed32 as float32 via unsafe reinterpret
fn read_float(buf []u8, offset int) f32 {
	bits := read_fixed32(buf, offset)
	mut f := f32(0.0)
	unsafe {
		C.memcpy(&f, &bits, 4)
	}
	return f
}

// Read a fixed64 as float64 via unsafe reinterpret
fn read_double(buf []u8, offset int) f64 {
	bits := read_fixed64(buf, offset)
	mut d := f64(0.0)
	unsafe {
		C.memcpy(&d, &bits, 8)
	}
	return d
}

// Helper: decode a packed repeated varint field into an existing array
fn read_packed_varints(buf []u8, offset int) ([]u64, int) {
	data, consumed := read_length_buf(buf, offset)
	mut vals := []u64{}
	mut off := 0
	for off < data.len {
		v, c := read_varint(data, off)
		vals << v
		off += c
	}
	return vals, consumed
}

// Helper: decode a packed repeated signed varint field
fn read_packed_svarints(buf []u8, offset int) ([]i64, int) {
	data, consumed := read_length_buf(buf, offset)
	mut vals := []i64{}
	mut off := 0
	for off < data.len {
		v, c := read_svarint(data, off)
		vals << v
		off += c
	}
	return vals, consumed
}

// read_map_string_entry decodes a single protobuf map entry submessage
// for map<string, string>. Returns (key, value) strings.
fn read_map_string_entry(buf []u8) (string, string) {
	mut key := ''
	mut val := ''
	mut off := 0
	for off < buf.len {
		field_num, wire_type, c := read_tag(buf, off)
		off += c
		match field_num {
			1 {
				s, c2 := read_string(buf, off)
				key = s
				off += c2
			}
			2 {
				s, c2 := read_string(buf, off)
				val = s
				off += c2
			}
			else {
				c2 := skip_field(buf, off, wire_type)
				off += c2
			}
		}
	}
	return key, val
}
