# Rodar Workflow Engine

[![CI](https://github.com/rodar-project/rodar/actions/workflows/ci.yml/badge.svg)](https://github.com/rodar-project/rodar/actions/workflows/ci.yml)

A BPMN 2.0 execution engine for Elixir. Parses BPMN 2.0 XML diagrams and executes processes using a token-based flow model.

## Table of contents

1. [Installation](#installation)
2. [Usage](#usage)
3. [Supported BPMN Elements](#supported-bpmn-elements)
4. [Architecture](#architecture)
5. [Task Handlers](#task-handlers)
6. [Hooks](#hooks)
7. [Validation](#validation)
8. [Collaboration](#collaboration)
9. [Observability](#observability)
10. [CLI Tools](#cli-tools)
11. [Development](#development)
12. [Versioning & Releases](#versioning--releases)
13. [Contributing](CONTRIBUTING.md)
14. [Code of Conduct](CODE_OF_CONDUCT.md)
15. [License](#license)
16. [References](#references)

## Installation

Add `rodar` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:rodar, github: "rodar-project/rodar"}]
end
```

Requires Elixir ~> 1.16 and OTP 27+.

## Usage

### Quick Start (Using Process Registry)

```elixir
# 1. Load and parse a BPMN diagram
diagram = Rodar.Engine.Diagram.load(File.read!("my_process.bpmn"))
{:bpmn_process, _attrs, _elements} = process = hd(diagram.processes)

# 2. Register the process definition
Rodar.Registry.register("my-process", process)

# 3. Create and run a process instance
{:ok, pid} = Rodar.Process.create_and_run("my-process", %{"username" => "alice"})

# 4. Check status and access results
Rodar.Process.status(pid)
# => :completed

context = Rodar.Process.get_context(pid)
Rodar.Context.get_data(context, "result")
```

### Manual Execution

```elixir
# 1. Load and parse a BPMN diagram
diagram = Rodar.Engine.Diagram.load(File.read!("my_process.bpmn"))
[{:bpmn_process, _attrs, elements}] = diagram.processes

# 2. Create an execution context with initial data
{:ok, context} = Rodar.Context.start_link(elements, %{"username" => "alice"})

# 3. Find and execute the start event
start_event = elements["StartEvent_1"]
result = Rodar.execute(start_event, context)

case result do
  {:ok, context}       -> # Process completed successfully
  {:manual, task_data} -> # Waiting for user input (user task)
  {:error, message}    -> # Error occurred
  {:not_implemented}   -> # Reached an unimplemented node
end
```

### Workflow API

For most applications, the Workflow API eliminates boilerplate. Layer 1 (`RodarBpmn.Workflow`) provides a functional API; Layer 2 (`RodarBpmn.Workflow.Server`) adds a GenServer with instance tracking.

```elixir
# Layer 1 — functional API via `use` macro
defmodule MyApp.OrderWorkflow do
  use RodarBpmn.Workflow,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app
end

MyApp.OrderWorkflow.setup()
{:ok, pid} = MyApp.OrderWorkflow.start_process(%{"customer" => "alice"})
MyApp.OrderWorkflow.process_status(pid)
```

```elixir
# Layer 2 — GenServer with instance tracking
defmodule MyApp.OrderManager do
  use RodarBpmn.Workflow.Server,
    bpmn_file: "priv/bpmn/order_processing.bpmn",
    process_id: "order_processing",
    otp_app: :my_app

  @impl RodarBpmn.Workflow.Server
  def init_data(params, instance_id) do
    %{"customer" => params["customer"], "order_id" => instance_id}
  end

  def create_order(params), do: create_instance(params)
  def approve(id), do: complete_task(id, "Task_Approval", %{"approved" => true})
end
```

See the [Workflow guide](guides/workflow.md) for the full API reference, smart completion detection, status mapping, and pending-task querying patterns.

### Resuming Paused Tasks

User tasks, manual tasks, and receive tasks all pause execution and return `{:manual, task_data}`. Resume them with input data:

```elixir
# User task — waiting for user input
Rodar.Activity.Task.User.resume(user_task_element, context, %{approved: true})

# Manual task — waiting for external completion signal
Rodar.Activity.Task.Manual.resume(manual_task_element, context, %{signed: true})

# Receive task — waiting for an external message
Rodar.Activity.Task.Receive.resume(receive_task_element, context, %{payment_id: "PAY-123"})
```

### Event Bus (Message and Signal Events)

The event bus enables communication between process nodes via messages, signals, and escalations:

```elixir
# Subscribe a catch event to wait for a message
Rodar.Event.Bus.subscribe(:message, "order_received", %{
  context: context,
  node_id: "catch1",
  outgoing: ["flow_out"]
})

# Publish a message (delivers to first subscriber, point-to-point)
Rodar.Event.Bus.publish(:message, "order_received", %{data: %{order_id: "123"}})

# Publish a signal (broadcasts to ALL subscribers)
Rodar.Event.Bus.publish(:signal, "system_alert", %{data: %{level: "warning"}})

# Send tasks auto-publish when messageRef is set
# Receive tasks auto-subscribe when messageRef is set
```

#### Message Correlation Keys

When multiple process instances wait for the same message name, correlation keys route messages to the correct instance:

```elixir
# Subscriber includes correlation metadata
Rodar.Event.Bus.subscribe(:message, "payment_confirmed", %{
  context: context,
  node_id: "catch1",
  outgoing: ["flow_out"],
  correlation: %{key: "order_id", value: "ORD-123"}
})

# Publisher includes matching correlation — routes to the correct subscriber
Rodar.Event.Bus.publish(:message, "payment_confirmed", %{
  data: %{amount: 99},
  correlation: %{key: "order_id", value: "ORD-123"}
})
```

In BPMN XML, set `correlationKey` on a `messageEventDefinition` to automatically extract the correlation value from context data:

```xml
<bpmn:messageEventDefinition messageRef="payment_confirmed" correlationKey="order_id" />
```

### Triggered Start Events

Auto-create process instances when a message or signal fires:

```elixir
# Register a process that has a message start event
Rodar.Registry.register("order-process", process_definition)
Rodar.Event.Start.Trigger.register("order-process")

# Publishing the matching message auto-creates a new instance
Rodar.Event.Bus.publish(:message, "new_order", %{data: %{"item" => "widget"}})
# => A new "order-process" instance runs with %{"item" => "widget"} as init data
```

### Service Tasks

Define a handler module implementing the `Rodar.Activity.Task.Service.Handler` behaviour:

```elixir
defmodule MyApp.CheckInventory do
  @behaviour Rodar.Activity.Task.Service.Handler

  @impl true
  def execute(_attrs, data) do
    # Your business logic here
    {:ok, %{in_stock: true, quantity: 42}}
  end
end
```

Wire handlers at parse time with `handler_map`, at runtime via `TaskRegistry`, or let convention-based discovery find them automatically:

```elixir
# Option 1: Convention-based auto-discovery (recommended)
# After scaffolding handlers with `mix rodar.scaffold`, load with discovery:
diagram = Rodar.Engine.Diagram.load(xml,
  bpmn_file: "order_processing.bpmn",
  app_name: "MyApp"
)
# Discovers MyApp.Workflow.OrderProcessing.Handlers.CheckInventory automatically

# Option 2: Inject at parse time with explicit handler_map
diagram = Rodar.Engine.Diagram.load(xml, handler_map: %{
  "Task_check" => MyApp.CheckInventory
})

# Option 3: Register at runtime (looked up by task ID)
Rodar.TaskRegistry.register("Task_check", MyApp.CheckInventory)
```

Handler resolution priority:
1. Explicit `:handler` attribute (from `handler_map`) — always wins
2. Convention discovery (module at scaffold path with correct behaviour)
3. `TaskRegistry` lookup by task ID
4. `{:not_implemented}` fallback

## Supported BPMN Elements

### Events

| Element                         | Status      | Notes                                                                     |
| ------------------------------- | ----------- | ------------------------------------------------------------------------- |
| Start Event                     | Implemented | Routes token to outgoing flows                                            |
| End Event (plain)               | Implemented | Normal process completion                                                 |
| End Event (error)               | Implemented | Sets error state in context                                               |
| End Event (terminate)           | Implemented | Marks process as terminated                                               |
| Intermediate Throw Event        | Implemented | Publishes message/signal/escalation to event bus                          |
| Intermediate Catch Event        | Implemented | Subscribes to event bus or conditional evaluation; returns `{:manual, _}` |
| Boundary Event (error)          | Implemented | Activated by parent activity on error                                     |
| Boundary Event (message)        | Implemented | Subscribes to event bus                                                   |
| Boundary Event (signal)         | Implemented | Subscribes to event bus                                                   |
| Boundary Event (timer)          | Implemented | Schedules via `Process.send_after`                                        |
| Boundary Event (escalation)     | Implemented | Subscribes to event bus                                                   |
| Boundary Event (conditional)    | Implemented | Subscribes to context data changes; fires when condition becomes true     |
| Boundary Event (compensate)     | Implemented | Passive — handler registration in dispatcher                              |
| Intermediate Throw (compensate) | Implemented | Triggers compensation; supports `activityRef` and `waitForCompletion`     |
| End Event (compensate)          | Implemented | Triggers compensation on process end                                      |

### Gateways

| Element             | Status      | Notes                                                           |
| ------------------- | ----------- | --------------------------------------------------------------- |
| Exclusive Gateway   | Implemented | Condition evaluation, default flow                              |
| Parallel Gateway    | Implemented | Fork/join with token synchronization                            |
| Inclusive Gateway   | Implemented | Fork/join with condition evaluation and activated-path tracking |
| Complex Gateway     | Implemented | Expression-based activation rules; configurable join condition  |
| Event-Based Gateway | Implemented | Returns `{:manual, _}` with downstream catch event info         |

### Tasks

| Element      | Status      | Notes                                                                 |
| ------------ | ----------- | --------------------------------------------------------------------- |
| Script Task  | Implemented | Elixir (sandboxed AST evaluation), FEEL                               |
| User Task    | Implemented | Pause/resume with `{:manual, task_data}`                              |
| Service Task | Implemented | Handler behaviour callback; inline handler, TaskRegistry, or fallback |
| Send Task    | Implemented | Publishes to event bus if `messageRef` present                        |
| Receive Task | Implemented | Subscribes to event bus if `messageRef` present; auto-resume on match |
| Manual Task  | Implemented | Pause/resume like User Task; type `:manual_task`                      |

### Other

| Element                    | Status      | Notes                                                                                                           |
| -------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------- |
| Sequence Flow              | Implemented | Conditional expressions supported (Elixir + FEEL)                                                               |
| Call Activity (Subprocess) | Implemented | Looks up external process from registry, executes in child context                                              |
| Embedded Subprocess        | Implemented | Executes nested elements within parent context; error boundary event propagation                                |
| Event Bus                  | Implemented | Registry-based pub/sub for message (point-to-point with correlation keys), signal/escalation (broadcast)        |
| Compensation               | Implemented | Tracks completed activities; executes handlers in reverse order via `Rodar.Compensation`                    |
| Triggered Start Events     | Implemented | Auto-create process instances on matching message/signal via `Rodar.Event.Start.Trigger`                    |
| Timer                      | Implemented | ISO 8601 duration (`PT5S`, `PT1H30M`) and cycle parsing (`R3/PT10S`, `R/PT1M`), `Process.send_after` scheduling |
| Telemetry                  | Implemented | `:telemetry` events for node execution, process lifecycle, token creation, event bus                            |
| Observability              | Implemented | Query APIs for running/waiting instances, execution history, health checks                                      |
| Lanes                      | Implemented | Parsed into process attrs; query via `Rodar.Lane`; supports nested child lane sets                         |
| Validation                 | Implemented | 9 process rules + lane referential integrity + collaboration validation; opt-in at `activate/1`                 |
| Collaboration              | Implemented | Multi-pool/multi-participant orchestration with message flow wiring                                             |

## Task Handlers

Register custom task types or override specific task instances:

```elixir
defmodule MyApp.ApprovalHandler do
  @behaviour Rodar.TaskHandler

  @impl true
  def token_in({_type, %{id: _id, outgoing: outgoing}}, context) do
    Rodar.Context.put_data(context, "approved", true)
    Rodar.release_token(outgoing, context)
  end
end

# Register for a custom type atom
Rodar.TaskRegistry.register(:approval_task, MyApp.ApprovalHandler)

# Or override a specific task by ID
Rodar.TaskRegistry.register("Task_approval_1", MyApp.ApprovalHandler)
```

Lookup priority: task ID (string) first, then task type (atom), then built-in handlers.

## Hooks

Per-context hooks for observing execution without modifying flow:

```elixir
{:ok, context} = Rodar.Context.start_link(process, %{})

Rodar.Hooks.register(context, :before_node, fn meta ->
  IO.puts("Entering: #{meta.node_id}")
  :ok
end)

Rodar.Hooks.register(context, :on_complete, fn meta ->
  IO.puts("Done at: #{meta.node_id}")
  :ok
end)
```

Events: `:before_node`, `:after_node`, `:on_error`, `:on_complete`. Hook exceptions are caught and logged — they never break execution.

## Architecture

The engine uses a **token-based execution model**. A `Rodar.Token` struct tracks the execution pointer (current node, state, parent token for forks). Each BPMN node implements `token_in/2` to receive a token and routes it to the next node(s) via `RodarRodar.release_token/2`.

### Key Modules

- **`Rodar`** — Main dispatcher; pattern-matches element type tuples to handler modules. `execute/2` (simple) and `execute/3` (with token tracking and execution history).
- **`Rodar.Token`** — Execution token struct with ID, current node, state, and parent tracking. Supports `fork/1` for parallel branches.
- **`Rodar.Context`** — GenServer-based state management (process data, node metadata, gateway token tracking, execution history).
- **`Rodar.Registry`** — Process definition registry using Elixir's `Registry` module. Register, lookup, and manage BPMN process definitions.
- **`Rodar.Process`** — Process lifecycle GenServer. Create instances, activate, suspend, resume, terminate. Tracks status transitions.
- **`Rodar.Expression`** — Evaluates condition expressions on sequence flows. Routes to the Elixir sandbox or FEEL evaluator based on language.
- **`Rodar.Expression.Sandbox`** — AST-restricted Elixir expression evaluator (replaces `Code.eval_string`).
- **`Rodar.Expression.Feel`** — FEEL (Friendly Enough Expression Language) evaluator. Delegates to the standalone [`rodar_feel`](https://hex.pm/packages/rodar_feel) package which provides a NimbleParsec-based parser with null propagation, three-valued boolean logic, and built-in functions.
- **`Rodar.Engine.Diagram`** — Parses BPMN 2.0 XML via `erlsom`. Extracts lane sets into process attrs (`:lane_set`). `load/2` accepts `:handler_map`, `:bpmn_file`, `:app_name`, and `:discover_handlers` options. When `:bpmn_file` and `:app_name` are provided, convention-based handler auto-discovery is enabled by default.
- **`Rodar.Event.Bus`** — Registry-based pub/sub for BPMN events (message, signal, escalation).
- **`Rodar.Event.Timer`** — ISO 8601 duration parsing and timer scheduling.
- **`Rodar.Telemetry`** — Telemetry event definitions and helpers; wraps node execution with `:telemetry.span/3`.
- **`Rodar.Telemetry.LogHandler`** — Default handler that converts telemetry events to structured `Logger` output.
- **`Rodar.Observability`** — Read-only query APIs for running instances, waiting tasks, execution history, and health checks.
- **`Rodar.Lane`** — Stateless utility module for querying lane assignments. Find a node's lane, build a node-to-lane map, or list all lanes (including nested).
- **`Rodar.Validation`** — Structural validation for process maps. 9 process rules + lane referential integrity + collaboration validation. Opt-in via config.
- **`Rodar.Collaboration`** — Multi-participant orchestration. Starts processes, wires message flows, activates all.
- **`Rodar.TaskHandler`** — Behaviour for custom task handlers. Register by type atom or task ID string via `Rodar.TaskRegistry`.
- **`Rodar.Hooks`** — Per-context hook system for observing execution (before/after node, on error, on complete).
- **`Rodar.Compensation`** — Tracks completed activities and their compensation handlers. Executes in reverse completion order.

### Supervision Tree

```
Rodar.Supervisor (one_for_one)
├── Rodar.ProcessRegistry (Elixir Registry, :unique keys)
├── Rodar.EventRegistry (Elixir Registry, :duplicate keys — event bus pub/sub)
├── Rodar.Registry (GenServer for process definitions)
├── Rodar.TaskRegistry (GenServer for custom task handler registrations)
├── Rodar.ContextSupervisor (DynamicSupervisor for context processes)
├── Rodar.ProcessSupervisor (DynamicSupervisor for process instances)
└── Rodar.Event.Start.Trigger (GenServer for signal/message-triggered start events)
```

## Validation

Validate parsed process maps for structural issues before execution:

```elixir
{:bpmn_process, _attrs, elements} = hd(diagram.processes)

case Rodar.Validation.validate(elements) do
  {:ok, _} -> IO.puts("Process is valid")
  {:error, issues} -> Enum.each(issues, &IO.puts(&1.message))
end
```

Enable automatic validation on `Rodar.Process.activate/1`:

```elixir
# In config/config.exs
config :rodar, :validate_on_activate, true
```

Checks 9 rules: start/end event existence and connectivity, sequence flow ref integrity, orphan nodes, gateway outgoing counts, exclusive gateway defaults (warning), and boundary event attachment.

For lane referential integrity (refs must exist, no duplicates at the same nesting level):

```elixir
{:bpmn_process, attrs, elements} = hd(diagram.processes)
Rodar.Validation.validate_lanes(attrs.lane_set, elements)
```

For collaboration diagrams, validate cross-process constraints:

```elixir
Rodar.Validation.validate_collaboration(diagram.collaboration, diagram.processes)
```

## Collaboration

Orchestrate multi-pool BPMN diagrams with message flows between participants:

```elixir
# Parse a collaboration diagram with multiple pools
diagram = Rodar.Engine.Diagram.load(File.read!("order_fulfillment.bpmn"))

# Start all participants — registers, wires message flows, activates
{:ok, result} = Rodar.Collaboration.start(diagram)
# => %{collaboration_id: "Collab_1", instances: %{"OrderProcess" => pid1, "PaymentProcess" => pid2}}

# Check individual process status
Rodar.Process.status(result.instances["OrderProcess"])

# Stop all processes
Rodar.Collaboration.stop(result)
```

Message flows are pre-wired via `Rodar.Event.Bus` before process activation, ensuring messages aren't lost if a throw event fires before its corresponding catch event subscribes.

## Observability

### Telemetry Events

The engine emits `:telemetry` events for all key operations. Attach your own handlers or use the built-in log handler:

```elixir
# Attach the default log handler
Rodar.Telemetry.LogHandler.attach()

# Or attach a custom handler to specific events
:telemetry.attach_many("my-handler", Rodar.Telemetry.events(), &MyHandler.handle/4, nil)
```

Events emitted:

| Event                                   | Measurements  | Metadata                                             |
| --------------------------------------- | ------------- | ---------------------------------------------------- |
| `[:rodar, :node, :start]`          | `system_time` | `node_id`, `node_type`, `token_id`                   |
| `[:rodar, :node, :stop]`           | `duration`    | `node_id`, `node_type`, `token_id`, `result`         |
| `[:rodar, :node, :exception]`      | `duration`    | `node_id`, `node_type`, `token_id`, `kind`, `reason` |
| `[:rodar, :process, :start]`       | `system_time` | `instance_id`, `process_id`                          |
| `[:rodar, :process, :stop]`        | `duration`    | `instance_id`, `process_id`, `status`                |
| `[:rodar, :token, :create]`        | `system_time` | `token_id`, `parent_id`, `node_id`                   |
| `[:rodar, :event_bus, :publish]`   | `system_time` | `event_type`, `event_name`, `subscriber_count`       |
| `[:rodar, :event_bus, :subscribe]` | `system_time` | `event_type`, `event_name`, `node_id`                |

### Dashboard Queries

```elixir
# List all running process instances
Rodar.Observability.running_instances()
# => [%{pid: #PID<0.123.0>, instance_id: "abc-123", status: :suspended}, ...]

# List only suspended (waiting) instances
Rodar.Observability.waiting_instances()

# Get execution history for a process
Rodar.Observability.execution_history(pid)

# Health check
Rodar.Observability.health()
# => %{supervisor_alive: true, process_count: 3, context_count: 3,
#       registry_definitions: 2, event_subscriptions: 5}
```

### Structured Logging

Logger metadata is automatically set during execution:

- `rodar_node_id`, `rodar_node_type`, `rodar_token_id` — set in `RodarRodar.execute/3`
- `rodar_instance_id`, `rodar_process_id` — set in `Rodar.Process` init

## CLI Tools

### Validate a BPMN file

```shell
mix rodar.validate path/to/process.bpmn
```

### Inspect parsed structure

```shell
mix rodar.inspect path/to/process.bpmn
```

### Execute a process

```shell
mix rodar.run path/to/process.bpmn
mix rodar.run path/to/process.bpmn --data '{"username": "alice"}'
```

### Scaffold handler modules

Generate handler modules for all actionable tasks in a BPMN file:

```shell
mix rodar.scaffold path/to/order.bpmn --dry-run           # Preview generated code
mix rodar.scaffold path/to/order.bpmn                     # Write handler files
mix rodar.scaffold path/to/order.bpmn --output-dir lib/my_app/handlers
mix rodar.scaffold path/to/order.bpmn --module-prefix MyApp.Custom.Handlers
mix rodar.scaffold path/to/order.bpmn --force              # Overwrite existing files
```

Generates one module per task with the correct behaviour (`Rodar.Activity.Task.Service.Handler` for service tasks, `Rodar.TaskHandler` for all others) and prints registration instructions.

Scaffolded handlers are placed at deterministic paths (e.g., `MyApp.Workflow.Order.Handlers.ValidateOrder`), enabling convention-based auto-discovery when loading with `Diagram.load/2` using `:bpmn_file` and `:app_name` options — no manual wiring required. Discovery is recursive: tasks inside embedded subprocesses are discovered at any nesting depth. The namespace segment (`Workflow`) is configurable via `config :rodar, :scaffold_namespace`.

## Development

```shell
mix deps.get          # Fetch dependencies
mix compile           # Compile the project
mix test              # Run tests
mix credo             # Lint
mix dialyzer          # Static analysis
mix docs              # Generate documentation
mix rodar.validate <file>   # Validate a BPMN file
mix rodar.inspect <file>    # Inspect parsed structure
mix rodar.run <file>        # Execute a process
mix rodar.scaffold <file>   # Generate handler modules
```

### BPMN Conformance Tests

The engine is validated against the [BPMN MIWG](https://www.omg.org/cgi-bin/doc?bmi/) reference test suite (2025 release), ensuring interoperability with diagrams from Camunda, Signavio, Bizagi, and other BPMN tools. **17 out of 21 MIWG reference files parse successfully** (94.1% element type coverage on B.2.0).

```shell
mix test test/rodar/conformance/                    # Run all conformance tests
mix test test/rodar/conformance/parse_test.exs      # MIWG parse verification
mix test test/rodar/conformance/execution_test.exs  # 12 execution patterns
mix test test/rodar/conformance/coverage_test.exs   # Element type coverage
./scripts/download_miwg.sh                          # Re-download latest MIWG files
```

Tests cover:

- **Parse conformance** — 17/21 MIWG reference files (A.1.0, A.2.0, A.2.1, A.3.0, A.4.0, B.1.0, B.2.0, C.2.0, C.4.0–C.9.2) parse correctly regardless of namespace prefix
- **Execution patterns** — 12 standard BPMN patterns (sequential, gateways, timers, messages, signals, error boundaries, compensation, subprocesses, event-based routing)
- **Element coverage** — Reports supported element types against the most complex MIWG reference (B.2.0)
- **Known gaps** — 4 files (A.4.1, C.1.0, C.1.1, C.3.0) use unqualified XML namespace conventions that the `erlsom`-based parser does not yet resolve

## Versioning & Releases

This project follows [Semantic Versioning](https://semver.org/). The version in `mix.exs` is the single source of truth. The **bump type** determines the release version, decided at release time:

| `mix.exs` version | Bump type | Release version | `mix.exs` after |
|--------------------|-----------|-----------------|-----------------|
| `1.0.8`            | `patch`   | `1.0.9`         | `1.0.9`         |
| `1.0.8`            | `minor`   | `1.1.0`         | `1.1.0`         |
| `1.0.8`            | `major`   | `2.0.0`         | `2.0.0`         |

### Create a release

1. Ensure `CHANGELOG.md` has entries under `## [Unreleased]`
2. Release:
   ```shell
   mix rodar_release patch --dry-run     # preview first
   mix rodar_release patch --publish     # release + publish to hex.pm
   git push origin main --tags
   ```

The release task bumps the version in `mix.exs`, updates CHANGELOG with the release date, commits, and tags `v{version}` (e.g., `v1.0.9`).

## Acknowledgments

This project is based on [Hashiru BPMN](https://github.com/around25/hashiru-bpmn) by [Around25](https://around25.com). We are grateful for the foundation they built — the original BPMN 2.0 XML parser and token-based execution model that this engine extends.

## License

Copyright (c) 2026 - Rodrigo Couto

Licensed under the Apache 2.0 license.

## References

- [BPMN 2.0 Specification](https://www.omg.org/spec/BPMN/2.0/About-BPMN/)
- [Elixir](https://elixir-lang.org/)
