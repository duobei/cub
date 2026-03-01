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
