# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Elixir BPMN 2.0 execution engine (formerly "hashiru-bpmn"). Parses BPMN 2.0 XML diagrams and executes processes using a token-based flow model. Version 0.1.0-dev targeting Elixir ~> 1.16 with OTP 27+.

## Build & Test Commands

```shell
mix deps.get && mix deps.compile && mix compile   # Setup
mix test                                           # Run all tests
mix test test/rodar/context_test.exs                # Run a single test file
mix test test/rodar/context_test.exs:10             # Run a single test at line
mix credo                                          # Lint
mix coveralls                                      # Tests with coverage
mix docs                                           # Generate documentation
mix rodar.validate <file>                           # Validate a BPMN file
mix rodar.inspect <file>                            # Inspect parsed structure
mix rodar.run <file> [--data '{}']                  # Execute a process
mix rodar.scaffold <file> [--output-dir DIR]        # Generate handler stubs
mix rodar_release <patch|minor|major>                     # Create a release
mix rodar_release patch --dry-run                        # Preview release
```

## Versioning

The project follows [Semantic Versioning](https://semver.org/). The version in `mix.exs` is the single source of truth (e.g., `version: "1.0.8"`). The `rodar_release` package (path dependency at `../rodar_release`) provides the `mix rodar_release` task.

**What the bump type controls**: The bump type (`patch`, `minor`, `major`) determines the **release version**, decided at release time.

| `mix.exs` version | Bump type | Release version | `mix.exs` after |
|--------------------|-----------|-----------------|-----------------|
| `1.0.8`            | `patch`   | `1.0.9`         | `1.0.9`         |
| `1.0.8`            | `minor`   | `1.1.0`         | `1.1.0`         |
| `1.0.8`            | `major`   | `2.0.0`         | `2.0.0`         |

**Release workflow** (step-by-step):

1. Work on `main`. Ensure `CHANGELOG.md` has entries under `## [Unreleased]`.
2. Run the release task, choosing the bump type based on what changed:
   ```shell
   mix rodar_release patch --dry-run    # preview first
   mix rodar_release patch --publish    # release + publish to hex.pm
   ```
   The task: bumps version in mix.exs → updates CHANGELOG with date → commits + tags → optionally publishes to hex.pm.
3. Push:
   ```shell
   git push origin main --tags
   ```

**Changelog**: `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/) format. All notable changes go under `## [Unreleased]` during development. The release task promotes unreleased entries to a versioned section.

## Architecture

### Token-based Execution Model

All BPMN nodes implement `token_in/2` (some also `token_in/3` with `from_flow` for gateway join tracking). The main dispatcher `Rodar` (lib/rodar.ex) routes elements by type to handler modules via `execute/2` (simple) or `execute/3` (with `Rodar.Token` tracking). `Rodar.release_token/2` or `release_token/3` passes tokens to the next nodes; `/3` forks child tokens for parallel branches.

Return tuples: `{:ok, context}`, `{:error, msg}`, `{:manual, _}`, `{:fatal, _}`, `{:not_implemented}`.

**Execution history classification**: `execute/3` records each node's result in the context history via `record_completion/4`. A node that calls `release_token` is classified as `:ok` (it completed its own work and forwarded the token), regardless of what downstream nodes return. Only nodes that return without releasing (e.g., a user task returning `{:manual, _}`) are classified by their own return value. This is tracked via a per-token meta flag (`{:_token_released, token_id}`) set by `mark_token_released/1`.

### Key Modules

- **`Rodar`** — Main dispatcher; `execute/2` (backward compat) and `execute/3` (with token tracking + execution history). Dispatches to handler modules via private `dispatch/2`.
- **`Rodar.Token`** — Execution token struct (id, current_node, state, parent_id, created_at). `new/1` generates UUID, `fork/1` creates child tokens for parallel branches.
- **`Rodar.Context`** — GenServer-based state management with `get/2`, `put_data/3`, `get_data/2`, `put_meta/3`, `get_meta/2`, `record_token/3`, `token_count/2`, `record_activated_paths/3`, `swap_process/2`, `get_state/1`, `restore_state/2`, `start_supervised/2`. Includes execution history API: `record_visit/2`, `record_completion/4`, `get_history/1`, `get_node_history/2`. Conditional subscription API: `subscribe_condition/4`, `unsubscribe_condition/2` — evaluates conditions on `put_data` and fires `{:condition_met, ...}`. Handles `{:timer_fired, ...}`, `{:timer_cycle_fired, ...}`, `{:bpmn_event, ...}`, and `{:condition_met, ...}` via `handle_info`.
- **`Rodar.Registry`** — GenServer + Elixir Registry for versioned process definition storage. `register/2` (backward compat, auto-increments version), `register/3` (with opts, returns `{:ok, version}`), `lookup/1` (latest), `lookup/2` (specific version), `versions/1`, `latest_version/1`, `deprecate/2`, `unregister/1`, `list/0`. Internal state uses a version ledger per process ID.
- **`Rodar.Process`** — Process lifecycle GenServer. `start_link/2`, `create_and_run/2`, `activate/1`, `suspend/1`, `resume/1`, `terminate/1`, `status/1`, `get_context/1`, `dehydrate/1`, `rehydrate/1`, `definition_version/1`, `process_id/1`, `update_definition_version/2`. Tracks `definition_version` in state. Auto-dehydrates on `{:manual, _}` when configured. Optional validation gate on activate via `config :rodar, :validate_on_activate, true`. Versioned rehydration uses `Registry.lookup/2` when `definition_version` is in snapshot.
- **`Rodar.Migration`** — Process instance migration between definition versions. `check_compatibility/2` validates active node positions against target version (node existence, outgoing flow integrity, gateway token state). `migrate/2` (or `/3` with `force: true`) suspends instance, swaps process definition via `Context.swap_process/2`, updates version tracker, resumes if previously running.
- **`Rodar.Event.Bus`** — Registry-based pub/sub using `Rodar.EventRegistry` (`:duplicate` keys). `subscribe/3`, `unsubscribe/2`, `publish/3` (message=point-to-point with correlation key support, signal/escalation=broadcast), `subscriptions/2`. Message correlation: subscribers/publishers include optional `correlation: %{key: ..., value: ...}` for routing to specific instances when multiple wait for the same message name.
- **`Rodar.Event.Timer`** — ISO 8601 duration parsing (`parse_duration/1`), cycle parsing (`parse_cycle/1` for `R3/PT10S`, `R/PT1M`, bare durations), `schedule/4` via `Process.send_after`, `schedule_cycle/5` for repeating timers, `cancel/1`.
- **`Rodar.Event.End`** — End event handler. Plain end returns `{:ok, context}`. Error end sets error state. Terminate end marks process terminated. Message/signal/escalation end events publish to `Rodar.Event.Bus` before returning (same pattern as intermediate throw). Compensate end triggers compensation handlers.
- **`Rodar.Event.Intermediate.Throw`** — Publishes message/signal/escalation to event bus, releases token. Link throw events act as intra-process GOTOs: scan the process map for a matching link catch event by name and release the token to the catch's outgoing flows.
- **`Rodar.Event.Intermediate.Catch`** — Subscribes to event bus, schedules timer, or subscribes to conditional evaluation; returns `{:manual, _}`. Fires immediately if condition is already true. Has `resume/3`. Link catch events are passive — they pass through on normal token flow and serve as jump targets for link throw events.
- **`Rodar.Event.Boundary`** — Full implementation: error (direct activation), message/signal/escalation (event bus), timer (scheduled), conditional (context subscription, fires on data change), compensate (passive — registration in dispatcher). Supports non-interrupting boundary events via `cancelActivity` attribute (boolean, defaults to `true`). Non-interrupting events (`cancelActivity: false`) fire their outgoing path without cancelling the parent activity. Error boundaries are always interrupting per BPMN spec.
- **`Rodar.Compensation`** — Tracks completed activities and their compensation handlers. `register_handler/3`, `compensate_activity/2` (targeted), `compensate_all/1` (reverse order), `remove_handlers/2` (cleanup on failure). Pre-registered in `Rodar.execute/3` for activities with compensation boundary events.
- **`Rodar.Expression`** — Evaluates condition expressions on sequence flows. Routes to `"elixir"` (Sandbox) or `"feel"` (FEEL) evaluator based on language tag. Accepts both `{:bpmn_expression, {lang, expr}}` and legacy `{:bpmn_condition_expression, %{...}}` formats.
- **`Rodar.Expression.Sandbox`** — AST-restricted Elixir expression evaluator. Parses via `Code.string_to_quoted`, walks AST against an allowlist, evaluates safe expressions via `Code.eval_quoted`. Prevents arbitrary code execution.
- **`Rodar.Expression.Feel`** — Thin delegation wrapper to the `rodar_feel` package (`RodarFeel`). FEEL (Friendly Enough Expression Language) is provided by the standalone `rodar_feel` dependency, which includes `RodarFeel` (facade with `eval/2` and `eval_unary/3` for DMN unary tests), `RodarFeel.Parser` (NimbleParsec-based parser with `between`, `for-in-return`, `some/every` quantifiers, `instance of` type checking, user-defined functions/lambdas, context literals, temporal literals with `@"..."` syntax, and `//`/`/* */` comments), `RodarFeel.Evaluator` (tree-walking evaluator with null propagation, three-valued boolean logic, sequential context evaluation, quantified expression support, temporal arithmetic/comparison with timezone support via `tz`, lambda closures, bracket access on maps and lists, and atom key support via `flex_get/2`), `RodarFeel.Functions` (48 built-in FEEL functions: numeric `abs`, `floor`, `ceiling`, `round`, `min`, `max`, `sum`, `count`, `product`, `mean`; string `string length`, `contains`, `starts with`, `ends with`, `upper case`, `lower case`, `substring`, `split`, `substring before`, `substring after`, `replace`, `trim`, `string join`, `matches`; list `append`, `concatenate`, `reverse`, `flatten`, `distinct values`, `sort`, `index of`, `list contains`; boolean `not`, `is null`, `all`, `any` with three-valued logic; conversion `string`, `number`; temporal `date`, `time`, `date and time`, `duration`, `now`, `today`; statistical `median`, `stddev`, `mode`; misc `random`), and `RodarFeel.Duration` (ISO 8601 duration struct with arithmetic and comparison).
- **`Rodar.Expression.ScriptEngine`** — Behaviour for pluggable script language engines. Single `eval/2` callback receiving script text and bindings map, returning `{:ok, result}` or `{:error, reason}`.
- **`Rodar.Expression.ScriptRegistry`** — GenServer for script engine registrations. `register/2` (language string → module), `unregister/1`, `lookup/1`, `list/0`. Used by `Activity.Task.Script` to resolve languages beyond built-in `"elixir"` and `"feel"`.
- **`Rodar.Expression.TestHelpers`** — Convenience functions for evaluating expressions against sample data without a full process context, and for validating expression safety.
- **`Rodar.Validation`** — Structural validation for parsed process maps. `validate/1` returns accumulated `{:ok, map} | {:error, [issue]}`. `validate!/1` raises. `validate_collaboration/2` checks participant refs and message flow refs. `validate_lanes/2` checks lane referential integrity (`:lane_flow_node_ref` — refs must exist, `:lane_duplicate_ref` — no duplicates at same nesting level). 9 process rules covering start/end events, sequence flow refs, orphan nodes, gateway outgoing, exclusive gateway defaults, boundary attachment.
- **`Rodar.Collaboration`** — Multi-participant orchestration. `start/2` registers processes, creates instances, wires message flows via event bus, activates all. `stop/1` terminates all instances. Uses existing `Rodar.Event.Bus` for inter-process messaging.
- **`Rodar.TaskHandler`** — Behaviour for custom task handlers. Single `token_in/2` callback matching existing handler signature.
- **`Rodar.TaskRegistry`** — GenServer for task handler registrations. `register/2` (atom type or string ID → module), `unregister/1`, `lookup/1`, `list/0`. Lookup priority: task ID first, then type.
- **`Rodar.Hooks`** — Per-context hook system. `register/3`, `unregister/2`, `notify/3`. Events: `:before_node`, `:after_node`, `:on_error`, `:on_complete`. Observational-only, exceptions caught.
- **`Rodar.Event.Start.Trigger`** — GenServer for signal/message-triggered start events. `register/1` scans a process definition for message/signal start events and subscribes to the event bus. Auto-creates process instances via `Rodar.Process.create_and_run/2` when matching events fire.
- **`Rodar.Activity.Task.Service`** — Service task execution. Handler resolution priority: (1) inline `:handler` attribute (e.g., injected via `Diagram.load/2` `:handler_map`), (2) `Rodar.TaskRegistry` lookup by task ID, (3) `{:not_implemented}` fallback. Handler modules implement the `Service.Handler` behaviour. Supports BPMN error propagation (`{:bpmn_error, code, msg}` → error boundary routing) and async execution (`{:async, ref}` → `{:manual, _}` with `complete_async/3` to resume).
- **`Rodar.Activity.Task.Service.Handler`** — Behaviour for service task handlers. Single `execute/2` callback receiving task attributes and context data map, returning `{:ok, result_map}`, `{:error, reason}`, `{:bpmn_error, error_code, message}` (routes to error boundary), or `{:async, reference}` (parks token for async completion). Used by `Activity.Task.Service` for handler dispatch.
- **`Rodar.Activity.Task.BusinessRule`** — Business rule task execution. Mirrors service task handler resolution exactly: (1) inline `:handler` attribute, (2) `Rodar.TaskRegistry` lookup by task ID, (3) `{:not_implemented}` fallback. Handler modules implement `BusinessRule.Handler`. Keeps the door open for future DMN integration via pluggable handlers.
- **`Rodar.Activity.Task.BusinessRule.Handler`** — Behaviour for business rule task handlers. Single `execute/2` callback with same signature as `Service.Handler`: receives task attributes and context data map, returns `{:ok, result_map}` or `{:error, reason}`.
- **`Rodar.Engine.Diagram`** — Parses BPMN 2.0 XML via `erlsom`, returns process maps keyed by element ID. Splits `intermediateThrowEvent` → `:bpmn_event_intermediate_throw`, `intermediateCatchEvent` → `:bpmn_event_intermediate_catch`. Emits condition expressions as `{:bpmn_expression, {lang, expr}}`. Parses `collaboration`, `participant`, `messageFlow`, `callActivity`, and `laneSet`/`lane` elements (including nested `childLaneSet`). Extracts `timeDuration`, `timeCycle`, `timeDate` from timer event definitions. Lane sets are stored in the process attrs as `:lane_set` (nil when absent). `load/1` parses XML, `load/2` accepts opts including `:handler_map` (map of element ID string → handler module) to inject `:handler` attributes into service task elements at parse time, plus `:bpmn_file`, `:app_name`, and `:discover_handlers` (boolean, default `true`) for convention-based handler auto-discovery via `Scaffold.Discovery`. When discovery is active, discovered handlers are merged with explicit `:handler_map` (explicit wins) and the result includes a `:discovery` key. `export/1` delegates to `Rodar.Engine.Diagram.Export.to_xml/1`.
- **`Rodar.Engine.Diagram.Export`** — IO list-based BPMN 2.0 XML builder. Inverse of `Diagram.load/1`. Exports all element types (events, gateways, tasks, sequence flows, subprocesses), event definitions, collaboration, item definitions, and lane sets (including nested child lane sets). Strips vendor-specific attributes and `_elems`. Deterministic output with sorted attributes and element ordering (sequence flows last).
- **`Rodar.Scaffold`** — Core scaffolding logic for generating BPMN handler modules. `extract_tasks/1` finds actionable tasks in a parsed diagram (recursively descending into embedded subprocesses at any depth), `generate_module/2` produces handler source code with the correct behaviour (`Service.Handler` for service tasks, `BusinessRule.Handler` for business rule tasks, `TaskHandler` for all others), `behaviour_for_type/1` maps BPMN types to behaviours, `registration_type/1` indicates handler wiring strategy, `bpmn_base_name/1` derives PascalCase name from a BPMN file path, `default_module_prefix/2` builds the handler module prefix from app name + BPMN name. Used by `Mix.Tasks.Rodar.Scaffold` and `Scaffold.Discovery`.
- **`Rodar.Scaffold.Discovery`** — Convention-based handler auto-discovery. `discover/2` checks whether handler modules exist at the expected namespace for each actionable task in a parsed diagram, including tasks nested inside embedded subprocesses (e.g., `MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder`). `discover_from_file/3` derives the prefix from a BPMN file path + app name. Returns a map with `:handler_map` (service tasks), `:task_registry_entries` (other tasks), and `:not_found`. `apply_handlers/2` injects discovered service handlers into diagram elements (recursing into subprocesses), `register_discovered/1` registers non-service handlers in `TaskRegistry`. The namespace segment (default `"Workflow"`) is configurable via `config :rodar, :scaffold_namespace`.
- **`Rodar.Lane`** — Stateless utility module for querying lane assignments. `find_lane_for_node(lane_set, node_id)` → `{:ok, lane} | :error` (deepest lane wins), `node_lane_map(lane_set)` → `%{node_id => lane}` flat map, `all_lanes(lane_set)` → flat list of all lanes including nested. All functions accept `nil` lane set gracefully.
- **`Rodar.Workflow`** — Functional API and `use` macro for BPMN workflow management (Layer 1). Eliminates boilerplate around loading BPMN XML, registering definitions, creating process instances, and resuming user tasks. Functions: `setup/1` (load + register + discover handlers), `start_process/2` (create instance with data, activate), `resume_user_task/3`, `complete_async_service/3` (resume async service task), `process_status/1` (smart status with completion detection), `process_data/1`, `process_history/1`. The `use` macro injects convenience functions with configured options (`:bpmn_file`, `:process_id`, `:otp_app`, `:app_name`) baked in. All injected functions are `defoverridable`.
- **`Rodar.Workflow.Server`** — GenServer abstraction for BPMN workflow management (Layer 2). Builds on `Rodar.Workflow` to add instance tracking, sequential IDs, and domain-specific status mapping. Callbacks: `init_data/2` (required — transform params + instance ID into BPMN data map), `map_status/1` (optional — translate BPMN status atoms to domain terms). Injected functions: `start_link/1`, `create_instance/1`, `complete_task/3`, `complete_service_task/3` (resume async service task), `list_instances/0`, `get_instance/1`. Uses `{:__workflow__, action, ...}` tuple tags for GenServer messages to avoid collisions with user-defined `handle_call` clauses.
- **`Rodar.Persistence`** — Behaviour defining adapter callbacks (`save/2`, `load/1`, `delete/1`, `list/0`) and facade delegating to the configured adapter. Reads config from `Application.get_env(:rodar, :persistence)`.
- **`Rodar.Persistence.Serializer`** — Converts live process state to persistable snapshots and back. Handles MapSets (→ sorted lists), timer refs (stripped), Token structs (→ plain maps). Uses `:erlang.term_to_binary`/`binary_to_term` for binary serialization.
- **`Rodar.Persistence.Adapter.ETS`** — GenServer owning a named ETS table (`:rodar_persistence`). Implements `Rodar.Persistence` behaviour. Suitable for development/testing.
- **`Rodar.Telemetry`** — Centralizes telemetry event definitions and helpers. `events/0` returns all event names, `node_span/2` wraps dispatch with `:telemetry.span/3`, plus typed emit functions for token, process, and event bus events.
- **`Rodar.Telemetry.LogHandler`** — Default telemetry handler that logs events via `Logger`. `attach/0`/`detach/0` to manage lifecycle. Node start/stop at debug, exception at error, process start/stop at info.
- **`Rodar.Observability`** — Read-only query APIs: `running_instances/0` (now includes `process_id` and `definition_version`), `waiting_instances/0`, `execution_history/1`, `instances_by_version/1` (filter by process ID, optional version), `health/0`. Queries existing supervisors and registries.

### Supervision Tree

`Rodar.Application` starts: `Rodar.ProcessRegistry` (Elixir Registry, `:unique`), `Rodar.EventRegistry` (Elixir Registry, `:duplicate`), `Rodar.Registry`, `Rodar.TaskRegistry`, `Rodar.Expression.ScriptRegistry`, `Rodar.ContextSupervisor` (DynamicSupervisor), `Rodar.ProcessSupervisor` (DynamicSupervisor), `Rodar.Event.Start.Trigger`, and conditionally the persistence adapter (e.g., `Rodar.Persistence.Adapter.ETS`) if `:persistence` config is set.

### Module Organization

- `lib/rodar/activity/` — Tasks (user, script, service, business rule, send, receive, manual) and subprocesses (embedded, call activity)
- `lib/rodar/event/` — Start, end, intermediate (throw/catch), boundary events, event bus, timer utilities
- `lib/rodar/gateway/` — Exclusive, parallel, inclusive, complex, event-based gateways
- `lib/rodar/expression/` — Sandboxed Elixir evaluator, FEEL delegation wrapper (implementation in `rodar_feel` package), pluggable script engine behaviour and registry, and test helpers
- `lib/rodar/persistence/` — Persistence behaviour, serializer, and adapters (ETS)
- `lib/rodar/telemetry/` — Telemetry event definitions, helpers, and default log handler
- `lib/rodar/observability.ex` — Dashboard query APIs and health checks
- `lib/rodar/engine/` — BPMN 2.0 XML parser (`diagram.ex`) and exporter (`diagram/export.ex`)
- `lib/rodar/scaffold.ex` — Handler module scaffolding logic (task extraction, code generation, naming conventions)
- `lib/rodar/scaffold/` — Discovery module for convention-based handler auto-discovery
- `lib/rodar/workflow.ex` — Functional workflow API and `use` macro (Layer 1)
- `lib/rodar/workflow/` — Workflow GenServer abstraction (`server.ex`, Layer 2)
- `lib/rodar/lane.ex` — Lane assignment queries (find, map, flatten)
- `lib/rodar/validation.ex` — Structural validation (9 process rules + lane validation + collaboration validation)
- `lib/rodar/collaboration.ex` — Multi-pool/multi-participant orchestration

### Testing Conventions

Tests rely heavily on doctests embedded in module documentation. Unit tests in `test/` mirror the `lib/` structure. Test modules use `async: true` where possible.

### Conformance Tests

BPMN conformance tests in `test/rodar/conformance/`:
- `parse_test.exs` — Verifies MIWG reference files (A.1.0–B.2.0) parse correctly
- `execution_test.exs` — End-to-end execution of 12 standard BPMN patterns
- `coverage_test.exs` — Element type coverage analysis against MIWG B.2.0

Fixtures: `test/fixtures/conformance/miwg/` (MIWG reference), `test/fixtures/conformance/execution/` (handcrafted patterns). Download script: `scripts/download_miwg.sh`.

## Commit Message Format

```
<type>(<scope>): <subject>
```

Types: `build`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `style`, `test`
Scopes: `engine`, `plugin`, `scripts`, `api`, `packaging`, `changelog`

Subject: imperative present tense, no capitalized first letter, no trailing dot.

## Branch Strategy

Feature branches off `develop`. PRs target `develop`.

## Agent Rules

All subagents (launched via the Agent tool) MUST follow these rules:

1. **Worktree isolation**: Always use `isolation: "worktree"` so multiple agents can work in parallel without file conflicts.
2. **Update documentation**: After making code changes, update relevant docs — CLAUDE.md (architecture, key modules), module `@moduledoc`/`@doc`, ExDoc guides in `guides/`, and `usage-rules.md` (see below) as needed.
3. **Pass all CI checks before committing**: Before creating a commit, run and verify all pass:
   - `mix compile --warnings-as-errors`
   - `mix test`
   - `mix credo --strict`
   - `mix dialyzer` (use 600000ms timeout)
4. **Commit at the end**: After all checks pass, commit the changes in the worktree with a properly formatted commit message (see Commit Message Format above).

## Usage Rules (usage-rules.md)

`usage-rules.md` is a package-level file that AI agents consume to learn coding conventions, best practices, and common mistakes when working with `rodar`. It is included in the hex package via the `files` list in `mix.exs`.

**When to update**: Any change that affects the public API, behaviours, configuration, or execution semantics must be reflected in `usage-rules.md`. This includes:
- New or changed module APIs (e.g., new Context functions, new behaviours)
- New configuration options (e.g., persistence settings, validation flags)
- Changed return values or execution flow
- New handler wiring approaches or lookup priority changes
- New event types or delivery semantics

**Quality guidelines**:
- Every section must include `# GOOD` and `# BAD` code examples showing correct usage and common mistakes
- Examples must be valid, runnable Elixir code (not pseudocode)
- Keep descriptions concise — focus on what users get wrong, not exhaustive API docs
- Organize by user intent (e.g., "Service Task Handlers"), not by module name
- When adding a new section, follow the existing structure: brief description → good example → bad example with explanation
