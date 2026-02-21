/// Bootstrap: build_runtime factory stub.

///|
/// Build the application runtime.
pub fn build_runtime(
  workspace : String,
  model? : String? = None,
  max_tokens? : Int? = None,
  allowed_tools? : Array[String]? = None,
  allowed_skills? : Array[String]? = None,
) -> AppRuntime {
  ignore(workspace)
  ignore(model)
  ignore(max_tokens)
  ignore(allowed_tools)
  ignore(allowed_skills)
  abort("build_runtime not implemented")
}
