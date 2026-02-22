/// Extension types for script tools and WASM plugins.

///|
/// Extension type: script (executable) or wasm (MoonBit plugin).
pub(all) enum ExtType {
  Script
  Wasm
} derive(Show, Eq)

///|
/// Extension manifest describing a discovered extension.
pub struct ExtManifest {
  name : String
  ext_type : ExtType
  description : String
  path : String
  parameters : Json
  scope : String
} derive(Show)
