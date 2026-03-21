defmodule Rodar.Event.End do
  @moduledoc """
  Handle passing the token through an end event element.

  Supports the following end event types:

  - **Plain end** — Normal completion. Returns `{:ok, context}`.
  - **Error end** — Sets error state in context. Returns `{:error, error_ref}`.
  - **Terminate end** — Signals all branches to stop. Returns `{:ok, context}`
    after marking the process as terminated.
  - **Message end** — Publishes a message to the event bus, then returns `{:ok, context}`.
  - **Signal end** — Publishes a signal (broadcast) to the event bus, then returns `{:ok, context}`.
  - **Escalation end** — Publishes an escalation (broadcast) to the event bus, then returns `{:ok, context}`.

  Message, signal, and escalation end events follow the same publishing pattern
  as `Rodar.Event.Intermediate.Throw`, using `Rodar.Event.Bus` for delivery.

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

  alias Rodar.Context
  alias Rodar.Event.Bus

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

        has_message?(attrs) ->
          publish_message(attrs, context)
          {:ok, context}

        has_signal?(attrs) ->
          publish_signal(attrs, context)
          {:ok, context}

        has_escalation?(attrs) ->
          publish_escalation(attrs, context)
          {:ok, context}

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

  defp has_message?(attrs) do
    match?({:bpmn_event_definition_message, _}, Map.get(attrs, :messageEventDefinition))
  end

  defp has_signal?(attrs) do
    match?({:bpmn_event_definition_signal, _}, Map.get(attrs, :signalEventDefinition))
  end

  defp has_escalation?(attrs) do
    match?(
      {:bpmn_event_definition_escalation, _},
      Map.get(attrs, :escalationEventDefinition)
    )
  end

  defp handle_error(attrs, context) do
    {:bpmn_event_definition_error, %{errorRef: error_ref}} = attrs.errorEventDefinition
    Context.put_meta(context, :error, error_ref)
    {:error, error_ref}
  end

  defp handle_terminate(context) do
    Context.put_meta(context, :terminated, true)
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

  defp publish_message(attrs, context) do
    id = Map.get(attrs, :id)
    {:bpmn_event_definition_message, def_attrs} = attrs.messageEventDefinition
    message_name = Map.get(def_attrs, :messageRef, id)
    data = Context.get(context, :data)
    payload = %{source: id, data: data}
    payload = put_correlation(payload, def_attrs, context)
    Bus.publish(:message, message_name, payload)
  end

  defp publish_signal(attrs, context) do
    id = Map.get(attrs, :id)
    {:bpmn_event_definition_signal, def_attrs} = attrs.signalEventDefinition
    signal_name = Map.get(def_attrs, :signalRef, id)
    data = Context.get(context, :data)
    Bus.publish(:signal, signal_name, %{source: id, data: data})
  end

  defp publish_escalation(attrs, context) do
    id = Map.get(attrs, :id)
    {:bpmn_event_definition_escalation, def_attrs} = attrs.escalationEventDefinition
    escalation_code = Map.get(def_attrs, :escalationRef, id)
    data = Context.get(context, :data)
    Bus.publish(:escalation, escalation_code, %{source: id, data: data})
  end

  defp put_correlation(payload, def_attrs, context) do
    case Map.get(def_attrs, :correlationKey) do
      nil ->
        payload

      key ->
        data = Context.get(context, :data)
        Map.put(payload, :correlation, %{key: key, value: Map.get(data, key)})
    end
  end
end
