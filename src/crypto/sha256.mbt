///|
/// SHA-256 round constants (first 32 bits of fractional parts of cube roots of first 64 primes).
let sha256_k : FixedArray[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
/// SHA-256 initial hash values (first 32 bits of fractional parts of square roots of first 8 primes).
let sha256_h0 : FixedArray[UInt] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
  0x5be0cd19,
]

///|
/// Right-rotate a 32-bit unsigned integer.
fn rotr(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// SHA-256 Ch function.
fn ch(x : UInt, y : UInt, z : UInt) -> UInt {
  (x & y) ^ (x.lnot() & z)
}

///|
/// SHA-256 Maj function.
fn maj(x : UInt, y : UInt, z : UInt) -> UInt {
  (x & y) ^ (x & z) ^ (y & z)
}

///|
/// SHA-256 big sigma 0.
fn big_sigma0(x : UInt) -> UInt {
  rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22)
}

///|
/// SHA-256 big sigma 1.
fn big_sigma1(x : UInt) -> UInt {
  rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25)
}

///|
/// SHA-256 small sigma 0.
fn small_sigma0(x : UInt) -> UInt {
  rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)
}

///|
/// SHA-256 small sigma 1.
fn small_sigma1(x : UInt) -> UInt {
  rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10)
}

///|
/// Pad message to a multiple of 512 bits per FIPS 180-4.
fn sha256_pad(data : Bytes) -> Bytes {
  let len = data.length()
  let bit_len = len * 8
  // Need: len + 1 (0x80) + padding_zeros + 8 (length) ≡ 0 mod 64
  let remainder = (len + 1 + 8) % 64
  let pad_zeros = if remainder == 0 { 0 } else { 64 - remainder }
  let total = len + 1 + pad_zeros + 8
  let buf = FixedArray::make(total, b'\x00')
  // Copy original data
  for i in 0..<len {
    buf[i] = data[i]
  }
  // Append 0x80
  buf[len] = b'\x80'
  // Append bit length as big-endian 64-bit
  let bit_len_u64 = bit_len.to_uint64()
  for i in 0..<8 {
    buf[total - 8 + i] = ((bit_len_u64 >> ((7 - i) * 8)) & 0xFFUL).to_byte()
  }
  Bytes::from_array(buf)
}

///|
/// Read a big-endian 32-bit word from bytes at offset.
fn read_be32(data : Bytes, offset : Int) -> UInt {
  let b0 = data[offset].to_uint()
  let b1 = data[offset + 1].to_uint()
  let b2 = data[offset + 2].to_uint()
  let b3 = data[offset + 3].to_uint()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
/// Compute SHA-256 digest. Returns 32 bytes.
pub fn sha256(data : Bytes) -> Bytes {
  let padded = sha256_pad(data)
  let num_blocks = padded.length() / 64
  // Initialize hash values
  let h : FixedArray[UInt] = FixedArray::make(8, 0U)
  for i in 0..<8 {
    h[i] = sha256_h0[i]
  }
  // Message schedule
  let w : FixedArray[UInt] = FixedArray::make(64, 0U)
  // Process each 512-bit block
  for block in 0..<num_blocks {
    let base = block * 64
    // Prepare message schedule
    for t in 0..<16 {
      w[t] = read_be32(padded, base + t * 4)
    }
    for t in 16..<64 {
      w[t] = small_sigma1(w[t - 2]) +
        w[t - 7] +
        small_sigma0(w[t - 15]) +
        w[t - 16]
    }
    // Working variables
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    let mut f = h[5]
    let mut g = h[6]
    let mut hh = h[7]
    // 64 rounds
    for t in 0..<64 {
      let t1 = hh + big_sigma1(e) + ch(e, f, g) + sha256_k[t] + w[t]
      let t2 = big_sigma0(a) + maj(a, b, c)
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    }
    // Update hash
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
  }
  // Produce 32-byte digest
  let result = FixedArray::make(32, b'\x00')
  for i in 0..<8 {
    result[i * 4] = (h[i] >> 24).to_byte()
    result[i * 4 + 1] = ((h[i] >> 16) & 0xFFU).to_byte()
    result[i * 4 + 2] = ((h[i] >> 8) & 0xFFU).to_byte()
    result[i * 4 + 3] = (h[i] & 0xFFU).to_byte()
  }
  Bytes::from_array(result)
}

///|
/// Convert bytes to lowercase hex string.
pub fn bytes_to_hex(data : Bytes) -> String {
  let hex_chars = "0123456789abcdef"
  let buf = @buffer.new(size_hint=data.length() * 2)
  for i in 0..<data.length() {
    let b = data[i].to_int()
    buf.write_char(hex_chars[(b >> 4) & 0xF].unsafe_to_char())
    buf.write_char(hex_chars[b & 0xF].unsafe_to_char())
  }
  buf.to_string()
}
