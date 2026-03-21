# Events

BPMN events represent things that happen during process execution. The engine supports start, end, intermediate (throw/catch), and boundary events, backed by a registry-based event bus.

## Event Types

| Type | Description |
|------|-------------|
| Start | Initiates process execution (none, message, signal, timer) |
| End | Completes a process path (none, error, escalation, signal, terminate) |
| Intermediate Throw | Emits an event mid-flow (message, signal, escalation) |
| Intermediate Catch | Pauses and waits for an event (message, signal, timer, conditional) |
| Boundary | Attached to an activity, triggers on specific conditions |

## Event Bus

`Rodar.Event.Bus` provides pub/sub for inter-node and inter-process communication with two delivery modes:

- **Message** -- point-to-point delivery to the first matching subscriber, then unregisters it
- **Signal and Escalation** -- broadcast delivery to all matching subscribers

### Subscribing and Publishing

```elixir
{:ok, _key} = Rodar.Event.Bus.subscribe(:message, "order_placed", %{
  context: context,
  node_id: "catch_order",
  outgoing: ["flow_next"]
})

Rodar.Event.Bus.publish(:message, "order_placed", %{order_id: "ORD-42"})
```

### Message Correlation

When multiple process instances subscribe to the same message name, correlation keys route messages to the correct subscriber:

```elixir
# Subscriber includes correlation metadata
Rodar.Event.Bus.subscribe(:message, "payment_received", %{
  context: context,
  correlation: %{key: "order_id", value: "ORD-42"}
})

# Publisher targets the correlated subscriber
Rodar.Event.Bus.publish(:message, "payment_received", %{
  correlation: %{key: "order_id", value: "ORD-42"},
  amount: 99.99
})
```

If no correlated match is found, the bus falls back to the first uncorrelated subscriber.

## Timers

`Rodar.Event.Timer` parses ISO 8601 durations and repeating intervals:

```elixir
{:ok, 5_000} = Rodar.Event.Timer.parse_duration("PT5S")
{:ok, 90_000} = Rodar.Event.Timer.parse_duration("PT1M30S")
{:ok, 3_600_000} = Rodar.Event.Timer.parse_duration("PT1H")
```

### Cycles

Repeating timers use the `R/duration` format:

```elixir
{:ok, %{repetitions: 3, duration_ms: 10_000}} = Rodar.Event.Timer.parse_cycle("R3/PT10S")
{:ok, %{repetitions: :infinite, duration_ms: 60_000}} = Rodar.Event.Timer.parse_cycle("R/PT1M")
```

Timers are scheduled via `Process.send_after/3` and fire `{:timer_fired, ...}` or `{:timer_cycle_fired, ...}` messages to the context.

## Boundary Events

Boundary events attach to activities and trigger when specific conditions occur. The `cancelActivity` attribute (boolean, defaults to `true`) controls whether the parent activity is interrupted.

| Boundary Type | Mechanism |
|---------------|-----------|
| Error | Activated directly by the parent activity on failure |
| Message | Subscribes to the event bus for a matching message |
| Signal | Subscribes to the event bus for a matching signal |
| Timer | Schedules a timer callback |
| Conditional | Subscribes to context data changes via `subscribe_condition/4` |
| Escalation | Subscribes to the event bus for a matching escalation |
| Compensate | Passive registration -- triggered during compensation |

### Interrupting vs Non-Interrupting

- **Interrupting** (`cancelActivity="true"`, the default) -- the parent activity is cancelled when the boundary fires. The boundary's outgoing path is taken exclusively.
- **Non-interrupting** (`cancelActivity="false"`) -- the boundary fires its outgoing path in parallel while the parent activity continues. The boundary stays active and can fire again (e.g., timer cycles, repeated signals).
- Error boundaries are always interrupting per BPMN spec, regardless of `cancelActivity`.

The parser normalizes `cancelActivity` from an XML string to a boolean. When the attribute is absent from the BPMN XML, it defaults to `true`.

## Triggered Start Events

`Rodar.Event.Start.Trigger` scans process definitions for message or signal start events and subscribes to the event bus. When a matching event fires, it automatically creates and runs a new process instance:

```elixir
Rodar.Event.Start.Trigger.register(process_definition)
# Now publishing a matching signal/message auto-starts instances
Rodar.Event.Bus.publish(:signal, "new_order", %{item: "widget"})
```

## Compensation

`Rodar.Compensation` tracks completed activities and their compensation handlers. The engine pre-registers handlers for activities with compensation boundary events. Compensation can be targeted or global:

```elixir
Rodar.Compensation.compensate_activity(context, "book_hotel")
Rodar.Compensation.compensate_all(context)  # reverse execution order
```

## Next Steps

- [Gateways](gateways.md) -- Routing and synchronization with gateway types
- [Expressions](expressions.md) -- Condition evaluation with FEEL and Elixir
- [Process Lifecycle](process_lifecycle.md) -- Instance creation, suspension, and persistence
