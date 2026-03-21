defmodule Rodar do
  @moduledoc """
  Main dispatcher for the Rodar Workflow execution engine.

  Routes BPMN elements to their handler modules based on element type. Each node
  in a parsed BPMN process is represented as a `{:bpmn_node_type, %{...}}` tuple,
  and the dispatcher resolves which module handles it.

  ## Execution Modes

  - `execute/2` — Simple dispatch, returns the handler result directly.
  - `execute/3` — Token-aware dispatch via `Rodar.Token`, records execution
    history in `Rodar.Context`, notifies `Rodar.Hooks`, and emits
    `Rodar.Telemetry` events.

  ## Token Flow

  `release_token/2` passes a token to the next node by ID. `release_token/3`
  forks child tokens for parallel branches (e.g., from a parallel gateway).

  ## Execution History Classification

  `execute/3` records each node's completion result in the execution history.
  A node that calls `release_token` is classified as `:ok` regardless of the
  downstream result, because calling `release_token` means the node itself
  completed its work successfully. Only nodes that return directly without
  releasing (e.g., a user task returning `{:manual, _}`) are classified by
  their own return value.

  ## Return Values

  All handlers return one of:

  - `{:ok, context}` — Node completed successfully.
  - `{:error, message}` — Execution error with a description.
  - `{:manual, context}` — Process paused at an external activity (user task, receive task, etc.).
  - `{:fatal, reason}` — Unrecoverable error.
  - `{:not_implemented}` — Element type has no handler implementation.
  """

  require Logger

  alias Rodar.Activity.Subprocess
  alias Rodar.Activity.Subprocess.Embedded, as: SubprocessEmbedded
  alias Rodar.Activity.Subprocess.Transaction, as: SubprocessTransaction
  alias Rodar.Activity.Task.Manual
  alias Rodar.Activity.Task.Receive, as: TaskReceive
  alias Rodar.Activity.Task.Script
  alias Rodar.Activity.Task.Send, as: TaskSend
  alias Rodar.Activity.Task.Service
  alias Rodar.Activity.Task.User
  alias Rodar.Compensation
  alias Rodar.Context
  alias Rodar.Event.Boundary
  alias Rodar.Event.End
  alias Rodar.Event.Intermediate
  alias Rodar.Event.Intermediate.Catch, as: IntermediateCatch
  alias Rodar.Event.Intermediate.Throw, as: IntermediateThrow
  alias Rodar.Event.Start
  alias Rodar.Gateway.Complex
  alias Rodar.Gateway.Exclusive
  alias Rodar.Gateway.Exclusive.Event, as: ExclusiveEvent
  alias Rodar.Gateway.Inclusive
  alias Rodar.Gateway.Parallel
  alias Rodar.Hooks
  alias Rodar.SequenceFlow
  alias Rodar.TaskRegistry
  alias Rodar.Telemetry
  alias Rodar.Token

  @typedoc "A BPMN element represented as a tagged tuple with a map of attributes"
  @type element :: {atom(), map()}

  @typedoc "A BPMN execution context (GenServer pid)"
  @type context :: pid()

  @typedoc "Result of executing a BPMN element"
  @type result ::
          {:ok, context()}
          | {:error, String.t()}
          | {:manual, any()}
          | {:fatal, any()}
          | {:not_implemented}
          | {false}

  @doc """
  Parse a string representation of a process into an executable process representation
  """
  @spec parse(any()) :: {:ok, map()}
  def parse(_process) do
    {:ok, %{"start_node_id" => {:bpmn_event_start, %{}}}}
  end

  @doc """
  Get a node from a process by target id
  """
  @spec next(String.t(), map()) :: element() | nil
  def next(target, process) do
    Map.get(process, target)
  end

  @doc """
  Release token to another target node
  """
  @spec release_token(String.t() | [String.t()], context()) :: result()
  def release_token(targets, context) when is_list(targets) do
    mark_token_released(context)

    targets
    |> Task.async_stream(&release_token(&1, context))
    |> Enum.reduce({:ok, context}, &reduce_result/2)
  end

  def release_token(target, context) do
    mark_token_released(context)
    process = Context.get(context, :process)
    next = next(target, process)

    case next do
      nil -> {:error, "Unable to find node '#{target}'"}
      _ -> execute(next, context)
    end
  end

  @doc """
  Release token to another target node, threading a `Rodar.Token` through execution.

  When `targets` is a list (parallel fork), creates child tokens via `Rodar.Token.fork/1`
  for each branch.
  """
  @spec release_token(String.t() | [String.t()], context(), Rodar.Token.t()) :: result()
  def release_token(targets, context, %Token{} = token) when is_list(targets) do
    mark_token_released(context)

    targets
    |> Task.async_stream(fn target ->
      child_token = Token.fork(token)
      release_token(target, context, child_token)
    end)
    |> Enum.reduce({:ok, context}, &reduce_result/2)
  end

  def release_token(target, context, %Token{} = token) do
    mark_token_released(context)
    process = Context.get(context, :process)
    next = next(target, process)

    case next do
      nil -> {:error, "Unable to find node '#{target}'"}
      _ -> execute(next, context, token)
    end
  end

  @doc """
  Execute a node in the process
  """
  @spec execute(element(), context()) :: result()
  def execute(elem, context) do
    token = Token.new()
    execute(elem, context, token)
  end

  @doc """
  Execute a node in the process with token tracking.

  Updates the token's `current_node` before dispatching to the handler,
  stores the token on the context, and records execution history.
  """
  @spec execute(element(), context(), Token.t()) :: result()
  def execute({type, %{id: id} = _attrs} = elem, context, %Token{} = token) do
    token = %{token | current_node: id}
    Context.put_meta(context, :current_token, token)
    Context.put_meta(context, {:_token_released, token.id}, false)

    Context.record_visit(context, %{
      node_id: id,
      token_id: token.id,
      node_type: type,
      timestamp: System.monotonic_time(:millisecond)
    })

    Logger.metadata(
      rodar_node_id: id,
      rodar_node_type: type,
      rodar_token_id: token.id
    )

    span_metadata = %{node_id: id, node_type: type, token_id: token.id}

    Hooks.notify(context, :before_node, %{node_id: id, node_type: type, token: token})

    if activity_type?(type), do: pre_register_compensation(context, id)

    result = Telemetry.node_span(span_metadata, fn -> dispatch(elem, context) end)

    Hooks.notify(context, :after_node, %{
      node_id: id,
      node_type: type,
      token: token,
      result: result
    })

    token_was_released = Context.get_meta(context, {:_token_released, token.id})
    Context.put_meta(context, {:_token_released, token.id}, nil)

    result_type =
      if token_was_released do
        :ok
      else
        classify_result(result, context, id)
      end

    Context.record_completion(context, id, token.id, result_type)

    if result_type != :ok and activity_type?(type) do
      Compensation.remove_handlers(context, id)
    end

    result
  end

  # Elements without :id (e.g., bare sequence flows in some paths) skip history recording
  def execute(elem, context, %Token{} = token) do
    Context.put_meta(context, :current_token, token)
    dispatch(elem, context)
  end

  defp dispatch({:bpmn_event_start, _} = elem, context),
    do: Start.token_in(elem, context)

  defp dispatch({:bpmn_event_end, _} = elem, context),
    do: End.token_in(elem, context)

  defp dispatch({:bpmn_event_intermediate, _} = elem, context),
    do: Intermediate.token_in(elem, context)

  defp dispatch({:bpmn_event_intermediate_throw, _} = elem, context),
    do: IntermediateThrow.token_in(elem, context)

  defp dispatch({:bpmn_event_intermediate_catch, _} = elem, context),
    do: IntermediateCatch.token_in(elem, context)

  defp dispatch({:bpmn_event_boundary, _} = elem, context),
    do: Boundary.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_user, _} = elem, context),
    do: User.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_script, _} = elem, context),
    do: Script.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_service, _} = elem, context),
    do: Service.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_manual, _} = elem, context),
    do: Manual.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_send, _} = elem, context),
    do: TaskSend.token_in(elem, context)

  defp dispatch({:bpmn_activity_task_receive, _} = elem, context),
    do: TaskReceive.token_in(elem, context)

  defp dispatch({:bpmn_activity_subprocess, _} = elem, context),
    do: Subprocess.token_in(elem, context)

  defp dispatch({:bpmn_activity_subprocess_embeded, _} = elem, context),
    do: SubprocessEmbedded.token_in(elem, context)

  defp dispatch({:bpmn_activity_subprocess_transaction, _} = elem, context),
    do: SubprocessTransaction.token_in(elem, context)

  defp dispatch({:bpmn_gateway_exclusive, _} = elem, context),
    do: Exclusive.token_in(elem, context)

  defp dispatch({:bpmn_gateway_exclusive_event, _} = elem, context),
    do: ExclusiveEvent.token_in(elem, context)

  defp dispatch({:bpmn_gateway_parallel, _} = elem, context) do
    from_flow = pop_from_flow()
    Parallel.token_in(elem, context, from_flow)
  end

  defp dispatch({:bpmn_gateway_inclusive, _} = elem, context) do
    from_flow = pop_from_flow()
    Inclusive.token_in(elem, context, from_flow)
  end

  defp dispatch({:bpmn_gateway_complex, _} = elem, context) do
    from_flow = pop_from_flow()
    Complex.token_in(elem, context, from_flow)
  end

  defp dispatch({:bpmn_sequence_flow, _} = elem, context),
    do: SequenceFlow.token_in(elem, context)

  defp dispatch({type, %{id: id}} = elem, context) do
    case TaskRegistry.lookup(id) do
      {:ok, handler} ->
        handler.token_in(elem, context)

      :error ->
        case TaskRegistry.lookup(type) do
          {:ok, handler} -> handler.token_in(elem, context)
          :error -> {:not_implemented}
        end
    end
  end

  defp dispatch(_elem, _context), do: {:not_implemented}

  @activity_types [
    :bpmn_activity_task_user,
    :bpmn_activity_task_script,
    :bpmn_activity_task_service,
    :bpmn_activity_task_manual,
    :bpmn_activity_task_send,
    :bpmn_activity_task_receive,
    :bpmn_activity_subprocess,
    :bpmn_activity_subprocess_embeded,
    :bpmn_activity_subprocess_transaction
  ]

  defp classify_result({:ok, _}, _context, _id), do: :ok
  defp classify_result({:manual, _}, _context, _id), do: :manual
  defp classify_result({:fatal, _}, _context, _id), do: :fatal
  defp classify_result({:not_implemented}, _context, _id), do: :not_implemented

  defp classify_result({:error, reason}, context, id) do
    Hooks.notify(context, :on_error, %{node_id: id, error: reason})
    :error
  end

  defp classify_result(_, _context, _id), do: :unknown

  defp activity_type?(type), do: type in @activity_types

  defp pop_from_flow do
    case Process.delete(:_rodar_from_flow) do
      :undefined -> nil
      value -> value
    end
  end

  defp mark_token_released(context) do
    case Context.get_meta(context, :current_token) do
      %Token{id: token_id} ->
        Context.put_meta(context, {:_token_released, token_id}, true)

      _ ->
        :ok
    end
  end

  defp pre_register_compensation(context, activity_id) do
    process = Context.get(context, :process)

    process
    |> find_compensation_boundaries(activity_id)
    |> Enum.each(fn {outgoing, _attrs} ->
      handler_id = find_handler_target(outgoing, process)
      if handler_id, do: Compensation.register_handler(context, activity_id, handler_id)
    end)
  end

  defp find_compensation_boundaries(process, activity_id) do
    Enum.flat_map(process, fn
      {_id, {:bpmn_event_boundary, %{attachedToRef: ^activity_id, outgoing: outgoing} = attrs}} ->
        if has_compensate_definition?(attrs), do: [{outgoing, attrs}], else: []

      _ ->
        []
    end)
  end

  defp has_compensate_definition?(attrs) do
    match?({:bpmn_event_definition_compensate, _}, Map.get(attrs, :compensateEventDefinition))
  end

  defp find_handler_target([flow_id | _], process) do
    case Map.get(process, flow_id) do
      {:bpmn_sequence_flow, %{targetRef: target}} -> target
      _ -> nil
    end
  end

  defp find_handler_target(_, _), do: nil

  defp reduce_result({:ok, {:ok, _} = result}, {:ok, _}), do: result
  defp reduce_result({:ok, {:error, _} = result}, {:ok, _}), do: result
  defp reduce_result({:ok, {:error, _}}, {:error, _} = acc), do: acc
  defp reduce_result({:ok, {:fatal, _} = result}, _), do: result
  defp reduce_result({:ok, {:not_implemented} = result}, _), do: result
  defp reduce_result({:ok, {:manual, _} = result}, {:ok, _}), do: result
  defp reduce_result({:ok, {:manual, _}}, acc), do: acc
end
