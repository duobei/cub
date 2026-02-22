/// MCP (Model Context Protocol) types.

///|
/// MCP server configuration.
pub struct McpServerConfig {
  name : String
  command : String
  args : Array[String]
  env : Map[String, String]
} derive(Show)

///|
/// MCP tool descriptor discovered from a server.
pub struct McpTool {
  name : String
  description : String
  input_schema : Json
} derive(Show)

///|
/// MCP client state for a single server.
pub struct McpClient {
  config : McpServerConfig
  mut slot : Int
  mut request_id : Int
  mut initialized : Bool
  tools : Array[McpTool]
} derive(Show)
