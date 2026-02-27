/// SSE streaming chat and think-block filtering for the LLM module.

///|
/// Make a streaming chat API call, calling on_chunk for each content delta.
/// Returns the full accumulated response.
pub async fn LLMClient::chat_streaming(
  self : LLMClient,
  messages : Array[Json],
  tools? : Array[Json] = [],
  max_tokens? : Int = 0,
  system_prompt? : String? = None,
) -> ChatResponse {
  let actual_max_tokens = if max_tokens > 0 {
    max_tokens
  } else {
    self.max_tokens
  }
  let body = self.build_stream_request_body(
    messages, tools, actual_max_tokens, system_prompt,
  )
  let body_str = body.stringify()
  let url = "\{self.api_base}/chat/completions"
  // Build headers
  let headers : Map[String, String] = Map::new()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer \{self.api_key}"
  if self.provider == "openrouter" {
    headers["X-Title"] = "cub"
    headers["HTTP-Referer"] = "https://github.com/duobei/cub"
  }
  for k, v in self.extra_headers {
    headers[k] = v
  }
  // Use post_stream for streaming
  let client = @platform.http_post_stream(url, headers~) catch {
    e =>
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("HTTP stream error: \{e}"),
      }
  }
  // Write request body
  client.write(body_str) catch {
    e => {
      client.close()
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("HTTP write error: \{e}"),
      }
    }
  }
  client.flush() catch {
    _ => ()
  }
  let response = client.end_request() catch {
    e => {
      client.close()
      return {
        text: "",
        tool_calls: [],
        finish_reason: "error",
        usage: None,
        error: Some("HTTP request error: \{e}"),
      }
    }
  }
  if response.code != 200 {
    let err_text = client.read_all() catch { _ => "" }
    let err_str = err_text.text() catch { _ => "HTTP \{response.code}" }
    client.close()
    return {
      text: "",
      tool_calls: [],
      finish_reason: "error",
      usage: None,
      error: Some("API error (\{response.code}): \{err_str}"),
    }
  }
  // Read SSE stream
  let content_buf = StringBuilder::new()
  // For streaming think-block suppression: buffer chunks and only emit non-think content
  let chunk_buf = StringBuilder::new()
  let mut in_think = false
  // For tool calls, we accumulate argument fragments by index
  let tc_ids : Map[Int, String] = {} // index → id
  let tc_names : Map[Int, String] = {} // index → function name
  let tc_args : Map[Int, StringBuilder] = {} // index → accumulated arguments
  let mut finish_reason = "stop"
  let mut stream_usage : TokenUsage? = None
  for {
    let line = client.read_until("\n") catch { _ => break }
    match line {
      None => break
      Some(l) => {
        let trimmed = l.trim().to_string()
        if trimmed.is_empty() {
          continue
        }
        if trimmed == "data: [DONE]" {
          break
        }
        if trimmed.has_prefix("data: ") {
          let json_str = trimmed[6:].to_string() catch { _ => continue }
          let json = @json.parse(json_str) catch { _ => continue }
          // Extract finish_reason
          match json {
            { "choices": [{ "finish_reason": String(fr), .. }, ..], .. } =>
              finish_reason = fr
            _ => ()
          }
          // Extract content delta
          match json {
            {
              "choices": [{ "delta": { "content": String(c), .. }, .. }, ..],
              ..
            } =>
              if c.length() > 0 {
                content_buf.write_string(c)
                // Filter <think> blocks from streaming output
                match self.on_chunk {
                  Some(cb) => {
                    chunk_buf.write_string(c)
                    let buf = chunk_buf.to_string()
                    // Process complete tags in buffer
                    let open_tag = "<think>"
                    let close_tag = "</think>"
                    if in_think {
                      let end_pos = find_substring(buf, close_tag)
                      if end_pos >= 0 {
                        // Think block ended — emit content after close tag
                        in_think = false
                        let after = buf[end_pos + 8:].to_string() catch {
                          _ => ""
                        }
                        chunk_buf.reset()
                        if after.length() > 0 {
                          chunk_buf.write_string(after)
                        }
                      }
                      // else: still inside think block, keep buffering
                    } else {
                      let start_pos = find_substring(buf, open_tag)
                      if start_pos >= 0 {
                        // Think block starting — emit content before it
                        let before = buf[:start_pos].to_string() catch {
                          _ => ""
                        }
                        if before.length() > 0 {
                          cb(before)
                        }
                        in_think = true
                        // Check if close tag is also in this chunk
                        let rest = buf[start_pos + 7:].to_string() catch {
                          _ => ""
                        }
                        let end_pos = find_substring(rest, close_tag)
                        if end_pos >= 0 {
                          in_think = false
                          let after = rest[end_pos + 8:].to_string() catch {
                            _ => ""
                          }
                          chunk_buf.reset()
                          if after.length() > 0 {
                            chunk_buf.write_string(after)
                          }
                        } else {
                          chunk_buf.reset()
                          chunk_buf.write_string(rest)
                        }
                      } else if find_substring(buf, "<") >= 0 &&
                        buf.length() < open_tag.length() {
                        // Partial tag — keep buffering
                        ()
                      } else {
                        // No think tag — emit and clear buffer
                        cb(buf)
                        chunk_buf.reset()
                      }
                    }
                  }
                  None => ()
                }
              }
            _ => ()
          }
          // Extract tool call deltas
          match json {
            {
              "choices": [
                { "delta": { "tool_calls": Array(calls), .. }, .. },
                ..,
              ],
              ..
            } =>
              for call in calls {
                let idx = match call {
                  { "index": Number(n, ..), .. } => n.to_int()
                  _ => 0
                }
                match call {
                  { "id": String(id), .. } => tc_ids[idx] = id
                  _ => ()
                }
                match call {
                  { "function": { "name": String(name), .. }, .. } =>
                    tc_names[idx] = name
                  _ => ()
                }
                match call {
                  { "function": { "arguments": String(args), .. }, .. } => {
                    if not(tc_args.contains(idx)) {
                      tc_args[idx] = StringBuilder::new()
                    }
                    match tc_args.get(idx) {
                      Some(sb) => sb.write_string(args)
                      None => ()
                    }
                  }
                  _ => ()
                }
              }
            _ => ()
          }
          // Extract usage from final chunk
          match json {
            {
              "usage": {
                "prompt_tokens": Number(pt, ..),
                "completion_tokens": Number(ct, ..),
                "total_tokens": Number(tt, ..),
                ..
              },
              ..
            } =>
              stream_usage = Some({
                prompt_tokens: pt.to_int(),
                completion_tokens: ct.to_int(),
                total_tokens: tt.to_int(),
              })
            _ => ()
          }
        }
      }
    }
  }
  client.close()
  // Build tool calls from accumulated fragments
  let tool_calls : Array[ToolCallInfo] = []
  for idx, id in tc_ids {
    let name = tc_names.get(idx).unwrap_or("")
    let args = match tc_args.get(idx) {
      Some(sb) => sb.to_string()
      None => ""
    }
    tool_calls.push({
      id,
      type_: "function",
      function_: { name, arguments: args },
    })
  }
  let text = strip_think_tags(content_buf.to_string())
  { text, tool_calls, finish_reason, error: None, usage: stream_usage }
}
