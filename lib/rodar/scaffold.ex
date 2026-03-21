defmodule Rodar.Scaffold do
  @moduledoc """
  Core scaffolding logic for generating BPMN handler modules.

  Extracts actionable tasks from parsed BPMN diagrams and generates
  handler module source code with the correct behaviour and callbacks.
  Service tasks get `Rodar.Activity.Task.Service.Handler` with `execute/2`,
  while all other task types get `Rodar.TaskHandler` with `token_in/2`.

  Task extraction is recursive — tasks nested inside embedded subprocesses
  (`:bpmn_activity_subprocess_embeded` elements) are discovered at any depth.

  This module also provides naming conventions used by both the scaffold Mix
  task and the convention-based auto-discovery system (`Rodar.Scaffold.Discovery`):

    * `bpmn_base_name/1` — derives a PascalCase name from a BPMN file path
    * `default_module_prefix/2` — builds the canonical handler namespace
      (e.g., `"MyApp.Workflow.OrderProcessing.Handlers"`)
    * `module_name_from_element/1` — converts a task name or ID to PascalCase

  Together these establish the convention: a handler for task "Validate Order"
  in `order_processing.bpmn` within app `MyApp` lives at
  `MyApp.Workflow.OrderProcessing.Handlers.ValidateOrder`.

  The namespace segment (default `"Workflow"`) is configurable via application config:

      config :rodar, :scaffold_namespace, "Workflow"

  ## See Also

    * `Mix.Tasks.Rodar.Scaffold` — CLI entry point for handler generation
    * `Rodar.Scaffold.Discovery` — auto-discovers handlers at conventional paths
  """

  @task_types [
    :bpmn_activity_task_service,
    :bpmn_activity_task_business_rule,
    :bpmn_activity_task_user,
    :bpmn_activity_task_send,
    :bpmn_activity_task_receive,
    :bpmn_activity_task_manual,
    :bpmn_activity_task
  ]

  @doc """
  Extracts all actionable tasks from a parsed BPMN diagram.

  Returns a list of maps with `:id`, `:name`, and `:bpmn_type` for each
  task element found across all processes. Recursively descends into
  embedded subprocesses (`:bpmn_activity_subprocess_embeded`) at any
  nesting depth.
  """
  @spec extract_tasks(map()) :: [map()]
  def extract_tasks(%{processes: processes}) do
    Enum.flat_map(processes, fn {:bpmn_process, _attrs, elements} ->
      extract_tasks_from_elements(elements)
    end)
  end

  @doc false
  @spec extract_tasks_from_elements(map()) :: [map()]
  def extract_tasks_from_elements(elements) do
    Enum.flat_map(elements, fn
      {id, {type, attrs}} when type in @task_types ->
        [%{id: id, name: Map.get(attrs, :name), bpmn_type: type}]

      {_id, {:bpmn_activity_subprocess_embeded, %{elements: nested}}} when is_map(nested) ->
        extract_tasks_from_elements(nested)

      _ ->
        []
    end)
  end

  @doc """
  Generates module source code for a task.

  Returns `{module_name, file_name, content}` where `module_name` is the
  short PascalCase name, `file_name` is the snake_case `.ex` file name,
  and `content` is the full module source code.
  """
  @spec generate_module(map(), String.t()) :: {String.t(), String.t(), String.t()}
  def generate_module(%{id: id, name: name, bpmn_type: bpmn_type}, module_prefix) do
    module_name = module_name_from_element(name || id)
    file_name = file_name_from_module(module_name)
    full_module = "#{module_prefix}.#{module_name}"

    content = build_module_content(full_module, bpmn_type)
    {module_name, file_name, content}
  end

  @doc """
  Converts an element name or ID to a PascalCase module name.

  Strips non-alphanumeric characters (except spaces and underscores),
  splits on word boundaries, and joins as PascalCase.

  ## Examples

      iex> Rodar.Scaffold.module_name_from_element("Check Inventory")
      "CheckInventory"

      iex> Rodar.Scaffold.module_name_from_element("Activity_0abc")
      "Activity0abc"

      iex> Rodar.Scaffold.module_name_from_element("send-email-task")
      "SendEmailTask"

  """
  @spec module_name_from_element(String.t()) :: String.t()
  def module_name_from_element(name_or_id) do
    name_or_id
    |> String.replace(~r/[^a-zA-Z0-9\s_-]/, "")
    |> String.split(~r/[\s_-]+/)
    |> Enum.map_join(&capitalize_first/1)
  end

  @doc """
  Converts a PascalCase module name to a snake_case file name with `.ex` extension.

  ## Examples

      iex> Rodar.Scaffold.file_name_from_module("CheckInventory")
      "check_inventory.ex"

      iex> Rodar.Scaffold.file_name_from_module("Activity0abc")
      "activity0abc.ex"

  """
  @spec file_name_from_module(String.t()) :: String.t()
  def file_name_from_module(module_name) do
    module_name
    |> Macro.underscore()
    |> Kernel.<>(".ex")
  end

  @doc """
  Produces a simple line-based diff between two strings for display.

  Returns a list of `{:removed, line}` and `{:added, line}` tuples
  for lines that differ, plus `{:context, line}` for shared lines.
  """
  @spec diff_contents(String.t(), String.t()) :: [{:removed | :added | :context, String.t()}]
  def diff_contents(old, new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")

    old_set = MapSet.new(old_lines)
    new_set = MapSet.new(new_lines)

    removed = Enum.filter(old_lines, &(not MapSet.member?(new_set, &1)))
    added = Enum.filter(new_lines, &(not MapSet.member?(old_set, &1)))

    removed_entries = Enum.map(removed, &{:removed, &1})
    added_entries = Enum.map(added, &{:added, &1})

    removed_entries ++ added_entries
  end

  @doc """
  Returns the behaviour module and callback info for a given BPMN type.
  """
  @spec behaviour_for_type(atom()) :: {module(), atom(), String.t()}
  def behaviour_for_type(:bpmn_activity_task_service) do
    {Rodar.Activity.Task.Service.Handler, :execute, "execute(_attrs, _data)"}
  end

  def behaviour_for_type(:bpmn_activity_task_business_rule) do
    {Rodar.Activity.Task.BusinessRule.Handler, :execute, "execute(_attrs, _data)"}
  end

  def behaviour_for_type(_type) do
    {Rodar.TaskHandler, :token_in, "token_in(_element, _context)"}
  end

  @doc """
  Returns the registration function name for a given BPMN type.

  Service tasks use `handler_map` with `Diagram.load/2`, while other
  task types use `Rodar.TaskRegistry.register/2`.
  """
  @spec registration_type(atom()) :: :handler_map | :task_registry
  def registration_type(:bpmn_activity_task_service), do: :handler_map
  def registration_type(:bpmn_activity_task_business_rule), do: :handler_map
  def registration_type(_), do: :task_registry

  @doc """
  Derives a PascalCase base name from a BPMN file path.

  Strips the directory and extension, then converts to PascalCase using
  `module_name_from_element/1`.

  ## Examples

      iex> Rodar.Scaffold.bpmn_base_name("path/to/order_processing.bpmn")
      "OrderProcessing"

      iex> Rodar.Scaffold.bpmn_base_name("my-workflow.bpmn2")
      "MyWorkflow"

  """
  @spec bpmn_base_name(String.t()) :: String.t()
  def bpmn_base_name(file_path) do
    file_path
    |> Path.basename()
    |> Path.rootname()
    |> module_name_from_element()
  end

  @doc """
  Builds the default handler module prefix from an app name and BPMN base name.

  The namespace segment between the app name and the BPMN name defaults to
  `"Workflow"` and can be configured via:

      config :rodar, :scaffold_namespace, "CustomNamespace"

  ## Examples

      iex> Rodar.Scaffold.default_module_prefix("MyApp", "OrderProcessing")
      "MyApp.Workflow.OrderProcessing.Handlers"

  """
  @spec default_module_prefix(String.t(), String.t()) :: String.t()
  def default_module_prefix(app_name, bpmn_name) do
    namespace = Application.get_env(:rodar, :scaffold_namespace, "Workflow")
    "#{app_name}.#{namespace}.#{bpmn_name}.Handlers"
  end

  # --- Private ---

  defp build_module_content(full_module, :bpmn_activity_task_service) do
    """
    defmodule #{full_module} do
      @moduledoc false

      @behaviour Rodar.Activity.Task.Service.Handler

      @impl true
      def execute(_attrs, _data) do
        # TODO: Implement service task logic
        {:ok, %{}}
      end
    end
    """
  end

  defp build_module_content(full_module, :bpmn_activity_task_business_rule) do
    """
    defmodule #{full_module} do
      @moduledoc false

      @behaviour Rodar.Activity.Task.BusinessRule.Handler

      @impl true
      def execute(_attrs, _data) do
        # TODO: Implement business rule logic
        {:ok, %{}}
      end
    end
    """
  end

  defp build_module_content(full_module, _bpmn_type) do
    """
    defmodule #{full_module} do
      @moduledoc false

      @behaviour Rodar.TaskHandler

      @impl true
      def token_in(_element, _context) do
        # TODO: Implement task logic
        {:ok, nil}
      end
    end
    """
  end

  defp capitalize_first(<<first::utf8, rest::binary>>) do
    String.upcase(<<first::utf8>>) <> rest
  end

  defp capitalize_first(""), do: ""
end
