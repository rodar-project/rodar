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

FEEL is provided by the standalone [`rodar_feel`](https://hex.pm/packages/rodar_feel) package (`RodarFeel`). It supports arithmetic (`+`, `-`, `*`, `/`, `%`, `**`), comparisons (`>`, `<`, `>=`, `<=`, `=`, `!=`), boolean operators (`and`, `or`, `not`), string concatenation (`+`), path access (`order.total`), bracket access (`items[0]`, `map["key"]`), if-then-else, the `in` operator (lists and ranges), `between X and Y` range checks, list literals, context literals (`{a: 1, b: a + 1}` with sequential evaluation), `for-in-return` iteration, quantified expressions (`some`/`every ... satisfies`), `instance of` type checking, user-defined functions (lambdas with closures), function calls including space-separated names, and comments (`//` single-line, `/* */` multi-line).

```elixir
# Via the Rodar wrapper (used internally by the engine)
Rodar.Expression.Feel.eval("if x > 10 then \"high\" else \"low\"", %{"x" => 15})
# => {:ok, "high"}

# Or directly via the standalone package
RodarFeel.eval("x in [1, 2, 3]", %{"x" => 2})
# => {:ok, true}

RodarFeel.eval("string length(name)", %{"name" => "Alice"})
# => {:ok, 5}

# Between operator
RodarFeel.eval("age between 18 and 65", %{"age" => 30})
# => {:ok, true}

# Context literals with sequential evaluation
RodarFeel.eval("{base: price, tax: base * 0.1}", %{"price" => 100})
# => {:ok, %{"base" => 100, "tax" => 10.0}}

# For-in-return iteration
RodarFeel.eval("for x in items return x * 2", %{"items" => [1, 2, 3]})
# => {:ok, [2, 4, 6]}

# Quantified expressions
RodarFeel.eval("some x in scores satisfies x > 90", %{"scores" => [70, 85, 95]})
# => {:ok, true}
```

## Temporal Types

FEEL has built-in support for dates, times, datetimes, and durations using the `@"..."` literal syntax. These can also be constructed via built-in functions.

```elixir
# Date literals
RodarFeel.eval(~s|@"2024-03-20"|, %{})
# => {:ok, ~D[2024-03-20]}

# Time literals
RodarFeel.eval(~s|@"10:30:00"|, %{})
# => {:ok, ~T[10:30:00]}

# DateTime literals (with timezone)
RodarFeel.eval(~s|@"2024-03-20T10:30:00Z"|, %{})
# => {:ok, ~U[2024-03-20 10:30:00Z]}

# Duration literals
RodarFeel.eval(~s|@"P1Y2M"|, %{})
# => {:ok, %RodarFeel.Duration{years: 1, months: 2, ...}}

# Temporal arithmetic
RodarFeel.eval(~s|@"2024-03-20" + @"P1M"|, %{})
# => {:ok, ~D[2024-04-20]}

# Property access on temporal values
RodarFeel.eval("d.year", %{"d" => ~D[2024-03-20]})
# => {:ok, 2024}

# Properties: .year, .month, .day, .hour, .minute, .second, .timezone, .offset

# Built-in temporal functions
RodarFeel.eval("today()", %{})
# => {:ok, ~D[...]}  (current date)

RodarFeel.eval("now()", %{})
# => {:ok, ...}  (current datetime)

# Constructing from components
RodarFeel.eval(~s|date and time(@"2024-03-20", @"10:30:00")|, %{})
# => {:ok, ~N[2024-03-20 10:30:00]}
```

## User-Defined Functions (Lambdas)

FEEL supports defining anonymous functions with closure capture:

```elixir
# Define and invoke a lambda
RodarFeel.eval("{add: function(x, y) x + y, result: add(3, 4)}", %{})
# => {:ok, %{"add" => {:feel_function, ...}, "result" => 7}}

# Closures capture bindings at definition time
RodarFeel.eval("{base: 10, add_base: function(x) x + base, result: add_base(5)}", %{})
# => {:ok, %{"base" => 10, "add_base" => {:feel_function, ...}, "result" => 15}}
```

## Instance of Type Checking

The `instance of` operator checks a value's type at runtime:

```elixir
RodarFeel.eval("x instance of number", %{"x" => 42})
# => {:ok, true}

RodarFeel.eval("x instance of string", %{"x" => 42})
# => {:ok, false}

# Supported types: number, string, boolean, date, time, date and time,
# years and months duration, days and time duration, list, context, null, any
```

## DMN Unary Tests

The `eval_unary/3` function evaluates DMN-style unary test expressions against an input value. Useful for decision table cells:

```elixir
# Comparison tests
RodarFeel.eval_unary("< 100", 50, %{})
# => {:ok, true}

# Range tests (inclusive/exclusive brackets)
RodarFeel.eval_unary("[1..5]", 3, %{})
# => {:ok, true}

RodarFeel.eval_unary("(1..5)", 1, %{})
# => {:ok, false}  (exclusive)

# Disjunction (match any)
RodarFeel.eval_unary("1, 2, 3", 2, %{})
# => {:ok, true}

# Negation
RodarFeel.eval_unary("not(< 100)", 150, %{})
# => {:ok, true}

# Wildcard (matches anything)
RodarFeel.eval_unary("-", "anything", %{})
# => {:ok, true}
```

## Built-in FEEL Functions

| Category | Functions |
|----------|-----------|
| Numeric | `abs(n)`, `floor(n)`, `ceiling(n)`, `round(n)`, `round(n, scale)`, `min(list)`, `max(list)`, `sum(list)`, `count(list)`, `product(list)`, `mean(list)` |
| String | `string length(s)`, `contains(s, sub)`, `starts with(s, prefix)`, `ends with(s, suffix)`, `upper case(s)`, `lower case(s)`, `substring(s, start)`, `substring(s, start, length)`, `split(s, delimiter)`, `substring before(s, match)`, `substring after(s, match)`, `replace(s, pattern, replacement)`, `trim(s)`, `string join(list)`, `string join(list, separator)`, `matches(s, pattern)` |
| Boolean | `not(b)`, `all(list)`, `any(list)` |
| Null | `is null(v)` |
| List | `append(list, item)`, `concatenate(list1, list2, ...)`, `reverse(list)`, `flatten(list)`, `distinct values(list)`, `sort(list)`, `index of(list, match)`, `list contains(list, element)` |
| Conversion | `string(value)`, `number(s)`, `number(s, grouping, decimal)` |
| Temporal | `date(s)`, `time(s)`, `date and time(s)`, `date and time(date, time)`, `duration(s)`, `now()`, `today()` |
| Statistical | `median(list)`, `stddev(list)`, `mode(list)` |
| Misc | `random()` |

All functions propagate `nil` -- if any argument is `nil`, the result is `nil`. The exceptions are `is null` (returns `true` for `nil`), `not` (returns `nil` for `nil`), `all` and `any` (three-valued boolean logic: `all([true, nil])` returns `nil`, `all([false, nil])` returns `false`), and `string` (returns `nil` for `nil`).

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
