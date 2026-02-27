/// Integration tests for P2P channel: handshake, HMAC, dedup.

///|
/// No-op async handler for P2P tests.
async fn noop_p2p_handler(_msg : @channels.ChannelMessage) -> Unit {
  @async.sleep(0)
}

///|
/// Test: two peers with matching secret complete handshake and connect.
async test "p2p handshake with valid HMAC" {
  let secret = "test-secret-123"
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19990,
    ["localhost:19991"],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19991,
    ["localhost:19990"],
    secret=Some(secret),
  )
  @async.with_task_group(fn(group) {
    group.spawn_bg(
      async fn() { peer_a.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() { peer_b.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        @async.sleep(2000)
        let a_peers = peer_a.list_peers()
        let b_peers = peer_b.list_peers()
        inspect(a_peers.length(), content="1")
        inspect(b_peers.length(), content="1")
        let a_peer_id = match a_peers[0] {
          { "id": String(id), .. } => id
          _ => ""
        }
        let b_peer_id = match b_peers[0] {
          { "id": String(id), .. } => id
          _ => ""
        }
        inspect(a_peer_id, content="bbb-peer")
        inspect(b_peer_id, content="aaa-peer")
        group.return_immediately(())
      },
      allow_failure=true,
    )
  })
}

///|
/// Test: peer with wrong secret is rejected.
async test "p2p handshake rejects wrong HMAC" {
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19992,
    [],
    secret=Some("correct-secret"),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19993,
    ["localhost:19992"],
    secret=Some("wrong-secret"),
  )
  @async.with_task_group(fn(group) {
    group.spawn_bg(
      async fn() { peer_a.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() { peer_b.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        @async.sleep(3000)
        let a_peers = peer_a.list_peers()
        inspect(a_peers.length(), content="0")
        group.return_immediately(())
      },
      allow_failure=true,
    )
  })
}

///|
/// Test: connection deduplication — only one connection per peer pair.
async test "p2p connection dedup" {
  let secret = "dedup-secret"
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19994,
    ["localhost:19995"],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19995,
    ["localhost:19994"],
    secret=Some(secret),
  )
  @async.with_task_group(fn(group) {
    group.spawn_bg(
      async fn() { peer_a.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() { peer_b.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        @async.sleep(3000)
        let a_peers = peer_a.list_peers()
        let b_peers = peer_b.list_peers()
        inspect(a_peers.length(), content="1")
        inspect(b_peers.length(), content="1")
        group.return_immediately(())
      },
      allow_failure=true,
    )
  })
}

///|
/// Test: no secret — peers connect without HMAC.
async test "p2p handshake without secret" {
  let peer_a = @channels.P2PChannel::new("aaa-peer", 0, 19996, [
    "localhost:19997",
  ])
  let peer_b = @channels.P2PChannel::new("bbb-peer", 0, 19997, [
    "localhost:19996",
  ])
  @async.with_task_group(fn(group) {
    group.spawn_bg(
      async fn() { peer_a.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() { peer_b.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        @async.sleep(2000)
        let a_peers = peer_a.list_peers()
        inspect(a_peers.length(), content="1")
        group.return_immediately(())
      },
      allow_failure=true,
    )
  })
}

///|
/// Test: send_to delivers a message to connected peer.
async test "p2p send_to message delivery" {
  let secret = "msg-secret"
  let received : Ref[String] = { val: "" }
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19998,
    ["localhost:19999"],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19999,
    [],
    secret=Some(secret),
  )
  let handler_b = async fn(msg : @channels.ChannelMessage) -> Unit {
    received.val = msg.prompt
    @async.sleep(0)
  }
  @async.with_task_group(fn(group) {
    group.spawn_bg(
      async fn() { peer_a.start(noop_p2p_handler) },
      allow_failure=true,
    )
    group.spawn_bg(async fn() { peer_b.start(handler_b) }, allow_failure=true)
    group.spawn_bg(
      async fn() {
        @async.sleep(2000)
        let payload : Map[String, Json] = {}
        payload["text"] = "hello from aaa".to_json()
        let sent = peer_a.send_to("bbb-peer", "message", Json::object(payload))
        inspect(sent, content="true")
        @async.sleep(500)
        inspect(received.val, content="hello from aaa")
        group.return_immediately(())
      },
      allow_failure=true,
    )
  })
}
