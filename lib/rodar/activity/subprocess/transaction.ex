defmodule Rodar.Activity.Subprocess.Transaction do
  @moduledoc """
  Handle passing the token through a transaction subprocess element.

  A transaction subprocess extends embedded subprocess semantics with
  cancel/compensation behavior. When a cancel end event fires inside
  a transaction:

  1. The `:cancelled` meta flag is set on the context
  2. Scoped compensation runs (only activities within the transaction)
  3. The cancel boundary event on the transaction fires

  If no cancel end event fires, the transaction behaves like a normal
  embedded subprocess.

  ## Execution flow

  1. Extract nested `elements` map from element attrs
  2. Set transaction scope metadata for scoped compensation
  3. Swap context process to nested elements
  4. Find and execute the start event within nested elements
  5. Restore parent process on completion
  6. If cancelled: find and activate the cancel boundary event
  7. If normal completion: release token to outgoing flows

  ## Examples

      iex> start = {:bpmn_event_start, %{id: "sub_start", incoming: [], outgoing: ["sub_flow"]}}
      iex> sub_end = {:bpmn_event_end, %{id: "sub_end", incoming: ["sub_flow"], outgoing: []}}
      iex> sub_flow = {:bpmn_sequence_flow, %{id: "sub_flow", sourceRef: "sub_start", targetRef: "sub_end", conditionExpression: nil, isImmediate: nil}}
      iex> nested = %{"sub_start" => start, "sub_end" => sub_end, "sub_flow" => sub_flow}
      iex> outer_end = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
      iex> flow_out = {:bpmn_sequence_flow, %{id: "flow_out", sourceRef: "txn", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> process = %{"flow_out" => flow_out, "end" => outer_end}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> elem = {:bpmn_activity_subprocess_transaction, %{id: "txn", outgoing: ["flow_out"], elements: nested}}
      iex> {:ok, ^context} = Rodar.Activity.Subprocess.Transaction.token_in(elem, context)
      iex> true
      true

  """

  alias Rodar.Context

  @activity_types [
    :bpmn_activity_task_user,
    :bpmn_activity_task_script,
    :bpmn_activity_task_service,
    :bpmn_activity_task_manual,
    :bpmn_activity_task_send,
    :bpmn_activity_task_receive,
    :bpmn_activity_subprocess,
    :bpmn_activity_subprocess_embeded,
    :bpmn_activity_task
  ]

  @doc """
  Receive the token for the element and execute the transaction subprocess.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in(
        {:bpmn_activity_subprocess_transaction,
         %{id: id, outgoing: outgoing, elements: elements}},
        context
      ) do
    Context.put_meta(context, id, %{active: true, completed: false, type: :transaction})

    # Track which activities are inside this transaction for scoped compensation
    activity_ids = collect_activity_ids(elements)
    Context.put_meta(context, :transaction_scope, activity_ids)

    old_process = Context.swap_process(context, elements)

    result =
      case find_start_event(elements) do
        nil ->
          {:error, "Transaction subprocess '#{id}': no start event found"}

        start_event ->
          Rodar.execute(start_event, context)
      end

    Context.swap_process(context, old_process)

    # Clear transaction scope
    Context.put_meta(context, :transaction_scope, nil)

    handle_result(result, context, id, outgoing, old_process)
  end

  defp handle_result(result, context, id, outgoing, old_process) do
    cancelled = Context.get_meta(context, :cancelled)

    cond do
      cancelled == true ->
        handle_cancelled(context, id, old_process)

      match?({:ok, _}, result) ->
        handle_success(context, id, outgoing)

      match?({:error, _}, result) ->
        handle_error(result, context, id, old_process)

      true ->
        result
    end
  end

  defp handle_cancelled(context, id, old_process) do
    Context.put_meta(context, :cancelled, nil)

    Context.put_meta(context, id, %{
      active: false,
      completed: false,
      type: :transaction,
      cancelled: true
    })

    case find_cancel_boundary(old_process, id) do
      nil ->
        {:ok, context}

      {:bpmn_event_boundary, %{outgoing: boundary_outgoing}} ->
        Rodar.release_token(boundary_outgoing, context)
    end
  end

  defp handle_success(context, id, outgoing) do
    Context.put_meta(context, id, %{
      active: false,
      completed: true,
      type: :transaction
    })

    Rodar.release_token(outgoing, context)
  end

  defp handle_error(result, context, id, old_process) do
    case find_error_boundary(old_process, id) do
      nil ->
        result

      {:bpmn_event_boundary, %{outgoing: boundary_outgoing}} ->
        Context.put_meta(context, id, %{
          active: false,
          completed: false,
          type: :transaction,
          error: true
        })

        Rodar.release_token(boundary_outgoing, context)
    end
  end

  defp find_start_event(elements) do
    Enum.find_value(elements, fn
      {_id, {:bpmn_event_start, _} = elem} -> elem
      _ -> nil
    end)
  end

  defp find_cancel_boundary(process, subprocess_id) do
    Enum.find_value(process, fn
      {_id, {:bpmn_event_boundary, %{attachedToRef: ^subprocess_id} = attrs} = elem} ->
        if has_cancel_definition?(attrs), do: elem

      _ ->
        nil
    end)
  end

  defp find_error_boundary(process, subprocess_id) do
    Enum.find_value(process, fn
      {_id, {:bpmn_event_boundary, %{attachedToRef: ^subprocess_id} = attrs} = elem} ->
        if has_error_definition?(attrs), do: elem

      _ ->
        nil
    end)
  end

  defp has_cancel_definition?(attrs) do
    match?({:bpmn_event_definition_cancel, _}, Map.get(attrs, :cancelEventDefinition))
  end

  defp has_error_definition?(attrs) do
    match?({:bpmn_event_definition_error, _}, Map.get(attrs, :errorEventDefinition))
  end

  defp collect_activity_ids(elements) do
    Enum.flat_map(elements, fn
      {id, {type, _}} when type in @activity_types -> [id]
      _ -> []
    end)
  end
end
