defmodule Rodar.Event.Boundary do
  @moduledoc """
  Handle passing the token through a boundary event element.

  Boundary events are attached to activities and can be triggered by
  various event types:

  - **Error** — activated directly by the parent activity on error
    (existing pattern in `Rodar.Activity.Subprocess.Embedded`)
  - **Message** — subscribes to the event bus for a matching message
  - **Signal** — subscribes to the event bus for a matching signal
  - **Timer** — schedules a timer callback
  - **Escalation** — subscribes to the event bus for a matching escalation

  ## Examples

      iex> end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow"], outgoing: []}}
      iex> flow = {:bpmn_sequence_flow, %{id: "flow", sourceRef: "b1", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> process = %{"flow" => flow, "end" => end_event}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> elem = {:bpmn_event_boundary, %{id: "b1", outgoing: ["flow"], attachedToRef: "task1", errorEventDefinition: {:bpmn_event_definition_error, %{_elems: []}}, messageEventDefinition: nil, signalEventDefinition: nil, timerEventDefinition: nil, escalationEventDefinition: nil}}
      iex> {:ok, ^context} = Rodar.Event.Boundary.token_in(elem, context)
      iex> true
      true

  """

  alias Rodar.Context
  alias Rodar.Event.Bus
  alias Rodar.Event.Timer

  @doc """
  Receive the token for the element and handle the boundary event.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_event_boundary, %{id: id, outgoing: outgoing} = attrs}, context) do
    dispatch_boundary(detect_type(attrs), id, attrs, outgoing, context)
  end

  defp detect_type(attrs) do
    detect_event_type(attrs) || detect_reactive_type(attrs) || :unknown
  end

  defp detect_event_type(attrs) do
    cond do
      has_error?(attrs) -> :error
      has_message?(attrs) -> :message
      has_signal?(attrs) -> :signal
      has_timer?(attrs) -> :timer
      has_escalation?(attrs) -> :escalation
      true -> nil
    end
  end

  defp detect_reactive_type(attrs) do
    cond do
      has_conditional?(attrs) -> :conditional
      has_cancel?(attrs) -> :cancel
      has_compensate?(attrs) -> :compensate
      true -> nil
    end
  end

  defp dispatch_boundary(:error, _id, _attrs, outgoing, context),
    do: handle_error_boundary(outgoing, context)

  defp dispatch_boundary(:message, id, attrs, outgoing, context),
    do: handle_message_boundary(id, attrs, outgoing, context)

  defp dispatch_boundary(:signal, id, attrs, outgoing, context),
    do: handle_signal_boundary(id, attrs, outgoing, context)

  defp dispatch_boundary(:timer, id, attrs, outgoing, context),
    do: handle_timer_boundary(id, attrs, outgoing, context)

  defp dispatch_boundary(:escalation, id, attrs, outgoing, context),
    do: handle_escalation_boundary(id, attrs, outgoing, context)

  defp dispatch_boundary(:conditional, id, attrs, outgoing, context),
    do: handle_conditional_boundary(id, attrs, outgoing, context)

  defp dispatch_boundary(:cancel, _id, _attrs, outgoing, context),
    do: handle_cancel_boundary(outgoing, context)

  # Compensation boundary events are passive — handler registration
  # happens in Rodar.execute/3 when the attached activity completes
  defp dispatch_boundary(:compensate, _id, _attrs, _outgoing, context),
    do: {:ok, context}

  defp dispatch_boundary(:unknown, id, _attrs, _outgoing, _context),
    do: {:error, "Boundary event '#{id}': unsupported event definition"}

  defp has_error?(attrs) do
    match?({:bpmn_event_definition_error, _}, Map.get(attrs, :errorEventDefinition))
  end

  defp has_message?(attrs) do
    match?({:bpmn_event_definition_message, _}, Map.get(attrs, :messageEventDefinition))
  end

  defp has_signal?(attrs) do
    match?({:bpmn_event_definition_signal, _}, Map.get(attrs, :signalEventDefinition))
  end

  defp has_timer?(attrs) do
    match?({:bpmn_event_definition_timer, _}, Map.get(attrs, :timerEventDefinition))
  end

  defp has_escalation?(attrs) do
    match?({:bpmn_event_definition_escalation, _}, Map.get(attrs, :escalationEventDefinition))
  end

  defp has_conditional?(attrs) do
    match?({:bpmn_event_definition_conditional, _}, Map.get(attrs, :conditionalEventDefinition))
  end

  defp has_cancel?(attrs) do
    match?({:bpmn_event_definition_cancel, _}, Map.get(attrs, :cancelEventDefinition))
  end

  defp has_compensate?(attrs) do
    match?({:bpmn_event_definition_compensate, _}, Map.get(attrs, :compensateEventDefinition))
  end

  # Error boundaries are activated directly by the parent activity
  defp handle_error_boundary(outgoing, context) do
    Rodar.release_token(outgoing, context)
  end

  defp handle_message_boundary(id, attrs, outgoing, context) do
    {:bpmn_event_definition_message, def_attrs} = attrs.messageEventDefinition
    message_name = Map.get(def_attrs, :messageRef, id)

    Context.put_meta(context, id, %{active: true, completed: false, type: :boundary_event})

    metadata = %{context: context, node_id: id, outgoing: outgoing}
    metadata = put_correlation(metadata, def_attrs, context)

    Bus.subscribe(:message, message_name, metadata)

    {:manual, %{id: id, type: :message_boundary, event_name: message_name, context: context}}
  end

  defp handle_signal_boundary(id, attrs, outgoing, context) do
    {:bpmn_event_definition_signal, def_attrs} = attrs.signalEventDefinition
    signal_name = Map.get(def_attrs, :signalRef, id)

    Context.put_meta(context, id, %{active: true, completed: false, type: :boundary_event})

    Bus.subscribe(:signal, signal_name, %{
      context: context,
      node_id: id,
      outgoing: outgoing
    })

    {:manual, %{id: id, type: :signal_boundary, event_name: signal_name, context: context}}
  end

  defp handle_timer_boundary(id, attrs, outgoing, context) do
    {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition

    Context.put_meta(context, id, %{active: true, completed: false, type: :boundary_event})

    if Map.has_key?(def_attrs, :timeCycle) do
      schedule_boundary_cycle(id, def_attrs.timeCycle, outgoing, context)
    else
      schedule_boundary_duration(id, Map.get(def_attrs, :timeDuration), outgoing, context)
    end
  end

  defp schedule_boundary_duration(id, duration, outgoing, context) when is_binary(duration) do
    case Timer.parse_duration(duration) do
      {:ok, ms} ->
        timer_ref = Timer.schedule(ms, context, id, outgoing)

        Context.put_meta(context, id, %{
          active: true,
          completed: false,
          type: :boundary_event,
          timer_ref: timer_ref
        })

        {:manual, %{id: id, type: :timer_boundary, duration_ms: ms, context: context}}

      {:error, reason} ->
        {:error, "Boundary event '#{id}': invalid timer duration — #{reason}"}
    end
  end

  defp schedule_boundary_duration(id, _other, _outgoing, context) do
    {:manual, %{id: id, type: :timer_boundary, context: context}}
  end

  defp schedule_boundary_cycle(id, cycle_expr, outgoing, context) do
    case Timer.parse_cycle(cycle_expr) do
      {:ok, %{repetitions: reps, duration_ms: ms}} ->
        timer_ref = Timer.schedule_cycle(ms, context, id, outgoing, reps)

        Context.put_meta(context, id, %{
          active: true,
          completed: false,
          type: :boundary_event,
          timer_ref: timer_ref
        })

        {:manual,
         %{
           id: id,
           type: :timer_cycle_boundary,
           duration_ms: ms,
           repetitions: reps,
           context: context
         }}

      {:error, reason} ->
        {:error, "Boundary event '#{id}': invalid timer cycle — #{reason}"}
    end
  end

  defp handle_conditional_boundary(id, attrs, outgoing, context) do
    {:bpmn_event_definition_conditional, def_attrs} = attrs.conditionalEventDefinition
    condition = Map.get(def_attrs, :condition)
    language = Map.get(def_attrs, :condition_language, "elixir")

    if is_nil(condition) do
      {:error, "Boundary event '#{id}': conditional event has no condition expression"}
    else
      Context.put_meta(context, id, %{active: true, completed: false, type: :boundary_event})

      Context.subscribe_condition(context, id, condition, %{
        node_id: id,
        outgoing: outgoing,
        context: context,
        condition_language: language
      })

      {:manual, %{id: id, type: :conditional_boundary, condition: condition, context: context}}
    end
  end

  defp put_correlation(metadata, def_attrs, context) do
    case Map.get(def_attrs, :correlationKey) do
      nil ->
        metadata

      key ->
        data = Context.get(context, :data)
        Map.put(metadata, :correlation, %{key: key, value: Map.get(data, key)})
    end
  end

  # Cancel boundaries are activated directly by the transaction subprocess
  defp handle_cancel_boundary(outgoing, context) do
    Rodar.release_token(outgoing, context)
  end

  defp handle_escalation_boundary(id, attrs, outgoing, context) do
    {:bpmn_event_definition_escalation, def_attrs} = attrs.escalationEventDefinition
    escalation_code = Map.get(def_attrs, :escalationRef, id)

    Context.put_meta(context, id, %{active: true, completed: false, type: :boundary_event})

    Bus.subscribe(:escalation, escalation_code, %{
      context: context,
      node_id: id,
      outgoing: outgoing
    })

    {:manual,
     %{id: id, type: :escalation_boundary, event_name: escalation_code, context: context}}
  end
end
