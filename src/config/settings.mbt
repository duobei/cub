/// Application settings loaded from environment variables and .env files.

/// FFI: copy env var into buffer, returns length or -1 if not set.
#borrow(name, buf)
extern "C" fn cub_getenv(name : Bytes, buf : Bytes, buf_size : Int) -> Int = "cub_getenv"

/// Get an environment variable by name. Returns None if not set.
pub fn getenv(name : String) -> String? {
  let name_bytes = string_to_cstr(name)
  // First call to get length
  let len = cub_getenv(name_bytes, Bytes::new(0), 0)
  if len < 0 {
    return None
  }
  if len == 0 {
    return Some("")
  }
  // Second call to get value
  let buf = Bytes::new(len)
  let _ = cub_getenv(name_bytes, buf, len)
  Some(@utf8.decode_lossy(buf[:len]))
}

/// Convert a MoonBit String to a null-terminated UTF-8 byte array for C.
fn string_to_cstr(s : String) -> Bytes {
  let utf8 = @utf8.encode(s)
  let len = utf8.length()
  // Build with extra byte for null terminator
  Bytes::makei(len + 1, fn(i) {
    if i < len { utf8[i] } else { b'\x00' }
  })
}

/// Collect all relevant environment variables into a Map.
pub fn collect_env_vars() -> Map[String, String] {
  let env : Map[String, String] = {}
  let keys = [
    "BUB_MODEL", "BUB_API_KEY", "BUB_API_BASE", "BUB_OLLAMA_API_KEY",
    "BUB_OLLAMA_API_BASE", "LLM_API_KEY", "OPENROUTER_API_KEY",
    "BUB_MAX_TOKENS", "BUB_MODEL_TIMEOUT_SECONDS", "BUB_SYSTEM_PROMPT",
    "BUB_HOME", "BUB_WORKSPACE_PATH", "BUB_TAPE_NAME", "BUB_MAX_STEPS",
    "BUB_PROACTIVE_RESPONSE", "BUB_TELEGRAM_ENABLED", "BUB_TELEGRAM_TOKEN",
    "BUB_TELEGRAM_ALLOW_FROM", "BUB_TELEGRAM_ALLOW_CHATS", "BUB_TELEGRAM_PROXY",
    "BUB_DISCORD_ENABLED", "BUB_DISCORD_TOKEN", "BUB_DISCORD_ALLOW_FROM",
    "BUB_DISCORD_ALLOW_CHANNELS", "BUB_DISCORD_COMMAND_PREFIX", "BUB_DISCORD_PROXY",
    "HOME", "PWD",
  ]
  for key in keys {
    match getenv(key) {
      Some(v) => env[key] = v
      None => ()
    }
  }
  env
}

/// Runtime settings for cub.
pub struct Settings {
  model : String
  api_key : String?
  api_base : String?
  ollama_api_key : String?
  ollama_api_base : String?
  llm_api_key : String?
  openrouter_api_key : String?
  max_tokens : Int
  model_timeout_seconds : Int?
  system_prompt : String
  home : String?
  workspace_path : String?
  tape_name : String
  max_steps : Int
  proactive_response : Bool
  telegram_enabled : Bool
  telegram_token : String?
  telegram_allow_from : Array[String]
  telegram_allow_chats : Array[String]
  telegram_proxy : String?
  discord_enabled : Bool
  discord_token : String?
  discord_allow_from : Array[String]
  discord_allow_channels : Array[String]
  discord_command_prefix : String
  discord_proxy : String?
} derive(Show)

/// Create default settings.
pub fn Settings::default() -> Settings {
  {
    model: "openrouter:qwen/qwen3-coder-next",
    api_key: None,
    api_base: None,
    ollama_api_key: None,
    ollama_api_base: None,
    llm_api_key: None,
    openrouter_api_key: None,
    max_tokens: 1024,
    model_timeout_seconds: Some(90),
    system_prompt: "",
    home: None,
    workspace_path: None,
    tape_name: "bub",
    max_steps: 20,
    proactive_response: false,
    telegram_enabled: false,
    telegram_token: None,
    telegram_allow_from: [],
    telegram_allow_chats: [],
    telegram_proxy: None,
    discord_enabled: false,
    discord_token: None,
    discord_allow_from: [],
    discord_allow_channels: [],
    discord_command_prefix: "!",
    discord_proxy: None,
  }
}

