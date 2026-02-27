///|
/// RFC 4231 Test Case 1: HMAC-SHA256 with 20-byte key.
test "hmac_sha256 rfc4231 case1" {
  // Key = 0x0b repeated 20 times
  let key = Bytes::from_array(FixedArray::make(20, b'\x0b'))
  let data = @utf8.encode("Hi There")
  let hex = @crypto.hmac_sha256_hex(key, data)
  inspect(
    hex,
    content="b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
}

///|
/// RFC 4231 Test Case 2: HMAC-SHA256 with "Jefe" key.
test "hmac_sha256 rfc4231 case2" {
  let key = @utf8.encode("Jefe")
  let data = @utf8.encode("what do ya want for nothing?")
  let hex = @crypto.hmac_sha256_hex(key, data)
  inspect(
    hex,
    content="5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
/// RFC 4231 Test Case 3: HMAC-SHA256 with 0xaa repeated 20 times.
test "hmac_sha256 rfc4231 case3" {
  let key = Bytes::from_array(FixedArray::make(20, b'\xaa'))
  let data = Bytes::from_array(FixedArray::make(50, b'\xdd'))
  let hex = @crypto.hmac_sha256_hex(key, data)
  inspect(
    hex,
    content="773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  )
}

///|
/// RFC 4231 Test Case 6: HMAC-SHA256 with 131-byte key (key > block size).
test "hmac_sha256 rfc4231 case6" {
  let key = Bytes::from_array(FixedArray::make(131, b'\xaa'))
  let data = @utf8.encode(
    "Test Using Larger Than Block-Size Key - Hash Key First",
  )
  let hex = @crypto.hmac_sha256_hex(key, data)
  inspect(
    hex,
    content="60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  )
}
