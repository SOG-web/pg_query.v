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

// valid_enum_int_strict is like valid_enum_int but returns an error
// instead of silently coercing invalid values to 0.
pub fn valid_enum_int_strict(valid_values []int, v u64) !int {
	iv := int(v)
	for vv in valid_values {
		if iv == vv {
			return iv
		}
	}
	return error('invalid enum value ${iv}, expected one of ${valid_values}')
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

// ---------------------------------------------------------------------------
// Protobuf wire format write helpers (used by generated pg_query_encode.v)
// ---------------------------------------------------------------------------

// write_tag returns the encoded tag bytes for a field number and wire type.
fn write_tag(field_num int, wire_type int) []u8 {
	return write_varint((u64(field_num) << 3) | u64(wire_type))
}

// write_varint encodes a u64 as a protobuf varint.
fn write_varint(v u64) []u8 {
	mut val := v
	mut buf := []u8{}
	for {
		mut b := u8(val & 0x7F)
		val >>= 7
		if val != 0 {
			b |= 0x80
		}
		buf << b
		if val == 0 {
			break
		}
	}
	return buf
}

// write_svarint encodes an i64 as a signed zigzag varint.
fn write_svarint(v i64) []u8 {
	// zigzag encode: (v << 1) ^ (v >> 63)
	encoded := (u64(v) << 1) ^ u64(v >> 63)
	return write_varint(encoded)
}

// write_fixed32 encodes a u32 as little-endian 4 bytes.
fn write_fixed32(val u32) []u8 {
	return [u8(val), u8(val >> 8), u8(val >> 16), u8(val >> 24)]
}

// write_fixed64 encodes a u64 as little-endian 8 bytes.
fn write_fixed64(val u64) []u8 {
	return [u8(val), u8(val >> 8), u8(val >> 16), u8(val >> 24),
		u8(val >> 32), u8(val >> 40), u8(val >> 48), u8(val >> 56)]
}

// write_float encodes a f32 as 4 bytes.
fn write_float(val f32) []u8 {
	mut bits := u32(0)
	unsafe { C.memcpy(&bits, &val, 4) }
	return write_fixed32(bits)
}

// write_double encodes a f64 as 8 bytes.
fn write_double(val f64) []u8 {
	mut bits := u64(0)
	unsafe { C.memcpy(&bits, &val, 8) }
	return write_fixed64(bits)
}

// write_bool encodes a bool as a varint (0 or 1).
fn write_bool(val bool) []u8 {
	if val { return [u8(1)] }
	return [u8(0)]
}

// write_string encodes a string as length-delimited bytes.
fn write_string(s string) []u8 {
	mut buf := write_varint(u64(s.len))
	if s.len > 0 {
		buf << unsafe { (&u8(s.str)).vbytes(s.len) }
	}
	return buf
}

// write_bytes encodes a []u8 as length-delimited bytes.
fn write_bytes(b []u8) []u8 {
	mut buf := write_varint(u64(b.len))
	buf << b
	return buf
}

// write_length_delimited wraps submessage/bytes with a length prefix.
fn write_length_delimited(sub []u8) []u8 {
	mut buf := write_varint(u64(sub.len))
	buf << sub
	return buf
}

// write_packed_varints packs multiple varints into a length-delimited wrapper.
fn write_packed_varints(vals []u64) []u8 {
	mut payload := []u8{}
	for v in vals {
		payload << write_varint(v)
	}
	mut buf := write_varint(u64(payload.len))
	buf << payload
	return buf
}

// write_packed_svarints packs multiple zigzag varints into a length-delimited wrapper.
fn write_packed_svarints(vals []i64) []u8 {
	mut payload := []u8{}
	for v in vals {
		payload << write_svarint(v)
	}
	mut buf := write_varint(u64(payload.len))
	buf << payload
	return buf
}

// write_map_string_entry encodes a single map<string, string> entry as a submessage.
fn write_map_string_entry(key string, val string) []u8 {
	mut entry := []u8{}
	entry << write_tag(1, wt_len)
	entry << write_string(key)
	entry << write_tag(2, wt_len)
	entry << write_string(val)
	mut buf := write_varint(u64(entry.len))
	buf << entry
	return buf
}

// ---------------------------------------------------------------------------
// Zero-allocation "_into" write helpers — append directly to caller's buffer.
// Used by generated pg_query_encode.v to avoid per-field heap allocations.
// ---------------------------------------------------------------------------

@[inline]
fn write_varint_into(mut buf []u8, v u64) {
	mut val := v
	for {
		mut b := u8(val & 0x7F)
		val >>= 7
		if val != 0 {
			b |= 0x80
		}
		buf << b
		if val == 0 {
			break
		}
	}
}

fn write_svarint_into(mut buf []u8, v i64) {
	write_varint_into(mut buf, (u64(v) << 1) ^ u64(v >> 63))
}

@[inline]
fn write_tag_into(mut buf []u8, field_num int, wire_type int) {
	write_varint_into(mut buf, (u64(field_num) << 3) | u64(wire_type))
}

fn write_bool_into(mut buf []u8, val bool) {
	buf << if val { u8(1) } else { u8(0) }
}

@[inline]
fn write_string_into(mut buf []u8, s string) {
	write_varint_into(mut buf, u64(s.len))
	if s.len > 0 {
		buf << unsafe { (&u8(s.str)).vbytes(s.len) }
	}
}

fn write_bytes_into(mut buf []u8, b []u8) {
	write_varint_into(mut buf, u64(b.len))
	buf << b
}

fn write_fixed32_into(mut buf []u8, val u32) {
	buf << u8(val)
	buf << u8(val >> 8)
	buf << u8(val >> 16)
	buf << u8(val >> 24)
}

fn write_fixed64_into(mut buf []u8, val u64) {
	buf << u8(val)
	buf << u8(val >> 8)
	buf << u8(val >> 16)
	buf << u8(val >> 24)
	buf << u8(val >> 32)
	buf << u8(val >> 40)
	buf << u8(val >> 48)
	buf << u8(val >> 56)
}

fn write_float_into(mut buf []u8, val f32) {
	mut bits := u32(0)
	unsafe { C.memcpy(&bits, &val, 4) }
	write_fixed32_into(mut buf, bits)
}

fn write_double_into(mut buf []u8, val f64) {
	mut bits := u64(0)
	unsafe { C.memcpy(&bits, &val, 8) }
	write_fixed64_into(mut buf, bits)
}

fn write_length_delimited_into(mut buf []u8, sub []u8) {
	write_varint_into(mut buf, u64(sub.len))
	buf << sub
}

// write_u32_placeholder appends 4 zero bytes as a length placeholder.
// The caller must later call backpatch_varint4 at the returned position.
fn write_u32_placeholder(mut buf []u8) {
	buf << u8(0)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0)
}

// backpatch_varint4 writes a padded 4-byte protobuf varint for `length` at
// buf[pos..pos+4]. Padded varints are valid wire format — all standard decoders
// accept multi-byte encodings of any value. Constraint: length < 2^28 (~268 MB).
@[direct_array_access]
fn backpatch_varint4(mut buf []u8, pos int, length int) {
	v := u32(length)
	buf[pos]     = u8(v & 0x7F) | 0x80
	buf[pos + 1] = u8((v >> 7) & 0x7F) | 0x80
	buf[pos + 2] = u8((v >> 14) & 0x7F) | 0x80
	buf[pos + 3] = u8((v >> 21) & 0x7F)
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
