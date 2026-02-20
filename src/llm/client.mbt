/// LLM client stub.

/// LLM client for OpenAI-compatible chat API.
pub struct LLMClient {
  model : String
  api_key : String
  api_base : String
  extra_headers : Map[String, String]
}

/// Create a new LLMClient.
pub fn LLMClient::new(
  model : String,
  api_key : String,
  api_base~ : String? = None,
  extra_headers~ : Map[String, String] = {}
) -> LLMClient {
  ignore(api_base)
  ignore(extra_headers)
  { model, api_key, api_base: "", extra_headers: {} }
}

/// Make a chat API call.
pub async fn LLMClient::chat(
  self : LLMClient,
  messages : Array[Json],
  tools~ : Array[Json] = [],
  max_tokens~ : Int = 1024,
  system_prompt~ : String? = None
) -> ChatResponse!Error {
  ignore(self)
  ignore(messages)
  ignore(tools)
  ignore(max_tokens)
  ignore(system_prompt)
  abort("LLMClient::chat not implemented")
}

/// Run tools: chat + execute tools + record to tape.
pub async fn LLMClient::run_tools(
  self : LLMClient,
  tape : @tape.Tape,
  prompt : String,
  system_prompt~ : String = "",
  max_tokens~ : Int = 1024,
  tools_json~ : Array[Json] = [],
  execute_tool~ : async (String, Json) -> String!Error
) -> ToolAutoResult!Error {
  ignore(self)
  ignore(tape)
  ignore(prompt)
  ignore(system_prompt)
  ignore(max_tokens)
  ignore(tools_json)
  ignore(execute_tool)
  abort("LLMClient::run_tools not implemented")
}
