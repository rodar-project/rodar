# Expressions

The engine supports two expression languages for condition evaluation on sequence flows, gateways, and conditional events: FEEL and sandboxed Elixir. The language is selected via the `language` attribute in BPMN XML condition expressions.

## Language Selection

In BPMN XML, set the `language` attribute on a `conditionExpression` element:

```xml
<!-- FEEL (default for BPMN 2.0) -->
<conditionExpression xsi:type="tFormalExpression" language="feel">
  amount > 1000
</conditionExpression>

<!-- Sandboxed Elixir -->
<conditionExpression xsi:type="tFormalExpression" language="elixir">
  data["amount"] > 1000
</conditionExpression>
```

You can also evaluate expressions programmatically:

```elixir
Rodar.Expression.execute({:bpmn_expression, {"feel", "amount > 1000"}}, context)
Rodar.Expression.execute({:bpmn_expression, {"elixir", "data[\"amount\"] > 1000"}}, context)
```

## Data Access

The two languages differ in how they access process data:

- **FEEL** receives the raw data map as bindings. Write `count > 5` directly.
- **Elixir sandbox** binds the data map to the `data` variable. Write `data["count"] > 5`.

## FEEL Syntax

FEEL is provided by the standalone [`rodar_feel`](https://hex.pm/packages/rodar_feel) package (`RodarFeel`). It supports arithmetic (`+`, `-`, `*`, `/`), comparisons (`>`, `<`, `>=`, `<=`, `=`, `!=`), boolean operators (`and`, `or`, `not`), string concatenation (`+`), path access (`order.total`), bracket access (`items[0]`), if-then-else, the `in` operator (lists and ranges), list literals, and function calls including space-separated names.

```elixir
# Via the Rodar wrapper (used internally by the engine)
Rodar.Expression.Feel.eval("if x > 10 then \"high\" else \"low\"", %{"x" => 15})
# => {:ok, "high"}

# Or directly via the standalone package
RodarFeel.eval("x in [1, 2, 3]", %{"x" => 2})
# => {:ok, true}

RodarFeel.eval("string length(name)", %{"name" => "Alice"})
# => {:ok, 5}
```

## Built-in FEEL Functions

| Category | Functions |
|----------|-----------|
| Numeric | `abs(n)`, `floor(n)`, `ceiling(n)`, `round(n)`, `round(n, scale)`, `min(list)`, `max(list)`, `sum(list)`, `count(list)` |
| String | `string length(s)`, `contains(s, sub)`, `starts with(s, prefix)`, `ends with(s, suffix)`, `upper case(s)`, `lower case(s)`, `substring(s, start)`, `substring(s, start, length)` |
| Boolean | `not(b)` |
| Null | `is null(v)` |

All functions propagate `nil` -- if any argument is `nil`, the result is `nil`. The exceptions are `is null` (returns `true` for `nil`) and `not` (returns `nil` for `nil`).

## Elixir Sandbox

The Elixir evaluator parses expressions into AST and walks the tree against an allowlist before evaluation. Allowed operations include comparisons, boolean logic, math, string operations (`String.*`), collection functions (`Enum.*`, `Map.*`, `List.*`), data access, literals, `if`/`case`/`cond`, and pipes.

Dangerous operations are rejected at parse time:

```elixir
Rodar.Expression.Sandbox.eval("System.cmd(\"ls\", [])")
# => {:error, "disallowed: module call System.cmd/2"}

Rodar.Expression.Sandbox.eval("1 + 2")
# => {:ok, 3}
```

## Pluggable Script Engines

Beyond FEEL and Elixir, you can register custom script languages for use in BPMN script tasks. This lets you embed Lua, Python, or any other language in your BPMN diagrams.

### Implementing an Engine

Create a module that implements the `Rodar.Expression.ScriptEngine` behaviour:

```elixir
defmodule MyApp.LuaEngine do
  @behaviour Rodar.Expression.ScriptEngine

  @impl true
  def eval(script, bindings) do
    # script: the script source text (String.t())
    # bindings: the current process data map
    case Lua.eval(script, bindings) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

The `eval/2` callback receives the raw script text and a map of the current process data (the same map from `Rodar.Context.get(context, :data)`).

### Registering an Engine

Register your engine at application startup so it is available before any process instance runs:

```elixir
# In your Application.start/2 callback, after rodar has started:
Rodar.Expression.ScriptRegistry.register("lua", MyApp.LuaEngine)
```

Once registered, any BPMN script task with `scriptFormat="lua"` will delegate to your engine:

```xml
<scriptTask id="Task_1" scriptFormat="lua">
  <script>return count + 1</script>
</scriptTask>
```

### Managing Registrations

```elixir
# List all registered engines
Rodar.Expression.ScriptRegistry.list()
# => [{"lua", MyApp.LuaEngine}]

# Look up an engine
{:ok, MyApp.LuaEngine} = Rodar.Expression.ScriptRegistry.lookup("lua")

# Remove a registration
Rodar.Expression.ScriptRegistry.unregister("lua")
```

### Companion Packages

Ready-made engine packages are planned:

- `rodar_lua` -- Lua scripting via Luerl
- `rodar_python` -- Python scripting via Erlport

### Language Resolution

The script language is resolved from the element's attributes:

1. `:type` attribute (legacy/explicit)
2. `:scriptFormat` attribute (standard BPMN 2.0, e.g., `<scriptTask scriptFormat="feel">`)
3. Defaults to `"elixir"` when neither is present

Once the language is determined, execution is dispatched to:

1. `"elixir"` -- built-in sandboxed Elixir evaluator
2. `"feel"` -- built-in FEEL evaluator
3. Any other string -- looked up in `Rodar.Expression.ScriptRegistry`
4. If no engine is found, returns `{:error, "Unsupported script language: ..."}`

## Next Steps

- [Gateways](https://hexdocs.pm/rodar/gateways.html) -- Conditional routing with expressions
- [Events](https://hexdocs.pm/rodar/events.html) -- Timer, conditional, and message events
- [Task Handlers](task_handlers.md) -- Register custom task implementations
