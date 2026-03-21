defmodule Rodar.Event.Intermediate.Throw do
  @moduledoc """
  Handle passing the token through an intermediate throw event element.

  Intermediate throw events emit events (messages, signals, escalations) to the
  event bus and then release the token to outgoing flows. Events without a
  specific definition (none) pass through immediately.

  Link throw events act as intra-process GOTOs. When a link throw event fires,
  it scans the process map for a matching link catch event (by link name) and
  releases the token to the catch event's outgoing flows, effectively jumping
  to the catch location.

  ## Examples

      iex> end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
      iex> flow_out = {:bpmn_sequence_flow, %{id: "flow_out", sourceRef: "throw1", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> process = %{"flow_out" => flow_out, "end" => end_event}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> elem = {:bpmn_event_intermediate_throw, %{id: "throw1", outgoing: ["flow_out"], messageEventDefinition: nil, signalEventDefinition: nil, escalationEventDefinition: nil}}
      iex> {:ok, ^context} = Rodar.Event.Intermediate.Throw.token_in(elem, context)
      iex> true
      true

  """

  alias Rodar.Compensation
  alias Rodar.Context
  alias Rodar.Event.Bus

  @doc """
  Receive the token for the element and handle the throw event.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_event_intermediate_throw, %{id: id, outgoing: outgoing} = attrs}, context) do
    cond do
      has_message?(attrs) ->
        publish_message(id, attrs, context)
        Rodar.release_token(outgoing, context)

      has_signal?(attrs) ->
        publish_signal(id, attrs, context)
        Rodar.release_token(outgoing, context)

      has_escalation?(attrs) ->
        publish_escalation(id, attrs, context)
        Rodar.release_token(outgoing, context)

      has_link?(attrs) ->
        handle_link(id, attrs, context)

      has_compensate?(attrs) ->
        handle_compensate(attrs, outgoing, context)

      true ->
        # None — pass through
        Rodar.release_token(outgoing, context)
    end
  end

  defp has_message?(attrs) do
    match?({:bpmn_event_definition_message, _}, Map.get(attrs, :messageEventDefinition))
  end

  defp has_signal?(attrs) do
    match?({:bpmn_event_definition_signal, _}, Map.get(attrs, :signalEventDefinition))
  end

  defp has_escalation?(attrs) do
    match?({:bpmn_event_definition_escalation, _}, Map.get(attrs, :escalationEventDefinition))
  end

  defp publish_message(id, attrs, context) do
    {:bpmn_event_definition_message, def_attrs} = attrs.messageEventDefinition
    message_name = Map.get(def_attrs, :messageRef, id)
    data = Context.get(context, :data)
    payload = %{source: id, data: data}
    payload = put_correlation(payload, def_attrs, context)
    Bus.publish(:message, message_name, payload)
  end

  defp publish_signal(id, attrs, context) do
    {:bpmn_event_definition_signal, def_attrs} = attrs.signalEventDefinition
    signal_name = Map.get(def_attrs, :signalRef, id)
    data = Context.get(context, :data)
    Bus.publish(:signal, signal_name, %{source: id, data: data})
  end

  defp has_link?(attrs) do
    match?({:bpmn_event_definition_link, _}, Map.get(attrs, :linkEventDefinition))
  end

  defp has_compensate?(attrs) do
    match?({:bpmn_event_definition_compensate, _}, Map.get(attrs, :compensateEventDefinition))
  end

  defp handle_link(id, attrs, context) do
    {:bpmn_event_definition_link, def_attrs} = attrs.linkEventDefinition
    link_name = Map.get(def_attrs, :name, "")
    process = Context.get(context, :process)

    case find_link_catch(process, link_name) do
      {:ok, catch_outgoing} ->
        Rodar.release_token(catch_outgoing, context)

      :error ->
        {:error, "Link throw '#{id}': no matching link catch event with name '#{link_name}'"}
    end
  end

  defp find_link_catch(process, link_name) when is_map(process) do
    Enum.find_value(process, :error, fn
      {_id,
       {:bpmn_event_intermediate_catch,
        %{linkEventDefinition: {:bpmn_event_definition_link, %{name: ^link_name}}} = catch_attrs}} ->
        {:ok, Map.get(catch_attrs, :outgoing, [])}

      _ ->
        nil
    end)
  end

  defp handle_compensate(attrs, outgoing, context) do
    {:bpmn_event_definition_compensate, def_attrs} = attrs.compensateEventDefinition
    activity_ref = Map.get(def_attrs, :activityRef)
    wait = Map.get(def_attrs, :waitForCompletion, "true")

    run_compensation = fn ->
      if activity_ref do
        Compensation.compensate_activity(context, to_string(activity_ref))
      else
        Compensation.compensate_all(context)
      end
    end

    if wait == "false" do
      spawn(run_compensation)
      Rodar.release_token(outgoing, context)
    else
      run_compensation.()
      Rodar.release_token(outgoing, context)
    end
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

  defp publish_escalation(id, attrs, context) do
    {:bpmn_event_definition_escalation, def_attrs} = attrs.escalationEventDefinition
    escalation_code = Map.get(def_attrs, :escalationRef, id)
    data = Context.get(context, :data)
    Bus.publish(:escalation, escalation_code, %{source: id, data: data})
  end
end
