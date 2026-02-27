/// Genome types: manifest, identity tracking, and lifecycle metadata.

///|
/// Manifest tracks cub's identity and lineage across generations.
pub struct Manifest {
  /// Unique ID (FNV-1a hash of workspace + birth time)
  id : String
  /// Generation number, starting at 0
  generation : Int
  /// Parent IDs (empty for generation 0)
  parents : Array[String]
  /// ISO 8601 birth timestamp
  born : String
  /// Full lineage chain (all ancestor IDs)
  lineage : Array[String]
} derive(Eq, Show)

///|
/// Serialize manifest to JSON.
pub fn Manifest::to_json(self : Manifest) -> Json {
  let obj : Map[String, Json] = {}
  obj["id"] = self.id.to_json()
  obj["generation"] = self.generation.to_json()
  obj["parents"] = self.parents.map(fn(s) { s.to_json() }).to_json()
  obj["born"] = self.born.to_json()
  obj["lineage"] = self.lineage.map(fn(s) { s.to_json() }).to_json()
  Json::object(obj)
}

///|
/// Deserialize manifest from JSON.
pub fn Manifest::from_json(json : Json) -> Manifest? {
  match json {
    {
      "id": String(id),
      "generation": Number(gen, ..),
      "born": String(born),
      ..
    } => {
      let parents = match json {
        { "parents": Array(arr), .. } =>
          arr.filter_map(fn(j) {
            match j {
              String(s) => Some(s)
              _ => None
            }
          })
        _ => []
      }
      let lineage = match json {
        { "lineage": Array(arr), .. } =>
          arr.filter_map(fn(j) {
            match j {
              String(s) => Some(s)
              _ => None
            }
          })
        _ => []
      }
      Some({ id, generation: gen.to_int(), parents, born, lineage })
    }
    _ => None
  }
}
