/// Skill discovery and loading.

/// Metadata for a discovered skill.
pub struct SkillMetadata {
  name : String
  description : String
  location : String
  metadata : Map[String, String]
  source : String
} derive(Show)

/// FFI: list directory entries into buffer, returns total size or -1.
#borrow(path, buf)
extern "C" fn cub_skills_list_dir(
  path : Bytes,
  buf : Bytes,
  buf_size : Int
) -> Int = "cub_skills_list_dir"

/// FFI: read file into buffer, returns file size or -1.
#borrow(path, buf)
extern "C" fn cub_skills_read_file(
  path : Bytes,
  buf : Bytes,
  buf_size : Int
) -> Int = "cub_skills_read_file"

/// Read a file synchronously via C FFI two-pass pattern.
fn read_file_sync(path : String) -> String {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_skills_read_file(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return ""
  }
  let buf = Bytes::new(len)
  let actual = cub_skills_read_file(path_bytes, buf, len)
  if actual <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[:actual])
}

/// List directory entries synchronously via C FFI two-pass pattern.
fn list_dir_sync(path : String) -> Array[String] {
  let path_bytes = @config.string_to_cstr(path)
  let len = cub_skills_list_dir(path_bytes, Bytes::new(0), 0)
  if len <= 0 {
    return []
  }
  let buf = Bytes::new(len)
  let actual = cub_skills_list_dir(path_bytes, buf, len)
  if actual <= 0 {
    return []
  }
  let text = @utf8.decode_lossy(buf[:actual])
  let entries : Array[String] = []
  for part in text.split("\n") {
    let s = part.to_string()
    if s.length() > 0 {
      entries.push(s)
    }
  }
  entries
}

/// Discover skills from workspace and global paths.
/// Three-level discovery: workspace/.agent/skills/, ~/.agent/skills/, builtin.
/// First-match-wins deduplication by name.
pub fn discover_skills(workspace : String) -> Array[SkillMetadata] {
  let seen : Map[String, Bool] = {}
  let skills : Array[SkillMetadata] = []
  // Level 1: workspace skills
  let ws_skills_dir = "\{workspace}/.agent/skills"
  scan_skills_dir(ws_skills_dir, "workspace", seen, skills)
  // Level 2: user-global skills (~/.agent/skills)
  let home = get_home_dir()
  if home.length() > 0 {
    let global_skills_dir = "\{home}/.agent/skills"
    scan_skills_dir(global_skills_dir, "global", seen, skills)
  }
  // Level 3: builtin skills (compiled into the binary via known path)
  // Builtins are discovered from the executable's adjacent skills dir
  // For now, use a hardcoded builtin list
  add_builtin_skills(seen, skills)
  skills
}

/// Get HOME directory via environment variable pattern.
fn get_home_dir() -> String {
  // Use the same FFI pattern as config/settings.mbt
  // We re-use cub_skills_read_file to read /etc/passwd or similar,
  // but simpler: just check HOME env var via a small file trick
  // Actually, we need getenv. Let's use a /proc/self approach or
  // just read from a known path. Simplest: expand ~ via C.
  // For now, read HOME from /proc/self/environ
  let home = read_env_home()
  home
}

/// Read HOME from /proc/self/environ (Linux-specific).
fn read_env_home() -> String {
  let content = read_file_sync("/proc/self/environ")
  if content.is_empty() {
    return ""
  }
  // /proc/self/environ has null-separated KEY=VALUE pairs
  // Since we read as text, nulls become replacement chars or breaks
  // Search for HOME= prefix
  let mut i = 0
  while i < content.length() {
    // Check if we're at start or after a null byte (char 0)
    let at_start = i == 0 || content[i - 1].to_int() == 0
    if at_start {
      // Check for "HOME=" prefix
      if i + 5 < content.length() {
        let matches = content[i].to_int() == 'H'.to_int() &&
          content[i + 1].to_int() == 'O'.to_int() &&
          content[i + 2].to_int() == 'M'.to_int() &&
          content[i + 3].to_int() == 'E'.to_int() &&
          content[i + 4].to_int() == '='.to_int()
        if matches {
          // Extract value until null or end
          let start = i + 5
          let mut end = start
          while end < content.length() && content[end].to_int() != 0 {
            end += 1
          }
          return try { content[start:end].to_string() } catch { _ => "" }
        }
      }
    }
    i += 1
  }
  ""
}

