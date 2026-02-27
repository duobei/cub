///|
/// NIST test vector: SHA-256("abc")
test "sha256 abc" {
  let data = @utf8.encode("abc")
  let hash = @crypto.bytes_to_hex(@crypto.sha256(data))
  inspect(
    hash,
    content="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
/// NIST test vector: SHA-256("")
test "sha256 empty" {
  let data = @utf8.encode("")
  let hash = @crypto.bytes_to_hex(@crypto.sha256(data))
  inspect(
    hash,
    content="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

///|
/// NIST test vector: SHA-256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
test "sha256 448bit" {
  let data = @utf8.encode(
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
  )
  let hash = @crypto.bytes_to_hex(@crypto.sha256(data))
  inspect(
    hash,
    content="248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
}

///|
/// SHA-256 of longer message (two blocks).
test "sha256 long" {
  let data = @utf8.encode(
    "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
  )
  let hash = @crypto.bytes_to_hex(@crypto.sha256(data))
  inspect(
    hash,
    content="cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
  )
}
