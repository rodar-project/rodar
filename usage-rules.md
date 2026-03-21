# Usage Rules for rodar

> Elixir BPMN 2.0 execution engine. Parses BPMN 2.0 XML diagrams and executes
> processes using a token-based flow model.

## Understanding Rodar Workflow

Rodar Workflow is a token-based execution engine. BPMN XML is parsed into a process
map of `{:bpmn_type, %{attrs}}` tuples keyed by element ID. Tokens flow from
node to node; each handler module implements `token_in/2` and returns one of:

- `{:ok, context}` — node completed
- `{:error, message}` — execution error
- `{:manual, context}` — process paused (user task, receive task, manual task)
- `{:fatal, reason}` — unrecoverable error
- `{:not_implemented}` — no handler for this element

The **Context** is a GenServer (a PID), not a data structure. All state reads
and writes go through `Rodar.Context` calls.

## Quick Start

```elixir
# GOOD: Standard workflow — parse, register, run
xml = File.read!("my_process.bpmn")
%{processes: [process | _]} = Rodar.Engine.Diagram.load(xml)
{:bpmn_process, _attrs, _elements} = process
Rodar.Registry.register("my_process", process)
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{order_id: "123"})

# BAD: Skipping registration — Process requires a registered definition
xml = File.read!("my_process.bpmn")
%{processes: [process | _]} = Rodar.Engine.Diagram.load(xml)
# This will fail — "my_process" is not in the registry
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{})
```

## Process Lifecycle

Status transitions:

```
:created → :running → :completed
                    → :error
:running → :suspended → :running (resume)
any      → :terminated
```

```elixir
# GOOD: create_and_run handles start_link + activate in one step
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{key: "value"})
:completed = Rodar.Process.status(pid)

# GOOD: Two-step when you need the pid before activation
{:ok, pid} = Rodar.Process.start_link("my_process", %{})
:created = Rodar.Process.status(pid)
:ok = Rodar.Process.activate(pid)

# BAD: Calling activate on a non-:created process
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{})
# Already activated — this returns an error
{:error, _} = Rodar.Process.activate(pid)

# BAD: Forgetting to activate after start_link
{:ok, pid} = Rodar.Process.start_link("my_process", %{})
# Process is stuck in :created — nothing executes
```

## Context (State Management)

The context is a GenServer PID, not a value. Use `Rodar.Context` functions
to read and write process data.

```elixir
# GOOD: Use Context API to read/write data
context = Rodar.Process.get_context(pid)
Rodar.Context.put_data(context, :status, "approved")
value = Rodar.Context.get_data(context, :status)

# GOOD: Inside a service handler, data is passed as a map
def execute(attrs, data) do
  count = Map.get(data, :count, 0)
  {:ok, %{count: count + 1}}
end

# BAD: Treating context as a map — it's a PID
context = Rodar.Process.get_context(pid)
# This will crash — context is a pid, not a map
context[:data]

# BAD: Trying to pattern-match on context
%{data: data} = context  # Crash — context is a pid
```

## Service Task Handlers

Service tasks use the `Rodar.Activity.Task.Service.Handler` behaviour.
Handlers receive task attributes and current context data. Four return types:

- `{:ok, map()}` — result merged into context data, token released
- `{:error, reason}` — error propagated to caller
- `{:bpmn_error, code, message}` — routes to error boundary event if attached, else `{:error, message}`
- `{:async, reference}` — parks the token, returns `{:manual, _}`; resume with `complete_async/3`

```elixir
# GOOD: Implement the Handler behaviour
defmodule MyApp.CheckInventory do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    item_id = Map.get(data, :item_id)
    in_stock = Inventory.check(item_id)
    {:ok, %{in_stock: in_stock}}
  end
end
```

### Two ways to wire handlers

**Option 1: handler_map at parse time** — inject handler modules into the
parsed diagram. Best when you know the mapping upfront.

```elixir
# GOOD: Wire handlers at parse time via handler_map
handler_map = %{
  "Task_check_inventory" => MyApp.CheckInventory,
  "Task_charge_payment" => MyApp.ChargePayment
}

%{processes: [process | _]} = Rodar.Engine.Diagram.load(xml, handler_map: handler_map)
Rodar.Registry.register("order_process", process)
```

**Option 2: TaskRegistry at runtime** — register handlers dynamically. Best
for plugins or when task IDs aren't known at compile time.

```elixir
# GOOD: Register handler at runtime by task ID
Rodar.TaskRegistry.register("Task_check_inventory", MyApp.CheckInventory)
```

**Lookup priority**: inline `:handler` attribute (from handler_map) → TaskRegistry by task ID → `{:not_implemented}`.

```elixir
# BAD: Using TaskHandler behaviour for service tasks
defmodule MyApp.CheckInventory do
  # Wrong behaviour — TaskHandler is for custom element types
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in(elem, context) do
    # ...
  end
end

# BAD: Forgetting to wire the handler — returns {:not_implemented}
# No handler_map, no TaskRegistry entry — this service task does nothing
Rodar.Registry.register("order_process", process)
{:ok, pid} = Rodar.Process.create_and_run("order_process", %{})
```

### BPMN Error Propagation

Service handlers can throw BPMN errors that route to attached error boundary
events. This implements the BPMN 2.0 error event semantics for service tasks.

```elixir
# GOOD: Return {:bpmn_error, code, message} to trigger error boundary
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

# The BPMN diagram should have an error boundary event attached to the
# service task. The engine will route the token to the boundary's outgoing
# flows when {:bpmn_error, _, _} is returned.

# If no error boundary is attached, the error propagates as {:error, message}

# BAD: Using {:error, reason} when you want BPMN error boundary routing
def execute(_attrs, data) do
  # This will NOT trigger the boundary event — it just returns an error
  {:error, "validation failed"}
end

# BAD: Raising an exception instead of returning {:bpmn_error, ...}
def execute(_attrs, _data) do
  raise "validation failed"  # Crashes the process, no boundary routing
end
```

