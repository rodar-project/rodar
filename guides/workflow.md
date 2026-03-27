# Workflow API

The Workflow API provides two layers of abstraction over the core BPMN engine, eliminating boilerplate for the most common patterns: loading a BPMN file, registering it, creating process instances, and resuming user tasks.

## Layer 1: `Rodar.Workflow`

A functional API (plus an optional `use` macro) that wraps the steps you would otherwise repeat in every module: read XML, parse, register, discover handlers, create an instance, activate.

### Using the `use` Macro

```elixir
defmodule MyApp.OrderWorkflow do
  use Rodar.Workflow,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app,           # optional — resolves path via Application.app_dir
    app_name: "MyApp"           # optional — enables handler auto-discovery
end
```

This injects convenience functions with the configured options baked in:

- `setup/0` — load BPMN, register definition, discover handlers
- `start_process/1` — create instance with a data map, activate
- `start_process/0` — shorthand with empty data
- `resume_user_task/3` — resume a user task by `(pid, task_id, input)`
- `process_status/1` — get process status (with smart completion detection)
- `process_data/1` — get the current data map
- `process_history/1` — get execution history

All injected functions are `defoverridable`, so you can customize any of them:

```elixir
defmodule MyApp.OrderWorkflow do
  use Rodar.Workflow,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing"

  # Override to add logging
  def start_process(data) do
    IO.puts("Starting order process with #{inspect(data)}")
    super(data)
  end
end
```

### Using the Functional API Directly

You can skip the `use` macro and call the module functions directly:

```elixir
# Setup — load, register, discover handlers
{:ok, diagram} = Rodar.Workflow.setup(
  bpmn_file: "priv/bpmn/order.bpmn",
  process_id: "order"
)

# Create and activate a process instance
{:ok, pid} = Rodar.Workflow.start_process("order", %{"item" => "widget"})

# Check status
:suspended = Rodar.Workflow.process_status(pid)

# Resume a user task
Rodar.Workflow.resume_user_task(pid, "Task_Approval", %{"approved" => true})
```

### Function Reference

#### `setup/1`

Loads a BPMN file, parses it, registers the process definition, and discovers handlers (if `:app_name` is provided).

Options:

- `:bpmn_file` (required) — path to the BPMN XML file
- `:process_id` (required) — the ID to register the process definition under
- `:otp_app` — OTP application for path resolution via `Application.app_dir/2`
- `:app_name` — PascalCase application name for handler auto-discovery

Returns `{:ok, diagram}` on success, `{:error, reason}` on failure.

#### `start_process/2`

Creates a process instance with data, then activates it.

Unlike `Rodar.Process.create_and_run/2` which passes data at creation time and activates immediately, `start_process/2` sets each data key individually via `Context.put_data/3` **before** calling `activate/1`. This ensures data is available to the start event and any immediately-reached nodes.

```elixir
{:ok, pid} = Rodar.Workflow.start_process("order", %{
  "customer" => "alice",
  "total" => 99
})
```

#### `resume_user_task/3`

Resumes a paused user task on a process instance. Looks up the task element in the process map, verifies it is a user task, and delegates to `Rodar.Activity.Task.User.resume/3`.

```elixir
result = Rodar.Workflow.resume_user_task(pid, "Task_Approval", %{
  "approved" => true
})
```

Returns `{:error, reason}` if the task is not found or is not a user task.

#### `process_status/1`

Returns the current status of a process instance with **smart completion detection**.

When the underlying `Rodar.Process` reports `:suspended` (which happens when a user task pauses execution during initial activation), this function inspects the context nodes. If no nodes are currently active, the process has actually completed (for example, after an external `resume_user_task` call ran the process to its end event), so `:completed` is returned instead of `:suspended`.

```elixir
{:ok, pid} = Rodar.Workflow.start_process("order", %{"item" => "widget"})

# Process hits a user task during activation — status is :suspended
:suspended = Rodar.Workflow.process_status(pid)

# After resuming the user task, the process runs to completion
Rodar.Workflow.resume_user_task(pid, "Task_Approval", %{"approved" => true})
:completed = Rodar.Workflow.process_status(pid)
```

#### `process_data/1`

Returns the current data map of a process instance.

```elixir
data = Rodar.Workflow.process_data(pid)
data["result"]
# => "approved"
```

#### `process_history/1`

Returns the execution history of a process instance.

```elixir
history = Rodar.Workflow.process_history(pid)
# => [%{node_id: "StartEvent_1", result: :ok, ...}, ...]
```

## Layer 2: `Rodar.Workflow.Server`

A GenServer abstraction that builds on Layer 1, adding instance tracking with sequential IDs and domain-specific status mapping. Use this when you need a long-lived process that manages multiple BPMN instances.

### Quick Example

