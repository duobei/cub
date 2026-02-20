/// Skill discovery and loading stub.

/// Metadata for a discovered skill.
pub struct SkillMetadata {
  name : String
  description : String
  location : String
  metadata : Map[String, String]
  source : String
} derive(Show)

/// Discover skills from workspace and global paths.
pub fn discover_skills(workspace : String) -> Array[SkillMetadata] {
  ignore(workspace)
  []
}

/// Parse YAML-like frontmatter from a SKILL.md file.
pub fn parse_frontmatter(content : String) -> (Map[String, String], String) {
  ignore(content)
  ({}, "")
}

/// Load the full SKILL.md body for a skill name.
pub fn load_skill_body(name : String, workspace : String) -> String? {
  ignore(name)
  ignore(workspace)
  None
}