/// Scan a skills directory for subdirectories containing SKILL.md.
fn scan_skills_dir(
  dir : String,
  source : String,
  seen : Map[String, Bool],
  skills : Array[SkillMetadata]
) -> Unit {
  let entries = list_dir_sync(dir)
  for entry in entries {
    let skill_dir = "\{dir}/\{entry}"
    let skill_md_path = "\{skill_dir}/SKILL.md"
    let content = read_file_sync(skill_md_path)
    if content.is_empty() {
      continue
    }
    let (meta, _body) = parse_frontmatter(content)
    let name = match meta.get("name") {
      Some(n) => n
      None => entry
    }
    // First-match-wins deduplication (case-insensitive)
    let key = name.to_lower()
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    let description = match meta.get("description") {
      Some(d) => d
      None => ""
    }
    // Extract nested metadata entries (channel, etc.)
    let skill_metadata : Map[String, String] = {}
    for k, v in meta {
      if k != "name" && k != "description" {
        skill_metadata[k] = v
      }
    }
    skills.push(
      {
        name,
        description,
        location: skill_dir,
        metadata: skill_metadata,
        source,
      },
    )
  }
}

/// Add builtin skills.
fn add_builtin_skills(
  seen : Map[String, Bool],
  skills : Array[SkillMetadata]
) -> Unit {
  // Regular skills
  let builtins : Array[(String, String)] = [
    ("cub", "Delegate sub-tasks to a child cub process"),
    ("gh", "GitHub CLI operations: PRs, issues, repos, workflows"),
    ("commit", "Git commit workflow with conventional commits"),
    ("review", "Code review checklist and structured findings"),
    ("skill-creator", "Guide for creating new SKILL.md skills"),
    ("skill-installer", "Install community skills via npx @anthropic/skills"),
  ]
  for pair in builtins {
    let (name, desc) = pair
    let key = name.to_lower()
    if not(seen.contains(key)) {
      seen[key] = true
      skills.push(
        {
          name,
          description: desc,
          location: "builtin:\{name}",
          metadata: {},
          source: "builtin",
        },
      )
    }
  }
  // Channel skills
  let channel_builtins : Array[(String, String, String)] = [
    ("discord", "Discord bot integration: message formatting, embeds, reactions", "discord"),
    ("telegram", "Telegram bot integration: message formatting, commands, inline keyboards", "telegram"),
  ]
  for triple in channel_builtins {
    let (name, desc, channel) = triple
    let key = name.to_lower()
    if not(seen.contains(key)) {
      seen[key] = true
      let meta : Map[String, String] = {}
      meta["metadata.channel"] = channel
      skills.push(
        {
          name,
          description: desc,
          location: "builtin:\{name}",
          metadata: meta,
          source: "builtin",
        },
      )
    }
  }
}

