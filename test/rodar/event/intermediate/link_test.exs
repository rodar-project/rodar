defmodule Rodar.Event.Intermediate.LinkTest do
  use ExUnit.Case, async: true

  alias Rodar.Context
  alias Rodar.Engine.Diagram
  alias Rodar.Event.Intermediate.Catch
  alias Rodar.Event.Intermediate.Throw

  defp build_link_process(link_name) do
    # Start -> Throw(link "X") ... Catch(link "X") -> Task -> End
    start =
      {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["flow_to_throw"]}}

    flow_to_throw =
      {:bpmn_sequence_flow,
       %{
         id: "flow_to_throw",
         sourceRef: "start",
         targetRef: "link_throw",
         conditionExpression: nil,
         isImmediate: nil
       }}

    link_throw =
      {:bpmn_event_intermediate_throw,
       %{
         id: "link_throw",
         incoming: ["flow_to_throw"],
         outgoing: ["flow_after_throw"],
         linkEventDefinition: {:bpmn_event_definition_link, %{name: link_name}},
         messageEventDefinition: nil,
         signalEventDefinition: nil,
         escalationEventDefinition: nil,
         compensateEventDefinition: nil
       }}

    flow_after_throw =
      {:bpmn_sequence_flow,
       %{
         id: "flow_after_throw",
         sourceRef: "link_throw",
         targetRef: "after_throw_task",
         conditionExpression: nil,
         isImmediate: nil
       }}

    after_throw_task =
      {:bpmn_activity_task,
       %{
         id: "after_throw_task",
         incoming: ["flow_after_throw"],
         outgoing: ["flow_to_dead_end"],
         _elems: []
       }}

    flow_to_dead_end =
      {:bpmn_sequence_flow,
       %{
         id: "flow_to_dead_end",
         sourceRef: "after_throw_task",
         targetRef: "dead_end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    dead_end =
      {:bpmn_event_end, %{id: "dead_end", incoming: ["flow_to_dead_end"], outgoing: []}}

    link_catch =
      {:bpmn_event_intermediate_catch,
       %{
         id: "link_catch",
         incoming: [],
         outgoing: ["flow_from_catch"],
         linkEventDefinition: {:bpmn_event_definition_link, %{name: link_name}},
         messageEventDefinition: nil,
         signalEventDefinition: nil,
         timerEventDefinition: nil,
         conditionalEventDefinition: nil
       }}

    flow_from_catch =
      {:bpmn_sequence_flow,
       %{
         id: "flow_from_catch",
         sourceRef: "link_catch",
         targetRef: "end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_from_catch"], outgoing: []}}

    %{
      "start" => start,
      "flow_to_throw" => flow_to_throw,
      "link_throw" => link_throw,
      "flow_after_throw" => flow_after_throw,
      "after_throw_task" => after_throw_task,
      "flow_to_dead_end" => flow_to_dead_end,
      "dead_end" => dead_end,
      "link_catch" => link_catch,
      "flow_from_catch" => flow_from_catch,
      "end" => end_event
    }
  end

  describe "link throw → catch pairing" do
    test "link throw jumps to matching catch's outgoing flows" do
      process = build_link_process("GoToSection2")
      {:ok, context} = Context.start_link(process, %{})

      elem = process["link_throw"]

      assert {:ok, ^context} = Throw.token_in(elem, context)
    end

    test "link throw returns error when no matching catch exists" do
      # Process with throw but no matching catch
      end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}

      flow_out =
        {:bpmn_sequence_flow,
         %{
           id: "flow_out",
           sourceRef: "link_throw",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }}

      process = %{"flow_out" => flow_out, "end" => end_event}
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_event_intermediate_throw,
         %{
           id: "link_throw",
           outgoing: ["flow_out"],
           linkEventDefinition: {:bpmn_event_definition_link, %{name: "NonExistent"}},
           messageEventDefinition: nil,
           signalEventDefinition: nil,
           escalationEventDefinition: nil,
           compensateEventDefinition: nil
         }}

      assert {:error, msg} = Throw.token_in(elem, context)
      assert msg =~ "no matching link catch"
      assert msg =~ "NonExistent"
    end

    test "link throw matches catch by name" do
      process = build_link_process("SpecificName")
      {:ok, context} = Context.start_link(process, %{})

      elem = process["link_throw"]
      assert {:ok, ^context} = Throw.token_in(elem, context)
    end
  end

  describe "link catch (passive)" do
    test "link catch passes through on normal token flow" do
      process = build_link_process("MyLink")
      {:ok, context} = Context.start_link(process, %{})

      elem = process["link_catch"]
      assert {:ok, ^context} = Catch.token_in(elem, context)
    end
  end

  describe "end-to-end via Rodar.execute/2" do
    test "link throw dispatches correctly" do
      process = build_link_process("E2ELink")
      {:ok, context} = Context.start_link(process, %{})

      elem = process["link_throw"]
      assert {:ok, ^context} = Rodar.execute(elem, context)
    end

    test "link catch dispatches correctly" do
      process = build_link_process("E2ELink")
      {:ok, context} = Context.start_link(process, %{})

      elem = process["link_catch"]
      assert {:ok, ^context} = Rodar.execute(elem, context)
    end
  end

  describe "parser integration" do
    test "parses link event definitions from XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="start">
            <bpmn:outgoing>f1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:intermediateThrowEvent id="throw1" name="Link Throw">
            <bpmn:incoming>f1</bpmn:incoming>
            <bpmn:linkEventDefinition name="GoTo2" />
          </bpmn:intermediateThrowEvent>
          <bpmn:intermediateCatchEvent id="catch1" name="Link Catch">
            <bpmn:outgoing>f2</bpmn:outgoing>
            <bpmn:linkEventDefinition name="GoTo2" />
          </bpmn:intermediateCatchEvent>
          <bpmn:endEvent id="end1">
            <bpmn:incoming>f2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="f1" sourceRef="start" targetRef="throw1" />
          <bpmn:sequenceFlow id="f2" sourceRef="catch1" targetRef="end1" />
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      {:bpmn_process, _, elements} = hd(diagram.processes)

      {:bpmn_event_intermediate_throw, throw_attrs} = elements["throw1"]
      assert {:bpmn_event_definition_link, %{name: "GoTo2"}} = throw_attrs.linkEventDefinition

      {:bpmn_event_intermediate_catch, catch_attrs} = elements["catch1"]
      assert {:bpmn_event_definition_link, %{name: "GoTo2"}} = catch_attrs.linkEventDefinition
    end
  end

  describe "export integration" do
    test "exports link event definitions to XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:intermediateThrowEvent id="throw1" name="Link Throw">
            <bpmn:linkEventDefinition name="GoTo2" />
          </bpmn:intermediateThrowEvent>
          <bpmn:intermediateCatchEvent id="catch1" name="Link Catch">
            <bpmn:linkEventDefinition name="GoTo2" />
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      exported = Diagram.export(diagram)

      assert exported =~ "bpmn2:linkEventDefinition"
      assert exported =~ ~s(name="GoTo2")
    end
  end
end
