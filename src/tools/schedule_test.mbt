///|
test "parse_cron: valid 5-field expression" {
  let expr = @tools.parse_cron("*/5 * * * *")
  inspect(expr is None, content="false")
}

///|
test "parse_cron: all wildcards" {
  let expr = @tools.parse_cron("* * * * *")
  inspect(expr is None, content="false")
}

///|
test "parse_cron: specific values" {
  let expr = @tools.parse_cron("30 14 1 6 3")
  inspect(expr is None, content="false")
}

///|
test "parse_cron: range and list" {
  let expr = @tools.parse_cron("0,30 9-17 * * 1-5")
  inspect(expr is None, content="false")
}

///|
test "parse_cron: invalid — too few fields" {
  let expr = @tools.parse_cron("*/5 * *")
  inspect(expr is None, content="true")
}

///|
test "parse_cron: invalid — too many fields" {
  let expr = @tools.parse_cron("* * * * * *")
  inspect(expr is None, content="true")
}

///|
test "parse_cron: invalid — empty string" {
  let expr = @tools.parse_cron("")
  inspect(expr is None, content="true")
}

///|
test "cron_matches: wildcard always matches" {
  // 2026-03-03 10:30:00 CST = 1772505000000 ms
  let dt = @tools.unix_ms_to_datetime(1772505000000L)
  let expr = @tools.parse_cron("* * * * *").unwrap()
  inspect(@tools.cron_matches(expr, dt), content="true")
}

///|
test "cron_matches: every-5-minutes at minute=30" {
  // minute=30, 30 % 5 == 0 → match
  let dt = @tools.unix_ms_to_datetime(1772505000000L)
  let expr = @tools.parse_cron("*/5 * * * *").unwrap()
  inspect(@tools.cron_matches(expr, dt), content="true")
}

///|
test "cron_matches: specific minute no match" {
  // minute=30, cron says minute=15 → no match
  let dt = @tools.unix_ms_to_datetime(1772505000000L)
  let expr = @tools.parse_cron("15 * * * *").unwrap()
  inspect(@tools.cron_matches(expr, dt), content="false")
}

///|
test "cron_matches: specific minute match" {
  // minute=30, cron says minute=30 → match
  let dt = @tools.unix_ms_to_datetime(1772505000000L)
  let expr = @tools.parse_cron("30 * * * *").unwrap()
  inspect(@tools.cron_matches(expr, dt), content="true")
}

///|
test "cron_matches: specific hour and minute" {
  // 10:30 CST → hour=10, minute=30
  let dt = @tools.unix_ms_to_datetime(1772505000000L)
  let expr = @tools.parse_cron("30 10 * * *").unwrap()
  inspect(@tools.cron_matches(expr, dt), content="true")
  let expr2 = @tools.parse_cron("30 11 * * *").unwrap()
  inspect(@tools.cron_matches(expr2, dt), content="false")
}

///|
test "parse_interval_seconds: various formats" {
  inspect(@tools.parse_interval_seconds("30m"), content="1800")
  inspect(@tools.parse_interval_seconds("1h"), content="3600")
  inspect(@tools.parse_interval_seconds("2d"), content="172800")
  inspect(@tools.parse_interval_seconds("90s"), content="90")
  inspect(@tools.parse_interval_seconds("invalid"), content="-1")
}
