///|
/// Tests for extension parameter validation.

///|
test "validate_required_params all present" {
  let schema : Json = @json.parse(
    (
      #|{"type":"object","required":["name","path"]}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let args : Json = @json.parse(
    (
      #|{"name":"test","path":"/tmp"}
    ),
  ) catch {
    _ => fail("bad json")
  }
  inspect(@app.validate_required_params(args, schema), content="")
}

///|
test "validate_required_params missing one" {
  let schema : Json = @json.parse(
    (
      #|{"type":"object","required":["name","path"]}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let args : Json = @json.parse(
    (
      #|{"name":"test"}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let result = @app.validate_required_params(args, schema)
  inspect(result.contains("path"), content="true")
}

///|
test "validate_required_params no required field" {
  let schema : Json = @json.parse(
    (
      #|{"type":"object","properties":{"name":{"type":"string"}}}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let args = Json::object({})
  inspect(@app.validate_required_params(args, schema), content="")
}

///|
test "validate_required_params empty schema" {
  let schema = Json::object({})
  let args = Json::object({})
  inspect(@app.validate_required_params(args, schema), content="")
}

///|
test "validate_required_params missing multiple" {
  let schema : Json = @json.parse(
    (
      #|{"type":"object","required":["a","b","c"]}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let args : Json = @json.parse(
    (
      #|{"a":"1"}
    ),
  ) catch {
    _ => fail("bad json")
  }
  let result = @app.validate_required_params(args, schema)
  inspect(result.contains("b"), content="true")
  inspect(result.contains("c"), content="true")
}
