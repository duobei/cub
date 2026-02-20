/// Skill prompt rendering.

/// Render skill prompt section for system prompt.
/// Produces <channel_skills> and <available_skills> blocks.
pub fn render_skill_prompt(skills : Array[SkillMetadata]) -> String {
  if skills.length() == 0 {
    return ""
  }
  let channel_skills : Array[SkillMetadata] = []
  let regular_skills : Array[SkillMetadata] = []
  for skill in skills {
    if skill.metadata.contains("channel") {
      channel_skills.push(skill)
    } else {
      regular_skills.push(skill)
    }
  }
  let buf = StringBuilder::new()
  // Channel skills block
  if channel_skills.length() > 0 {
    buf.write_string("<channel_skills>\n")
    for skill in channel_skills {
      buf.write_string("- ")
      buf.write_string(skill.name)
      if skill.description.length() > 0 {
        buf.write_string(": ")
        buf.write_string(skill.description)
      }
      buf.write_string(" [")
      buf.write_string(skill.source)
      buf.write_string("]\n")
    }
    buf.write_string("</channel_skills>")
  }
  // Regular skills block
  if regular_skills.length() > 0 {
    if channel_skills.length() > 0 {
      buf.write_string("\n\n")
    }
    buf.write_string("<available_skills>\n")
    buf.write_string(
      "Use '$name' hint to expand a skill's instructions.\n\n",
    )
    for skill in regular_skills {
      buf.write_string("- ")
      buf.write_string(skill.name)
      if skill.description.length() > 0 {
        buf.write_string(": ")
        buf.write_string(skill.description)
      }
      buf.write_string(" [")
      buf.write_string(skill.source)
      buf.write_string("]\n")
    }
    buf.write_string("</available_skills>")
  }
  buf.to_string()
}

/// Render expanded skill body blocks for activated skills.
pub fn render_expanded_skills(expanded : Map[String, String]) -> String {
  if expanded.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  let mut first = true
  for name, body in expanded {
    if not(first) {
      buf.write_string("\n\n")
    }
    buf.write_string("<skill name=\"")
    buf.write_string(name)
    buf.write_string("\">\n")
    buf.write_string(body)
    buf.write_string("\n</skill>")
    first = false
  }
  buf.to_string()
}
