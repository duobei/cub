/// Tests for tape fork/merge operations.

///|
/// Test: fork creates a new tape, merge appends new entries back.
async test "fork and merge appends new entries to main tape" {
  let tmp = "/tmp/cub_fork_test_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace")
  // Write some entries to the main tape
  store.append("main", TapeEntry::anchor("session/start"))
  store.append("main", TapeEntry::message("user", "hello"))
  let before = store.read("main")
  inspect(before.length(), content="2")
  // Fork
  let fork_name = store.fork("main")
  inspect(fork_name.contains("__fork__"), content="true")
  // Fork should have the same entries
  let fork_entries = store.read(fork_name)
  inspect(fork_entries.length(), content="2")
  // Append new entries to fork
  store.append(fork_name, TapeEntry::message("assistant", "hi there"))
  store.append(fork_name, TapeEntry::message("user", "thanks"))
  let fork_after = store.read(fork_name)
  inspect(fork_after.length(), content="4")
  // Main tape should still have only 2
  // Reset read cache to force re-read
  let main_before_merge = store.read("main")
  inspect(main_before_merge.length(), content="2")
  // Merge
  store.merge(fork_name, "main")
  let main_after = store.read("main")
  // Main should now have 2 original + 2 new = 4
  inspect(main_after.length(), content="4")
  // Verify the new entries are there
  match main_after[2].payload {
    { "content": String(c), .. } => inspect(c, content="hi there")
    _ => fail("expected assistant message")
  }
  match main_after[3].payload {
    { "content": String(c), .. } => inspect(c, content="thanks")
    _ => fail("expected user message")
  }
  // Fork tape should be deleted
  let tapes = store.list_tapes()
  for name in tapes {
    inspect(name.contains("__fork__"), content="false")
  }
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: fork and discard leaves main tape unchanged.
async test "fork and discard does not modify main tape" {
  let tmp = "/tmp/cub_fork_test_discard_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace2")
  // Write entries to main tape
  store.append("main", TapeEntry::anchor("session/start"))
  store.append("main", TapeEntry::message("user", "hello"))
  let before = store.read("main")
  inspect(before.length(), content="2")
  // Fork and add entries
  let fork_name = store.fork("main")
  store.append(
    fork_name,
    TapeEntry::message("assistant", "should be discarded"),
  )
  // Discard fork
  store.delete_tape(fork_name)
  // Main tape should be unchanged
  let after = store.read("main")
  inspect(after.length(), content="2")
  // Verify content
  match after[1].payload {
    { "content": String(c), .. } => inspect(c, content="hello")
    _ => fail("expected user message")
  }
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: scan_existing skips fork residual files.
async test "scan_existing skips fork residuals" {
  let tmp = "/tmp/cub_fork_test_scan_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace3")
  // Create a main tape
  store.append("main", TapeEntry::message("user", "test"))
  // Create a fork (simulating a crash — fork exists but never merged)
  let fork_name = store.fork("main")
  store.append(fork_name, TapeEntry::message("assistant", "orphan"))
  // Now create a new store (simulating restart) — it should skip the fork
  let store2 = FileTapeStore::new(tmp, "/test/workspace3")
  let tapes = store2.list_tapes()
  // Should only have "main", not the fork
  inspect(tapes.length(), content="1")
  inspect(tapes[0], content="main")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: TapeService fork/merge/discard lifecycle.
async test "TapeService fork merge lifecycle" {
  let tmp = "/tmp/cub_fork_test_svc_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace4")
  let svc = TapeService::new("session", store)
  // Add initial entry
  svc.append_event("test", "data".to_json())
  inspect(svc.fork_active, content="false")
  // Fork
  svc.fork()
  inspect(svc.fork_active, content="true")
  inspect(svc.current_tape_name != svc.base_tape_name, content="true")
  // Add entry during fork
  svc.append_event("forked_event", "forked_data".to_json())
  // Merge
  svc.merge()
  inspect(svc.fork_active, content="false")
  inspect(svc.current_tape_name, content="session")
  // Verify main tape has both entries
  let entries = svc.read_entries()
  inspect(entries.length(), content="2")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: TapeService discard_fork restores base tape name.
