defmodule Rodar.Workflow.Server do
  @moduledoc """
  GenServer abstraction for BPMN workflow management.

  Builds on `Rodar.Workflow` (Layer 1) to eliminate GenServer boilerplate
  for common BPMN patterns: instance creation, task completion, and instance
  tracking.

  ## Usage

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

        # Optional
        @impl Rodar.Workflow.Server
        def map_status(:suspended), do: :pending_approval
        def map_status(other), do: other

        # Domain API
        def create_order(params), do: create_instance(params)
        def approve(id), do: complete_task(id, "Task_Approval", %{"approved" => true})
      end

  ## Callbacks

    * `init_data/2` (required) — transform input params and instance ID into
      the BPMN process data map
    * `map_status/1` (optional) — translate BPMN status atoms to domain-specific
      status atoms. Defaults to identity.

  ## Injected Functions

    * `start_link/1` — accepts `name:` option, defaults to `__MODULE__`
    * `create_instance/1` — create a BPMN process instance from params
    * `complete_task/3` — resume a user task on an instance
    * `list_instances/0` — list all tracked instances (newest first)
    * `get_instance/1` — get a specific instance by ID

  All workflow GenServer messages use `{:__workflow__, action, ...}` tuple tags
  to avoid collisions with user-defined `handle_call` clauses.

  ## Error Handling

    * If `setup/0` fails during `init/1`, the server returns
      `{:stop, {:workflow_setup_failed, reason}}` — the wrapper makes it clear
      the error originated from workflow setup rather than a generic init failure.
    * `complete_task/3` propagates errors from `Rodar.Workflow.resume_user_task/3`
      (e.g., wrong task ID, non-user task) instead of silently discarding them.
  """

  @doc """
  Transform input parameters into the BPMN process data map.

  Called during `create_instance/1` before activating the process.
  The `instance_id` is a sequential integer assigned by the server.
  """
  @callback init_data(params :: map(), instance_id :: pos_integer()) :: map()

  @doc """
  Translate a BPMN process status atom to a domain-specific status.

  Optional — defaults to returning the status unchanged.
  """
  @callback map_status(bpmn_status :: atom()) :: atom()

  @optional_callbacks [map_status: 1]

  @doc false
  def __apply_map_status__(module, status) do
    if function_exported?(module, :map_status, 1) do
      module.map_status(status)
    else
      status
    end
  end

  defmacro __using__(opts) do
    quote do
      use GenServer
      use Rodar.Workflow, unquote(opts)

      @behaviour Rodar.Workflow.Server

      @__server_opts__ unquote(opts)

      # --- Client API ---

      @doc false
      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @doc false
      def create_instance(params \\ %{}) do
        GenServer.call(__MODULE__, {:__workflow__, :create_instance, params})
      end

      @doc false
      def complete_task(instance_id, task_id, input) do
        GenServer.call(__MODULE__, {:__workflow__, :complete_task, instance_id, task_id, input})
      end

      @doc false
      def complete_service_task(instance_id, task_id, result) do
        GenServer.call(
          __MODULE__,
          {:__workflow__, :complete_service_task, instance_id, task_id, result}
        )
      end

      @doc false
      def list_instances do
        GenServer.call(__MODULE__, {:__workflow__, :list_instances})
      end

      @doc false
      def get_instance(instance_id) do
        GenServer.call(__MODULE__, {:__workflow__, :get_instance, instance_id})
      end

      # --- GenServer Callbacks ---

      @impl GenServer
      def init(_opts) do
        case setup() do
          {:ok, _diagram} ->
            {:ok, %{instances: %{}, counter: 0}}

          {:error, reason} ->
            {:stop, {:workflow_setup_failed, reason}}
        end
      end

      @impl GenServer
      def handle_call({:__workflow__, :create_instance, params}, _from, state) do
        next_id = state.counter + 1
        data = init_data(params, next_id)

        process_id = Keyword.fetch!(@__server_opts__, :process_id)

        case Rodar.Workflow.start_process(process_id, data) do
          {:ok, pid} ->
            status = Rodar.Workflow.process_status(pid)
            mapped = unquote(__MODULE__).__apply_map_status__(__MODULE__, status)

            instance = %{
              id: next_id,
              process_pid: pid,
              status: mapped,
              created_at: DateTime.utc_now()
            }

            instances = Map.put(state.instances, next_id, instance)
            new_state = %{state | instances: instances, counter: next_id}
            {:reply, {:ok, instance}, new_state}

          {:error, _} = error ->
            {:reply, error, state}
        end
      end

      def handle_call(
            {:__workflow__, :complete_task, instance_id, task_id, input},
            _from,
            state
          ) do
        case Map.fetch(state.instances, instance_id) do
          {:ok, instance} ->
            case Rodar.Workflow.resume_user_task(instance.process_pid, task_id, input) do
              {:error, _} = error ->
                {:reply, error, state}

              _result ->
                status = Rodar.Workflow.process_status(instance.process_pid)
                mapped = unquote(__MODULE__).__apply_map_status__(__MODULE__, status)

                updated = %{instance | status: mapped}
                instances = Map.put(state.instances, instance_id, updated)
                {:reply, {:ok, updated}, %{state | instances: instances}}
            end

          :error ->
            {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call(
            {:__workflow__, :complete_service_task, instance_id, task_id, result},
            _from,
            state
          ) do
        case Map.fetch(state.instances, instance_id) do
          {:ok, instance} ->
            case Rodar.Workflow.complete_async_service(
                   instance.process_pid,
                   task_id,
                   result
                 ) do
              {:error, _} = error ->
                {:reply, error, state}

              _result ->
                status = Rodar.Workflow.process_status(instance.process_pid)
                mapped = unquote(__MODULE__).__apply_map_status__(__MODULE__, status)

                updated = %{instance | status: mapped}
                instances = Map.put(state.instances, instance_id, updated)
                {:reply, {:ok, updated}, %{state | instances: instances}}
            end

          :error ->
            {:reply, {:error, :not_found}, state}
        end
      end

      def handle_call({:__workflow__, :list_instances}, _from, state) do
        sorted =
          state.instances
          |> Map.values()
          |> Enum.sort_by(& &1.id, :desc)

        {:reply, sorted, state}
      end

      def handle_call({:__workflow__, :get_instance, instance_id}, _from, state) do
        case Map.fetch(state.instances, instance_id) do
          {:ok, instance} -> {:reply, {:ok, instance}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      end

      defoverridable start_link: 0,
                     start_link: 1,
                     create_instance: 0,
                     create_instance: 1,
                     complete_task: 3,
                     complete_service_task: 3,
                     list_instances: 0,
                     get_instance: 1,
                     init: 1,
                     handle_call: 3
    end
  end
end
