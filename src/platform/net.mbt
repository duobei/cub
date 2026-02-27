/// Platform network abstraction — HTTP + WebSocket operations.
/// All callers should use these instead of @http/@websocket directly.
/// Types (@http.Response, @http.Client, @websocket.Conn) are accessed
/// through the underlying modules when needed in struct/param declarations.

///|
/// HTTP GET request. Returns (response, body_text).
pub async fn http_get(
  url : String,
  headers? : Map[String, String] = {},
) -> (@http.Response, &@io.Data) {
  @http.get(url, headers~)
}

///|
/// HTTP POST request. Returns (response, body_data).
pub async fn http_post(
  url : String,
  body : String,
  headers? : Map[String, String] = {},
) -> (@http.Response, &@io.Data) {
  @http.post(url, body, headers~)
}

///|
/// HTTP POST streaming request. Returns a Client for reading SSE.
pub async fn http_post_stream(
  url : String,
  headers? : Map[String, String] = {},
) -> @http.Client {
  @http.post_stream(url, headers~)
}

///|
/// Connect to a WebSocket server.
pub async fn ws_connect(url : String) -> @websocket.Conn {
  @websocket.connect(url)
}
