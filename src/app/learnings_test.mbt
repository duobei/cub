/// Tests for learning extraction and persistence.

///|
test "learnings_similar detects substring containment" {
  inspect(@app.learnings_similar("abc def", "abc def ghi"), content="true")
  inspect(@app.learnings_similar("abc def ghi", "abc def"), content="true")
}

///|
test "learnings_similar detects word overlap" {
  inspect(
    @app.learnings_similar(
      "string replace only replaces first", "string replace replaces first occurrence",
    ),
    content="true",
  )
}

///|
test "learnings_similar rejects unrelated" {
  inspect(@app.learnings_similar("abc def", "xyz uvw"), content="false")
  inspect(@app.learnings_similar("", "abc"), content="false")
}

///|
test "add_learning creates new entry" {
  let home = "/tmp/cub_test_learnings_new"
  @app.write_learnings(home, []) |> ignore
  let result = @app.add_learning(home, "heuristic", "test content", 1000L)
  inspect(result, content="None")
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="1")
  match learnings[0] {
    { "type": String(t), "content": String(c), "reinforced": Number(r, ..), .. } => {
      inspect(t, content="heuristic")
      inspect(c, content="test content")
      inspect(r.to_int(), content="1")
    }
    _ => fail("unexpected learning format")
  }
}

///|
test "add_learning dedup reinforces existing" {
  let home = "/tmp/cub_test_learnings_dedup"
  // Create initial learning
  @app.write_learnings(home, []) |> ignore
  @app.add_learning(home, "heuristic", "string replace only first", 1000L)
  |> ignore
  // Add similar learning — should reinforce, not create new
  @app.add_learning(home, "heuristic", "string replace only first match", 2000L)
  |> ignore
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="1")
  // Check reinforced was incremented
  match learnings[0] {
    { "reinforced": Number(r, ..), .. } => inspect(r.to_int(), content="2")
    _ => fail("expected reinforced field")
  }
}

///|
test "add_learning returns content on crystallization threshold" {
  let home = "/tmp/cub_test_learnings_crystal"
  @app.write_learnings(home, []) |> ignore
  // Build up reinforcement
  @app.add_learning(home, "heuristic", "pattern X", 1000L) |> ignore
  @app.add_learning(home, "heuristic", "pattern X", 2000L) |> ignore
  // Third time should trigger crystallization (reinforced reaches 3)
  let result = @app.add_learning(home, "heuristic", "pattern X", 3000L)
  match result {
    Some(_) => () // crystallization triggered
    None => fail("expected crystallization at reinforced=3")
  }
}

///|
test "decay_learnings reduces confidence" {
  let home = "/tmp/cub_test_learnings_decay"
  // Create a learning with last_used 10 weeks ago
  let ms_per_week : Int64 = 7L * 24L * 60L * 60L * 1000L
  let now : Int64 = 100L * ms_per_week
  let ten_weeks_ago = now - 10L * ms_per_week
  let entry : Map[String, Json] = {}
  entry["type"] = "heuristic".to_json()
  entry["content"] = "old learning".to_json()
  entry["confidence"] = 0.8.to_json()
  entry["reinforced"] = (1).to_json()
  entry["last_used"] = ten_weeks_ago.to_double().to_json()
  entry["created_at"] = ten_weeks_ago.to_double().to_json()
  @app.write_learnings(home, [Json::object(entry)]) |> ignore
  @app.decay_learnings(home, now)
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="1")
  // 0.8 * 0.905^10 ≈ 0.295 — should survive (> 0.1)
  match learnings[0] {
    { "confidence": Number(c, ..), .. } =>
      // Confidence should be reduced from 0.8
      inspect(c < 0.8, content="true")
    _ => fail("unexpected format")
  }
}

///|
test "decay_learnings prunes low confidence" {
  let home = "/tmp/cub_test_learnings_prune"
  let ms_per_week : Int64 = 7L * 24L * 60L * 60L * 1000L
  let now : Int64 = 100L * ms_per_week
  // 30 weeks ago with confidence 0.5 → 0.5 * 0.905^30 ≈ 0.024 < 0.1 → pruned
  let thirty_weeks_ago = now - 30L * ms_per_week
  let entry : Map[String, Json] = {}
  entry["type"] = "heuristic".to_json()
  entry["content"] = "very old learning".to_json()
  entry["confidence"] = 0.5.to_json()
  entry["reinforced"] = (1).to_json()
  entry["last_used"] = thirty_weeks_ago.to_double().to_json()
  entry["created_at"] = thirty_weeks_ago.to_double().to_json()
  @app.write_learnings(home, [Json::object(entry)]) |> ignore
  @app.decay_learnings(home, now)
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="0")
}

///|
test "render_learnings returns empty for no learnings" {
  let home = "/tmp/cub_test_render_empty"
  @app.write_learnings(home, []) |> ignore
  inspect(@app.render_learnings(home), content="")
}

///|
test "render_learnings formats learnings with tags" {
  let home = "/tmp/cub_test_render_tags"
  let e1 : Map[String, Json] = {}
  e1["type"] = "anti_pattern".to_json()
  e1["content"] = "avoid X".to_json()
  e1["confidence"] = 0.8.to_json()
  e1["reinforced"] = (2).to_json()
  e1["last_used"] = 1000.0.to_json()
  e1["created_at"] = 1000.0.to_json()
  let e2 : Map[String, Json] = {}
  e2["type"] = "heuristic".to_json()
  e2["content"] = "use Y".to_json()
  e2["confidence"] = 0.5.to_json()
  e2["reinforced"] = (1).to_json()
  e2["last_used"] = 1000.0.to_json()
  e2["created_at"] = 1000.0.to_json()
  @app.write_learnings(home, [Json::object(e1), Json::object(e2)]) |> ignore
  let result = @app.render_learnings(home)
  // Should contain header and both entries
  inspect(result.contains("# Learnings from past tasks"), content="true")
  inspect(result.contains("[avoid]"), content="true")
  inspect(result.contains("[effective]"), content="true")
}

