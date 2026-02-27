///|
/// HMAC-SHA256 (RFC 2104).
pub fn hmac_sha256(key : Bytes, data : Bytes) -> Bytes {
  let block_size = 64
  // If key is longer than block size, hash it
  let k = if key.length() > block_size { sha256(key) } else { key }
  // Pad key to block_size
  let k_pad = FixedArray::make(block_size, b'\x00')
  for i in 0..<k.length() {
    k_pad[i] = k[i]
  }
  // Inner: key XOR ipad (0x36)
  let inner_buf = FixedArray::make(block_size + data.length(), b'\x00')
  for i in 0..<block_size {
    inner_buf[i] = (k_pad[i].to_int() ^ 0x36).to_byte()
  }
  for i in 0..<data.length() {
    inner_buf[block_size + i] = data[i]
  }
  let inner_hash = sha256(Bytes::from_array(inner_buf))
  // Outer: key XOR opad (0x5c) || inner_hash
  let outer_buf = FixedArray::make(block_size + 32, b'\x00')
  for i in 0..<block_size {
    outer_buf[i] = (k_pad[i].to_int() ^ 0x5c).to_byte()
  }
  for i in 0..<32 {
    outer_buf[block_size + i] = inner_hash[i]
  }
  sha256(Bytes::from_array(outer_buf))
}

///|
/// HMAC-SHA256 returning hex string.
pub fn hmac_sha256_hex(key : Bytes, data : Bytes) -> String {
  bytes_to_hex(hmac_sha256(key, data))
}
