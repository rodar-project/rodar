defmodule Rodar.Activity.Subprocess.EventTest do
  use ExUnit.Case, async: true

  alias Rodar.Activity.Subprocess.Event, as: SubprocessEvent
  alias Rodar.Context
  alias Rodar.Engine.Diagram
  alias Rodar.Engine.Diagram.Export
  alias Rodar.Event.Bus

  doctest Rodar.Activity.Subprocess.Event

  defp seq_flow(id, source, target) do
    {:bpmn_sequence_flow,
     %{
       id: id,
       sourceRef: source,
       targetRef: target,
       conditionExpression: nil,
       isImmediate: nil
     }}
  end

  defp build_event_subprocess_elements(opts \\ []) do
    message_ref = Keyword.get(opts, :message_ref, "test_message")
    is_interrupting = Keyword.get(opts, :is_interrupting, "true")

    start =
      {:bpmn_event_start,
       %{
         id: "ev_start",
         incoming: [],
         outgoing: ["esf1"],
         isInterrupting: is_interrupting,
         messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: message_ref}},
         signalEventDefinition: nil,
         timerEventDefinition: nil,
         errorEventDefinition: nil,
         escalationEventDefinition: nil,
         conditionalEventDefinition: nil,
         compensateEventDefinition: nil,
         terminateEventDefinition: nil
       }}

    sub_end = {:bpmn_event_end, %{id: "ev_end", incoming: ["esf1"], outgoing: []}}
    flow = seq_flow("esf1", "ev_start", "ev_end")

    %{"ev_start" => start, "ev_end" => sub_end, "esf1" => flow}
  end

  defp build_process_with_event_subprocess(opts \\ []) do
    message_ref = Keyword.get(opts, :message_ref, "test_message")
    is_interrupting = Keyword.get(opts, :is_interrupting, "true")

    elements =
      build_event_subprocess_elements(
        message_ref: message_ref,
        is_interrupting: is_interrupting
      )

    parent_start =
      {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}}

    user_task =
      {:bpmn_activity_task_user, %{id: "user_task", incoming: ["f1"], outgoing: ["f2"]}}

    parent_end = {:bpmn_event_end, %{id: "end", incoming: ["f2"], outgoing: []}}

    event_sub =
      {:bpmn_activity_subprocess_event,
       %{
         id: "event_sub",
         incoming: [],
         outgoing: [],
         elements: elements
       }}

    %{
      "start" => parent_start,
      "f1" => seq_flow("f1", "start", "user_task"),
      "user_task" => user_task,
      "f2" => seq_flow("f2", "user_task", "end"),
      "end" => parent_end,
      "event_sub" => event_sub
    }
  end

  describe "register/2" do
    test "registers message event subprocess start event" do
      process = build_process_with_event_subprocess()
      {:ok, context} = Context.start_link(process, %{})

      subs = SubprocessEvent.register(process, context)

      assert length(subs) == 1
      assert hd(subs).subprocess_id == "event_sub"
      assert hd(subs).event_type == :message
      assert hd(subs).event_name == "test_message"
    end

    test "registers signal event subprocess" do
      signal_start =
        {:bpmn_event_start,
         %{
           id: "ev_start",
           incoming: [],
           outgoing: ["esf1"],
           isInterrupting: "true",
           messageEventDefinition: nil,
           signalEventDefinition: {:bpmn_event_definition_signal, %{signalRef: "test_signal"}},
           timerEventDefinition: nil,
           errorEventDefinition: nil,
           escalationEventDefinition: nil,
           conditionalEventDefinition: nil,
           compensateEventDefinition: nil,
           terminateEventDefinition: nil
         }}

      sub_end = {:bpmn_event_end, %{id: "ev_end", incoming: ["esf1"], outgoing: []}}

      elements = %{
        "ev_start" => signal_start,
        "ev_end" => sub_end,
        "esf1" => seq_flow("esf1", "ev_start", "ev_end")
      }

      event_sub =
        {:bpmn_activity_subprocess_event,
         %{id: "event_sub", incoming: [], outgoing: [], elements: elements}}

      process = %{
        "start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: []}},
        "event_sub" => event_sub
      }

      {:ok, context} = Context.start_link(process, %{})
      subs = SubprocessEvent.register(process, context)

      assert length(subs) == 1
      assert hd(subs).event_type == :signal
      assert hd(subs).event_name == "test_signal"
    end

    test "returns empty list when no event subprocesses exist" do
      process = %{
        "start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: []}}
      }

      {:ok, context} = Context.start_link(process, %{})
      assert SubprocessEvent.register(process, context) == []
    end
  end

  describe "token_in/2" do
    test "event subprocess token_in is a no-op" do
      elements = build_event_subprocess_elements()

      event_sub =
        {:bpmn_activity_subprocess_event,
         %{id: "event_sub", incoming: [], outgoing: [], elements: elements}}

      {:ok, context} = Context.start_link(%{}, %{})
      assert {:ok, ^context} = SubprocessEvent.token_in(event_sub, context)
    end
  end

  describe "activate/3" do
    test "interrupting event subprocess executes and completes" do
      elements = build_event_subprocess_elements()

      attrs = %{
        id: "event_sub",
        incoming: [],
        outgoing: [],
        elements: elements
      }

      process = build_process_with_event_subprocess()
      {:ok, context} = Context.start_link(process, %{})

      result = SubprocessEvent.activate(attrs, context)

      assert {:ok, ^context} = result

      meta = Context.get_meta(context, "event_sub")
      assert meta.active == false
      assert meta.completed == true
      assert meta.type == :event_subprocess
      assert meta.interrupting == true
    end

    test "non-interrupting event subprocess runs in parallel" do
      elements = build_event_subprocess_elements(is_interrupting: "false")

      attrs = %{
        id: "event_sub",
        incoming: [],
        outgoing: [],
        elements: elements
      }

      process = build_process_with_event_subprocess(is_interrupting: "false")
      {:ok, context} = Context.start_link(process, %{})

      result = SubprocessEvent.activate(attrs, context)
      assert {:ok, ^context} = result

      # Give spawned process time to complete
      Process.sleep(200)

      meta = Context.get_meta(context, "event_sub")
      assert meta.completed == true
      assert meta.interrupting == false
    end
  end

  describe "message-triggered event subprocess fires on publish" do
    test "event subprocess activates when message is published" do
      process = build_process_with_event_subprocess(message_ref: "order_cancel")
      {:ok, context} = Context.start_link(process, %{})

      # Register event subprocesses (normally done by start event)
      SubprocessEvent.register(process, context)

      # Verify subscription exists
      subs = Bus.subscriptions(:message, "order_cancel")
      assert subs != []

      # Publish the message — this should trigger the event subprocess
      Bus.publish(:message, "order_cancel", %{reason: "customer_request"})

      # Give event subprocess time to execute
      Process.sleep(100)

      meta = Context.get_meta(context, "event_sub")
      assert meta != nil
      assert meta.type == :event_subprocess
    end
  end

  describe "parsing" do
    test "triggeredByEvent=true produces :bpmn_activity_subprocess_event" do
      xml = File.read!("test/fixtures/conformance/execution/14_event_subprocess.bpmn")
      diagram = Diagram.load(xml)

      {:bpmn_process, _attrs, elements} = hd(diagram.processes)

      {type, attrs} = elements["EventSub_1"]
      assert type == :bpmn_activity_subprocess_event
      assert is_map(attrs.elements)

      # Verify nested elements were parsed
      assert Map.has_key?(attrs.elements, "EventSub_Start")
      assert Map.has_key?(attrs.elements, "EventSub_Task")
      assert Map.has_key?(attrs.elements, "EventSub_End")
    end

    test "regular subprocess without triggeredByEvent remains embedded" do
      xml = File.read!("test/fixtures/conformance/execution/10_embedded_subprocess.bpmn")
      diagram = Diagram.load(xml)

      {:bpmn_process, _attrs, elements} = hd(diagram.processes)

      {type, _attrs} = elements["Sub_1"]
      assert type == :bpmn_activity_subprocess_embeded
    end
  end

  describe "export" do
    test "event subprocess exports with triggeredByEvent=true" do
      xml = File.read!("test/fixtures/conformance/execution/14_event_subprocess.bpmn")
      diagram = Diagram.load(xml)

      exported = Export.to_xml(diagram)

      assert String.contains?(exported, "triggeredByEvent=\"true\"")
      assert String.contains?(exported, "bpmn2:subProcess")
      assert String.contains?(exported, "EventSub_1")
    end

    test "regular subprocess does not get triggeredByEvent" do
      xml = File.read!("test/fixtures/conformance/execution/10_embedded_subprocess.bpmn")
      diagram = Diagram.load(xml)

      exported = Export.to_xml(diagram)

      refute String.contains?(exported, "triggeredByEvent")
    end
  end
end