/// Parse YAML-like frontmatter from a SKILL.md file.
/// Returns (metadata_map, body_text).
pub fn parse_frontmatter(content : String) -> (Map[String, String], String) {
  let meta : Map[String, String] = {}
  // Must start with ---
  if content.length() < 3 {
    return (meta, content)
  }
  let starts_with_delim = content[0].to_int() == '-'.to_int() &&
    content[1].to_int() == '-'.to_int() &&
    content[2].to_int() == '-'.to_int()
  if not(starts_with_delim) {
    return (meta, content)
  }
  // Find end delimiter ---
  let mut end_pos = -1
  let mut i = 3
  // Skip rest of first --- line
  while i < content.length() && content[i].to_int() != '\n'.to_int() {
    i += 1
  }
  if i < content.length() {
    i += 1 // skip newline
  }
  let fm_start = i
  // Search for closing ---
  while i < content.length() {
    // Check if line starts with ---
    let at_line_start = i == 0 || content[i - 1].to_int() == '\n'.to_int()
    if at_line_start && i + 2 < content.length() &&
      content[i].to_int() == '-'.to_int() &&
      content[i + 1].to_int() == '-'.to_int() &&
      content[i + 2].to_int() == '-'.to_int() {
      end_pos = i
      break
    }
    i += 1
  }
  if end_pos < 0 {
    return (meta, content)
  }
  // Extract frontmatter text and body
  let fm_text = try {
    content[fm_start:end_pos].to_string()
  } catch {
    _ => return (meta, content)
  }
  // Body starts after the closing --- line
  let mut body_start = end_pos + 3
  while body_start < content.length() &&
    content[body_start].to_int() != '\n'.to_int() {
    body_start += 1
  }
  if body_start < content.length() {
    body_start += 1
  }
  let body = try {
    content[body_start:].to_string()
  } catch {
    _ => ""
  }
  // Parse frontmatter key: value pairs
  let mut current_nested_prefix = ""
  for line in fm_text.split("\n") {
    let line_str = line.to_string()
    let trimmed = line_str.trim().to_string()
    if trimmed.is_empty() {
      continue
    }
    // Check if this is a nested block header (e.g., "metadata:")
    let is_indented = line_str.length() > 0 &&
      (line_str[0].to_int() == ' '.to_int() ||
      line_str[0].to_int() == '\t'.to_int())
    if not(is_indented) && trimmed[trimmed.length() - 1].to_int() ==
      ':'.to_int() {
      // Check if there's no value after the colon (block header)
      let colon_idx = find_char(trimmed, ':')
      if colon_idx >= 0 && colon_idx == trimmed.length() - 1 {
        current_nested_prefix = try {
          trimmed[:colon_idx].to_string()
        } catch {
          _ => ""
        }
        continue
      }
    }
    // Parse key: value
    let colon_idx = find_char(trimmed, ':')
    if colon_idx > 0 {
      let key = try {
        trimmed[:colon_idx].to_string().trim().to_string()
      } catch {
        _ => continue
      }
      let value = try {
        trimmed[(colon_idx + 1):].to_string().trim().to_string()
      } catch {
        _ => continue
      }
      if is_indented && current_nested_prefix.length() > 0 {
        meta["\{current_nested_prefix}.\{key}"] = value
      } else {
        current_nested_prefix = ""
        meta[key] = value
      }
    }
  }
  (meta, body)
}

/// Find the first occurrence of a char in a string. Returns -1 if not found.
fn find_char(s : String, ch : Char) -> Int {
  let target = ch.to_int()
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == target {
      return i
    }
  }
  -1
}

/// Load the full SKILL.md body for a skill name.
/// Searches workspace, global, and builtin skill locations.
pub fn load_skill_body(name : String, workspace : String) -> String? {
  let lower_name = name.to_lower()
  // Search in order: workspace, global, builtin
  let dirs : Array[(String, String)] = []
  dirs.push((workspace + "/.agent/skills", "workspace"))
  let home = get_home_dir()
  if home.length() > 0 {
    dirs.push((home + "/.agent/skills", "global"))
  }
  // Check each directory (try both original and lowercase name)
  for pair in dirs {
    let (dir, _source) = pair
    // Try original name first
    let skill_md_path = "\{dir}/\{name}/SKILL.md"
    let content = read_file_sync(skill_md_path)
    if content.length() > 0 {
      let (_meta, body) = parse_frontmatter(content)
      return Some(body)
    }
    // Try lowercase name
    if lower_name != name {
      let lower_path = "\{dir}/\{lower_name}/SKILL.md"
      let lower_content = read_file_sync(lower_path)
      if lower_content.length() > 0 {
        let (_meta, body) = parse_frontmatter(lower_content)
        return Some(body)
      }
    }
  }
  // Check builtin (case-insensitive)
  let builtin_body = load_builtin_skill_body(lower_name)
  if builtin_body.length() > 0 {
    return Some(builtin_body)
  }
  None
}

/// Load body for a builtin skill.
fn load_builtin_skill_body(name : String) -> String {
  match name {
    "cub" => cub_skill_body()
    "gh" => gh_skill_body()
    "commit" => commit_skill_body()
    "review" => review_skill_body()
    "skill-creator" => skill_creator_skill_body()
    "skill-installer" => skill_installer_skill_body()
    "discord" => discord_skill_body()
    "telegram" => telegram_skill_body()
    _ => ""
  }
}

/// Body for the builtin cub skill.
fn cub_skill_body() -> String {
  let body =
    #|You can delegate sub-tasks to a child cub process using `cub run '<prompt>'`.
    #|
    #|Use this when:
    #|- A task is independent and can be handled in isolation
    #|- You want to parallelize work across multiple sub-agents
    #|- The sub-task has a clear, self-contained objective
    #|
    #|Example: `cub run 'summarize the file README.md'`
    #|
    #|The child process inherits the current workspace and settings.
  body
}

