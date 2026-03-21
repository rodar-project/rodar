defmodule Rodar.Event.End do
  @moduledoc """
  Handle passing the token through an end event element.

  Supports four types of end events:

  - **Plain end** — Normal completion. Returns `{:ok, context}`.
  - **Error end** — Sets error state in context. Returns `{:error, error_ref}`.
  - **Terminate end** — Signals all branches to stop. Returns `{:ok, context}`
    after marking the process as terminated.
  - **Cancel end** — Triggers cancellation of the enclosing transaction subprocess.
    Sets `:cancelled` meta on context and triggers scoped compensation for
    activities within the transaction scope. Returns `{:ok, context}`.

  ## Examples

      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> {:ok, ^context} = Rodar.Event.End.token_in({:bpmn_event_end, %{incoming: []}}, context)
      iex> true
      true

      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> elem = {:bpmn_event_end, %{id: "end_err", incoming: ["f1"], errorEventDefinition: {:bpmn_event_definition_error, %{errorRef: "Error_001"}}}}
      iex> {:error, "Error_001"} = Rodar.Event.End.token_in(elem, context)
      iex> true
      true

      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> elem = {:bpmn_event_end, %{id: "end_term", incoming: ["f1"], terminateEventDefinition: %{}}}
      iex> {:ok, ^context} = Rodar.Event.End.token_in(elem, context)
      iex> Rodar.Context.get_meta(context, :terminated)
      true

  """

  @doc """
  Receive the token for the element and handle end event logic.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_event_end, attrs} = _elem, context) do
    result =
      cond do
        has_error_definition?(attrs) ->
          handle_error(attrs, context)

        has_terminate_definition?(attrs) ->
          handle_terminate(context)

        has_compensate_definition?(attrs) ->
          handle_compensate(attrs, context)

        has_cancel_definition?(attrs) ->
          handle_cancel(context)

        true ->
          {:ok, context}
      end

    node_id = Map.get(attrs, :id)

    if match?({:ok, _}, result) do
      Rodar.Hooks.notify(context, :on_complete, %{node_id: node_id})
    end

    result
  end

  defp has_error_definition?(attrs) do
    match?({:bpmn_event_definition_error, _}, Map.get(attrs, :errorEventDefinition))
  end

  defp has_terminate_definition?(attrs) do
    Map.get(attrs, :terminateEventDefinition) != nil
  end

  defp handle_error(attrs, context) do
    {:bpmn_event_definition_error, %{errorRef: error_ref}} = attrs.errorEventDefinition
    Rodar.Context.put_meta(context, :error, error_ref)
    {:error, error_ref}
  end

  defp handle_terminate(context) do
    Rodar.Context.put_meta(context, :terminated, true)
    {:ok, context}
  end

  defp has_cancel_definition?(attrs) do
    match?({:bpmn_event_definition_cancel, _}, Map.get(attrs, :cancelEventDefinition))
  end

  defp handle_cancel(context) do
    Rodar.Context.put_meta(context, :cancelled, true)

    # Trigger scoped compensation for the transaction scope
    transaction_scope = Rodar.Context.get_meta(context, :transaction_scope)

    if transaction_scope do
      Rodar.Compensation.compensate_scope(context, transaction_scope)
    else
      Rodar.Compensation.compensate_all(context)
    end

    {:ok, context}
  end

  defp has_compensate_definition?(attrs) do
    match?({:bpmn_event_definition_compensate, _}, Map.get(attrs, :compensateEventDefinition))
  end

  defp handle_compensate(attrs, context) do
    {:bpmn_event_definition_compensate, def_attrs} = attrs.compensateEventDefinition
    activity_ref = Map.get(def_attrs, :activityRef)

    if activity_ref do
      Rodar.Compensation.compensate_activity(context, to_string(activity_ref))
    else
      Rodar.Compensation.compensate_all(context)
    end

    {:ok, context}
  end
end