async test "TapeService discard_fork restores state" {
  let tmp = "/tmp/cub_fork_test_svc_disc_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace5")
  let svc = TapeService::new("session", store)
  svc.append_event("initial", "data".to_json())
  // Fork and add data
  svc.fork()
  svc.append_event("should_discard", "gone".to_json())
  // Discard
  svc.discard_fork()
  inspect(svc.fork_active, content="false")
  inspect(svc.current_tape_name, content="session")
  // Main tape should only have initial entry
  let entries = svc.read_entries()
  inspect(entries.length(), content="1")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: ensure_bootstrap_anchor does not write duplicate anchor on restart.
async test "ensure_bootstrap_anchor skips when anchor exists" {
  let tmp = "/tmp/cub_fork_test_anchor_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  // First store: write anchor + message
  let store1 = FileTapeStore::new(tmp, "/test/ws_anchor")
  let svc1 = TapeService::new("main", store1)
  svc1.ensure_bootstrap_anchor()
  svc1.tape().append(TapeEntry::message("user", "hello"))
  let entries1 = svc1.read_entries()
  inspect(entries1.length(), content="2")
  let anchor_count1 = entries1
    .iter()
    .filter(fn(e) { e.kind == "anchor" })
    .count()
  inspect(anchor_count1, content="1")
  // Second store: simulate restart — new store reads same directory
  let store2 = FileTapeStore::new(tmp, "/test/ws_anchor")
  let svc2 = TapeService::new("main", store2)
  svc2.ensure_bootstrap_anchor()
  let entries2 = svc2.read_entries()
  // Should still have only 1 anchor + 1 message
  let anchor_count2 = entries2
    .iter()
    .filter(fn(e) { e.kind == "anchor" })
    .count()
  inspect(anchor_count2, content="1")
  inspect(entries2.length(), content="2")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: handoff during fork does not compact (entries preserved).
async test "handoff during fork preserves entries" {
  let tmp = "/tmp/cub_fork_test_handoff_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace_handoff")
  let svc = TapeService::new("session", store)
  // Add initial entries
  svc.tape().append(TapeEntry::anchor("session/start"))
  svc.tape().append(TapeEntry::message("user", "hello"))
  svc.tape().append(TapeEntry::message("assistant", "hi"))
  svc.tape().append(TapeEntry::message("user", "do something"))
  let before_count = svc.read_entries().length()
  inspect(before_count, content="4")
  // Fork
  svc.fork()
  inspect(svc.fork_active, content="true")
  // Add entries to fork
  svc.tape().append(TapeEntry::message("assistant", "working on it"))
  svc.tape().append(TapeEntry::message("user", "more context"))
  // Handoff during fork — should NOT compact
  let after = svc.tape().handoff("auto/context_overflow")
  // All entries should be preserved: 4 original + 2 new + 1 anchor = 7
  inspect(after.length(), content="7")
  // Verify compact_enabled is false during fork
  inspect(svc.tape().compact_enabled, content="false")
  // Merge back
  svc.merge()
  // After merge, base tape should have all entries
  let merged = svc.read_entries()
  inspect(merged.length(), content="7")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: search_all with kind filter returns only matching kinds.
async test "search_all kind filter" {
  let tmp = "/tmp/cub_search_kind_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/ws_search_kind")
  // Write entries of different kinds
  store.append("tape1", TapeEntry::anchor("session/start"))
  store.append("tape1", TapeEntry::message("user", "hello world"))
  store.append("tape1", TapeEntry::message("assistant", "hello back"))
  let data : Map[String, Json] = {}
  data["info"] = "hello event".to_json()
  store.append("tape1", TapeEntry::event("test.hello", data=Json::object(data)))
  // Search without kind filter — should find all entries containing "hello"
  let all_results = store.search_all("hello", limit=20)
  inspect(all_results.length(), content="3")
  // Search with kind=message — should find only message entries
  let msg_results = store.search_all("hello", limit=20, kind="message")
  inspect(msg_results.length(), content="2")
  for pair in msg_results {
    inspect(pair.1.kind, content="message")
  }
  // Search with kind=event — should find only event entries
  let evt_results = store.search_all("hello", limit=20, kind="event")
  inspect(evt_results.length(), content="1")
  inspect(evt_results[0].1.kind, content="event")
  // Search with kind=anchor — no anchors contain "hello"
  let anchor_results = store.search_all("hello", limit=20, kind="anchor")
  inspect(anchor_results.length(), content="0")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: TapeService search_all passes kind through.
async test "TapeService search_all kind passthrough" {
  let tmp = "/tmp/cub_svc_search_kind_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/ws_svc_kind")
  let svc = TapeService::new("main", store)
  svc.tape().append(TapeEntry::message("user", "test query"))
  let data : Map[String, Json] = {}
  data["note"] = "test query event".to_json()
  svc.tape().append(TapeEntry::event("log", data=Json::object(data)))
  // Without kind filter
  let all = svc.search_all("test query")
  inspect(all.length(), content="2")
  // With kind=message
  let msgs = svc.search_all("test query", kind="message")
  inspect(msgs.length(), content="1")
  inspect(msgs[0].1.kind, content="message")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: double fork is no-op.
async test "TapeService double fork is no-op" {
  let tmp = "/tmp/cub_fork_test_double_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/workspace6")
  let svc = TapeService::new("session", store)
  svc.fork()
  let fork_name = svc.current_tape_name
  // Second fork should be no-op
  svc.fork()
  inspect(svc.current_tape_name, content=fork_name)
  // Cleanup
  svc.discard_fork()
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: compact creates archive file with pre-anchor entries.
async test "compact creates archive file" {
  let tmp = "/tmp/cub_archive_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let tape_path = "\{tmp}/tape.jsonl"
  let archive_path = "\{tmp}/tape_archive.jsonl"
  let tf = TapeFile::new(tape_path)
  // Write 3 messages + 1 anchor + 2 messages
  tf.append(TapeEntry::message("user", "msg one"))
  tf.append(TapeEntry::message("assistant", "reply one"))
  tf.append(TapeEntry::message("user", "msg two"))
  tf.append(TapeEntry::anchor("handoff/1"))
  tf.append(TapeEntry::message("user", "msg three"))
  tf.append(TapeEntry::message("assistant", "reply three"))
  inspect(tf.read().length(), content="6")
  // Compact with archive
  let archived = tf.compact(archive_path~)
  inspect(archived, content="3")
  // Verify archive file has 3 entries
  let archive_tf = TapeFile::new(archive_path)
  let archive_entries = archive_tf.read()
  inspect(archive_entries.length(), content="3")
  inspect(archive_entries[0].kind, content="message")
  // Verify current tape has 3 entries (anchor + 2)
  let current = tf.read()
  inspect(current.length(), content="3")
  inspect(current[0].kind, content="anchor")
  // Verify original IDs are preserved (not renumbered)
  inspect(current[0].id, content="4")
  inspect(current[1].id, content="5")
  inspect(current[2].id, content="6")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}

///|
/// Test: search_all finds entries in archive files.
async test "search_all includes archives" {
  let tmp = "/tmp/cub_search_archive_\{@async.now()}"
  @platform.mkdir(tmp, permission=0o755, recursive=true)
  let store = FileTapeStore::new(tmp, "/test/ws_search_archive")
  // Write entries with unique content
  store.append("main", TapeEntry::message("user", "unique_archived_content"))
  store.append("main", TapeEntry::message("assistant", "some reply"))
  store.append("main", TapeEntry::anchor("handoff/1"))
  store.append("main", TapeEntry::message("user", "after anchor msg"))
  // Compact — archives first 2 entries
  let removed = store.compact("main")
  inspect(removed, content="2")
  // Search for archived content — should find it in archive
  let results = store.search_all("unique_archived_content")
  inspect(results.length(), content="1")
  inspect(results[0].0.contains("archived"), content="true")
  // Search for current content — should find in active tape
  let results2 = store.search_all("after anchor msg")
  inspect(results2.length(), content="1")
  inspect(results2[0].0.contains("archived"), content="false")
  // Cleanup
  @platform.rmdir(tmp, recursive=true) catch {
    _ => ()
  }
}
