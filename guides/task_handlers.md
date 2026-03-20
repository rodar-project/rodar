# Task Handlers

The `Rodar.TaskHandler` behaviour lets you register custom task types or override specific task instances without modifying the engine.

## Defining a Handler

Implement the `Rodar.TaskHandler` behaviour with a `token_in/2` callback:

```elixir
defmodule MyApp.ApprovalHandler do
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in({_type, %{id: id}} = _element, context) do
    # Your business logic here
    Rodar.Context.put_data(context, "approved", true)
    Rodar.release_token(["next_flow"], context)
  end
end
```

The callback receives the BPMN element tuple and the context pid, and should return a standard result tuple (`{:ok, context}`, `{:error, reason}`, `{:manual, data}`).

## Registering Handlers

### By Type (atom)

Register a handler for all tasks of a custom type:

```elixir
Rodar.TaskRegistry.register(:my_approval_task, MyApp.ApprovalHandler)
```

Any element with type `:my_approval_task` will be dispatched to this handler.

### By Task ID (string)

Register a handler for a specific task instance:

```elixir
Rodar.TaskRegistry.register("Task_approval_1", MyApp.ApprovalHandler)
```

### Lookup Priority

When dispatching, the engine checks:

1. **Task ID** (string) — specific override for one task instance
2. **Task type** (atom) — generic handler for all tasks of that type
3. **Built-in handlers** — the engine's default dispatch

This lets you override individual tasks while keeping a generic handler for the type.

## Managing Registrations

```elixir
# List all registered handlers
Rodar.TaskRegistry.list()
# => [{:my_task, MyApp.Handler}, {"Task_1", MyApp.Other}]

# Remove a registration
Rodar.TaskRegistry.unregister(:my_task)

# Check if a handler exists
case Rodar.TaskRegistry.lookup(:my_task) do
  {:ok, module} -> # handler found
  :error -> # no handler registered
end
```

## Example: Custom HTTP Task

```elixir
defmodule MyApp.HttpTask do
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in({_type, %{id: _id, outgoing: outgoing} = attrs}, context) do
    url = Map.get(attrs, :url, Rodar.Context.get_data(context, "request_url"))
    # Perform HTTP request...
    Rodar.Context.put_data(context, "response", %{status: 200})
    Rodar.release_token(outgoing, context)
  end
end

# Register for all :http_task elements
Rodar.TaskRegistry.register(:http_task, MyApp.HttpTask)
```

## Service Task Handlers

Service tasks use a separate handler mechanism from `Rodar.TaskHandler`. A service task handler implements the `Rodar.Activity.Task.Service.Handler` behaviour, which has an `execute/2` callback instead of `token_in/2`:

```elixir
defmodule MyApp.CheckInventory do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(attrs, data) do
    item_id = Map.get(data, "item_id")
    # ... business logic ...
    {:ok, %{in_stock: true, quantity: 42}}
  end
end
```

The `execute/2` callback receives:

- `attrs` -- the BPMN element attribute map (including `:id`, `:name`, `:outgoing`, etc.)
- `data` -- the current process data map (from `Rodar.Context.get(context, :data)`)

The `execute/2` callback supports four return types:

- `{:ok, result_map}` -- merge keys into context data, release token to outgoing flows
- `{:error, reason}` -- signal failure, error propagates to caller
- `{:bpmn_error, error_code, message}` -- throw a BPMN error; if an error boundary event is attached to the service task, the token routes there. Otherwise falls back to `{:error, message}`
- `{:async, reference}` -- park the token and return `{:manual, _}` to suspend the process. Use `Rodar.Activity.Task.Service.complete_async/3` or `Rodar.Workflow.complete_async_service/3` to resume later

### BPMN Error Propagation

A handler can throw a BPMN error that routes to an attached error boundary event:

```elixir
defmodule MyApp.ValidateOrder do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    case validate(data) do
      :ok -> {:ok, %{validated: true}}
      {:error, reason} -> {:bpmn_error, "VALIDATION_ERROR", reason}
    end
  end
end
```

When `{:bpmn_error, code, message}` is returned, the engine stores the error info in context meta (`:error`, `:error_code`, `:error_message`) and searches for an error boundary event attached to the service task. If found, the token is released to the boundary's outgoing flows. If no error boundary is attached, the error falls back to `{:error, message}`.

### Async Service Tasks

For external integrations (webhooks, queued jobs), return `{:async, reference}` to suspend the process:

```elixir
defmodule MyApp.SendEmail do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    job_id = EmailService.send_async(data["to"], data["body"])
    {:async, job_id}
  end
end
```