/// Create a new Settings with optional overrides applied.
pub fn Settings::with_overrides(
  self : Settings,
  model~ : String? = None,
  max_tokens~ : Int? = None,
  system_prompt~ : String? = None
) -> Settings {
  {
    ..self,
    model: match model {
      Some(m) => m
      None => self.model
    },
    max_tokens: match max_tokens {
      Some(t) => t
      None => self.max_tokens
    },
    system_prompt: match system_prompt {
      Some(p) => p
      None => self.system_prompt
    },
  }
}

/// Resolve the API key with cascade: api_key > llm_api_key > openrouter_api_key > env vars.
pub fn Settings::resolved_api_key(self : Settings) -> String? {
  if self.api_key is Some(k) {
    return Some(k)
  }
  if self.llm_api_key is Some(k) {
    return Some(k)
  }
  if self.openrouter_api_key is Some(k) {
    return Some(k)
  }
  if getenv("LLM_API_KEY") is Some(k) {
    return Some(k)
  }
  if getenv("OPENROUTER_API_KEY") is Some(k) {
    return Some(k)
  }
  None
}

/// Resolve home directory, default to ~/.bub.
pub fn Settings::resolve_home(self : Settings) -> String {
  match self.home {
    Some(h) => h
    None => {
      let home = getenv("HOME").unwrap_or(".")
      home + "/.bub"
    }
  }
}

/// Get an optional env var.
fn get_env(env : Map[String, String], key : String) -> String? {
  env.get(key)
}

/// Get an env var as bool.
fn get_env_bool(env : Map[String, String], key : String) -> Bool? {
  match env.get(key) {
    Some("true") | Some("1") | Some("yes") | Some("TRUE") | Some("True") =>
      Some(true)
    Some("false") | Some("0") | Some("no") | Some("FALSE") | Some("False") =>
      Some(false)
    _ => None
  }
}

/// Get an env var as int.
fn get_env_int(env : Map[String, String], key : String) -> Int? {
  match env.get(key) {
    Some(s) =>
      try {
        Some(@strconv.parse_int(s))
      } catch {
        _ => None
      }
    None => None
  }
}

/// Parse a comma-separated list from an env var.
fn get_env_list(env : Map[String, String], key : String) -> Array[String] {
  match env.get(key) {
    Some(s) => {
      let trimmed = s.trim(chars=" \t").to_string()
      // Try JSON array first
      if trimmed.length() >= 2 && trimmed[0] == '['.to_int().to_uint16() {
        let parsed = try { @json.parse(trimmed) } catch { _ => Json::null() }
        match parsed {
          Array(items) => {
            let result : Array[String] = []
            for item in items {
              match item {
                String(v) => result.push(v)
                _ => ()
              }
            }
            return result
          }
          _ => ()
        }
      }
      // Fallback: comma-separated
      let parts : Array[String] = []
      let current = StringBuilder::new()
      for ch in s {
        if ch == ',' {
          let part = current.to_string().trim(chars=" ").to_string()
          if part.length() > 0 {
            parts.push(part)
          }
          current.reset()
        } else {
          current.write_char(ch)
        }
      }
      let last = current.to_string().trim(chars=" ").to_string()
      if last.length() > 0 {
        parts.push(last)
      }
      parts
    }
    None => []
  }
}

/// Parse a single dotenv line into (key, value). Returns None on skip.
fn parse_dotenv_line(line : StringView) -> (String, String)? {
  let trimmed = line.trim(chars=" \t\r")
  if trimmed.length() == 0 || trimmed.has_prefix("#") {
    return None
  }
  // Find first = sign
  let mut eq_pos = -1
  for i, ch in trimmed {
    if ch == '=' {
      eq_pos = i
      break
    }
  }
  if eq_pos < 0 {
    return None
  }
  let trimmed_str = trimmed.to_string()
  try {
    let key = trimmed_str[:eq_pos].to_string().trim(chars=" \t").to_string()
    let value_str = trimmed_str[eq_pos + 1:].to_string()
    let value_trimmed = value_str.trim(chars=" \t")
    // Strip surrounding quotes
    let value = if value_trimmed.length() >= 2 {
      let vt = value_trimmed.to_string()
      let first = vt[0]
      let last = vt[vt.length() - 1]
      if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
        vt[1:vt.length() - 1].to_string()
      } else {
        vt
      }
    } else {
      value_trimmed.to_string()
    }
    Some((key, value))
  } catch {
    _ => None
  }
}