### Async Service Tasks

Handlers can return `{:async, reference}` to indicate the work will complete
asynchronously (e.g., external API calls, webhooks). The process suspends and
can be resumed later.

```elixir
# GOOD: Return {:async, ref} for external work
defmodule MyApp.SendEmail do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(attrs, data) do
    job_id = EmailService.send_async(data["to"], data["body"])
    {:async, job_id}
  end
end

# GOOD: Resume with complete_async when the external work finishes
context = Rodar.Process.get_context(pid)
Rodar.Activity.Task.Service.complete_async(context, "Task_send_email", %{
  sent: true,
  message_id: "msg-456"
})

# GOOD: Use the Workflow convenience function
Rodar.Workflow.complete_async_service(pid, "Task_send_email", %{sent: true})

# BAD: Using resume_user_task for async service tasks
Rodar.Workflow.resume_user_task(pid, "Task_send_email", %{sent: true})
# => {:error, "Task 'Task_send_email' is :bpmn_activity_task_service, not a user task"}

# BAD: Forgetting to complete the async task — process stays suspended forever
def execute(_attrs, data) do
  SomeService.fire_and_forget(data)
  {:async, "ref"}  # If nothing ever calls complete_async, the process hangs
end
```

## Business Rule Task Handlers

Business rule tasks use the `Rodar.Activity.Task.BusinessRule.Handler` behaviour,
which is identical to the service task handler. Handler resolution follows the
same priority: inline `:handler` attribute, then `TaskRegistry` lookup, then
`{:not_implemented}`. This keeps the door open for future DMN integration.

```elixir
# GOOD: Implement the BusinessRule.Handler behaviour
defmodule MyApp.EvaluateDiscount do
  @behaviour Rodar.Activity.Task.BusinessRule.Handler

  @impl true
  def execute(_attrs, data) do
    discount =
      cond do
        data[:total] > 1000 -> 0.15
        data[:total] > 500 -> 0.10
        true -> 0.0
      end

    {:ok, %{discount: discount}}
  end
end

# GOOD: Wire via handler_map (same as service tasks)
diagram = Rodar.Engine.Diagram.load(xml,
  handler_map: %{"Task_evaluate_discount" => MyApp.EvaluateDiscount}
)

# GOOD: Wire via TaskRegistry at runtime
Rodar.TaskRegistry.register("Task_evaluate_discount", MyApp.EvaluateDiscount)

# BAD: Using Service.Handler behaviour for business rule tasks
defmodule MyApp.BadRule do
  # Wrong behaviour — use BusinessRule.Handler for business rule tasks
  @behaviour Rodar.Activity.Task.Service.Handler
  # ...
end

# BAD: Using TaskHandler behaviour for business rule tasks
defmodule MyApp.BadRule do
  # Wrong — TaskHandler is for custom element types, not business rule tasks
  @behaviour Rodar.TaskHandler
  # ...
end
```

## Custom Task Handlers

For custom element types (not service or business rule tasks), use the
`Rodar.TaskHandler` behaviour. These handle the raw token flow.

```elixir
# GOOD: Custom task handler for a non-standard element type
defmodule MyApp.ApprovalHandler do
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in({_type, %{id: id, outgoing: outgoing}} = _element, context) do
    Rodar.Context.put_data(context, "approved_by", id)
    Rodar.release_token(outgoing, context)
  end
end

# Register by custom type atom or by specific task ID
Rodar.TaskRegistry.register(:my_custom_task, MyApp.ApprovalHandler)
Rodar.TaskRegistry.register("Task_approval_1", MyApp.ApprovalHandler)

# BAD: Forgetting to release the token — process stalls
defmodule MyApp.BadHandler do
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in(_element, context) do
    Rodar.Context.put_data(context, "key", "value")
    # Missing release_token — execution stops here
    {:ok, context}
  end
end
```

## Manual Tasks & Resuming

User tasks, manual tasks, and receive tasks return `{:manual, context}`,
suspending the process. You must explicitly resume execution.

```elixir
# GOOD: Handle :manual result and resume later
{:ok, pid} = Rodar.Process.create_and_run("approval_process", %{})
:suspended = Rodar.Process.status(pid)

# Later, when the user completes the task:
context = Rodar.Process.get_context(pid)
Rodar.Context.put_data(context, :approved, true)

# Resume by releasing the token to the outgoing flow
Rodar.release_token(outgoing_flow_ids, context)

# BAD: Calling Process.resume/1 to continue from a manual task
# resume/1 only changes status from :suspended to :running
# It does NOT re-execute or release the token
Rodar.Process.resume(pid)  # Status changes but nothing executes
```

## End Event Publishing

End events with message, signal, or escalation definitions publish to the event
bus before completing. This mirrors the behavior of intermediate throw events.
The payload includes the element source ID and the current context data.

```elixir
# GOOD: Subscribe before the end event fires — subscriber receives the event
Rodar.Event.Bus.subscribe(:message, "order_completed", %{
  context: context,
  node_id: "catch_order_done"
})
# When the process reaches an end event with a messageEventDefinition
# referencing "order_completed", the subscriber receives the message

# GOOD: Signal end events broadcast to all subscribers
Rodar.Event.Bus.subscribe(:signal, "process_finished", %{node_id: "listener_1"})
Rodar.Event.Bus.subscribe(:signal, "process_finished", %{node_id: "listener_2"})
# Both subscribers receive the signal when the end event fires

# GOOD: Escalation end events also broadcast
Rodar.Event.Bus.subscribe(:escalation, "Escalation_001", %{node_id: "boundary_esc"})
# Subscriber receives escalation when end event with that code fires

# BAD: Expecting end event publishing without an event definition
# A plain end event (no messageEventDefinition, signalEventDefinition, etc.)
# does NOT publish anything — it just returns {:ok, context}

# BAD: Subscribing after the end event fires — message is already gone
# End events publish synchronously, so subscribe before the process runs
```

