/// Tape entry and related types.

///|
/// A single entry in the tape.
pub struct TapeEntry {
  id : Int
  kind : String // "message" | "tool_call" | "tool_result" | "anchor" | "event"
  payload : Json
  meta : Json
} derive(ToJson, @json.FromJson, Show)

///|
/// Summary of an anchor point.
pub struct AnchorSummary {
  name : String
  state : Map[String, Json]
} derive(Show)

///|
/// Runtime tape info summary.
pub struct TapeInfo {
  name : String
  entries : Int
  anchors : Int
  last_anchor : String?
  entries_since_last_anchor : Int
} derive(Show)

///|
/// Create a message entry (user/assistant/system).
pub fn TapeEntry::message(role : String, content : String) -> TapeEntry {
  let payload : Map[String, Json] = Map::new()
  payload["role"] = role.to_json()
  payload["content"] = content.to_json()
  {
    id: 0,
    kind: "message",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}

///|
/// Create a message entry with image attachments (OpenAI vision format).
pub fn TapeEntry::message_with_images(
  role : String,
  text : String,
  image_urls : Array[String],
) -> TapeEntry {
  let parts : Array[Json] = []
  if text.length() > 0 {
    let text_part : Map[String, Json] = {}
    text_part["type"] = "text".to_json()
    text_part["text"] = text.to_json()
    parts.push(Json::object(text_part))
  }
  for url in image_urls {
    let url_obj : Map[String, Json] = {}
    url_obj["url"] = url.to_json()
    let img_part : Map[String, Json] = {}
    img_part["type"] = "image_url".to_json()
    img_part["image_url"] = Json::object(url_obj)
    parts.push(Json::object(img_part))
  }
  let payload : Map[String, Json] = Map::new()
  payload["role"] = role.to_json()
  payload["content"] = Json::array(parts)
  {
    id: 0,
    kind: "message",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}

///|
/// Create a system message entry.
pub fn TapeEntry::system(content : String) -> TapeEntry {
  TapeEntry::message("system", content)
}

///|
/// Create an event entry.
pub fn TapeEntry::event(
  name : String,
  data? : Json = Json::object(Map::new()),
) -> TapeEntry {
  let payload : Map[String, Json] = Map::new()
  payload["name"] = name.to_json()
  payload["data"] = data
  {
    id: 0,
    kind: "event",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}

///|
/// Create an anchor entry.
pub fn TapeEntry::anchor(
  name : String,
  state? : Map[String, Json]? = None,
) -> TapeEntry {
  let state_json : Json = match state {
    Some(s) => Json::object(s)
    None => Json::object(Map::new())
  }
  let payload : Map[String, Json] = Map::new()
  payload["name"] = name.to_json()
  payload["state"] = state_json
  {
    id: 0,
    kind: "anchor",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}

///|
/// Create a tool_call entry.
pub fn TapeEntry::tool_call(calls : Array[Json]) -> TapeEntry {
  let payload : Map[String, Json] = Map::new()
  payload["calls"] = Json::array(calls)
  {
    id: 0,
    kind: "tool_call",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}

///|
/// Create a tool_result entry.
pub fn TapeEntry::tool_result(results : Array[Json]) -> TapeEntry {
  let payload : Map[String, Json] = Map::new()
  payload["results"] = Json::array(results)
  {
    id: 0,
    kind: "tool_result",
    payload: Json::object(payload),
    meta: Json::object(Map::new()),
  }
}
