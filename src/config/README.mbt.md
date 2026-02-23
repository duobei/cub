# Config — Settings and Environment Parsing

The `config` package handles loading configuration from environment variables
and `.env` files. All settings use the `CUB_` prefix convention.

## Parsing .env Files

```mbt nocheck
///|
test "parse dotenv content" {
  let content =
    #|# Database config
    #|DB_HOST=localhost
    #|DB_PORT=5432
    #|SECRET="my secret value"
  let env = @config.parse_dotenv(content)
  inspect(env.get("DB_HOST"), content="Some(\"localhost\")")
  inspect(env.get("DB_PORT"), content="Some(\"5432\")")
  inspect(env.get("SECRET"), content="Some(\"my secret value\")")
}
```

## Parsing Individual Lines

```mbt nocheck
///|
test "parse dotenv lines" {
  // Key=value pair
  inspect(
    @config.parse_dotenv_line("KEY=value"),
    content="Some((\"KEY\", \"value\"))",
  )
  // Comments return None
  inspect(@config.parse_dotenv_line("# comment") is None, content="true")
  // Empty lines return None
  inspect(@config.parse_dotenv_line("") is None, content="true")
}
```

## Environment Parsing Helpers

```mbt nocheck
///|
test "parse boolean env vars" {
  let env : Map[String, String] = { "ENABLED": "true", "DEBUG": "0" }
  inspect(@config.get_env_bool(env, "ENABLED"), content="Some(true)")
  inspect(@config.get_env_bool(env, "DEBUG"), content="Some(false)")
  inspect(@config.get_env_bool(env, "MISSING") is None, content="true")
}

///|
test "parse integer env vars" {
  let env : Map[String, String] = { "PORT": "8080" }
  inspect(@config.get_env_int(env, "PORT"), content="Some(8080)")
  inspect(@config.get_env_int(env, "MISSING") is None, content="true")
}

///|
test "parse list env vars" {
  let env : Map[String, String] = { "ITEMS": "a,b,c" }
  let items = @config.get_env_list(env, "ITEMS")
  inspect(items.length(), content="3")
}
```

## Default Settings

```mbt nocheck
///|
test "default settings" {
  let settings = @config.Settings::default()
  inspect(settings.max_tokens, content="1024")
  inspect(settings.max_steps, content="100")
  inspect(settings.rate_limit_per_minute, content="10")
  inspect(settings.context_budget, content="128000")
  inspect(settings.tape_name, content="cub")
}
```