## Event Bus

The event bus supports message, signal, and escalation events with different
delivery semantics.

```elixir
# GOOD: Message events are point-to-point (one subscriber receives)
Rodar.Event.Bus.subscribe(:message, "order_received", %{
  context: context,
  node_id: "catch_1",
  outgoing: ["flow_out"]
})
Rodar.Event.Bus.publish(:message, "order_received", %{order_id: "123"})

# GOOD: Signal events broadcast to all subscribers
Rodar.Event.Bus.subscribe(:signal, "system_shutdown", %{context: ctx1})
Rodar.Event.Bus.subscribe(:signal, "system_shutdown", %{context: ctx2})
# Both subscribers receive this
Rodar.Event.Bus.publish(:signal, "system_shutdown", %{})

# GOOD: Use correlation keys to route messages to specific instances
Rodar.Event.Bus.subscribe(:message, "payment_received", %{
  context: context,
  correlation: %{key: "order_id", value: "ORD-123"}
})
Rodar.Event.Bus.publish(:message, "payment_received", %{
  correlation: %{key: "order_id", value: "ORD-123"}
})

# BAD: Using :message when you want broadcast — only one subscriber gets it
Rodar.Event.Bus.publish(:message, "notify_all", %{})
# Use :signal for broadcast instead

# BAD: Mismatching correlation keys — message won't route correctly
Rodar.Event.Bus.subscribe(:message, "payment", %{
  correlation: %{key: "order_id", value: "ORD-123"}
})
Rodar.Event.Bus.publish(:message, "payment", %{
  correlation: %{key: "payment_id", value: "PAY-456"}  # Wrong key!
})
```

## Expressions

BPMN condition expressions support two languages: FEEL and Elixir. FEEL is
provided by the standalone `rodar_feel` package (`RodarFeel`), which is included
as a dependency. They have different binding conventions.

```elixir
# GOOD: FEEL expressions receive data directly — write naturally
# If context data is %{count: 10, status: "active"}
# In BPMN XML: <conditionExpression language="feel">count > 5</conditionExpression>

# GOOD: Elixir expressions access data through the "data" binding
# In BPMN XML: <conditionExpression language="elixir">data["count"] > 5</conditionExpression>

# GOOD: FEEL supports temporal literals and arithmetic in conditions
# <conditionExpression language="feel">due_date < today()</conditionExpression>
# <conditionExpression language="feel">age >= @"P18Y"</conditionExpression>

# GOOD: FEEL supports instance of for type-based routing
# <conditionExpression language="feel">amount instance of number</conditionExpression>

# BAD: Using Elixir syntax in a FEEL expression
# language="feel": data["count"] > 5  — FEEL doesn't have data["..."] syntax

# BAD: Using FEEL syntax in an Elixir expression
# language="elixir": count > 5  — "count" is not bound; use data["count"]

# BAD: Expecting FEEL eval to raise — it returns {:ok, _} or {:error, _} tuples
result = RodarFeel.eval("1 + 2", %{})
# result is {:ok, 3}, not 3
# Note: Rodar.Expression.evaluate/3 does raise on {:error, _} internally

# BAD: Using atom keys exclusively — FEEL uses string keys canonically
RodarFeel.eval("count > 5", %{count: 10})
# Works via flex_get, but string keys take precedence and are the convention
# Prefer: %{"count" => 10}
```

### FEEL Temporal Types

FEEL has built-in date, time, datetime, and duration support. These are useful
in timer conditions, deadline checks, and date-based routing.

```elixir
# GOOD: Use @"..." literals for temporal values in FEEL expressions
# Dates, times, datetimes, and durations all use the @"..." syntax
RodarFeel.eval(~s|@"2024-03-20" + @"P1M"|, %{})
# => {:ok, ~D[2024-04-20]}

# GOOD: Pass Elixir temporal values as bindings
RodarFeel.eval("due_date < today()", %{"due_date" => ~D[2024-01-15]})
# => {:ok, true}

# GOOD: Access temporal properties
RodarFeel.eval("order_date.year", %{"order_date" => ~D[2024-03-20]})
# => {:ok, 2024}
# Available properties: .year, .month, .day, .hour, .minute, .second,
# .timezone, .offset

# GOOD: Use temporal built-in functions
# now(), today(), date(s), time(s), date and time(s), duration(s)

# BAD: Using Elixir date syntax in FEEL — use @"..." or built-in functions
# ~D[2024-03-20] works as a binding value, but not as a literal in FEEL text
```

### FEEL User-Defined Functions

FEEL supports lambdas with closures for reusable logic within expressions.

```elixir
# GOOD: Define functions in context literals for reuse
RodarFeel.eval("""
{
  discount: function(price, rate) price * rate,
  final: price - discount(price, 0.1)
}
""", %{"price" => 100})
# => {:ok, %{"discount" => {:feel_function, ...}, "final" => 90.0}}

# BAD: Expecting FEEL functions to be Elixir functions
# {:feel_function, params, body_ast, closure} is an internal representation
# You cannot call them from Elixir — only from within FEEL expressions
```

## Persistence

Persistence requires explicit configuration. Without it, dehydrate/rehydrate
won't work.