The process suspends (returns `{:manual, _}`) with the async reference stored in context meta. When the external work completes, resume with:

```elixir
# Direct API
context = Rodar.Process.get_context(pid)
Rodar.Activity.Task.Service.complete_async(context, "Task_send_email", %{sent: true})

# Workflow convenience function
Rodar.Workflow.complete_async_service(pid, "Task_send_email", %{sent: true})

# Workflow.Server
MyApp.OrderManager.complete_service_task(instance_id, "Task_send_email", %{sent: true})
```

### Wiring Service Handlers

There are two ways to connect a handler to a service task:

#### 1. At parse time with `handler_map`

Pass a `:handler_map` option to `Rodar.Engine.Diagram.load/2`. The map keys are BPMN element ID strings, and the values are handler modules:

```elixir
handler_map = %{
  "Task_check_inventory" => MyApp.CheckInventory,
  "Task_send_email" => MyApp.SendEmail
}

diagram = Rodar.Engine.Diagram.load(xml, handler_map: handler_map)
```

This injects a `:handler` attribute directly into the parsed element, so the handler is resolved without any registry lookup at runtime.

#### 2. At runtime with `TaskRegistry`

Register the handler by the task's BPMN element ID:

```elixir
Rodar.TaskRegistry.register("Task_check_inventory", MyApp.CheckInventory)
```

The service task module looks up the task ID in the `TaskRegistry` when no inline `:handler` attribute is present.

### Convention-Based Auto-Discovery

When you scaffold handlers with `mix rodar.scaffold`, modules are placed at predictable paths (e.g., `MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder`). The engine can auto-discover these handlers when you provide the `:bpmn_file` and `:app_name` options to `Diagram.load/2`:

```elixir
# Discovery is ON by default when bpmn_file + app_name are provided
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp"
)

# Discovered service task handlers are automatically injected.
# The discovery result is available for inspection:
diagram.discovery
# => %{
#   handler_map: %{"Task_1" => MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder},
#   task_registry_entries: [{"Task_2", MyApp.Workflow.OrderProcessing.Handlers.ApproveOrder}],
#   not_found: ["Task_3"]
# }
```

Discovery checks each task for a module at the expected namespace and verifies it implements the correct callback (`execute/2` for service tasks, `token_in/2` for others). Discovery is recursive — tasks nested inside embedded subprocesses are discovered at any depth using the same namespace convention as top-level tasks.

You can mix explicit `handler_map` entries with discovery — explicit entries always win for overlapping task IDs:

```elixir
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order.bpmn",
  app_name: "MyApp",
  handler_map: %{"Task_1" => MyApp.CustomOverride}
)
```

To disable discovery, set `discover_handlers: false`:

```elixir
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order.bpmn",
  app_name: "MyApp",
  discover_handlers: false
)
```

For non-service task handlers (user, send, receive, manual), discovery returns them in `task_registry_entries`. Register them with:

```elixir
Rodar.Scaffold.Discovery.register_discovered(diagram.discovery)
```

You can also use the `Discovery` module directly for programmatic discovery without `Diagram.load/2`:

```elixir
alias Rodar.Scaffold.Discovery

result = Discovery.discover(diagram, module_prefix: "MyApp.Workflow.OrderProcessing.Handlers")
diagram = Discovery.apply_handlers(diagram, result.handler_map)
Discovery.register_discovered(result)
```

### Handler Resolution Priority

When a service task executes, the handler is resolved in this order:

1. **Inline `:handler` attribute** -- if the element has a `:handler` key (set by `Diagram.load/2` `:handler_map` or convention discovery), that module is used directly.
2. **`Rodar.TaskRegistry` lookup** -- the task's `:id` is looked up in the registry. This works for both service-task-specific registrations and general type registrations.
3. **Fallback** -- if neither source provides a handler, `{:not_implemented}` is returned.

## Script Engines vs Task Handlers

Task handlers and script engines serve different extensibility roles:

- **Task handlers** (`Rodar.TaskHandler`) replace the entire execution logic for a task type or specific task ID. Use these for custom business logic like HTTP calls, database operations, or approval workflows.
- **Script engines** (`Rodar.Expression.ScriptEngine`) add support for new script languages in script tasks. Use these when your BPMN diagrams embed scripts in Lua, Python, or other languages.

See the [Expressions guide](expressions.md#pluggable-script-engines) for details on registering script engines.

## Next Steps

- [Process Lifecycle](process_lifecycle.md) — Instance creation and status transitions
- [Hooks](hooks.md) — Observe execution with lifecycle hooks
- [Expressions](expressions.md) — FEEL and Elixir sandbox expression evaluation