```elixir
defmodule MyApp.OrderManager do
  use Rodar.Workflow.Server,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app,
    app_name: "MyApp"

  @impl Rodar.Workflow.Server
  def init_data(params, instance_id) do
    %{
      "customer" => params["customer"],
      "order_id" => instance_id
    }
  end

  # Optional — translate BPMN statuses to domain terms
  @impl Rodar.Workflow.Server
  def map_status(:suspended), do: :pending_approval
  def map_status(other), do: other

  # Domain-specific API wrappers
  def create_order(params), do: create_instance(params)
  def approve(id), do: complete_task(id, "Task_Approval", %{"approved" => true})
end
```

### Required Callback: `init_data/2`

Transforms the input parameters and a sequential instance ID into the BPMN process data map. Called during `create_instance/1` before activating the process.

```elixir
@impl Rodar.Workflow.Server
def init_data(params, instance_id) do
  %{
    "customer" => params["customer"],
    "order_id" => instance_id,
    "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
  }
end
```

The `instance_id` is a sequential integer (1, 2, 3, ...) assigned by the server.

### Optional Callback: `map_status/1`

Translates BPMN process status atoms (`:created`, `:running`, `:suspended`, `:completed`, `:error`, `:terminated`) to domain-specific terms. Defaults to identity (returns the status unchanged).

```elixir
@impl Rodar.Workflow.Server
def map_status(:suspended), do: :pending_approval
def map_status(:completed), do: :fulfilled
def map_status(other), do: other
```

### Injected Functions

#### `start_link/1`

Starts the GenServer. Accepts a keyword list with an optional `:name` key (defaults to `__MODULE__`). Calls `setup/0` during `init/1` to load the BPMN definition.

#### `create_instance/1`

Creates a new BPMN process instance. Increments the sequential ID counter, calls your `init_data/2` callback, starts the process, and tracks the instance.

Returns `{:ok, instance}` where `instance` is a map with `:id`, `:process_pid`, `:status`, and `:created_at`.

#### `complete_task/3`

Resumes a user task on a tracked instance. Takes `(instance_id, task_id, input)`.

Returns `{:ok, updated_instance}` or `{:error, :not_found}`.

#### `list_instances/0`

Returns all tracked instances sorted by ID (newest first).

#### `get_instance/1`

Returns `{:ok, instance}` or `{:error, :not_found}`.

### Message Isolation

All workflow GenServer messages use `{:__workflow__, action, ...}` tuple tags. This prevents collisions with any `handle_call` clauses you add to the module. You can freely define your own `handle_call`, `handle_cast`, and `handle_info` callbacks alongside the injected ones.

### Adding to the Supervision Tree

Add your workflow server to your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.OrderManager
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Domain-Specific API Pattern

The recommended pattern is to wrap the injected functions with domain-specific names:

```elixir
defmodule MyApp.OrderManager do
  use Rodar.Workflow.Server,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app

  @impl Rodar.Workflow.Server
  def init_data(params, instance_id) do
    %{"customer" => params["customer"], "order_id" => instance_id}
  end

  @impl Rodar.Workflow.Server
  def map_status(:suspended), do: :pending_approval
  def map_status(:completed), do: :fulfilled
  def map_status(other), do: other

  # Domain API — callers never see BPMN details
  def create_order(params), do: create_instance(params)
  def approve(id), do: complete_task(id, "Task_Approval", %{"approved" => true})
  def reject(id), do: complete_task(id, "Task_Approval", %{"approved" => false})
  def orders, do: list_instances()
  def order(id), do: get_instance(id)
end
```

Callers interact with `MyApp.OrderManager.create_order/1` and `MyApp.OrderManager.approve/1` without knowing BPMN is involved.

## Querying Pending User Tasks

To find active user tasks on a process instance, inspect the context nodes for entries marked as active with a user task type:

```elixir
def pending_tasks(pid) do
  context = Rodar.Process.get_context(pid)
  process_map = Rodar.Context.get(context, :process)
  nodes = Rodar.Context.get(context, :nodes)

  nodes
  |> Enum.filter(fn
    {key, %{active: true}} when is_binary(key) -> true
    _ -> false
  end)
  |> Enum.filter(fn {node_id, _} ->
    match?({:bpmn_activity_task_user, _}, Map.get(process_map, node_id))
  end)
  |> Enum.map(fn {node_id, _meta} ->
    {:bpmn_activity_task_user, attrs} = Map.get(process_map, node_id)
    %{id: node_id, name: Map.get(attrs, :name, node_id)}
  end)
end
```

This is useful for building a "pending tasks" list in a dashboard or API endpoint.

## Next Steps

- [Process Lifecycle](process_lifecycle.md) — Instance creation, status transitions, suspend/resume
- [Task Handlers](task_handlers.md) — Register custom task implementations
- [Getting Started](getting_started.md) — Quick start with the core engine API
