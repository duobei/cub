/// P2P channel: WebSocket-based cub-to-cub communication.

///|
/// A connected peer.
pub struct P2PPeer {
  id : String
  generation : Int
  addr : String
  conn : @websocket.Conn
}

///|
/// P2P channel managing both server and client connections.
pub struct P2PChannel {
  local_id : String
  local_generation : Int
  port : Int
  peer_addrs : Array[String]
  secret : String?
  peers : Map[String, P2PPeer]
}

///|
/// Create a new P2PChannel.
pub fn P2PChannel::new(
  local_id : String,
  local_generation : Int,
  port : Int,
  peer_addrs : Array[String],
  secret? : String? = None,
) -> P2PChannel {
  { local_id, local_generation, port, peer_addrs, secret, peers: {} }
}

///|
/// Channel name for logging.
pub fn P2PChannel::name(self : P2PChannel) -> String {
  "p2p:\{self.port}"
}

///|
/// Build a JSON message envelope, optionally HMAC-signed.
fn build_envelope(
  from : String,
  to : String,
  msg_type : String,
  payload : Json,
  secret? : String? = None,
) -> String {
  let obj : Map[String, Json] = {}
  obj["from"] = from.to_json()
  obj["to"] = to.to_json()
  obj["type"] = msg_type.to_json()
  obj["payload"] = payload
  obj["ts"] = @async.now().to_json()
  match secret {
    Some(s) => {
      let body = Json::object(obj).stringify()
      let hmac = @crypto.hmac_sha256_hex(@utf8.encode(s), @utf8.encode(body))
      obj["hmac"] = hmac.to_json()
    }
    None => ()
  }
  Json::object(obj).stringify()
}

///|
/// Verify HMAC on a received message. Returns parsed Json on success, None on failure.
fn verify_hmac(text : String, secret : String) -> Json? {
  let json : Json = @json.parse(text) catch { _ => return None }
  // Extract the hmac field
  let hmac_val = match json {
    { "hmac": String(h), .. } => h
    _ => return None
  }
  // Rebuild the body without the hmac field
  let obj : Map[String, Json] = match json {
    Json::Object(m) => m
    _ => return None
  }
  let body_obj : Map[String, Json] = {}
  for k, v in obj {
    if k != "hmac" {
      body_obj[k] = v
    }
  }
  let body = Json::object(body_obj).stringify()
  let expected = @crypto.hmac_sha256_hex(
    @utf8.encode(secret),
    @utf8.encode(body),
  )
  if expected == hmac_val {
    Some(json)
  } else {
    None
  }
}

///|
/// Parse a received message: verify HMAC if secret is set, otherwise just parse JSON.
fn parse_message(text : String, secret : String?) -> Json? {
  match secret {
    Some(s) => verify_hmac(text, s)
    None => {
      let json : Json = @json.parse(text) catch { _ => return None }
      Some(json)
    }
  }
}

///|
/// Build handshake payload.
fn build_handshake(id : String, generation : Int) -> Json {
  let p : Map[String, Json] = {}
  p["id"] = id.to_json()
  p["generation"] = generation.to_json()
  Json::object(p)
}

///|
/// Parse a peer handshake from JSON payload.
fn parse_handshake(payload : Json) -> (String, Int)? {
  match payload {
    { "id": String(id), "generation": Number(g, ..), .. } =>
      Some((id, g.to_int()))
    _ => None
  }
}

