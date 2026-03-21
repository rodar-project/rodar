defmodule Rodar.Event.Boundary.NonInterruptingTest do
  use ExUnit.Case, async: true

  alias Rodar.{Context, Engine.Diagram, Engine.Diagram.Export, Event.Boundary, Event.Timer}

  defp make_process do
    end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow"], outgoing: []}}

    flow =
      {:bpmn_sequence_flow,
       %{
         id: "flow",
         sourceRef: "b1",
         targetRef: "end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    %{"flow" => flow, "end" => end_event}
  end

  defp make_boundary_elem(id, event_def_key, event_def_value, cancel_activity) do
    base = %{
      id: id,
      outgoing: ["flow"],
      attachedToRef: "task1",
      cancelActivity: cancel_activity,
      errorEventDefinition: nil,
      messageEventDefinition: nil,
      signalEventDefinition: nil,
      timerEventDefinition: nil,
      escalationEventDefinition: nil,
      conditionalEventDefinition: nil,
      compensateEventDefinition: nil
    }

    {:bpmn_event_boundary, Map.put(base, event_def_key, event_def_value)}
  end

  describe "non-interrupting timer boundary event" do
    test "stores cancel_activity: false in metadata" do
      {:ok, context} = Context.start_link(make_process(), %{})

      elem =
        make_boundary_elem(
          "b1",
          :timerEventDefinition,
          {:bpmn_event_definition_timer, %{timeDuration: "PT10S"}},
          false
        )

      assert {:manual, task_data} = Boundary.token_in(elem, context)
      assert task_data.type == :timer_boundary

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
      assert meta.active == true

      Timer.cancel(meta.timer_ref)
    end

    test "timer_fired does not mark non-interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      # Pre-set boundary metadata as non-interrupting
      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: false
      })

      Context.put_meta(context, "task1", %{active: true, completed: false, type: :user_task})

      # Simulate timer firing by sending the message directly to context
      send(context, {:timer_fired, "b1", ["flow"]})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      # Non-interrupting: boundary stays active
      assert meta.cancel_activity == false
      assert meta.active == true
      assert meta.completed == false

      # Parent activity remains active
      parent_meta = Context.get_meta(context, "task1")
      assert parent_meta.active == true
      assert parent_meta.completed == false
    end

    test "timer_fired marks interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: true
      })

      send(context, {:timer_fired, "b1", ["flow"]})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.active == false
      assert meta.completed == true
    end
  end

  describe "non-interrupting message boundary event" do
    test "stores cancel_activity: false in metadata" do
      {:ok, context} = Context.start_link(make_process(), %{})
      msg_name = "ni_msg_#{:erlang.unique_integer([:positive])}"

      elem =
        make_boundary_elem(
          "b1",
          :messageEventDefinition,
          {:bpmn_event_definition_message, %{messageRef: msg_name}},
          false
        )

      assert {:manual, task_data} = Boundary.token_in(elem, context)
      assert task_data.type == :message_boundary

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
    end

    test "bpmn_event does not mark non-interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: false
      })

      Context.put_meta(context, "task1", %{active: true, completed: false, type: :user_task})

      metadata = %{node_id: "b1", outgoing: ["flow"], context: context}
      send(context, {:bpmn_event, :message, "test_msg", %{}, metadata})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
      assert meta.active == true

      parent_meta = Context.get_meta(context, "task1")
      assert parent_meta.active == true
    end

    test "bpmn_event marks interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: true
      })

      metadata = %{node_id: "b1", outgoing: ["flow"], context: context}
      send(context, {:bpmn_event, :message, "test_msg", %{}, metadata})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.active == false
      assert meta.completed == true
    end
  end

  describe "non-interrupting signal boundary event" do
    test "stores cancel_activity: false in metadata" do
      {:ok, context} = Context.start_link(make_process(), %{})
      sig_name = "ni_sig_#{:erlang.unique_integer([:positive])}"

      elem =
        make_boundary_elem(
          "b1",
          :signalEventDefinition,
          {:bpmn_event_definition_signal, %{signalRef: sig_name}},
          false
        )

      assert {:manual, task_data} = Boundary.token_in(elem, context)
      assert task_data.type == :signal_boundary

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
    end

    test "signal bpmn_event does not mark non-interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: false
      })

      Context.put_meta(context, "task1", %{active: true, completed: false, type: :user_task})

      metadata = %{node_id: "b1", outgoing: ["flow"], context: context}
      send(context, {:bpmn_event, :signal, "test_sig", %{}, metadata})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
      assert meta.active == true

      parent_meta = Context.get_meta(context, "task1")
      assert parent_meta.active == true
    end
  end

  describe "non-interrupting conditional boundary event" do
    test "stores cancel_activity: false in metadata" do
      {:ok, context} = Context.start_link(make_process(), %{})

      elem =
        make_boundary_elem(
          "b1",
          :conditionalEventDefinition,
          {:bpmn_event_definition_conditional,
           %{condition: "data[\"ready\"] == true", condition_language: "elixir"}},
          false
        )

      assert {:manual, task_data} = Boundary.token_in(elem, context)
      assert task_data.type == :conditional_boundary

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
    end

    test "condition_met does not mark non-interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: false
      })

      Context.put_meta(context, "task1", %{active: true, completed: false, type: :user_task})

      send(context, {:condition_met, "b1", ["flow"]})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == false
      assert meta.active == true

      parent_meta = Context.get_meta(context, "task1")
      assert parent_meta.active == true
    end

    test "condition_met marks interrupting boundary as completed" do
      {:ok, context} = Context.start_link(make_process(), %{})

      Context.put_meta(context, "b1", %{
        active: true,
        completed: false,
        type: :boundary_event,
        cancel_activity: true
      })

      send(context, {:condition_met, "b1", ["flow"]})
      Process.sleep(50)

      meta = Context.get_meta(context, "b1")
      assert meta.active == false
      assert meta.completed == true
    end
  end

  describe "cancelActivity defaults" do
    test "defaults to true (interrupting) when cancelActivity not set" do
      {:ok, context} = Context.start_link(make_process(), %{})
      msg_name = "default_msg_#{:erlang.unique_integer([:positive])}"

      elem =
        {:bpmn_event_boundary,
         %{
           id: "b1",
           outgoing: ["flow"],
           attachedToRef: "task1",
           errorEventDefinition: nil,
           messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: msg_name}},
           signalEventDefinition: nil,
           timerEventDefinition: nil,
           escalationEventDefinition: nil
         }}

      assert {:manual, _} = Boundary.token_in(elem, context)

      meta = Context.get_meta(context, "b1")
      assert meta.cancel_activity == true
    end
  end

  describe "parser integration" do
    test "parses cancelActivity='false' as boolean false" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:userTask id="Task_1" name="Do Work">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="false">
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition id="Timer_1">
              <bpmn:timeDuration>PT5M</bpmn:timeDuration>
            </bpmn:timerEventDefinition>
          </bpmn:boundaryEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_boundary, attrs} = elements["Boundary_1"]
      assert attrs.cancelActivity == false
    end

    test "parses cancelActivity='true' as boolean true" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:userTask id="Task_1" name="Do Work">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="true">
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition id="Timer_1" />
          </bpmn:boundaryEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_boundary, attrs} = elements["Boundary_1"]
      assert attrs.cancelActivity == true
    end

    test "defaults cancelActivity to true when attribute missing" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:userTask id="Task_1" name="Do Work">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1">
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition id="Timer_1" />
          </bpmn:boundaryEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_boundary, attrs} = elements["Boundary_1"]
      assert attrs.cancelActivity == true
    end

    test "export round-trips cancelActivity boolean" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:userTask id="Task_1" name="Do Work">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="false">
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition id="Timer_1">
              <bpmn:timeDuration>PT5M</bpmn:timeDuration>
            </bpmn:timerEventDefinition>
          </bpmn:boundaryEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      exported = Export.to_xml(diagram)
      assert exported =~ ~s(cancelActivity="false")
    end
  end
end
