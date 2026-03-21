defmodule Rodar.Context do
  @moduledoc """
  GenServer-based execution context for a running BPMN process instance.

  Holds all mutable state during process execution: the process definition,
  initial and current data, node metadata, token counts, and execution history.
  Each process instance gets its own context, typically started under
  `Rodar.ContextSupervisor` via `start_supervised/2`.

  ## State Management

  - `get/2` — Read top-level state keys (`:init`, `:data`, `:process`, `:nodes`, `:meta`).
  - `get_state/1` / `restore_state/2` — Snapshot and restore full state (for persistence).
  - `swap_process/2` — Replace the process definition (for version migration).

  ## Data and Metadata

  - `put_data/3` / `get_data/2` — Read and write process variables. Writing triggers
    any registered conditional subscriptions.
  - `put_meta/3` / `get_meta/2` — Store auxiliary metadata outside the process data.

  ## Token Tracking

  - `record_token/3` / `token_count/2` — Track how many tokens have arrived at a
    node (used by join gateways).
  - `record_activated_paths/3` — Track which outgoing paths were activated (for
    inclusive gateway joins).

  ## Execution History

  - `record_visit/2` / `record_completion/4` — Log node entry and exit.
  - `get_history/1` / `get_node_history/2` — Query the execution log.

  ## Conditional Subscriptions

  - `subscribe_condition/4` / `unsubscribe_condition/2` — Register expressions
    that are evaluated on every `put_data/3` call, firing `{:condition_met, ...}`
    when satisfied.
  """

  use GenServer

  alias Rodar.Activity.Subprocess.Event, as: SubprocessEvent
  alias Rodar.Event.Bus
  alias Rodar.Event.Timer
  alias Rodar.Expression.Feel
  alias Rodar.Expression.Sandbox

  # --- Client API ---

  @doc "Start the context process"
  @spec start_link({map(), map()} | map(), map()) :: {:ok, pid()}
  def start_link({process, init_data}) do
    start_link(process, init_data)
  end

  def start_link(process, init_data) do
    GenServer.start_link(__MODULE__, {process, init_data})
  end

  @doc """
  Start a supervised context under `Rodar.ContextSupervisor`.
  """
  @spec start_supervised(map(), map()) :: {:ok, pid()} | {:error, any()}
  def start_supervised(process, init_data) do
    DynamicSupervisor.start_child(
      Rodar.ContextSupervisor,
      {__MODULE__, {process, init_data}}
    )
  end

  @doc """
  Get a key from the current state of the context.
  Use this method to have access to the following:
  - init: the initial data with which the context was started
  - data: the current data saved in the context
  - process: a representation of the current process that is executing
  - nodes: metadata about each node information
  """
  @spec get(pid(), atom()) :: any()
  def get(context, key) do
    GenServer.call(context, {:get, key})
  end

  @doc """
  Persist a value under the given key in the data state of the context.
  """
  @spec put_data(pid(), any(), any()) :: :ok
  def put_data(context, key, value) do
    GenServer.call(context, {:put_data, key, value})
  end

  @doc """
  Load some information from the current data of the context from the given key
  """
  @spec get_data(pid(), any()) :: any()
  def get_data(context, key) do
    GenServer.call(context, {:get_data, key})
  end

  @doc """
  Put metadata information for a node.
  """
  @spec put_meta(pid(), any(), any()) :: :ok
  def put_meta(context, key, meta) do
    GenServer.call(context, {:put_meta, key, meta})
  end

  @doc """
  Get meta data for a node
  """
  @spec get_meta(pid(), any()) :: any()
  def get_meta(context, key) do
    GenServer.call(context, {:get_meta, key})
  end

  @doc """
  Check if the node is active
  """
  @spec node_active?(pid(), any()) :: boolean()
  def node_active?(context, key) do
    GenServer.call(context, {:node_active?, key})
  end

  @doc """
  Check if the node is completed
  """
  @spec node_completed?(pid(), any()) :: boolean()
  def node_completed?(context, key) do
    GenServer.call(context, {:node_completed?, key})
  end

  @doc """
  Record a token arrival at a gateway from a specific incoming flow.
  Returns the number of tokens that have arrived so far.
  """
  @spec record_token(pid(), String.t(), String.t()) :: non_neg_integer()
  def record_token(context, gateway_id, flow_id) do
    GenServer.call(context, {:record_token, gateway_id, flow_id})
  end

  @doc """
  Get the number of tokens that have arrived at a gateway.
  """
  @spec token_count(pid(), String.t()) :: non_neg_integer()
  def token_count(context, gateway_id) do
    GenServer.call(context, {:token_count, gateway_id})
  end

  @doc """
  Clear recorded tokens for a gateway (after join completes).
  """
  @spec clear_tokens(pid(), String.t()) :: :ok
  def clear_tokens(context, gateway_id) do
    GenServer.call(context, {:clear_tokens, gateway_id})
  end

  @doc """
  Record which outgoing flows were activated at an inclusive gateway fork.
  """
  @spec record_activated_paths(pid(), String.t(), [String.t()]) :: :ok
  def record_activated_paths(context, gateway_id, flow_ids) do
    GenServer.call(context, {:record_activated_paths, gateway_id, flow_ids})
  end

  @doc """
  Retrieve the list of activated flows for an inclusive gateway.
  """
  @spec get_activated_paths(pid(), String.t()) :: [String.t()] | nil
  def get_activated_paths(context, gateway_id) do
    GenServer.call(context, {:get_activated_paths, gateway_id})
  end

  @doc """
  Clear activated paths for a gateway (after join completes).
  """
  @spec clear_activated_paths(pid(), String.t()) :: :ok
  def clear_activated_paths(context, gateway_id) do
    GenServer.call(context, {:clear_activated_paths, gateway_id})
  end

  @doc """
  Swap the current process definition. Returns the old process for later restoration.
  """
  @spec swap_process(pid(), map()) :: map()
  def swap_process(context, new_process) do
    GenServer.call(context, {:swap_process, new_process})
  end

  @doc """
  Return the full state snapshot (for crash recovery and inspection).
  """
  @spec get_state(pid()) :: map()
  def get_state(context) do
    GenServer.call(context, :get_state)
  end

  @doc """
  Record a node visit in execution history.
  """
  @spec record_visit(pid(), map()) :: :ok
  def record_visit(context, entry) do
    GenServer.call(context, {:record_visit, entry})
  end

  @doc """
  Record the completion of a node visit, updating the last matching history entry.
  """
  @spec record_completion(pid(), String.t(), String.t(), atom()) :: :ok
  def record_completion(context, node_id, token_id, result_type) do
    GenServer.call(context, {:record_completion, node_id, token_id, result_type})
  end

  @doc """
  Get the full execution history.
  """
  @spec get_history(pid()) :: [map()]
  def get_history(context) do
    GenServer.call(context, :get_history)
  end

  @doc """
  Get execution history filtered by node ID.
  """
  @spec get_node_history(pid(), String.t()) :: [map()]
  def get_node_history(context, node_id) do
    GenServer.call(context, {:get_node_history, node_id})
  end

  @doc """
  Replace the full GenServer state wholesale (used during rehydration).
  """
  @spec restore_state(pid(), map()) :: :ok
  def restore_state(context, new_state) do
    GenServer.call(context, {:restore_state, new_state})
  end

  @doc """
  Subscribe to the event bus from within the context GenServer process.

  This ensures the context is the registered subscriber PID, so that
  `{:bpmn_event, ...}` messages are delivered to the context's `handle_info`.
  """
  @spec subscribe_event(pid(), atom(), String.t(), map()) :: {:ok, {atom(), String.t()}}
  def subscribe_event(context, event_type, event_name, metadata) do
    GenServer.call(context, {:subscribe_event, event_type, event_name, metadata})
  end

  @doc """
  Subscribe to condition evaluation on data changes.
  When any `put_data` call makes the condition expression evaluate to true,
  the context sends a `{:condition_met, ...}` message to itself.
  """
  @spec subscribe_condition(pid(), String.t(), String.t(), map()) :: :ok
  def subscribe_condition(context, subscription_id, condition_expr, metadata) do
    GenServer.call(context, {:subscribe_condition, subscription_id, condition_expr, metadata})
  end

  @doc """
  Remove a conditional subscription.
  """
  @spec unsubscribe_condition(pid(), String.t()) :: :ok
  def unsubscribe_condition(context, subscription_id) do
    GenServer.call(context, {:unsubscribe_condition, subscription_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({process, init_data}) do
    {:ok,
     %{
       init: init_data,
       data: %{},
       process: process,
       nodes: %{},
       history: [],
       conditional_subscriptions: %{}
     }}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, state[key], state}
  end

  def handle_call({:put_data, key, value}, _from, state) do
    new_state = update_in(state.data, &Map.put(&1, key, value))
    evaluate_conditions(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:get_data, key}, _from, state) do
    {:reply, state.data[key], state}
  end

  def handle_call({:put_meta, key, meta}, _from, state) do
    {:reply, :ok, update_in(state.nodes, &Map.put(&1, key, meta))}
  end

  def handle_call({:get_meta, key}, _from, state) do
    {:reply, state.nodes[key], state}
  end

  def handle_call({:node_active?, key}, _from, state) do
    {:reply, state.nodes[key].active, state}
  end

  def handle_call({:node_completed?, key}, _from, state) do
    {:reply, state.nodes[key].completed, state}
  end

  def handle_call({:record_token, gateway_id, flow_id}, _from, state) do
    tokens_key = {:gateway_tokens, gateway_id}
    current = Map.get(state.nodes, tokens_key, MapSet.new())
    updated = MapSet.put(current, flow_id)
    new_state = update_in(state.nodes, &Map.put(&1, tokens_key, updated))
    {:reply, MapSet.size(updated), new_state}
  end

  def handle_call({:token_count, gateway_id}, _from, state) do
    tokens_key = {:gateway_tokens, gateway_id}
    count = state.nodes |> Map.get(tokens_key, MapSet.new()) |> MapSet.size()
    {:reply, count, state}
  end

  def handle_call({:clear_tokens, gateway_id}, _from, state) do
    tokens_key = {:gateway_tokens, gateway_id}
    {:reply, :ok, update_in(state.nodes, &Map.delete(&1, tokens_key))}
  end

  def handle_call({:record_activated_paths, gateway_id, flow_ids}, _from, state) do
    key = {:gateway_activated_paths, gateway_id}
    {:reply, :ok, update_in(state.nodes, &Map.put(&1, key, flow_ids))}
  end

  def handle_call({:get_activated_paths, gateway_id}, _from, state) do
    key = {:gateway_activated_paths, gateway_id}
    {:reply, Map.get(state.nodes, key), state}
  end

  def handle_call({:clear_activated_paths, gateway_id}, _from, state) do
    key = {:gateway_activated_paths, gateway_id}
    {:reply, :ok, update_in(state.nodes, &Map.delete(&1, key))}
  end

  def handle_call({:swap_process, new_process}, _from, state) do
    {:reply, state.process, %{state | process: new_process}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:restore_state, new_state}, _from, _old_state) do
    {:reply, :ok, new_state}
  end

  def handle_call({:record_visit, entry}, _from, state) do
    {:reply, :ok, %{state | history: state.history ++ [entry]}}
  end

  def handle_call({:record_completion, node_id, token_id, result_type}, _from, state) do
    history =
      state.history
      |> Enum.reverse()
      |> update_first_match(node_id, token_id, result_type)
      |> Enum.reverse()

    {:reply, :ok, %{state | history: history}}
  end

  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call({:get_node_history, node_id}, _from, state) do
    filtered = Enum.filter(state.history, &(&1.node_id == node_id))
    {:reply, filtered, state}
  end

  def handle_call({:subscribe_event, event_type, event_name, metadata}, _from, state) do
    result = Bus.subscribe(event_type, event_name, metadata)
    {:reply, result, state}
  end

  def handle_call({:subscribe_condition, sub_id, condition_expr, metadata}, _from, state) do
    subs =
      Map.put(state.conditional_subscriptions, sub_id, %{
        condition: condition_expr,
        metadata: metadata
      })

    {:reply, :ok, %{state | conditional_subscriptions: subs}}
  end

  def handle_call({:unsubscribe_condition, sub_id}, _from, state) do
    subs = Map.delete(state.conditional_subscriptions, sub_id)
    {:reply, :ok, %{state | conditional_subscriptions: subs}}
  end

  @impl true
  def handle_info({:condition_met, "event_subprocess:" <> _ = sub_id, _outgoing}, state) do
    # Look up the conditional subscription metadata for this event subprocess
    sub = Map.get(state.conditional_subscriptions, sub_id)

    new_state =
      if sub do
        %{metadata: meta} = sub
        subprocess_attrs = Map.get(meta, :subprocess_attrs)
        interrupting = Map.get(meta, :interrupting, true)
        context = self()

        spawn(fn ->
          SubprocessEvent.activate(subprocess_attrs, context, %{})
        end)

        if interrupting do
          subs = Map.delete(state.conditional_subscriptions, sub_id)
          %{state | conditional_subscriptions: subs}
        else
          state
        end
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({:condition_met, node_id, outgoing}, state) do
    nodes = Map.put(state.nodes, node_id, %{active: false, completed: true, type: :catch_event})
    subs = Map.delete(state.conditional_subscriptions, node_id)
    new_state = %{state | nodes: nodes, conditional_subscriptions: subs}
    context = self()
    spawn(fn -> Rodar.release_token(outgoing, context) end)
    {:noreply, new_state}
  end

  def handle_info({:timer_fired, node_id, outgoing}, state) do
    nodes = Map.put(state.nodes, node_id, %{active: false, completed: true, type: :catch_event})
    new_state = %{state | nodes: nodes}
    context = self()
    spawn(fn -> Rodar.release_token(outgoing, context) end)
    {:noreply, new_state}
  end

  def handle_info({:timer_cycle_fired, node_id, outgoing, remaining, duration_ms}, state) do
    context = self()
    spawn(fn -> Rodar.release_token(outgoing, context) end)

    new_state =
      if remaining == 0 do
        nodes =
          Map.put(state.nodes, node_id, %{active: false, completed: true, type: :catch_event})

        %{state | nodes: nodes}
      else
        timer_ref =
          Timer.schedule_cycle(duration_ms, context, node_id, outgoing, remaining)

        nodes =
          Map.put(state.nodes, node_id, %{
            active: true,
            completed: false,
            type: :catch_event,
            timer_ref: timer_ref
          })

        %{state | nodes: nodes}
      end

    {:noreply, new_state}
  end

  def handle_info(
        {:bpmn_event, _type, _name, payload, %{type: :event_subprocess} = metadata},
        state
      ) do
    %{subprocess_attrs: subprocess_attrs, context: context} = metadata

    spawn(fn ->
      SubprocessEvent.activate(subprocess_attrs, context, payload)
    end)

    # Re-subscribe for non-interrupting (can fire multiple times)
    # This runs inside the context GenServer, so Bus.subscribe registers
    # the context PID as the subscriber automatically.
    if not Map.get(metadata, :interrupting, true) do
      event_type = Map.get(metadata, :event_type)
      event_name = Map.get(metadata, :event_name)

      if event_type && event_name do
        Bus.subscribe(event_type, event_name, metadata)
      end
    end

    {:noreply, state}
  end

  def handle_info({:bpmn_event, _type, _name, _payload, metadata}, state) do
    %{node_id: node_id, outgoing: outgoing, context: context} = metadata
    nodes = Map.put(state.nodes, node_id, %{active: false, completed: true, type: :catch_event})
    new_state = %{state | nodes: nodes}
    spawn(fn -> Rodar.release_token(outgoing, context) end)
    {:noreply, new_state}
  end

  def handle_info(
        {:event_subprocess_timer, _subprocess_id, subprocess_attrs, _interrupting},
        state
      ) do
    context = self()

    spawn(fn ->
      SubprocessEvent.activate(subprocess_attrs, context, %{})
    end)

    {:noreply, state}
  end

  def handle_info(
        {:event_subprocess_timer_cycle, subprocess_id, subprocess_attrs, interrupting, remaining,
         duration_ms},
        state
      ) do
    context = self()

    spawn(fn ->
      SubprocessEvent.activate(subprocess_attrs, context, %{})
    end)

    if remaining > 1 || remaining == :infinity do
      new_remaining =
        if remaining == :infinity, do: :infinity, else: remaining - 1

      Process.send_after(
        context,
        {:event_subprocess_timer_cycle, subprocess_id, subprocess_attrs, interrupting,
         new_remaining, duration_ms},
        duration_ms
      )
    end

    {:noreply, state}
  end

  defp evaluate_conditions(state) do
    context = self()

    Enum.each(state.conditional_subscriptions, fn {sub_id, %{condition: expr, metadata: meta}} ->
      result = eval_subscription_condition(expr, meta, state)

      case result do
        {:ok, true} ->
          outgoing = Map.get(meta, :outgoing, [])
          send(context, {:condition_met, sub_id, outgoing})

        _ ->
          :ok
      end
    end)
  end

  defp eval_subscription_condition(expr, meta, state) do
    case Map.get(meta, :condition_language, "elixir") do
      "feel" -> Feel.eval(expr, state.data)
      _ -> Sandbox.eval(expr, %{"data" => state.data})
    end
  end

  defp update_first_match([], _node_id, _token_id, _result_type), do: []

  defp update_first_match([entry | rest], node_id, token_id, result_type) do
    if entry.node_id == node_id and entry.token_id == token_id and
         not Map.has_key?(entry, :result) do
      [Map.put(entry, :result, result_type) | rest]
    else
      [entry | update_first_match(rest, node_id, token_id, result_type)]
    end
  end
end