///|
/// Read a text message from a WebSocket connection.
async fn p2p_read_text(conn : @websocket.Conn) -> String {
  let msg = conn.recv()
  let buf = @buffer.new()
  let tmp : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  for {
    let n = msg.read(tmp)
    if n == 0 {
      break
    }
    for i in 0..<n {
      buf.write_byte(tmp[i])
    }
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// Handle an incoming peer connection (server-side or client-side after handshake).
async fn P2PChannel::handle_peer(
  self : P2PChannel,
  conn : @websocket.Conn,
  peer_id : String,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  @log.info("p2p", "peer \{peer_id} connected")
  for {
    let text = p2p_read_text(conn) catch {
      _ => {
        @log.info("p2p", "peer \{peer_id} disconnected")
        break
      }
    }
    if text.is_empty() {
      continue
    }
    let json = match parse_message(text, self.secret) {
      Some(j) => j
      None => {
        @log.warn("p2p", "invalid or unauthenticated message from \{peer_id}")
        continue
      }
    }
    let msg_type = match json {
      { "type": String(t), .. } => t
      _ => continue
    }
    match msg_type {
      "ping" => {
        let pong = build_envelope(
          self.local_id,
          peer_id,
          "pong",
          Json::null(),
          secret=self.secret,
        )
        conn.send_text(pong) catch {
          _ => break
        }
      }
      "pong" => () // health check response, ignore
      "message" | "query" => {
        let prompt = match json {
          { "payload": { "text": String(t), .. }, .. } => t
          { "payload": String(t), .. } => t
          _ => continue
        }
        let request_id = match json {
          { "id": String(id), .. } => id
          _ => ""
        }
        let meta : Map[String, Json] = {}
        meta["from_peer"] = peer_id.to_json()
        meta["msg_type"] = msg_type.to_json()
        if request_id.length() > 0 {
          meta["request_id"] = request_id.to_json()
        }
        let msg = ChannelMessage::{
          channel: "p2p",
          session_id: "p2p:\{peer_id}",
          prompt,
          metadata: Json::object(meta),
          attachments: [],
          documents: [],
        }
        handler(msg) catch {
          e => @log.error("p2p", "handler error for \{peer_id}: \{e}")
        }
      }
      _ =>
        @log.debug("p2p", "unknown message type '\{msg_type}' from \{peer_id}")
    }
  }
  // Clean up
  self.peers.remove(peer_id)
  conn.close()
}

///|
/// Run the WebSocket server accepting peer connections.
async fn P2PChannel::run_server(
  self : P2PChannel,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  let addr_str = "0.0.0.0:\{self.port}"
  let addr = @socket.Addr::parse(addr_str) catch {
    _ => {
      @log.error("p2p", "failed to parse address \{addr_str}")
      return
    }
  }
  let server = @http.Server::new(addr, reuse_addr=true) catch {
    _ => {
      @log.error("p2p", "failed to start server on port \{self.port}")
      return
    }
  }
  @log.info("p2p", "server listening on port \{self.port}")
  server.run_forever(
    async fn(request, _reader, conn) {
      // Check for WebSocket upgrade on /ws path
      let path = request.path
      if path != "/ws" {
        conn.send_response(404, "Not Found")
        return
      }
      // Upgrade to WebSocket
      let ws = @websocket.Conn::from_http_server(request, conn) catch {
        _ => {
          @log.warn("p2p", "WebSocket upgrade failed")
          return
        }
      }
      // Wait for handshake
      let hs_text = p2p_read_text(ws) catch {
        _ => {
          ws.close()
          return
        }
      }
      let hs_json = match parse_message(hs_text, self.secret) {
        Some(j) => j
        None => {
          @log.warn("p2p", "server: invalid or unauthenticated handshake")
          ws.close()
          return
        }
      }
      let hs_type = match hs_json {
        { "type": String(t), .. } => t
        _ => ""
      }
      if hs_type != "handshake" {
        @log.warn("p2p", "expected handshake, got '\{hs_type}'")
        ws.close()
        return
      }
      let (peer_id, peer_gen) = match hs_json {
        { "payload": payload, .. } =>
          match parse_handshake(payload) {
            Some(r) => r
            None => {
              ws.close()
              return
            }
          }
        _ => {
          ws.close()
          return
        }
      }
      // Send our handshake back
      let reply = build_envelope(
        self.local_id,
        peer_id,
        "handshake",
        build_handshake(self.local_id, self.local_generation),
        secret=self.secret,
      )
      ws.send_text(reply) catch {
        _ => {
          ws.close()
          return
        }
      }
      @log.info("p2p", "server: accepted peer \{peer_id} (gen \{peer_gen})")
      // Connection dedup: if already connected to this peer, resolve which conn to keep.
      // Rule: the node with the smaller local_id keeps its outbound connection.
      match self.peers.get(peer_id) {
        Some(existing) =>
          if self.local_id < peer_id {
            // We prefer our outbound (existing), close this new inbound
            @log.info(
              "p2p",
              "dedup: keeping outbound to \{peer_id}, closing inbound",
            )
            ws.close()
            return
          } else {
            // We prefer this new inbound, close old outbound
            @log.info(
              "p2p",
              "dedup: replacing outbound with inbound for \{peer_id}",
            )
            existing.conn.close()
          }
        None => ()
      }
      // Register peer
      self.peers[peer_id] = P2PPeer::{
        id: peer_id,
        generation: peer_gen,
        addr: "inbound",
        conn: ws,
      }
      // Handle messages
      self.handle_peer(ws, peer_id, handler)
    },
    allow_failure=true,
  )
}

///|
/// Connect to a single peer as client with exponential backoff.
async fn P2PChannel::connect_to_peer(
  self : P2PChannel,
  addr : String,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  let mut delay = 2000 // ms
  let max_delay = 60000
  for {
    // addr may be a full URL (ws://host:port/ws) or just host:port
    let url = if addr.has_prefix("ws://") || addr.has_prefix("wss://") {
      addr
    } else {
      "ws://\{addr}/ws"
    }
    let conn = @platform.ws_connect(url) catch {
      _ => {
        @log.debug(
          "p2p",
          "failed to connect to \{url}, retry in \{delay / 1000}s",
        )
        @async.sleep(delay)
        delay = if delay * 2 < max_delay { delay * 2 } else { max_delay }
        continue
      }
    }
    // Send handshake
    let hs = build_envelope(
      self.local_id,
      "*",
      "handshake",
      build_handshake(self.local_id, self.local_generation),
      secret=self.secret,
    )
    conn.send_text(hs) catch {
      _ => {
        conn.close()
        @async.sleep(delay)
        continue
      }
    }
    // Wait for handshake response
    let reply_text = p2p_read_text(conn) catch {
      _ => {
        conn.close()
        @async.sleep(delay)
        continue
      }
    }
    let reply_json = match parse_message(reply_text, self.secret) {
      Some(j) => j
      None => {
        @log.warn(
          "p2p",
          "client: invalid or unauthenticated handshake reply from \{addr}",
        )
        conn.close()
        @async.sleep(delay)
        continue
      }
    }
    let (peer_id, peer_gen) = match reply_json {
      { "type": String("handshake"), "payload": payload, .. } =>
        match parse_handshake(payload) {
          Some(r) => r
          None => {
            conn.close()
            @async.sleep(delay)
            continue
          }
        }
      _ => {
        conn.close()
        @async.sleep(delay)
        continue
      }
    }
    @log.info(
      "p2p",
      "client: connected to \{peer_id} at \{addr} (gen \{peer_gen})",
    )
    // Connection dedup: if already connected to this peer, resolve which conn to keep.
    // Rule: the node with the smaller local_id keeps its outbound connection.
    let should_skip = match self.peers.get(peer_id) {
      Some(existing) =>
        if self.local_id > peer_id {
          // We prefer inbound (existing), close this new outbound
          @log.info(
            "p2p",
            "dedup: keeping inbound from \{peer_id}, closing outbound",
          )
          conn.close()
          true
        } else {
          // We prefer this new outbound, close old inbound
          @log.info(
            "p2p",
            "dedup: replacing inbound with outbound for \{peer_id}",
          )
          existing.conn.close()
          false
        }
      None => false
    }
    if should_skip {
      @async.sleep(delay)
      continue
    }
    // Register peer
    self.peers[peer_id] = P2PPeer::{
      id: peer_id,
      generation: peer_gen,
      addr,
      conn,
    }
    // Reset backoff on successful connect
    delay = 2000
    // Handle messages until disconnect
    self.handle_peer(conn, peer_id, handler)
    // After disconnect, reconnect
    @log.info("p2p", "peer \{peer_id} at \{addr} disconnected, reconnecting...")
    @async.sleep(delay)
  }
}

///|
/// Start the P2P channel: run server + connect to configured peers.
pub async fn P2PChannel::start(
  self : P2PChannel,
  handler : async (ChannelMessage) -> Unit,
) -> Unit {
  @log.info(
    "p2p",
    "starting (id=\{self.local_id}, port=\{self.port}, peers=\{self.peer_addrs.length()})",
  )
  @async.with_task_group(fn(group) {
    // Start WebSocket server
    group.spawn_bg(async fn() { self.run_server(handler) }, allow_failure=true)
    // Connect to each configured peer
    for addr in self.peer_addrs {
      let peer_addr = addr
      group.spawn_bg(
        async fn() { self.connect_to_peer(peer_addr, handler) },
        allow_failure=true,
      )
    }
  })
}

///|
/// Send a message to a specific peer.
pub async fn P2PChannel::send_to(
  self : P2PChannel,
  peer_id : String,
  msg_type : String,
  payload : Json,
) -> Bool {
  match self.peers.get(peer_id) {
    Some(peer) => {
      let env = build_envelope(
        self.local_id,
        peer_id,
        msg_type,
        payload,
        secret=self.secret,
      )
      peer.conn.send_text(env) catch {
        _ => return false
      }
      true
    }
    None => false
  }
}

///|
/// List connected peers.
pub fn P2PChannel::list_peers(self : P2PChannel) -> Array[Json] {
  let result : Array[Json] = []
  for id, peer in self.peers {
    let obj : Map[String, Json] = {}
    obj["id"] = id.to_json()
    obj["generation"] = peer.generation.to_json()
    obj["addr"] = peer.addr.to_json()
    result.push(Json::object(obj))
  }
  result
}
