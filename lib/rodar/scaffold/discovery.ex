defmodule Rodar.Scaffold.Discovery do
  @moduledoc """
  Convention-based handler auto-discovery for BPMN tasks.

  After scaffolding generates handler modules at predictable paths
  (via `Mix.Tasks.Rodar.Scaffold`), this module discovers them at runtime
  by checking whether a module exists at the expected namespace and implements
  the correct callback.

  The naming convention is: `<AppName>.Workflow.<BpmnFilename>.Handlers.<TaskName>`.
  For example, a task named "Validate Order" in `order_processing.bpmn` within
  app `MyApp` is expected at `MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder`.

  The namespace segment (default `"Workflow"`) is configurable via:

      config :rodar, :scaffold_namespace, "Workflow"

  Discovery is recursive — tasks nested inside embedded subprocesses
  (`:bpmn_activity_subprocess_embeded`) are discovered at any depth. Handler
  injection via `apply_handlers/2` also recurses into subprocess elements.

  Discovery verifies each module:
    * Exists on the BEAM (`Code.ensure_loaded/1`)
    * Exports the correct callback — `execute/2` for service tasks
      (`Rodar.Activity.Task.Service.Handler`) or `token_in/2` for all
      others (`Rodar.TaskHandler`)

  Results are partitioned into three groups:
    * `:handler_map` — service task handlers (inject into diagram via `apply_handlers/2`)
    * `:task_registry_entries` — non-service task handlers (register via `register_discovered/1`)
    * `:not_found` — tasks with no matching module at the conventional path

  ## Integration with `Diagram.load/2`

  The easiest way to use discovery is through `Rodar.Engine.Diagram.load/2`:

      diagram = Rodar.Engine.Diagram.load(xml,
        bpmn_file: "order_processing.bpmn",
        app_name: "MyApp"
      )
      # diagram.discovery contains the discovery result

  Discovery is ON by default when `:bpmn_file` and `:app_name` are provided.
  Disable with `discover_handlers: false`. Explicit `:handler_map` entries
  always take precedence over discovered handlers for the same task ID.

  ## Direct Usage

      result = Discovery.discover(diagram,
        module_prefix: "MyApp.Workflow.OrderProcessing.Handlers"
      )
      diagram = Discovery.apply_handlers(diagram, result.handler_map)
      Discovery.register_discovered(result)

  ## See Also

    * `Rodar.Scaffold` — naming conventions and code generation
    * `Rodar.Engine.Diagram` — `load/2` integrates discovery automatically
    * `Mix.Tasks.Rodar.Scaffold` — CLI for generating handler stubs
  """

  alias Rodar.Scaffold

  @type discovery_result :: %{
          handler_map: %{String.t() => module()},
          task_registry_entries: [{String.t(), module()}],
          not_found: [String.t()]
        }

  @doc """
  Discovers handlers for all actionable tasks in a parsed diagram.

  ## Options

    * `:module_prefix` (required) — the fully-qualified module prefix
      (e.g., `"MyApp.Workflow.OrderProcessing.Handlers"`)

  Returns a map with three keys:

    * `:handler_map` — service task ID → module, for tasks whose handler
      implements `execute/2`
    * `:task_registry_entries` — list of `{task_id, module}` for non-service
      tasks whose handler implements `token_in/2`
    * `:not_found` — list of task IDs with no matching module

  """
  @spec discover(map(), keyword()) :: discovery_result()
  def discover(diagram, opts) do
    module_prefix = Keyword.fetch!(opts, :module_prefix)
    tasks = Scaffold.extract_tasks(diagram)

    Enum.reduce(tasks, %{handler_map: %{}, task_registry_entries: [], not_found: []}, fn task,
                                                                                         acc ->
      module_name = Scaffold.module_name_from_element(task.name || task.id)
      module = Module.concat([module_prefix, module_name])
      classify_task(acc, task, module)
    end)
  end

  @doc """
  Convenience that derives the module prefix from a BPMN file path and app name,
  then calls `discover/2`.

  ## Options

    * `:app_name` (required) — the PascalCase application name (e.g., `"MyApp"`)

  """
  @spec discover_from_file(map(), String.t(), keyword()) :: discovery_result()
  def discover_from_file(diagram, bpmn_file, opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    bpmn_name = Scaffold.bpmn_base_name(bpmn_file)
    prefix = Scaffold.default_module_prefix(app_name, bpmn_name)
    discover(diagram, module_prefix: prefix)
  end

  @doc """
  Injects discovered service task handlers into a parsed diagram.

  Iterates over processes and sets the `:handler` attribute on matching
  service task elements.
  """
  @spec apply_handlers(map(), %{String.t() => module()}) :: map()
  def apply_handlers(diagram, handler_map) when handler_map == %{}, do: diagram

  def apply_handlers(%{processes: processes} = diagram, handler_map) do
    updated =
      Enum.map(processes, fn {:bpmn_process, proc_attrs, elements} ->
        {:bpmn_process, proc_attrs, inject_into_elements(elements, handler_map)}
      end)

    %{diagram | processes: updated}
  end

  @doc """
  Registers discovered non-service task handlers in `Rodar.TaskRegistry`.

  Returns the list of task IDs that were registered.
  """
  @spec register_discovered(discovery_result()) :: [String.t()]
  def register_discovered(%{task_registry_entries: entries}) do
    Enum.map(entries, fn {task_id, module} ->
      Rodar.TaskRegistry.register(task_id, module)
      task_id
    end)
  end

  @handler_injectable_types [:bpmn_activity_task_service, :bpmn_activity_task_business_rule]

  defp inject_into_elements(elements, handler_map) do
    Map.new(elements, fn
      {id, {type, attrs}} when type in @handler_injectable_types ->
        case Map.fetch(handler_map, id) do
          {:ok, handler} ->
            {id, {type, Map.put(attrs, :handler, handler)}}

          :error ->
            {id, {type, attrs}}
        end

      {id, {:bpmn_activity_subprocess_embeded, %{elements: nested} = attrs}}
      when is_map(nested) ->
        updated_nested = inject_into_elements(nested, handler_map)
        {id, {:bpmn_activity_subprocess_embeded, %{attrs | elements: updated_nested}}}

      {id, elem} ->
        {id, elem}
    end)
  end

  # --- Private ---

  defp classify_task(acc, task, module) do
    case check_handler(module, task.bpmn_type) do
      :ok -> add_discovered(acc, task, module)
      :not_found -> %{acc | not_found: acc.not_found ++ [task.id]}
    end
  end

  defp add_discovered(acc, task, module) do
    case Scaffold.registration_type(task.bpmn_type) do
      :handler_map ->
        %{acc | handler_map: Map.put(acc.handler_map, task.id, module)}

      :task_registry ->
        %{acc | task_registry_entries: acc.task_registry_entries ++ [{task.id, module}]}
    end
  end

  defp check_handler(module, bpmn_type) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         {_behaviour, callback, _sig} = Scaffold.behaviour_for_type(bpmn_type),
         true <- function_exported?(module, callback, callback_arity(callback)) do
      :ok
    else
      _ -> :not_found
    end
  end

  defp callback_arity(:execute), do: 2
  defp callback_arity(:token_in), do: 2
end
