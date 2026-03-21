defmodule Rodar.Activity.Subprocess.Event do
  @moduledoc """
  Handle event subprocess elements.

  An event subprocess lives inside a parent process scope but only activates
  when its start event triggers. It has no incoming or outgoing sequence flows
  from the parent process -- it is triggered entirely by its start event
  definition (message, signal, timer, error, escalation, or conditional).

  ## Interrupting vs Non-interrupting

  - **Interrupting** (`isInterrupting: true`, the default): When the start event
    fires, the parent scope is cancelled and the subprocess executes exclusively.
  - **Non-interrupting** (`isInterrupting: false`): The subprocess executes in
    parallel with the parent scope. It can fire multiple times.

  ## Registration

  Event subprocesses are registered when the parent process starts execution.
  The `register/2` function scans for event subprocess elements and subscribes
  their start events to the event bus, timer scheduler, or conditional
  evaluation system.

  ## Execution

  When a start event trigger fires, `activate/3` swaps the context to the
  subprocess elements and executes from the start event. For interrupting
  subprocesses, the parent scope is not resumed. For non-interrupting ones,
  execution happens in a spawned process with shared context.

  ## Examples

      iex> sub_start = {:bpmn_event_start, %{id: "ev_start", incoming: [], outgoing: ["sf1"],
      ...>   messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: "order_msg"}},
      ...>   signalEventDefinition: nil, timerEventDefinition: nil, errorEventDefinition: nil,
      ...>   escalationEventDefinition: nil, conditionalEventDefinition: nil,
      ...>   compensateEventDefinition: nil, terminateEventDefinition: nil}}
      iex> sub_end = {:bpmn_event_end, %{id: "ev_end", incoming: ["sf1"], outgoing: []}}
      iex> sf1 = {:bpmn_sequence_flow, %{id: "sf1", sourceRef: "ev_start", targetRef: "ev_end", conditionExpression: nil, isImmediate: nil}}
      iex> elements = %{"ev_start" => sub_start, "ev_end" => sub_end, "sf1" => sf1}
      iex> event_sub = {:bpmn_activity_subprocess_event, %{id: "event_sub", incoming: [], outgoing: [], elements: elements}}
      iex> parent_end = {:bpmn_event_end, %{id: "end", incoming: ["f1"], outgoing: []}}
      iex> f1 = {:bpmn_sequence_flow, %{id: "f1", sourceRef: "start", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> process = %{"start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}}, "f1" => f1, "end" => parent_end, "event_sub" => event_sub}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> subs = Rodar.Activity.Subprocess.Event.register(process, context)
      iex> is_list(subs)
      true

  """

  alias Rodar.Context
  alias Rodar.Event.Timer

  @doc """
  Scan a process definition for event subprocess elements and register their
  start event triggers.

  Returns a list of registration metadata maps for each subscription created.
  """
  @spec register(map(), pid()) :: [map()]
  def register(process, context) do
    process
    |> Enum.flat_map(fn
      {_id, {:bpmn_activity_subprocess_event, attrs}} ->
        register_event_subprocess(attrs, context)

      _ ->
        []
    end)
  end

  @doc """
  Receive the token for the event subprocess element.

  Event subprocesses have no incoming sequence flows in normal execution flow.
  They are activated by their start event trigger, not by token arrival.
  This function is a no-op that returns `{:ok, context}`.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_activity_subprocess_event, _attrs}, context) do
    {:ok, context}
  end

  @doc """
  Activate the event subprocess when its start event fires.

  For interrupting subprocesses, swaps the parent context process to the
  subprocess elements and executes. For non-interrupting, spawns a parallel
  execution.
  """
  @spec activate(map(), pid(), map()) :: Rodar.result()
  def activate(attrs, context, _payload \\ %{}) do
    %{id: id, elements: elements} = attrs

    is_interrupting = interrupting?(attrs)

    Context.put_meta(context, id, %{
      active: true,
      completed: false,
      type: :event_subprocess,
      interrupting: is_interrupting
    })

    if is_interrupting do
      execute_interrupting(id, elements, context)
    else
      execute_non_interrupting(id, elements, context)
    end
  end

  # --- Private ---

  defp register_event_subprocess(attrs, context) do
    %{elements: elements} = attrs

    case find_start_event(elements) do
      nil ->
        []

      {:bpmn_event_start, start_attrs} ->
        register_start_trigger(start_attrs, attrs, context)
    end
  end

  defp register_start_trigger(start_attrs, subprocess_attrs, context) do
    subprocess_id = subprocess_attrs.id
    is_interrupting = interrupting_start?(start_attrs)

    cond do
      has_message?(start_attrs) ->
        register_message(subprocess_id, start_attrs, subprocess_attrs, is_interrupting, context)

      has_signal?(start_attrs) ->
        register_signal(subprocess_id, start_attrs, subprocess_attrs, is_interrupting, context)

      has_timer?(start_attrs) ->
        register_timer(subprocess_id, start_attrs, subprocess_attrs, is_interrupting, context)

      has_error?(start_attrs) ->
        register_error(subprocess_id, subprocess_attrs, is_interrupting, context)

      has_escalation?(start_attrs) ->
        register_escalation(
          subprocess_id,
          start_attrs,
          subprocess_attrs,
          is_interrupting,
          context
        )

      has_conditional?(start_attrs) ->
        register_conditional(
          subprocess_id,
          start_attrs,
          subprocess_attrs,
          is_interrupting,
          context
        )

      true ->
        []
    end
  end

  defp register_message(subprocess_id, start_attrs, subprocess_attrs, interrupting, context) do
    {:bpmn_event_definition_message, def_attrs} = start_attrs.messageEventDefinition
    message_name = Map.get(def_attrs, :messageRef, subprocess_id)

    metadata = %{
      context: context,
      node_id: subprocess_id,
      subprocess_attrs: subprocess_attrs,
      interrupting: interrupting,
      type: :event_subprocess
    }

    Context.subscribe_event(context, :message, message_name, metadata)

    [%{subprocess_id: subprocess_id, event_type: :message, event_name: message_name}]
  end

  defp register_signal(subprocess_id, start_attrs, subprocess_attrs, interrupting, context) do
    {:bpmn_event_definition_signal, def_attrs} = start_attrs.signalEventDefinition
    signal_name = Map.get(def_attrs, :signalRef, subprocess_id)

    metadata = %{
      context: context,
      node_id: subprocess_id,
      subprocess_attrs: subprocess_attrs,
      interrupting: interrupting,
      type: :event_subprocess
    }

    Context.subscribe_event(context, :signal, signal_name, metadata)

    [%{subprocess_id: subprocess_id, event_type: :signal, event_name: signal_name}]
  end

  defp register_timer(subprocess_id, start_attrs, subprocess_attrs, interrupting, context) do
    {:bpmn_event_definition_timer, def_attrs} = start_attrs.timerEventDefinition

    metadata = %{
      subprocess_attrs: subprocess_attrs,
      interrupting: interrupting
    }

    cond do
      Map.has_key?(def_attrs, :timeDuration) ->
        case Timer.parse_duration(def_attrs.timeDuration) do
          {:ok, ms} ->
            schedule_timer_activation(ms, subprocess_id, subprocess_attrs, interrupting, context)

            [%{subprocess_id: subprocess_id, event_type: :timer, duration_ms: ms}]

          {:error, _} ->
            []
        end

      Map.has_key?(def_attrs, :timeCycle) ->
        case Timer.parse_cycle(def_attrs.timeCycle) do
          {:ok, %{repetitions: reps, duration_ms: ms}} ->
            schedule_cycle_activation(
              ms,
              subprocess_id,
              subprocess_attrs,
              interrupting,
              context,
              reps
            )

            [
              %{
                subprocess_id: subprocess_id,
                event_type: :timer_cycle,
                duration_ms: ms,
                repetitions: reps
              }
            ]

          {:error, _} ->
            []
        end

      true ->
        _ = metadata
        []
    end
  end

  defp register_error(subprocess_id, subprocess_attrs, interrupting, context) do
    Context.put_meta(context, {:event_subprocess_error, subprocess_id}, %{
      subprocess_attrs: subprocess_attrs,
      interrupting: interrupting
    })

    [%{subprocess_id: subprocess_id, event_type: :error}]
  end

  defp register_escalation(subprocess_id, start_attrs, subprocess_attrs, interrupting, context) do
    {:bpmn_event_definition_escalation, def_attrs} = start_attrs.escalationEventDefinition
    escalation_code = Map.get(def_attrs, :escalationRef, subprocess_id)

    metadata = %{
      context: context,
      node_id: subprocess_id,
      subprocess_attrs: subprocess_attrs,
      interrupting: interrupting,
      type: :event_subprocess
    }

    Context.subscribe_event(context, :escalation, escalation_code, metadata)

    [%{subprocess_id: subprocess_id, event_type: :escalation, event_name: escalation_code}]
  end

  defp register_conditional(subprocess_id, start_attrs, subprocess_attrs, interrupting, context) do
    {:bpmn_event_definition_conditional, def_attrs} = start_attrs.conditionalEventDefinition
    condition = Map.get(def_attrs, :condition)

    if is_nil(condition) do
      []
    else
      language = Map.get(def_attrs, :condition_language, "elixir")

      sub_id = "event_subprocess:#{subprocess_id}"

      Context.subscribe_condition(context, sub_id, condition, %{
        node_id: subprocess_id,
        subprocess_attrs: subprocess_attrs,
        interrupting: interrupting,
        context: context,
        condition_language: language,
        type: :event_subprocess
      })

      [%{subprocess_id: subprocess_id, event_type: :conditional, condition: condition}]
    end
  end

  defp schedule_timer_activation(ms, subprocess_id, subprocess_attrs, interrupting, context) do
    Process.send_after(
      context,
      {:event_subprocess_timer, subprocess_id, subprocess_attrs, interrupting},
      ms
    )
  end

  defp schedule_cycle_activation(ms, subprocess_id, subprocess_attrs, interrupting, context, reps) do
    Process.send_after(
      context,
      {:event_subprocess_timer_cycle, subprocess_id, subprocess_attrs, interrupting, reps, ms},
      ms
    )
  end

  defp execute_interrupting(id, elements, context) do
    old_process = Context.swap_process(context, elements)

    result =
      case find_start_event(elements) do
        nil ->
          {:error, "Event subprocess '#{id}': no start event found"}

        start_event ->
          Rodar.execute(start_event, context)
      end

    Context.swap_process(context, old_process)

    case result do
      {:ok, _} ->
        Context.put_meta(context, id, %{
          active: false,
          completed: true,
          type: :event_subprocess,
          interrupting: true
        })

        {:ok, context}

      other ->
        other
    end
  end

  defp execute_non_interrupting(id, elements, context) do
    spawn(fn ->
      old_process = Context.swap_process(context, elements)

      result =
        case find_start_event(elements) do
          nil ->
            {:error, "Event subprocess '#{id}': no start event found"}

          start_event ->
            Rodar.execute(start_event, context)
        end

      Context.swap_process(context, old_process)

      case result do
        {:ok, _} ->
          Context.put_meta(context, id, %{
            active: false,
            completed: true,
            type: :event_subprocess,
            interrupting: false
          })

        _ ->
          :ok
      end
    end)

    {:ok, context}
  end

  defp find_start_event(elements) do
    Enum.find_value(elements, fn
      {_id, {:bpmn_event_start, _} = elem} -> elem
      _ -> nil
    end)
  end

  defp interrupting?(attrs) do
    elements = Map.get(attrs, :elements, %{})

    case find_start_event(elements) do
      {:bpmn_event_start, start_attrs} -> interrupting_start?(start_attrs)
      nil -> true
    end
  end

  defp interrupting_start?(start_attrs) do
    case Map.get(start_attrs, :isInterrupting) do
      "false" -> false
      _ -> true
    end
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

  defp has_error?(attrs) do
    match?({:bpmn_event_definition_error, _}, Map.get(attrs, :errorEventDefinition))
  end

  defp has_escalation?(attrs) do
    match?({:bpmn_event_definition_escalation, _}, Map.get(attrs, :escalationEventDefinition))
  end

  defp has_conditional?(attrs) do
    match?(
      {:bpmn_event_definition_conditional, _},
      Map.get(attrs, :conditionalEventDefinition)
    )
  end
end