```elixir
# GOOD: Configure persistence in your app config
# config/config.exs
config :rodar, :persistence,
  adapter: Rodar.Persistence.Adapter.ETS,
  auto_dehydrate: true

# GOOD: Manual dehydrate and rehydrate
{:ok, instance_id} = Rodar.Process.dehydrate(pid)
# Later...
{:ok, new_pid} = Rodar.Process.rehydrate(instance_id)

# GOOD: auto_dehydrate saves automatically when process hits {:manual, _}
# Just configure auto_dehydrate: true and it happens on suspend

# BAD: Assuming persistence works without configuration
# No persistence config → adapter defaults but ETS adapter must be in supervision tree
{:ok, instance_id} = Rodar.Process.dehydrate(pid)  # May fail

# BAD: Expecting auto-dehydrate on {:ok, _} — it only fires on {:manual, _}
# Completed processes are NOT auto-dehydrated
```

## Validation

Validation is opt-in. You can validate explicitly or enable it as a gate
before process activation.

```elixir
# GOOD: Explicit validation before registration
%{processes: [{:bpmn_process, _attrs, elements} | _]} = Rodar.Engine.Diagram.load(xml)
process_map = Map.new(elements, fn {_type, %{id: id}} = elem -> {id, elem} end)
{:ok, _} = Rodar.Validation.validate(process_map)

# GOOD: Enable validation gate on activate
# config/config.exs
config :rodar, :validate_on_activate, true
# Now Process.activate/1 validates before running

# BAD: Passing the raw Diagram.load/1 result to validate/1
# validate/1 expects a process_map (%{id => element}), not the diagram struct
diagram = Rodar.Engine.Diagram.load(xml)
Rodar.Validation.validate(diagram)  # Wrong shape!
```

## Version Management

The registry supports versioned process definitions for safe updates.

```elixir
# GOOD: Register multiple versions, look up specific ones
Rodar.Registry.register("my_process", process_v1)  # version 1
Rodar.Registry.register("my_process", process_v2)  # version 2

{:ok, latest} = Rodar.Registry.lookup("my_process")       # v2
{:ok, v1} = Rodar.Registry.lookup("my_process", 1)        # v1

# GOOD: Migrate running instances to a new version
:ok = Rodar.Migration.migrate(process_pid, 2)

# BAD: Assuming register/2 replaces — it creates a new version
Rodar.Registry.register("my_process", process_v1)
Rodar.Registry.register("my_process", process_v2)
# Both versions exist; lookup/1 returns v2, but v1 is still accessible
```

## Common Patterns

```elixir
# GOOD: Full end-to-end pattern
xml = File.read!("order_process.bpmn")

diagram = Rodar.Engine.Diagram.load(xml,
  handler_map: %{
    "Task_validate" => MyApp.ValidateOrder,
    "Task_charge" => MyApp.ChargePayment
  }
)

[process | _] = diagram.processes
Rodar.Registry.register("order_process", process)
{:ok, pid} = Rodar.Process.create_and_run("order_process", %{order_id: "123"})

case Rodar.Process.status(pid) do
  :completed -> :done
  :suspended -> :waiting_for_manual_task
  :error -> :handle_error
end
```

## Scaffolding Handlers

The `mix rodar.scaffold` task generates handler stubs from a BPMN file.
It picks the correct behaviour based on task type and prints wiring instructions.

```elixir
# GOOD: Scaffold handlers, then customize the generated stubs
# $ mix rodar.scaffold order_process.bpmn
# Creates lib/my_app/workflow/order_process/handlers/*.ex

# GOOD: Preview before writing with --dry-run
# $ mix rodar.scaffold order_process.bpmn --dry-run

# GOOD: Customize output location and module prefix
# $ mix rodar.scaffold order_process.bpmn \
#     --output-dir lib/my_app/handlers \
#     --module-prefix MyApp.Handlers

# GOOD: After scaffolding, wire service task handlers via handler_map
handler_map = %{
  "Task_check_inventory" => MyApp.Handlers.CheckInventory,
  "Task_charge_payment" => MyApp.Handlers.ChargePayment
}
diagram = Rodar.Engine.Diagram.load(xml, handler_map: handler_map)

# GOOD: After scaffolding, wire non-service task handlers via TaskRegistry
Rodar.TaskRegistry.register("Task_approval", MyApp.Handlers.Approval)

# BAD: Using Service.Handler behaviour for non-service tasks
# The scaffold task picks the right behaviour automatically — don't change it
# Service tasks → Service.Handler (execute/2)
# All other tasks → TaskHandler (token_in/2)

# BAD: Forgetting to wire handlers after scaffolding
# Generated stubs are not auto-registered — you must wire them yourself
# Follow the registration instructions printed by the scaffold task
```

## Convention-Based Handler Discovery

After scaffolding handlers with `mix rodar.scaffold`, the engine can
auto-discover them at parse time. When you pass `:bpmn_file` and `:app_name` to
`Diagram.load/2`, it checks whether handler modules exist at the conventional
namespace (`AppName.Workflow.BpmnBaseName.Handlers.TaskName`) and wires them
automatically. The namespace segment (default `"Workflow"`) is configurable via
`config :rodar, :scaffold_namespace, "CustomNamespace"`.

