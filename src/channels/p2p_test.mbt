/// Integration tests for P2P channel: handshake, HMAC, dedup.

///|
/// No-op async handler for P2P tests.
async fn noop_p2p_handler(_msg : @channels.ChannelMessage) -> Unit {
  @async.sleep(0)
}

///|
/// Test timeout in milliseconds. Prevents tests from hanging in CI when
/// task group cancellation doesn't interrupt blocked I/O.
let p2p_test_timeout : Int = 10000

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
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
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
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(1000)
          let a_peers = peer_a.list_peers()
          inspect(a_peers.length(), content="0")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
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
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
          let a_peers = peer_a.list_peers()
          let b_peers = peer_b.list_peers()
          inspect(a_peers.length(), content="1")
          inspect(b_peers.length(), content="1")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
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
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
          let a_peers = peer_a.list_peers()
          inspect(a_peers.length(), content="1")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
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
  @async.with_timeout(p2p_test_timeout, async fn() {
    @async.with_task_group(fn(group) {
      group.spawn_bg(
        async fn() { peer_a.start(noop_p2p_handler) },
        allow_failure=true,
      )
      group.spawn_bg(async fn() { peer_b.start(handler_b) }, allow_failure=true)
      group.spawn_bg(
        async fn() {
          @async.sleep(500)
          let payload : Map[String, Json] = {}
          payload["text"] = "hello from aaa".to_json()
          let sent = peer_a.send_to(
            "bbb-peer",
            "message",
            Json::object(payload),
          )
          inspect(sent, content="true")
          @async.sleep(500)
          inspect(received.val, content="hello from aaa")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
  })
}

///|
/// Test: peer A provides skills, peer B requests skill list.
async test "p2p skill list request/response" {
  let secret = "skill-secret"
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19870,
    [],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19871,
    ["localhost:19870"],
    secret=Some(secret),
  )
  // Peer A has skills
  peer_a.set_skill_list_fn(fn() {
    let s1 : Map[String, Json] = {}
    s1["name"] = "code-review".to_json()
    s1["description"] = "Review code for quality".to_json()
    s1["source"] = "workspace".to_json()
    let s2 : Map[String, Json] = {}
    s2["name"] = "deploy".to_json()
    s2["description"] = "Deploy to production".to_json()
    s2["source"] = "global".to_json()
    [Json::object(s1), Json::object(s2)]
  })
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
          let skills = peer_b.request_skill_list("aaa-peer")
          inspect(skills.length(), content="2")
          let name0 = match skills[0] {
            { "name": String(n), .. } => n
            _ => ""
          }
          inspect(name0, content="code-review")
          let name1 = match skills[1] {
            { "name": String(n), .. } => n
            _ => ""
          }
          inspect(name1, content="deploy")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
  })
}

///|
/// Test: peer B requests a specific skill body from peer A.
async test "p2p skill body request/response" {
  let secret = "body-secret"
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    0,
    19872,
    [],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    0,
    19873,
    ["localhost:19872"],
    secret=Some(secret),
  )
  peer_a.set_skill_list_fn(fn() { [] })
  peer_a.set_skill_body_fn(fn(name) {
    if name == "code-review" {
      Some("---\nname: code-review\n---\n\nReview code carefully.")
    } else {
      None
    }
  })
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
          // Request existing skill
          let body = peer_b.request_skill_body("aaa-peer", "code-review")
          inspect(body is Some(_), content="true")
          let content = body.unwrap()
          inspect(
            content,
            content="---\nname: code-review\n---\n\nReview code carefully.",
          )
          // Request non-existent skill
          let missing = peer_b.request_skill_body("aaa-peer", "nonexistent")
          inspect(missing is None, content="true")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
  })
}

///|
/// Test: list_peers returns correct fields (id, addr, generation) for peer.list tool.
async test "p2p list_peers returns structured data" {
  let secret = "list-secret"
  let peer_a = @channels.P2PChannel::new(
    "aaa-peer",
    3,
    19880,
    ["localhost:19881"],
    secret=Some(secret),
  )
  let peer_b = @channels.P2PChannel::new(
    "bbb-peer",
    5,
    19881,
    [],
    secret=Some(secret),
  )
  @async.with_timeout(p2p_test_timeout, async fn() {
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
          @async.sleep(500)
          let a_peers = peer_a.list_peers()
          inspect(a_peers.length(), content="1")
          let peer = a_peers[0]
          // Verify id field
          let id = match peer {
            { "id": String(id), .. } => id
            _ => ""
          }
          inspect(id, content="bbb-peer")
          // Verify generation field
          let gen = match peer {
            { "generation": Number(g, ..), .. } => g.to_int()
            _ => -1
          }
          inspect(gen, content="5")
          // Verify addr field exists and is non-empty
          let addr = match peer {
            { "addr": String(a), .. } => a
            _ => ""
          }
          inspect(addr.is_empty(), content="false")
          group.return_immediately(())
        },
        allow_failure=true,
      )
    })
  })
}
