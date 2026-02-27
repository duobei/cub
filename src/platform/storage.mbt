/// Platform storage abstraction — filesystem operations.
/// All callers should use these instead of @fs directly.

///|
/// Read file content as text.
pub async fn read_file_text(path : String) -> String {
  @fs.read_file(path).text()
}

///|
/// Read file content as binary bytes.
pub async fn read_file_binary(path : String) -> Bytes {
  @fs.read_file(path).binary()
}

///|
/// Write text content to a file.
pub async fn write_file(
  path : String,
  content : String,
  create? : Int = 0,
  append? : Bool = false,
  truncate? : Bool = true,
) -> Unit {
  if create > 0 {
    if append {
      @fs.write_file(path, content, create~, append~, truncate=false)
    } else if not(truncate) {
      @fs.write_file(path, content, create~, truncate~)
    } else {
      @fs.write_file(path, content, create~)
    }
  } else {
    @fs.write_file(path, content)
  }
}

///|
/// Create a directory.
pub async fn mkdir(
  path : String,
  permission? : Int = 0o755,
  recursive? : Bool = true,
) -> Unit {
  @fs.mkdir(path, permission~, recursive~)
}

///|
/// List directory entries.
pub async fn readdir(path : String) -> Array[String] {
  @fs.readdir(path)
}

///|
/// Remove a file.
pub async fn remove(path : String) -> Unit {
  @fs.remove(path)
}

///|
/// Check if a file/directory exists.
pub async fn exists(path : String) -> Bool {
  @fs.exists(path)
}

///|
/// Get file kind (Regular, Directory, etc).
pub async fn file_kind(path : String) -> @fs.FileKind {
  @fs.kind(path)
}

///|
/// Change file permissions.
pub async fn chmod(path : String, mode : Int) -> Unit {
  @fs.chmod(path, mode)
}

///|
/// Remove a directory.
pub async fn rmdir(path : String, recursive? : Bool = false) -> Unit {
  @fs.rmdir(path, recursive~)
}