```elixir
# GOOD: Enable auto-discovery by passing :bpmn_file and :app_name
# Assumes handlers were scaffolded at MyApp.Workflow.OrderProcessing.Handlers.*
xml = File.read!("order_processing.bpmn")

diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp"
)

# Discovery results are in diagram.discovery
# %{handler_map: %{"Task_1" => MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder, ...},
#   task_registry_entries: [{"Task_user_1", MyApp.Workflow.OrderProcessing.Handlers.ApproveOrder}],
#   not_found: ["Task_3"]}

# GOOD: Mix explicit handler_map with discovery (explicit wins)
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp",
  handler_map: %{"Task_1" => MyApp.CustomHandler}  # overrides discovered handler
)

# GOOD: Register discovered non-service task handlers in TaskRegistry
Rodar.Scaffold.Discovery.register_discovered(diagram.discovery)

# GOOD: Disable discovery when you don't want it
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp",
  discover_handlers: false
)

# GOOD: Use discovery programmatically for more control
alias Rodar.Scaffold.Discovery
diagram = Rodar.Engine.Diagram.load(xml)
result = Discovery.discover(diagram, module_prefix: "MyApp.Workflow.OrderProcessing.Handlers")
diagram = Discovery.apply_handlers(diagram, result.handler_map)
Discovery.register_discovered(result)

# BAD: Passing :bpmn_file without :app_name — discovery silently skipped
diagram = Rodar.Engine.Diagram.load(xml, bpmn_file: "order_processing.bpmn")
# No :app_name → no discovery happens, no :discovery key in result

# BAD: Expecting discovery to work without scaffolding first
# Discovery only finds modules that already exist and implement the correct callback
# If you haven't created the handler modules, everything lands in :not_found

# BAD: Forgetting to register non-service task handlers after discovery
diagram = Rodar.Engine.Diagram.load(xml, bpmn_file: "f.bpmn", app_name: "MyApp")
# Service tasks are wired automatically via handler_map injection,
# but user/send/receive/manual tasks need TaskRegistry registration:
# Discovery.register_discovered(diagram.discovery)  # Don't forget this!
```

### Subprocess Handler Discovery

Discovery is recursive — tasks inside embedded subprocesses are discovered
using the same naming convention as top-level tasks. A service task named
"Check Stock" inside a subprocess is expected at
`MyApp.Workflow.OrderProcessing.Handlers.CheckStock`, just like a top-level task.
This works at any nesting depth (subprocesses within subprocesses).

```elixir
# GOOD: Handlers inside subprocesses are discovered automatically
# No extra configuration needed — just scaffold and load
# $ mix rodar.scaffold order_processing.bpmn
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp"
)
# Tasks inside subprocesses appear in diagram.discovery alongside top-level tasks

# BAD: Assuming subprocess tasks need a different namespace
# Subprocess tasks use the SAME handler namespace as top-level tasks
# MyApp.Workflow.OrderProcessing.Handlers.CheckStock  (correct)
# MyApp.Workflow.OrderProcessing.Handlers.Sub1.CheckStock  (wrong — no subprocess nesting in module path)
```

## Event Subprocesses

Event subprocesses are subprocesses with `triggeredByEvent="true"` in BPMN XML.
They have no incoming/outgoing sequence flows from the parent process -- they
activate only when their start event fires (message, signal, timer, error,
escalation, or conditional). The parser emits `:bpmn_activity_subprocess_event`
for these elements.

Interrupting event subprocesses (default, `isInterrupting="true"` on start event)
cancel the parent scope. Non-interrupting ones (`isInterrupting="false"`) run in
parallel and can fire multiple times.

Event subprocess start events are automatically registered when the parent
process start event executes.

```elixir
# GOOD: Event subprocesses are parsed and registered automatically
xml = File.read!("process_with_event_sub.bpmn")
diagram = Rodar.Engine.Diagram.load(xml)
[process | _] = diagram.processes
Rodar.Registry.register("my_process", process)
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{})
# Event subprocess triggers are now active — publishing a matching
# message/signal will activate the event subprocess

# GOOD: Check that a subprocess was parsed as an event subprocess
{:bpmn_process, _attrs, elements} = process
{:bpmn_activity_subprocess_event, attrs} = elements["EventSub_1"]
# attrs.elements contains the nested subprocess elements

# GOOD: Event subprocesses export correctly with triggeredByEvent
exported = Rodar.Engine.Diagram.Export.to_xml(diagram)
# Contains: <bpmn2:subProcess id="EventSub_1" triggeredByEvent="true">

# BAD: Expecting event subprocesses to have incoming/outgoing flows
# Event subprocesses are NOT part of the normal sequence flow
# They activate ONLY via their start event trigger

# BAD: Manually calling token_in on an event subprocess
# token_in is a no-op — event subprocesses activate via event triggers
Rodar.execute({:bpmn_activity_subprocess_event, attrs}, context)
# Returns {:ok, context} without executing the subprocess
```

## Workflow DSL

The Workflow modules provide two layers of abstraction over the low-level engine
API. **Layer 1** (`Rodar.Workflow`) is a functional API with a `use` macro.
**Layer 2** (`Rodar.Workflow.Server`) adds a GenServer with instance tracking.

### Layer 1: Functional API / `use` macro

```elixir
# GOOD: Use the macro to eliminate boilerplate
defmodule MyApp.OrderWorkflow do
  use Rodar.Workflow,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app,        # optional — resolves path via Application.app_dir
    app_name: "MyApp"        # optional — enables handler auto-discovery
end

# Then call the injected functions:
MyApp.OrderWorkflow.setup()
{:ok, pid} = MyApp.OrderWorkflow.start_process(%{"item" => "widget"})
:suspended = MyApp.OrderWorkflow.process_status(pid)
MyApp.OrderWorkflow.resume_user_task(pid, "Task_Approval", %{"approved" => true})
data = MyApp.OrderWorkflow.process_data(pid)

# GOOD: Use the functional API directly (without the macro)
Rodar.Workflow.setup(
  bpmn_file: "priv/bpmn/order.bpmn",
  process_id: "order"
)
{:ok, pid} = Rodar.Workflow.start_process("order", %{"item" => "widget"})
:suspended = Rodar.Workflow.process_status(pid)

# GOOD: start_process sets data BEFORE activation (unlike create_and_run)
# This matters when service tasks need data during the initial execution
{:ok, pid} = Rodar.Workflow.start_process("order", %{"customer" => "Acme"})

# BAD: Forgetting to call setup before start_process
# setup registers the BPMN definition — without it, start_process fails
{:ok, pid} = MyApp.OrderWorkflow.start_process(%{"item" => "widget"})
# => {:error, ...} because "order_processing" is not in the Registry

# BAD: Passing a process_id to the macro's start_process
# The macro bakes in the process_id from options — just pass data
{:ok, pid} = MyApp.OrderWorkflow.start_process("order_processing", %{})
# => Wrong arity — the injected start_process/1 only takes a data map

# BAD: Using resume_user_task on a non-user task
Rodar.Workflow.resume_user_task(pid, "ServiceTask_1", %{})
# => {:error, "Task 'ServiceTask_1' is :bpmn_activity_task_service, not a user task"}
```