/// Parse a simple .env file content into key-value pairs.
pub fn parse_dotenv(content : String) -> Map[String, String] {
  let result : Map[String, String] = {}
  for line in content.split("\n") {
    match parse_dotenv_line(line) {
      Some((k, v)) => result[k] = v
      None => ()
    }
  }
  result
}

/// Load settings from environment variables (with BUB_ prefix) and optional .env file.
pub async fn load_settings(workspace_path~ : String? = None) -> Settings {
  let env = collect_env_vars()
  // Try loading .env file
  let dotenv = try {
    let content = @fs.read_file(".env")
    parse_dotenv(content.text())
  } catch {
    _ => Map::new()
  }
  // Merge dotenv into a combined map, env vars take precedence
  let combined : Map[String, String] = {}
  for k, v in dotenv {
    combined[k] = v
  }
  for k, v in env {
    combined[k] = v
  }
  let defaults = Settings::default()
  {
    model: get_env(combined, "BUB_MODEL").unwrap_or(defaults.model),
    api_key: get_env(combined, "BUB_API_KEY"),
    api_base: get_env(combined, "BUB_API_BASE"),
    ollama_api_key: get_env(combined, "BUB_OLLAMA_API_KEY"),
    ollama_api_base: get_env(combined, "BUB_OLLAMA_API_BASE"),
    llm_api_key: get_env(combined, "LLM_API_KEY"),
    openrouter_api_key: get_env(combined, "OPENROUTER_API_KEY"),
    max_tokens: get_env_int(combined, "BUB_MAX_TOKENS").unwrap_or(defaults.max_tokens),
    model_timeout_seconds: match get_env_int(combined, "BUB_MODEL_TIMEOUT_SECONDS") {
      Some(v) => Some(v)
      None => defaults.model_timeout_seconds
    },
    system_prompt: get_env(combined, "BUB_SYSTEM_PROMPT").unwrap_or(defaults.system_prompt),
    home: get_env(combined, "BUB_HOME"),
    workspace_path: match workspace_path {
      Some(p) => Some(p)
      None => get_env(combined, "BUB_WORKSPACE_PATH")
    },
    tape_name: get_env(combined, "BUB_TAPE_NAME").unwrap_or(defaults.tape_name),
    max_steps: get_env_int(combined, "BUB_MAX_STEPS").unwrap_or(defaults.max_steps),
    proactive_response: get_env_bool(combined, "BUB_PROACTIVE_RESPONSE").unwrap_or(
      defaults.proactive_response,
    ),
    telegram_enabled: get_env_bool(combined, "BUB_TELEGRAM_ENABLED").unwrap_or(
      defaults.telegram_enabled,
    ),
    telegram_token: get_env(combined, "BUB_TELEGRAM_TOKEN"),
    telegram_allow_from: {
      let l = get_env_list(combined, "BUB_TELEGRAM_ALLOW_FROM")
      if l.length() > 0 { l } else { defaults.telegram_allow_from }
    },
    telegram_allow_chats: {
      let l = get_env_list(combined, "BUB_TELEGRAM_ALLOW_CHATS")
      if l.length() > 0 { l } else { defaults.telegram_allow_chats }
    },
    telegram_proxy: get_env(combined, "BUB_TELEGRAM_PROXY"),
    discord_enabled: get_env_bool(combined, "BUB_DISCORD_ENABLED").unwrap_or(
      defaults.discord_enabled,
    ),
    discord_token: get_env(combined, "BUB_DISCORD_TOKEN"),
    discord_allow_from: {
      let l = get_env_list(combined, "BUB_DISCORD_ALLOW_FROM")
      if l.length() > 0 { l } else { defaults.discord_allow_from }
    },
    discord_allow_channels: {
      let l = get_env_list(combined, "BUB_DISCORD_ALLOW_CHANNELS")
      if l.length() > 0 { l } else { defaults.discord_allow_channels }
    },
    discord_command_prefix: get_env(combined, "BUB_DISCORD_COMMAND_PREFIX").unwrap_or(
      defaults.discord_command_prefix,
    ),
    discord_proxy: get_env(combined, "BUB_DISCORD_PROXY"),
  }
}
