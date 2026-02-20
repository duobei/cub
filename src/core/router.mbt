/// Routing and command execution stub.

/// Command-aware router for user and model outputs.
pub struct InputRouter {
  registry : @tools.ToolRegistry
  tool_view : @tools.ProgressiveToolView
  tape : @tape.TapeService
  workspace : String
}

/// Create a new InputRouter.
pub fn InputRouter::new(
  registry : @tools.ToolRegistry,
  tool_view : @tools.ProgressiveToolView,
  tape : @tape.TapeService,
  workspace : String
) -> InputRouter {
  { registry, tool_view, tape, workspace }
}

/// Route user input.
pub async fn InputRouter::route_user(
  self : InputRouter,
  raw : String
) -> UserRouteResult!Error {
  ignore(self)
  ignore(raw)
  abort("InputRouter::route_user not implemented")
}

/// Route assistant output.
pub async fn InputRouter::route_assistant(
  self : InputRouter,
  raw : String
) -> AssistantRouteResult!Error {
  ignore(self)
  ignore(raw)
  abort("InputRouter::route_assistant not implemented")
}
