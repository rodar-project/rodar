defmodule Rodar.Workflow do
  @moduledoc """
  Functional API and thin `use` macro for BPMN workflow management.

  Eliminates boilerplate around loading BPMN XML, registering definitions,
  creating process instances, and resuming user tasks. The functions are
  stateless and work anywhere (GenServer, LiveView, controller, plain module).

  ## Using the macro

      use Rodar.Workflow,
        bpmn_file: "priv/bpmn/order_processing.bpmn",
        process_id: "order_processing",
        otp_app: :my_app,           # optional — resolves path via Application.app_dir
        app_name: "MyApp"           # optional — enables handler auto-discovery

  This injects convenience functions that delegate to `Rodar.Workflow.*`
  with the configured options baked in:

    * `setup/0` — load BPMN, register definition + discovered handlers
    * `start_process/1` — create instance with data map, activate
    * `start_process/0` — shorthand with empty data
    * `resume_user_task/3` — resume user task by `(pid, task_id, input)`
    * `process_status/1` — get process status
    * `process_data/1` — get process data map
    * `process_history/1` — get execution history

  ## Using the functional API directly

      Rodar.Workflow.setup(
        bpmn_file: "priv/bpmn/order.bpmn",
        process_id: "order"
      )

      {:ok, pid} = Rodar.Workflow.start_process("order", %{"item" => "widget"})
      :suspended = Rodar.Workflow.process_status(pid)
      Rodar.Workflow.resume_user_task(pid, "Task_Approval", %{"approved" => true})
  """

  alias Rodar.Activity.Task.Service
  alias Rodar.Activity.Task.User, as: UserTask
  alias Rodar.Context
  alias Rodar.Engine.Diagram
  alias Rodar.Process
  alias Rodar.Scaffold.Discovery

  @doc """
  Load a BPMN file, parse it, register the definition, and discover handlers.

  ## Options

    * `:bpmn_file` (required) — path to the BPMN XML file
    * `:process_id` (required) — the process ID to register under
    * `:otp_app` — OTP application for path resolution via `Application.app_dir/2`
    * `:app_name` — PascalCase application name for handler auto-discovery

  Returns `{:ok, diagram}` on success, `{:error, reason}` on failure.
  File-not-found errors include the file path in the message for easier debugging.
  """
  @spec setup(keyword()) :: {:ok, map()} | {:error, any()}
  def setup(opts) do
    bpmn_file = Keyword.fetch!(opts, :bpmn_file)
    process_id = Keyword.fetch!(opts, :process_id)
    otp_app = Keyword.get(opts, :otp_app)
    app_name = Keyword.get(opts, :app_name)

    path = resolve_path(bpmn_file, otp_app)

    with {:ok, xml} <- read_bpmn_file(path),
         diagram <- load_diagram(xml, bpmn_file, app_name),
         :ok <- register_definition(diagram, process_id),
         :ok <- register_handlers(diagram) do
      {:ok, diagram}
    end
  end

  @doc """
  Create a process instance with data, then activate it.

  Unlike `Rodar.Process.create_and_run/2` which activates immediately,
  this function sets data BEFORE activation: start_child → put_data × N → activate.

  Returns `{:ok, pid}` on success.
  """
  @spec start_process(String.t(), map()) :: {:ok, pid()} | {:error, any()}
  def start_process(process_id, data \\ %{}) do
    case DynamicSupervisor.start_child(
           Rodar.ProcessSupervisor,
           {Process, {process_id, %{}}}
         ) do
      {:ok, pid} ->
        context = Process.get_context(pid)

        Enum.each(data, fn {key, value} ->
          Context.put_data(context, key, value)
        end)

        Process.activate(pid)
        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Resume a user task on a process instance.

  Looks up the task element in the process map, verifies it is a user task,
  and delegates to `Rodar.Activity.Task.User.resume/3`.

  Returns the result of `UserTask.resume/3`, or `{:error, reason}` if the
  task is not found or not a user task.
  """
  @spec resume_user_task(pid(), String.t(), map()) :: Rodar.result() | {:error, String.t()}
  def resume_user_task(pid, task_id, input) when is_map(input) do
    context = Process.get_context(pid)
    process_map = Context.get(context, :process)

    case Map.get(process_map, task_id) do
      {:bpmn_activity_task_user, _attrs} = element ->
        UserTask.resume(element, context, input)

      nil ->
        {:error, "Task '#{task_id}' not found in process"}

      {type, _attrs} ->
        {:error, "Task '#{task_id}' is #{type}, not a user task"}
    end
  end

  @doc """
  Complete an async service task on a process instance.

  Looks up the context for the process and delegates to
  `Rodar.Activity.Task.Service.complete_async/3`.

  Returns the result of `Service.complete_async/3`.
  """
  @spec complete_async_service(pid(), String.t(), map()) :: Rodar.result() | {:error, String.t()}
  def complete_async_service(pid, task_id, result) when is_map(result) do
    context = Process.get_context(pid)
    Service.complete_async(context, task_id, result)
  end

  @doc """
  Get the current status of a process instance.

  When the Process GenServer reports `:suspended` (set during initial activation
  when a user task pauses execution), this function checks whether any nodes
  are still active in the context. If no nodes are active, the process has
  actually completed via an external `resume_user_task` call, so `:completed`
  is returned instead.
  """
  @spec process_status(pid()) :: Rodar.Process.status()
  def process_status(pid) do
    case Process.status(pid) do
      :suspended ->
        context = Process.get_context(pid)
        nodes = Context.get(context, :nodes)

        has_active =
          Enum.any?(nodes, fn
            {key, %{active: true}} when is_binary(key) -> true
            _ -> false
          end)

        if has_active, do: :suspended, else: :completed

      other ->
        other
    end
  end

  @doc """
  Get the current data map of a process instance.
  """
  @spec process_data(pid()) :: map()
  def process_data(pid) do
    context = Process.get_context(pid)
    Context.get(context, :data)
  end

  @doc """
  Get the execution history of a process instance.
  """
  @spec process_history(pid()) :: [map()]
  def process_history(pid) do
    context = Process.get_context(pid)
    Context.get_history(context)
  end

  # --- Private ---

  defp read_bpmn_file(path) do
    case File.read(path) do
      {:ok, xml} -> {:ok, xml}
      {:error, reason} -> {:error, "Could not read BPMN file '#{path}': #{inspect(reason)}"}
    end
  end

  defp resolve_path(bpmn_file, nil), do: bpmn_file

  defp resolve_path(bpmn_file, otp_app) do
    Application.app_dir(otp_app, bpmn_file)
  end

  defp load_diagram(xml, bpmn_file, app_name) when is_binary(app_name) do
    Diagram.load(xml, bpmn_file: bpmn_file, app_name: app_name)
  end

  defp load_diagram(xml, _bpmn_file, _app_name) do
    Diagram.load(xml)
  end

  defp register_definition(diagram, process_id) do
    case diagram.processes do
      [process | _] ->
        Rodar.Registry.register(process_id, process)
        :ok

      [] ->
        {:error, "No processes found in BPMN diagram"}
    end
  end

  defp register_handlers(%{discovery: discovery}) when is_map(discovery) do
    Discovery.register_discovered(discovery)
    :ok
  end

  defp register_handlers(_diagram), do: :ok

  # --- `use` macro ---

  defmacro __using__(opts) do
    quote do
      @__workflow_opts__ unquote(opts)

      @doc false
      def setup do
        Rodar.Workflow.setup(@__workflow_opts__)
      end

      @doc false
      def start_process(data \\ %{}) do
        process_id = Keyword.fetch!(@__workflow_opts__, :process_id)
        Rodar.Workflow.start_process(process_id, data)
      end

      @doc false
      def resume_user_task(pid, task_id, input) do
        Rodar.Workflow.resume_user_task(pid, task_id, input)
      end

      @doc false
      def complete_async_service(pid, task_id, result) do
        Rodar.Workflow.complete_async_service(pid, task_id, result)
      end

      @doc false
      def process_status(pid) do
        Rodar.Workflow.process_status(pid)
      end

      @doc false
      def process_data(pid) do
        Rodar.Workflow.process_data(pid)
      end

      @doc false
      def process_history(pid) do
        Rodar.Workflow.process_history(pid)
      end

      defoverridable setup: 0,
                     start_process: 0,
                     start_process: 1,
                     resume_user_task: 3,
                     complete_async_service: 3,
                     process_status: 1,
                     process_data: 1,
                     process_history: 1
    end
  end
end
