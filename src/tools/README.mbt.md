# Tools — Registry and Progressive Disclosure

The `tools` package provides a tool registry for registering, discovering,
and executing tools, plus a progressive disclosure view that shows compact
listings by default and expands details on demand.

## Tool Registry

Register tools with a name, description, parameter schema, and async handler.

```mbt nocheck
///|
test "register and query tools" {
  let registry = @tools.ToolRegistry::new()
  registry.register(
    "echo",
    "Echo input back",
    detail="Returns the input text unchanged.",
    parameters=@tools.make_params(
      { "text": @tools.string_prop("Text to echo") },
      ["text"],
    ),
    handler=fn(args) {
      match args {
        { "text": String(t), .. } => t
        _ => "no text"
      }
    },
  )
  inspect(registry.has("echo"), content="true")
  inspect(registry.has("missing"), content="false")
}
```

## Tool Descriptors

Query registered tools for their metadata.

```mbt nocheck
///|
test "list tool descriptors" {
  let registry = @tools.ToolRegistry::new()
  registry.register("greet", "Say hello", handler=fn(_args) { "hello" })
  let descs = registry.descriptors()
  inspect(descs.length(), content="1")
  inspect(descs[0].name, content="greet")
}
```

## Progressive Tool View

The progressive view renders compact tool listings and expands details
only when a tool is hinted or selected by the model.

```mbt nocheck
///|
test "progressive view compact and expand" {
  let registry = @tools.ToolRegistry::new()
  registry.register("bash", "Run shell commands", handler=fn(_a) { "" })
  registry.register("fs.read", "Read files", handler=fn(_a) { "" })
  let view = @tools.ProgressiveToolView::new(registry)
  // All tools listed
  inspect(view.all_tools().length(), content="2")
  // Expand on hint
  let found = view.note_hint("bash")
  inspect(found, content="true")
}
```

## Name Conversion

Tool names use dots internally (`fs.read`) but underscores for LLM
function calling (`fs_read`).

```mbt nocheck
///|
test "name conversion" {
  inspect(@tools.to_model_name("fs.read"), content="fs_read")
  inspect(@tools.to_model_name("bash"), content="bash")
}
```

## Utility Helpers

```mbt nocheck
///|
test "url safety check" {
  inspect(@tools.is_safe_url("https://example.com"), content="true")
  inspect(@tools.is_safe_url("file:///etc/passwd"), content="false")
}

///|
test "path traversal detection" {
  inspect(@tools.has_path_traversal("../secret"), content="true")
  inspect(@tools.has_path_traversal("src/main.mbt"), content="false")
}
```
