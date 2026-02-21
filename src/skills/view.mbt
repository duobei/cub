/// Skill prompt rendering.

/// Format a skill entry as a list item.
fn format_skill_entry(skill : SkillMetadata) -> String {
  let desc = if skill.description.length() > 0 { ": \{skill.description}" } else { "" }
  "- \{skill.name}\{desc} [\{skill.source}]"
}

/// Render skill prompt section for system prompt.
/// Produces <channel_skills> and <available_skills> blocks.
pub fn render_skill_prompt(skills : Array[SkillMetadata]) -> String {
  if skills.is_empty() {
    return ""
  }
  let is_channel = fn(s : SkillMetadata) {
    s.metadata.contains("channel") || s.metadata.contains("metadata.channel")
  }
  let channel_skills = skills.filter(is_channel)
  let regular_skills = skills.filter(fn(s) { not(is_channel(s)) })
  let blocks : Array[String] = []
  if not(channel_skills.is_empty()) {
    let lines = channel_skills.map(format_skill_entry).join("\n")
    blocks.push("<channel_skills>\n\{lines}\n</channel_skills>")
  }
  if not(regular_skills.is_empty()) {
    let lines = regular_skills.map(format_skill_entry).join("\n")
    blocks.push("<available_skills>\nUse '$name' hint to expand a skill's instructions.\n\n\{lines}\n</available_skills>")
  }
  blocks.join("\n\n")
}

/// Render expanded skill body blocks for activated skills.
pub fn render_expanded_skills(expanded : Map[String, String]) -> String {
  if expanded.is_empty() {
    return ""
  }
  let entries : Array[String] = []
  for name, body in expanded {
    entries.push("<skill name=\"\{name}\">\n\{body}\n</skill>")
  }
  entries.join("\n\n")
}