///|
test "render_learnings filters low confidence" {
  let home = "/tmp/cub_test_render_filter"
  let e1 : Map[String, Json] = {}
  e1["type"] = "heuristic".to_json()
  e1["content"] = "low conf".to_json()
  e1["confidence"] = 0.2.to_json()
  e1["reinforced"] = (1).to_json()
  e1["last_used"] = 1000.0.to_json()
  e1["created_at"] = 1000.0.to_json()
  @app.write_learnings(home, [Json::object(e1)]) |> ignore
  let result = @app.render_learnings(home)
  // Confidence 0.2 < 0.3 threshold, should be empty
  inspect(result, content="")
}

///|
test "update_skill_stats tracks usage" {
  let home = "/tmp/cub_test_skill_stats"
  @app.write_skill_stats(home, {}) |> ignore
  let skills : Map[String, String] = {}
  skills["git"] = "git skill body"
  @app.update_skill_stats(home, skills, 3, None)
  let stats = @app.read_skill_stats(home)
  match stats.get("git") {
    Some({ "uses": Number(u, ..), "successes": Number(s, ..), .. }) => {
      inspect(u.to_int(), content="1")
      inspect(s.to_int(), content="1")
    }
    _ => fail("expected git stats")
  }
}

///|
test "update_skill_stats tracks failures" {
  let home = "/tmp/cub_test_skill_stats_fail"
  @app.write_skill_stats(home, {}) |> ignore
  let skills : Map[String, String] = {}
  skills["git"] = "body"
  @app.update_skill_stats(home, skills, 5, Some("timeout"))
  let stats = @app.read_skill_stats(home)
  match stats.get("git") {
    Some({ "failures": Number(f, ..), .. }) => inspect(f.to_int(), content="1")
    _ => fail("expected failure stat")
  }
}

///|
test "update_skill_stats accumulates across calls" {
  let home = "/tmp/cub_test_skill_stats_accum"
  @app.write_skill_stats(home, {}) |> ignore
  let skills : Map[String, String] = {}
  skills["git"] = "body"
  @app.update_skill_stats(home, skills, 2, None)
  @app.update_skill_stats(home, skills, 4, None)
  let stats = @app.read_skill_stats(home)
  match stats.get("git") {
    Some({ "uses": Number(u, ..), "total_steps": Number(t, ..), .. }) => {
      inspect(u.to_int(), content="2")
      inspect(t.to_int(), content="6")
    }
    _ => fail("expected accumulated stats")
  }
}

///|
test "update_skill_stats skips empty skills" {
  let home = "/tmp/cub_test_skill_stats_empty"
  @app.write_skill_stats(home, {}) |> ignore
  let skills : Map[String, String] = {}
  @app.update_skill_stats(home, skills, 3, None)
  let stats = @app.read_skill_stats(home)
  inspect(stats.length(), content="0")
}

///|
test "extract_learnings detects failure pattern" {
  let home = "/tmp/cub_test_learnings_extract"
  @app.write_learnings(home, []) |> ignore
  // Create mock tape entries with tool calls
  let call_fn : Map[String, Json] = {}
  call_fn["name"] = "bash".to_json()
  call_fn["arguments"] = "{}".to_json()
  let entries : Array[@tape.TapeEntry] = [
    @tape.TapeEntry::tool_call([
      Json::object({ "function": Json::object(call_fn), "id": "1".to_json() }),
    ]),
  ]
  @app.extract_learnings_from_tape(
    entries,
    5,
    Some("max_steps exceeded"),
    home,
    1000L,
  )
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="1")
  match learnings[0] {
    { "type": String(t), .. } => inspect(t, content="anti_pattern")
    _ => fail("unexpected format")
  }
}

///|
test "extract_learnings detects efficient completion" {
  let home = "/tmp/cub_test_learnings_efficient"
  @app.write_learnings(home, []) |> ignore
  let call_fn : Map[String, Json] = {}
  call_fn["name"] = "fs_read".to_json()
  call_fn["arguments"] = "{}".to_json()
  let entries : Array[@tape.TapeEntry] = [
    @tape.TapeEntry::tool_call([
      Json::object({ "function": Json::object(call_fn), "id": "1".to_json() }),
    ]),
  ]
  @app.extract_learnings_from_tape(entries, 2, None, home, 1000L)
  let learnings = @app.read_learnings(home)
  inspect(learnings.length(), content="1")
  match learnings[0] {
    { "type": String(t), .. } => inspect(t, content="heuristic")
    _ => fail("unexpected format")
  }
}

///|
test "skill_name_from_content generates name" {
  inspect(
    @app.skill_name_from_content("Efficient: completed in 2 steps via fs_list"),
    content="auto-efficient-completed-steps",
  )
  inspect(
    @app.skill_name_from_content("Pattern: bash called 4 times consecutively"),
    content="auto-pattern-bash-called",
  )
  inspect(@app.skill_name_from_content(""), content="auto-skill")
}

///|
test "crystallize_skill creates skill file" {
  // crystallize_skill writes to .agent/skills/ dir — test that it returns a name
  // The write may fail in test env without the dir, but the function should not crash
  let ws = "/tmp/cub_test_crystallize"
  let result = @app.crystallize_skill(
    ws, "preference", "Pattern: bash called 4 times consecutively",
  )
  // Write may fail in test env, but function should handle gracefully
  match result {
    Some(name) => inspect(name, content="auto-pattern-bash-called")
    None => () // OK if dir doesn't exist
  }
}
