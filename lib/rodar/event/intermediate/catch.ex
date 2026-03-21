defmodule Rodar.Event.Intermediate.Catch do
  @moduledoc """
  Handle passing the token through an intermediate catch event element.

  Intermediate catch events pause execution and subscribe to the event bus,
  waiting for a matching event (message, signal, or timer) before releasing
  the token to outgoing flows.

  Link catch events are passive targets — they are jumped to by a matching
  link throw event. When reached via normal token flow (not from a throw),
  they simply release the token to their outgoing flows.

  ## Examples

      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> elem = {:bpmn_event_intermediate_catch, %{id: "catch1", outgoing: ["flow_out"], messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: "msg1"}}, signalEventDefinition: nil, timerEventDefinition: nil}}
      iex> {:manual, task_data} = Rodar.Event.Intermediate.Catch.token_in(elem, context)
      iex> task_data.id
      "catch1"

  """

  alias Rodar.Context
  alias Rodar.Event.Bus
  alias Rodar.Event.Timer
  alias Rodar.Expression.Feel
  alias Rodar.Expression.Sandbox

  @doc """
  Receive the token for the element and handle the catch event.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_event_intermediate_catch, %{id: id, outgoing: outgoing} = attrs}, context) do
    cond do
      has_message?(attrs) ->
        subscribe_message(id, attrs, outgoing, context)

      has_signal?(attrs) ->
        subscribe_signal(id, attrs, outgoing, context)

      has_timer?(attrs) ->
        handle_timer(id, attrs, outgoing, context)

      has_conditional?(attrs) ->
        handle_conditional(id, attrs, outgoing, context)

      has_link?(attrs) ->
        # Link catches are passive — just pass through on normal token flow
        Rodar.release_token(outgoing, context)

      true ->
        {:error, "Catch event '#{id}': unsupported event definition"}
    end
  end

  @doc """
  Resume execution of a paused catch event with the provided data.
  """
  @spec resume(Rodar.element(), Rodar.context(), map()) :: Rodar.result()
  def resume({:bpmn_event_intermediate_catch, %{id: id, outgoing: outgoing}}, context, input)
      when is_map(input) do
    Enum.each(input, fn {key, value} ->
      Context.put_data(context, key, value)
    end)

    Context.put_meta(context, id, %{active: false, completed: true, type: :catch_event})
    Rodar.release_token(outgoing, context)
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

  defp has_conditional?(attrs) do
    match?({:bpmn_event_definition_conditional, _}, Map.get(attrs, :conditionalEventDefinition))
  end

  defp has_link?(attrs) do
    match?({:bpmn_event_definition_link, _}, Map.get(attrs, :linkEventDefinition))
  end

  defp subscribe_message(id, attrs, outgoing, context) do
    {:bpmn_event_definition_message, def_attrs} = attrs.messageEventDefinition
    message_name = Map.get(def_attrs, :messageRef, id)

    Context.put_meta(context, id, %{active: true, completed: false, type: :catch_event})

    metadata = %{context: context, node_id: id, outgoing: outgoing}
    metadata = put_correlation(metadata, def_attrs, context)

    Bus.subscribe(:message, message_name, metadata)

    {:manual,
     %{
       id: id,
       type: :message_catch,
       event_name: message_name,
       outgoing: outgoing,
       context: context
     }}
  end

  defp subscribe_signal(id, attrs, outgoing, context) do
    {:bpmn_event_definition_signal, def_attrs} = attrs.signalEventDefinition
    signal_name = Map.get(def_attrs, :signalRef, id)

    Context.put_meta(context, id, %{active: true, completed: false, type: :catch_event})

    Bus.subscribe(:signal, signal_name, %{
      context: context,
      node_id: id,
      outgoing: outgoing
    })

    {:manual,
     %{id: id, type: :signal_catch, event_name: signal_name, outgoing: outgoing, context: context}}
  end

  defp handle_timer(id, attrs, outgoing, context) do
    {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition

    Context.put_meta(context, id, %{active: true, completed: false, type: :catch_event})

    cond do
      Map.has_key?(def_attrs, :timeCycle) ->
        schedule_cycle_timer(id, def_attrs.timeCycle, outgoing, context)

      Map.has_key?(def_attrs, :timeDuration) ->
        schedule_duration_timer(id, def_attrs.timeDuration, outgoing, context)

      true ->
        {:manual, %{id: id, type: :timer_catch, outgoing: outgoing, context: context}}
    end
  end

  defp schedule_duration_timer(id, nil, outgoing, context) do
    {:manual, %{id: id, type: :timer_catch, outgoing: outgoing, context: context}}
  end

  defp schedule_duration_timer(id, duration, outgoing, context) when is_binary(duration) do
    case Timer.parse_duration(duration) do
      {:ok, ms} ->
        timer_ref = Timer.schedule(ms, context, id, outgoing)

        Context.put_meta(context, id, %{
          active: true,
          completed: false,
          type: :catch_event,
          timer_ref: timer_ref
        })

        {:manual,
         %{id: id, type: :timer_catch, duration_ms: ms, outgoing: outgoing, context: context}}

      {:error, reason} ->
        {:error, "Catch event '#{id}': invalid timer duration — #{reason}"}
    end
  end

  defp schedule_duration_timer(id, _other, outgoing, context) do
    {:manual, %{id: id, type: :timer_catch, outgoing: outgoing, context: context}}
  end

  defp handle_conditional(id, attrs, outgoing, context) do
    {:bpmn_event_definition_conditional, def_attrs} = attrs.conditionalEventDefinition
    condition = Map.get(def_attrs, :condition)
    language = Map.get(def_attrs, :condition_language, "elixir")

    if is_nil(condition) do
      {:error, "Catch event '#{id}': conditional event has no condition expression"}
    else
      handle_conditional_expr(id, condition, language, outgoing, context)
    end
  end

  defp handle_conditional_expr(id, condition, language, outgoing, context) do
    result = eval_condition(language, condition, context)

    case result do
      {:ok, true} ->
        Context.put_meta(context, id, %{active: false, completed: true, type: :catch_event})
        Rodar.release_token(outgoing, context)

      _ ->
        Context.put_meta(context, id, %{active: true, completed: false, type: :catch_event})

        Context.subscribe_condition(context, id, condition, %{
          node_id: id,
          outgoing: outgoing,
          context: context,
          condition_language: language
        })

        {:manual,
         %{
           id: id,
           type: :conditional_catch,
           condition: condition,
           outgoing: outgoing,
           context: context
         }}
    end
  end

  defp eval_condition("feel", condition, context) do
    data = Context.get(context, :data)
    Feel.eval(condition, data)
  end

  defp eval_condition(_lang, condition, context) do
    data = Context.get(context, :data)
    Sandbox.eval(condition, %{"data" => data})
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

  defp schedule_cycle_timer(id, cycle_expr, outgoing, context) do
    case Timer.parse_cycle(cycle_expr) do
      {:ok, %{repetitions: reps, duration_ms: ms}} ->
        timer_ref = Timer.schedule_cycle(ms, context, id, outgoing, reps)

        Context.put_meta(context, id, %{
          active: true,
          completed: false,
          type: :catch_event,
          timer_ref: timer_ref
        })

        {:manual,
         %{
           id: id,
           type: :timer_cycle_catch,
           duration_ms: ms,
           repetitions: reps,
           outgoing: outgoing,
           context: context
         }}

      {:error, reason} ->
        {:error, "Catch event '#{id}': invalid timer cycle — #{reason}"}
    end
  end
end