/// Body for the builtin gh skill.
fn gh_skill_body() -> String {
  let body =
    #|# GitHub CLI (`gh`) Operations
    #|
    #|Use the `gh` CLI tool for GitHub operations. Always check auth first with `gh auth status`.
    #|
    #|## Common Workflows
    #|
    #|### Pull Requests
    #|```bash
    #|gh pr create --title "title" --body "description"
    #|gh pr list --state open
    #|gh pr view <number>
    #|gh pr merge <number> --squash
    #|gh pr checkout <number>
    #|```
    #|
    #|### Issues
    #|```bash
    #|gh issue create --title "title" --body "description"
    #|gh issue list --state open --label "bug"
    #|gh issue close <number>
    #|```
    #|
    #|### Repository
    #|```bash
    #|gh repo view
    #|gh repo clone <owner/repo>
    #|gh release create <tag> --generate-notes
    #|```
    #|
    #|### API (for advanced queries)
    #|```bash
    #|gh api repos/{owner}/{repo}/pulls --jq '.[].title'
    #|gh api graphql -f query='{ viewer { login } }'
    #|```
    #|
    #|## Tips
    #|- Use `--json` flag for structured output: `gh pr list --json number,title,state`
    #|- Use `--jq` for filtering: `gh pr list --json title --jq '.[].title'`
    #|- Set `GH_REPO` env var to avoid specifying repo each time
  body
}

/// Body for the builtin commit skill.
fn commit_skill_body() -> String {
  let body =
    #|# Git Commit Workflow
    #|
    #|## Steps
    #|1. Review changes: `git diff --staged` (or `git diff` for unstaged)
    #|2. Stage files: `git add <specific-files>` (avoid `git add .`)
    #|3. Write commit message following conventional commits
    #|4. Commit: `git commit -m "type(scope): description"`
    #|
    #|## Conventional Commits Format
    #|```
    #|<type>(<scope>): <description>
    #|
    #|[optional body]
    #|```
    #|
    #|### Types
    #|- `feat`: new feature
    #|- `fix`: bug fix
    #|- `docs`: documentation only
    #|- `style`: formatting, no code change
    #|- `refactor`: code change that neither fixes nor adds
    #|- `perf`: performance improvement
    #|- `test`: adding or correcting tests
    #|- `chore`: maintenance tasks
    #|
    #|## Rules
    #|- Keep subject line under 72 characters
    #|- Use imperative mood: "add feature" not "added feature"
    #|- Don't end subject with period
    #|- Separate subject from body with blank line
    #|- Review diff before committing to ensure no secrets or debug code
    #|- Prefer specific file staging over `git add .`
  body
}

/// Body for the builtin review skill.
fn review_skill_body() -> String {
  let body =
    #|# Code Review Checklist
    #|
    #|When reviewing code, check the following areas systematically:
    #|
    #|## 1. Correctness
    #|- Does the code do what it claims to do?
    #|- Are edge cases handled (null, empty, overflow, concurrent access)?
    #|- Are error conditions handled properly?
    #|
    #|## 2. Security
    #|- No hardcoded secrets, tokens, or credentials
    #|- Input validation at system boundaries
    #|- No SQL injection, XSS, or command injection
    #|- Proper authentication/authorization checks
    #|
    #|## 3. Performance
    #|- No unnecessary allocations in hot paths
    #|- Appropriate data structures for the use case
    #|- No N+1 queries or unbounded loops
    #|- Resource cleanup (file handles, connections)
    #|
    #|## 4. Readability
    #|- Clear naming for variables, functions, types
    #|- Appropriate comments for non-obvious logic
    #|- Consistent style with the rest of the codebase
    #|- Functions are focused (single responsibility)
    #|
    #|## 5. Testing
    #|- Are critical paths covered by tests?
    #|- Do tests verify behavior, not implementation?
    #|- Are test names descriptive?
    #|
    #|## Output Format
    #|For each finding:
    #|```
    #|[severity] file:line — description
    #|  suggestion: how to fix
    #|```
    #|Severity: CRITICAL, WARNING, INFO, STYLE
  body
}