### Layer 2: GenServer with instance tracking

```elixir
# GOOD: Use Workflow.Server for stateful workflow management
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

  # Optional: translate BPMN statuses to domain terms
  @impl Rodar.Workflow.Server
  def map_status(:suspended), do: :pending_approval
  def map_status(other), do: other

  # Expose domain-specific API on top of the injected functions
  def create_order(params), do: create_instance(params)
  def approve(id), do: complete_task(id, "Task_Approval", %{"approved" => true})
end

# Start in your supervision tree
children = [MyApp.OrderManager]

# Then use the domain API:
{:ok, instance} = MyApp.OrderManager.create_order(%{"customer" => "Acme"})
instance.id       # => 1 (sequential integer)
instance.status   # => :pending_approval (mapped from :suspended)

{:ok, updated} = MyApp.OrderManager.approve(1)
updated.status    # => :completed

instances = MyApp.OrderManager.list_instances()  # newest first
{:ok, inst} = MyApp.OrderManager.get_instance(1)

# GOOD: init_data/2 receives the sequential instance_id — use it for correlation
def init_data(params, instance_id) do
  %{"order_id" => "ORD-#{instance_id}", "items" => params["items"]}
end

# BAD: Forgetting to implement init_data/2 — it is a required callback
defmodule MyApp.BadManager do
  use Rodar.Workflow.Server,
    bpmn_file: "priv/bpmn/order.bpmn",
    process_id: "order"

  # Missing init_data/2 — compilation warning, runtime crash on create_instance
end

# BAD: Returning non-map from init_data/2
def init_data(_params, _id), do: "not a map"
# => Context.put_data expects string keys and values

# BAD: Using GenServer.call with plain atoms — use the injected functions
GenServer.call(MyApp.OrderManager, :create_instance)
# => No match — internal messages use {:__workflow__, action, ...} tuples
# Use MyApp.OrderManager.create_instance/1 instead

# BAD: Starting Workflow.Server without it being in the supervision tree
# The GenServer calls setup() in init/1, which needs Registry and other
# OTP processes to be running
MyApp.OrderManager.start_link()
# => May fail if Rodar.Application hasn't started
```

## Error Handling

The engine uses tagged tuples consistently for errors. Unknown element types
return `{:not_implemented}` (not `nil`), file errors include the path, and
setup failures are wrapped with context.

```elixir
# GOOD: Handle {:not_implemented} from dispatch for unknown elements
result = Rodar.execute({:my_custom_type, %{id: "task_1"}}, context)
case result do
  {:ok, context} -> :success
  {:error, msg} -> Logger.error(msg)
  {:not_implemented} -> Logger.warning("No handler for element")
end

# GOOD: Handle Workflow.setup errors — they include the file path
case Rodar.Workflow.setup(bpmn_file: path, process_id: id) do
  {:ok, diagram} -> diagram
  {:error, msg} when is_binary(msg) -> Logger.error(msg)
  # e.g. "Could not read BPMN file 'missing.bpmn': :enoent"
end

# GOOD: Handle complete_task errors — they propagate from resume_user_task
case MyApp.OrderManager.complete_task(instance_id, task_id, input) do
  {:ok, updated} -> updated
  {:error, :not_found} -> :unknown_instance
  {:error, msg} when is_binary(msg) -> Logger.error(msg)
  # e.g. "Task 'Bad_Id' not found in process"
end

# GOOD: Handle Workflow.Server init failure
case MyApp.OrderManager.start_link() do
  {:ok, pid} -> pid
  {:error, {:workflow_setup_failed, reason}} -> Logger.error("Setup failed: #{reason}")
end

# BAD: Assuming dispatch returns nil for unknown elements
result = Rodar.execute({:unknown, %{id: "x"}}, context)
if result == nil, do: :no_handler  # Wrong — returns {:not_implemented} now

# BAD: Pattern-matching on raw :enoent from Workflow.setup
{:error, :enoent} = Rodar.Workflow.setup(bpmn_file: "bad.bpmn", process_id: "x")
# Wrong — errors are now descriptive strings, not bare atoms

# BAD: Ignoring complete_task result — errors are now propagated
MyApp.OrderManager.complete_task(1, "Wrong_Task", %{})
# Returns {:error, "Task 'Wrong_Task' not found in process"} — handle it!
```

## Transaction Subprocesses

Transaction subprocesses (`bpmn2:transaction`) extend embedded subprocess
semantics with cancel/compensation behavior. When a cancel end event fires
inside a transaction, scoped compensation runs (only activities within the
transaction) and the cancel boundary event on the transaction fires.

