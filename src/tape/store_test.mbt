/// Tests for tape store helpers.

test "fnv1a_hash deterministic output" {
  let hash1 = fnv1a_hash("/home/user/project")
  let hash2 = fnv1a_hash("/home/user/project")
  inspect(hash1, content=hash2)
}

test "fnv1a_hash different inputs produce different hashes" {
  let hash1 = fnv1a_hash("abc")
  let hash2 = fnv1a_hash("xyz")
  inspect(hash1 != hash2, content="true")
}

test "fnv1a_hash produces 16-char hex string" {
  let hash = fnv1a_hash("test")
  inspect(hash.length(), content="16")
  // All characters should be hex digits
  for ch in hash {
    let is_hex = (ch >= 'a' && ch <= 'f') || (ch >= '0' && ch <= '9')
    inspect(is_hex, content="true")
  }
}

test "url_encode alphanumeric passthrough" {
  let result = url_encode("hello123")
  inspect(result, content="hello123")
}

test "url_encode special characters encoded" {
  let result = url_encode("a:b/c")
  inspect(result, content="a%3Ab%2Fc")
}

test "url_encode safe characters not encoded" {
  let result = url_encode("a-b_c.d")
  inspect(result, content="a-b_c.d")
}

test "url_encode space encoded" {
  let result = url_encode("hello world")
  inspect(result, content="hello%20world")
}