/// Body for the builtin skill-creator skill.
fn skill_creator_skill_body() -> String {
  let body =
    #|# Creating a New Skill
    #|
    #|## Directory Structure
    #|```
    #|.agent/skills/<skill-name>/
    #|  SKILL.md          # Required: frontmatter + instructions
    #|  scripts/           # Optional: executable scripts
    #|  references/        # Optional: additional docs
    #|```
    #|
    #|## SKILL.md Format
    #|```markdown
    #|---
    #|name: my-skill
    #|description: What the skill does and when to use it.
    #|metadata:
    #|  channel: discord    # optional, for channel-specific skills
    #|---
    #|
    #|# Skill Title
    #|
    #|Instructions for the agent when this skill is activated.
    #|```
    #|
    #|## Best Practices
    #|- **Description is key**: it determines when the skill gets activated via `$hint`
    #|- Keep SKILL.md under 500 lines
    #|- Use progressive disclosure: reference separate files for detail
    #|- Include concrete examples and command templates
    #|- Scope: project skills in `.agent/skills/`, global in `~/.agent/skills/`
    #|
    #|## Skill Levels
    #|1. **Project** (`.agent/skills/`): workspace-specific, highest priority
    #|2. **Global** (`~/.agent/skills/`): user-wide, shared across projects
    #|3. **Builtin**: shipped with cub, lowest priority
    #|
    #|Project skills override global skills with the same name.
  body
}

/// Body for the builtin skill-installer skill.
fn skill_installer_skill_body() -> String {
  let body =
    #|# Install Community Skills
    #|
    #|Use `npx @anthropic/skills` to browse and install community skills.
    #|
    #|## Quick Install
    #|```bash
    #|# Browse available skills
    #|npx @anthropic/skills list
    #|
    #|# Install a skill to the current project
    #|npx @anthropic/skills install <skill-name>
    #|
    #|# Install globally
    #|npx @anthropic/skills install <skill-name> --global
    #|```
    #|
    #|## What It Does
    #|- Downloads the skill's SKILL.md and supporting files
    #|- Places them in `.agent/skills/<name>/` (project) or `~/.agent/skills/<name>/` (global)
    #|- The skill becomes available immediately via `,skills.list`
    #|
    #|## Manual Install
    #|You can also create skills manually:
    #|1. Create `.agent/skills/<name>/SKILL.md`
    #|2. Add frontmatter with `name` and `description`
    #|3. Write instructions in the body
    #|
    #|See the `skill-creator` skill for detailed guidance.
  body
}

/// Body for the builtin telegram channel skill.
fn telegram_skill_body() -> String {
  let body =
    #|# Telegram Channel Integration
    #|
    #|You are operating in a Telegram channel. Follow these guidelines:
    #|
    #|## Message Formatting
    #|- Telegram supports Markdown: **bold**, _italic_, `code`, ```code blocks```
    #|- Max message length is 4096 characters
    #|- Use code blocks with language hints: ```python, ```bash, etc.
    #|- Mentions: @username
    #|
    #|## Response Style
    #|- Keep responses concise — Telegram is a chat interface
    #|- Use bullet points and short paragraphs
    #|- For long output, summarize first then offer details on request
    #|- Avoid walls of text — break into multiple messages if needed
    #|
    #|## Behavioral Rules
    #|- Respond only to messages directed at the bot
    #|- Do not tag or mention users unless explicitly asked
    #|- Do not send empty messages
    #|- If a tool call produces very long output, summarize it
    #|
    #|## Telegram Bot API Notes
    #|- Use `sendMessage` with `parse_mode: "Markdown"` for formatted text
    #|- For inline keyboards, use `reply_markup` with `InlineKeyboardMarkup`
    #|- Long-polling via `getUpdates` with `timeout` parameter
    #|- Handle `/start` and `/help` commands as standard bot commands
  body
}

/// Body for the builtin discord channel skill.
fn discord_skill_body() -> String {
  let body =
    #|# Discord Channel Integration
    #|
    #|You are operating in a Discord channel. Follow these guidelines:
    #|
    #|## Message Formatting
    #|- Discord uses Markdown: **bold**, *italic*, `code`, ```code blocks```
    #|- Max message length is 2000 characters (auto-chunked by runtime)
    #|- Use code blocks with language hints: ```python, ```bash, etc.
    #|- Mentions: <@user_id>, <#channel_id>, <@&role_id>
    #|
    #|## Response Style
    #|- Keep responses concise — Discord is a chat interface, not a document
    #|- Use bullet points and short paragraphs
    #|- For long output, summarize first then offer details on request
    #|- Avoid walls of text — break into multiple focused messages if needed
    #|
    #|## Behavioral Rules
    #|- Respond only to messages directed at you (containing "cub" or using prefix)
    #|- Do not tag or mention users unless explicitly asked
    #|- Do not send empty messages
    #|- If a tool call produces very long output, summarize it
  body
}