```elixir
# GOOD: Transaction subprocess in BPMN XML uses <bpmn:transaction> tag
# It is parsed as :bpmn_activity_subprocess_transaction
xml = """
<bpmn:transaction id="Txn_1" name="Book Trip">
  <bpmn:startEvent id="Txn_Start"><bpmn:outgoing>F1</bpmn:outgoing></bpmn:startEvent>
  <bpmn:task id="Book_Hotel"><bpmn:incoming>F1</bpmn:incoming><bpmn:outgoing>F2</bpmn:outgoing></bpmn:task>
  <bpmn:endEvent id="Cancel_End"><bpmn:incoming>F2</bpmn:incoming><bpmn:cancelEventDefinition/></bpmn:endEvent>
  <bpmn:sequenceFlow id="F1" sourceRef="Txn_Start" targetRef="Book_Hotel"/>
  <bpmn:sequenceFlow id="F2" sourceRef="Book_Hotel" targetRef="Cancel_End"/>
</bpmn:transaction>
<bpmn:boundaryEvent id="Cancel_Boundary" attachedToRef="Txn_1">
  <bpmn:outgoing>F3</bpmn:outgoing>
  <bpmn:cancelEventDefinition/>
</bpmn:boundaryEvent>
"""

# GOOD: Use Compensation.compensate_scope/2 for transaction-scoped compensation
# Only compensates activities within the transaction, not the whole process
Rodar.Compensation.compensate_scope(context, ["Book_Hotel", "Book_Flight"])

# GOOD: Use Compensation.compensate_all/1 for global compensation
Rodar.Compensation.compensate_all(context)

# BAD: Using compensate_all when inside a transaction — compensates parent too
# Cancel end events automatically use scoped compensation via the transaction scope

# BAD: Confusing <bpmn:subProcess> with <bpmn:transaction>
# subProcess → :bpmn_activity_subprocess_embeded (no cancel semantics)
# transaction → :bpmn_activity_subprocess_transaction (cancel + scoped compensation)

# BAD: Using cancelEventDefinition outside a transaction subprocess
# Cancel end events only make sense inside a transaction
# Cancel boundary events only make sense attached to a transaction
```

## Data I/O Mapping

Tasks can use `ioSpecification` with `dataInputAssociation` and `dataOutputAssociation`
to control which data flows into and out of a task. This is opt-in — tasks without
`ioSpecification` receive the full context data map (backward compatible).

```elixir
# GOOD: Service handler receives only mapped inputs when ioSpecification is present
# In BPMN XML, the service task has:
#   <ioSpecification>
#     <dataInput id="din_1" name="order_id"/>
#     <dataOutput id="dout_1" name="result"/>
#   </ioSpecification>
#   <dataInputAssociation>
#     <sourceRef>order_id</sourceRef>      <!-- context data key -->
#     <targetRef>din_1</targetRef>          <!-- task input slot -->
#   </dataInputAssociation>
#   <dataOutputAssociation>
#     <sourceRef>handler_result</sourceRef> <!-- handler result key -->
#     <targetRef>order_status</targetRef>   <!-- context data key to write -->
#   </dataOutputAssociation>

# The handler only sees %{"din_1" => 42}, NOT the full context data
defmodule MyApp.ProcessOrder do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    order_id = data["din_1"]
    {:ok, %{"handler_result" => process(order_id)}}
  end
end

# GOOD: Use DataMapper directly for custom logic
alias Rodar.Activity.DataMapper
data = DataMapper.map_inputs(element_attrs, context)
DataMapper.map_outputs(element_attrs, result_map, context)

# GOOD: Check if an element has I/O mapping
if DataMapper.has_io_spec?(attrs) do
  # scoped data
else
  # full context data
end

# BAD: Assuming handler always gets full context data
# When ioSpecification is present, only mapped keys are passed
def execute(_attrs, data) do
  # data["secret_key"] may be nil if not in dataInputAssociation!
  {:ok, %{}}
end

# BAD: Writing output keys that don't match dataOutputAssociation sourceRef
# If the association maps "result" -> "order_result",
# but handler returns %{"wrong_key" => value}, it won't be written to context
def execute(_attrs, _data) do
  {:ok, %{"wrong_key" => "value"}}  # Not mapped — lost!
end
```

## Lanes (Role/Group Assignment)

Lanes are structural metadata that assign flow nodes to roles, groups, or
departments. They do not affect execution — the engine treats them as read-only
annotations stored in the process attrs (`:lane_set` key).

```elixir
# GOOD: Query lane assignment for a node (e.g., route a manual task)
%{processes: [process | _]} = Rodar.Engine.Diagram.load(xml)
{:bpmn_process, attrs, _elements} = process

# Find which lane a specific node belongs to
{:ok, lane} = Rodar.Lane.find_lane_for_node(attrs.lane_set, "UserTask_1")
lane.name  # => "HR Department"

# Build a lookup map for all nodes
node_map = Rodar.Lane.node_lane_map(attrs.lane_set)
node_map["UserTask_1"].name  # => "HR Department"

# Get a flat list of all lanes (including nested)
all = Rodar.Lane.all_lanes(attrs.lane_set)

# Validate lane refs against the process
{:ok, _} = Rodar.Validation.validate_lanes(attrs.lane_set, elements)

# BAD: Trying to access lane_set from the elements map
# Lane set is in the process *attrs*, not in the elements map
elements["LaneSet_1"]  # => nil — lanes are not elements

# BAD: Assuming lane_set is always present
# lane_set is nil when the BPMN has no lanes
attrs.lane_set.lanes  # => KeyError if no lanes in the process

# GOOD: Handle nil gracefully (all Lane functions accept nil)
Rodar.Lane.find_lane_for_node(nil, "task1")  # => :error
Rodar.Lane.node_lane_map(nil)                 # => %{}
Rodar.Lane.all_lanes(nil)                      # => []
```

## Boundary Events (Interrupting vs Non-Interrupting)

Boundary events attach to activities. The `cancelActivity` attribute (boolean,
defaults to `true`) controls whether the parent activity is interrupted when the
boundary fires.

```elixir
# GOOD: Non-interrupting boundary event in BPMN XML
# <bpmn:boundaryEvent id="Timer_1" attachedToRef="Task_1" cancelActivity="false">
#   <bpmn:timerEventDefinition><bpmn:timeDuration>PT5M</bpmn:timeDuration></bpmn:timerEventDefinition>
# </bpmn:boundaryEvent>
#
# The parser normalizes cancelActivity to a boolean:
%{processes: [process]} = Rodar.Engine.Diagram.load(xml)
{:bpmn_process, _, elements} = process
{:bpmn_event_boundary, attrs} = elements["Timer_1"]
attrs.cancelActivity  # => false (boolean, not string)

# GOOD: Non-interrupting boundary fires its path WITHOUT cancelling the parent
# The parent activity continues running; the boundary path runs in parallel

# GOOD: Error boundaries are always interrupting per BPMN spec
# Even with cancelActivity="false", error boundaries interrupt the parent

# BAD: Expecting cancelActivity to be a string
attrs.cancelActivity == "false"  # Wrong — it's a boolean now

# BAD: Forgetting the default — cancelActivity defaults to true (interrupting)
# If you omit cancelActivity in your BPMN XML, the boundary will interrupt
```

## Link Events (Intra-Process GOTO)

Link events act as intra-process GOTOs. A link throw event jumps execution to
the matching link catch event (paired by name). The throw scans the process map
for a catch with the same link name and releases the token to the catch's
outgoing flows. No event bus or registry is involved.

Link catch events are passive targets — when reached via normal token flow
(not from a throw), they simply pass through to their outgoing flows.

```elixir
# GOOD: Link throw and catch paired by name in BPMN XML
# <bpmn:intermediateThrowEvent id="throw1">
#   <bpmn:linkEventDefinition name="GoToSection2" />
# </bpmn:intermediateThrowEvent>
# <bpmn:intermediateCatchEvent id="catch1">
#   <bpmn:linkEventDefinition name="GoToSection2" />
# </bpmn:intermediateCatchEvent>

# Parsed elements will have:
# {:bpmn_event_intermediate_throw, %{linkEventDefinition: {:bpmn_event_definition_link, %{name: "GoToSection2"}}, ...}}
# {:bpmn_event_intermediate_catch, %{linkEventDefinition: {:bpmn_event_definition_link, %{name: "GoToSection2"}}, ...}}

# The throw handler finds the catch by name and releases token to catch's outgoing flows

# BAD: Using different link names for throw and catch
# The throw will return {:error, "no matching link catch event with name '...'"}
# <bpmn:intermediateThrowEvent id="throw1">
#   <bpmn:linkEventDefinition name="SectionA" />
# </bpmn:intermediateThrowEvent>
# <bpmn:intermediateCatchEvent id="catch1">
#   <bpmn:linkEventDefinition name="SectionB" />    <!-- names don't match! -->
# </bpmn:intermediateCatchEvent>

# BAD: Using link events across processes
# Link events are intra-process only. For cross-process communication,
# use message events with the event bus instead.
```

## Multi-Instance Activities

Multi-instance activities execute a task or subprocess multiple times based on
BPMN `multiInstanceLoopCharacteristics`. The engine handles this transparently —
any activity type supports multi-instance without handler changes.

```elixir
# GOOD: Define multi-instance in BPMN XML — no handler changes needed
# <bpmn:serviceTask id="Task_Send_Emails" name="Send Email">
#   <bpmn:multiInstanceLoopCharacteristics isSequential="true" loopDataInputRef="recipients">
#     <bpmn:inputDataItem name="recipient"/>
#     <bpmn:outputDataItem name="send_results"/>
#   </bpmn:multiInstanceLoopCharacteristics>
# </bpmn:serviceTask>

# GOOD: Service handler reads the loop variable naturally — no MI awareness needed
defmodule MyApp.SendEmail do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    recipient = Map.get(data, "recipient")
    result = Mailer.send(recipient)
    {:ok, %{"_mi_current_result" => result}}
  end
end

# GOOD: Use loopCardinality for a fixed number of iterations
# <bpmn:multiInstanceLoopCharacteristics>
#   <bpmn:loopCardinality>3</bpmn:loopCardinality>
# </bpmn:multiInstanceLoopCharacteristics>

# GOOD: Use completionCondition for early termination (FEEL expression)
# <bpmn:multiInstanceLoopCharacteristics isSequential="true">
#   <bpmn:loopCardinality>100</bpmn:loopCardinality>
#   <bpmn:completionCondition>loopCounter >= 5</bpmn:completionCondition>
# </bpmn:multiInstanceLoopCharacteristics>

# GOOD: Store per-iteration results via _mi_current_result
def execute(_attrs, data) do
  counter = Map.get(data, "loopCounter")
  {:ok, %{"_mi_current_result" => "processed_#{counter}"}}
end
# Results collected into the outputDataItem variable (or "_mi_results" by default)

# BAD: Trying to manage multi-instance logic inside the handler
defmodule MyApp.BadMIHandler do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    items = Map.get(data, "items", [])
    # Don't loop manually — let BPMN multi-instance handle it!
    results = Enum.map(items, &process/1)
    {:ok, %{results: results}}
  end
end

# BAD: Multi-instance without loopCardinality or loopDataInputRef
# Validation will reject this — one of them is required
# <bpmn:multiInstanceLoopCharacteristics isSequential="true">
#   <!-- Missing loopCardinality AND loopDataInputRef -->
# </bpmn:multiInstanceLoopCharacteristics>

# BAD: Forgetting to set the input collection in context data
# When using loopDataInputRef, the collection must exist in context data
{:ok, pid} = Rodar.Process.create_and_run("my_process", %{})
# If loopDataInputRef="items" but "items" is not in data → error
```
