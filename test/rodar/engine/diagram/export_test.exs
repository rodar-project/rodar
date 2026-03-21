defmodule Rodar.Engine.Diagram.ExportTest do
  use ExUnit.Case, async: true

  alias Rodar.Engine.Diagram
  alias Rodar.Engine.Diagram.Export

  # --- Unit tests by element type ---

  describe "to_xml/1 XML structure" do
    test "includes XML declaration" do
      xml = minimal_diagram() |> Export.to_xml()
      assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))
    end

    test "includes namespace declarations" do
      xml = minimal_diagram() |> Export.to_xml()
      assert xml =~ ~s(xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL")
      assert xml =~ ~s(xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance")
    end

    test "escapes special characters in attribute values" do
      diagram = minimal_diagram()

      diagram =
        put_in(diagram, [:processes], [
          {:bpmn_process, %{id: "p1", name: "A & B <C>"}, %{}}
        ])

      xml = Export.to_xml(diagram)
      assert xml =~ "A &amp; B &lt;C&gt;"
    end

    test "escapes special characters in text content" do
      diagram = minimal_diagram()

      diagram =
        put_in(diagram, [:processes], [
          {:bpmn_process, %{id: "p1", name: "Test"},
           %{
             "flow1" =>
               {:bpmn_sequence_flow,
                %{
                  id: "flow1",
                  name: "",
                  sourceRef: "s1",
                  targetRef: "t1",
                  conditionExpression:
                    {:bpmn_expression, {"elixir", ~s(data["x"] > 5 && data["y"] < 3)}}
                }}
           }}
        ])

      xml = Export.to_xml(diagram)
      assert xml =~ "&amp;&amp;"
      assert xml =~ "&lt;"
      assert xml =~ "&gt;"
    end

    test "nil collaboration is not emitted" do
      diagram = minimal_diagram()
      xml = Export.to_xml(diagram)
      refute xml =~ "bpmn2:collaboration"
    end
  end

  describe "to_xml/1 events" do
    test "exports start event with outgoing" do
      diagram =
        diagram_with_element(
          "start1",
          {:bpmn_event_start,
           %{
             id: "start1",
             name: "Begin",
             incoming: [],
             outgoing: ["flow1"],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             terminateEventDefinition: nil,
             timerEventDefinition: nil,
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:startEvent"
      assert xml =~ ~s(id="start1")
      assert xml =~ ~s(name="Begin")
      assert xml =~ "<bpmn2:outgoing>flow1</bpmn2:outgoing>"
    end

    test "exports end event with terminate event definition" do
      diagram =
        diagram_with_element(
          "end1",
          {:bpmn_event_end,
           %{
             id: "end1",
             name: "Terminate",
             incoming: ["flow1"],
             outgoing: [],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             terminateEventDefinition: {:bpmn_event_definition_terminate, %{_elems: []}},
             timerEventDefinition: nil,
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:endEvent"
      assert xml =~ "bpmn2:terminateEventDefinition"
    end

    test "exports message event definition with messageRef" do
      diagram =
        diagram_with_element(
          "catch1",
          {:bpmn_event_intermediate_catch,
           %{
             id: "catch1",
             name: "",
             incoming: ["f1"],
             outgoing: ["f2"],
             messageEventDefinition:
               {:bpmn_event_definition_message, %{messageRef: "msg1", _elems: []}},
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             terminateEventDefinition: nil,
             timerEventDefinition: nil,
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:intermediateCatchEvent"
      assert xml =~ ~s(messageRef="msg1")
    end

    test "exports timer event definition with timeDuration" do
      diagram =
        diagram_with_element(
          "start1",
          {:bpmn_event_start,
           %{
             id: "start1",
             incoming: [],
             outgoing: ["f1"],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             terminateEventDefinition: nil,
             timerEventDefinition: {:bpmn_event_definition_timer, %{timeDuration: "PT1H"}},
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:timerEventDefinition>"
      assert xml =~ "<bpmn2:timeDuration>PT1H</bpmn2:timeDuration>"
    end

    test "exports compensate event definition with activityRef" do
      diagram =
        diagram_with_element(
          "throw1",
          {:bpmn_event_intermediate_throw,
           %{
             id: "throw1",
             incoming: ["f1"],
             outgoing: ["f2"],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition:
               {:bpmn_event_definition_compensate,
                %{
                  activityRef: "task1",
                  waitForCompletion: "true",
                  _elems: []
                }},
             terminateEventDefinition: nil,
             timerEventDefinition: nil,
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "bpmn2:compensateEventDefinition"
      assert xml =~ ~s(activityRef="task1")
      assert xml =~ ~s(waitForCompletion="true")
    end

    test "exports conditional event definition" do
      diagram =
        diagram_with_element(
          "catch1",
          {:bpmn_event_intermediate_catch,
           %{
             id: "catch1",
             incoming: ["f1"],
             outgoing: ["f2"],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition: nil,
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             terminateEventDefinition: nil,
             timerEventDefinition: nil,
             conditionalEventDefinition:
               {:bpmn_event_definition_conditional,
                %{
                  condition: "x > 5",
                  condition_language: "feel",
                  _elems: []
                }}
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "bpmn2:conditionalEventDefinition"
      assert xml =~ ~s(language="feel")
      assert xml =~ ">x &gt; 5</bpmn2:condition>"
    end

    test "exports boundary event with attachedToRef" do
      diagram =
        diagram_with_element(
          "bound1",
          {:bpmn_event_boundary,
           %{
             id: "bound1",
             name: "Error",
             attachedToRef: "task1",
             cancelActivity: true,
             incoming: [],
             outgoing: ["f1"],
             messageEventDefinition: nil,
             signalEventDefinition: nil,
             errorEventDefinition:
               {:bpmn_event_definition_error, %{errorRef: "err1", _elems: []}},
             escalationEventDefinition: nil,
             compensateEventDefinition: nil,
             timerEventDefinition: nil,
             conditionalEventDefinition: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:boundaryEvent"
      assert xml =~ ~s(attachedToRef="task1")
      assert xml =~ ~s(cancelActivity="true")
      assert xml =~ "bpmn2:errorEventDefinition"
      assert xml =~ ~s(errorRef="err1")
    end
  end

  describe "to_xml/1 gateways" do
    test "exports exclusive gateway with default" do
      diagram =
        diagram_with_element(
          "gw1",
          {:bpmn_gateway_exclusive,
           %{
             id: "gw1",
             name: "Decision",
             default: "flow2",
             incoming: ["f1"],
             outgoing: ["flow2", "flow3"]
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:exclusiveGateway"
      assert xml =~ ~s(default="flow2")
      assert xml =~ ~s(name="Decision")
    end

    test "exports parallel gateway" do
      diagram =
        diagram_with_element(
          "gw1",
          {:bpmn_gateway_parallel,
           %{
             id: "gw1",
             incoming: ["f1"],
             outgoing: ["f2", "f3"]
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:parallelGateway"
    end
  end

  describe "to_xml/1 tasks" do
    test "exports script task with script content" do
      diagram =
        diagram_with_element(
          "task1",
          {:bpmn_activity_task_script,
           %{
             id: "task1",
             name: "Run Script",
             scriptFormat: "elixir",
             incoming: ["f1"],
             outgoing: ["f2"],
             ioSpecification: [],
             dataInputAssociation: [],
             dataOutputAssociation: [],
             script: {:bpmn_script, %{expression: "1 + 1"}}
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:scriptTask"
      assert xml =~ ~s(scriptFormat="elixir")
      assert xml =~ "<bpmn2:script>1 + 1</bpmn2:script>"
    end

    test "exports call activity with calledElement" do
      diagram =
        diagram_with_element(
          "task1",
          {:bpmn_activity_subprocess,
           %{
             id: "task1",
             name: "Call",
             calledElement: "other_process",
             incoming: ["f1"],
             outgoing: ["f2"]
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:callActivity"
      assert xml =~ ~s(calledElement="other_process")
    end

    test "exports receive task with messageRef" do
      diagram =
        diagram_with_element(
          "task1",
          {:bpmn_activity_task_receive,
           %{
             id: "task1",
             name: "Wait",
             messageRef: "msg1",
             incoming: ["f1"],
             outgoing: ["f2"]
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:receiveTask"
      assert xml =~ ~s(messageRef="msg1")
    end
  end

  describe "to_xml/1 sequence flows" do
    test "exports sequence flow with condition expression" do
      diagram =
        diagram_with_element(
          "flow1",
          {:bpmn_sequence_flow,
           %{
             id: "flow1",
             name: "Yes",
             sourceRef: "gw1",
             targetRef: "task1",
             conditionExpression: {:bpmn_expression, {"elixir", ~s(data["ok"] == true)}}
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:sequenceFlow"
      assert xml =~ ~s(sourceRef="gw1")
      assert xml =~ ~s(targetRef="task1")
      assert xml =~ "bpmn2:conditionExpression"
      assert xml =~ ~s(xsi:type="bpmn2:tFormalExpression")
    end

    test "exports sequence flow without condition as self-closing" do
      diagram =
        diagram_with_element(
          "flow1",
          {:bpmn_sequence_flow,
           %{
             id: "flow1",
             name: "",
             sourceRef: "s1",
             targetRef: "t1",
             conditionExpression: nil
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ ~r/<bpmn2:sequenceFlow[^>]+\/>/
    end

    test "exports empty condition expression as self-closing" do
      diagram =
        diagram_with_element(
          "flow1",
          {:bpmn_sequence_flow,
           %{
             id: "flow1",
             name: "",
             sourceRef: "s1",
             targetRef: "t1",
             conditionExpression: {:bpmn_expression, {"elixir", ""}}
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ ~r/<bpmn2:conditionExpression[^>]+\/>/
    end
  end

  describe "to_xml/1 collaboration" do
    test "exports collaboration with participants and message flows" do
      diagram = %{
        id: "defs1",
        expression_language: "",
        type_language: "",
        processes: [],
        item_definitions: %{},
        collaboration: %{
          id: "collab1",
          participants: [
            %{id: "p1", name: "Pool A", processRef: "proc1"},
            %{id: "p2", name: "Pool B", processRef: "proc2"}
          ],
          message_flows: [
            %{id: "mf1", name: "Request", sourceRef: "task1", targetRef: "task2"}
          ]
        }
      }

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:collaboration"
      assert xml =~ ~s(id="collab1")
      assert xml =~ "<bpmn2:participant"
      assert xml =~ ~s(name="Pool A")
      assert xml =~ "<bpmn2:messageFlow"
      assert xml =~ ~s(sourceRef="task1")
    end
  end

  describe "to_xml/1 item definitions" do
    test "exports item definitions" do
      diagram = %{
        id: "defs1",
        expression_language: "",
        type_language: "",
        processes: [],
        item_definitions: %{
          "item1" => {:bpmn_item_definition, %{id: "item1", structureRef: "String"}}
        },
        collaboration: nil
      }

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:itemDefinition"
      assert xml =~ ~s(id="item1")
      assert xml =~ ~s(structureRef="String")
    end
  end

  describe "to_xml/1 embedded subprocess" do
    test "exports subprocess with nested elements" do
      diagram =
        diagram_with_element(
          "sub1",
          {:bpmn_activity_subprocess_embeded,
           %{
             id: "sub1",
             name: "Sub",
             incoming: ["f1"],
             outgoing: ["f2"],
             elements: %{
               "s1" =>
                 {:bpmn_event_start,
                  %{
                    id: "s1",
                    incoming: [],
                    outgoing: ["sf1"],
                    messageEventDefinition: nil,
                    signalEventDefinition: nil,
                    errorEventDefinition: nil,
                    escalationEventDefinition: nil,
                    compensateEventDefinition: nil,
                    terminateEventDefinition: nil,
                    timerEventDefinition: nil,
                    conditionalEventDefinition: nil
                  }},
               "e1" =>
                 {:bpmn_event_end,
                  %{
                    id: "e1",
                    incoming: ["sf1"],
                    outgoing: [],
                    messageEventDefinition: nil,
                    signalEventDefinition: nil,
                    errorEventDefinition: nil,
                    escalationEventDefinition: nil,
                    compensateEventDefinition: nil,
                    terminateEventDefinition: nil,
                    timerEventDefinition: nil,
                    conditionalEventDefinition: nil
                  }},
               "sf1" =>
                 {:bpmn_sequence_flow,
                  %{
                    id: "sf1",
                    name: "",
                    sourceRef: "s1",
                    targetRef: "e1",
                    conditionExpression: nil
                  }}
             }
           }}
        )

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:subProcess"
      assert xml =~ "<bpmn2:startEvent"
      assert xml =~ "<bpmn2:endEvent"
      assert xml =~ "<bpmn2:sequenceFlow"
    end
  end

  describe "to_xml/1 lane set" do
    test "exports lane set with lanes and flowNodeRefs" do
      diagram = %{
        id: "defs1",
        expression_language: "",
        type_language: "",
        processes: [
          {:bpmn_process,
           %{
             id: "p1",
             lane_set: %{
               id: "ls1",
               lanes: [
                 %{id: "l1", name: "HR", flow_node_refs: ["task1", "task2"], child_lane_set: nil},
                 %{id: "l2", name: "IT", flow_node_refs: ["task3"], child_lane_set: nil}
               ]
             }
           }, %{}}
        ],
        item_definitions: %{},
        collaboration: nil
      }

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:laneSet"
      assert xml =~ ~s(id="ls1")
      assert xml =~ "<bpmn2:lane"
      assert xml =~ ~s(name="HR")
      assert xml =~ "<bpmn2:flowNodeRef>task1</bpmn2:flowNodeRef>"
      assert xml =~ "<bpmn2:flowNodeRef>task2</bpmn2:flowNodeRef>"
      assert xml =~ ~s(name="IT")
    end

    test "exports nested childLaneSet" do
      diagram = %{
        id: "defs1",
        expression_language: "",
        type_language: "",
        processes: [
          {:bpmn_process,
           %{
             id: "p1",
             lane_set: %{
               id: "ls1",
               lanes: [
                 %{
                   id: "l1",
                   name: "Mgr",
                   flow_node_refs: ["task1"],
                   child_lane_set: %{
                     id: "cls1",
                     lanes: [
                       %{
                         id: "l1a",
                         name: "Senior",
                         flow_node_refs: ["task1"],
                         child_lane_set: nil
                       }
                     ]
                   }
                 }
               ]
             }
           }, %{}}
        ],
        item_definitions: %{},
        collaboration: nil
      }

      xml = Export.to_xml(diagram)
      assert xml =~ "<bpmn2:childLaneSet"
      assert xml =~ ~s(id="cls1")
      assert xml =~ ~s(name="Senior")
    end

    test "does not emit laneSet when nil" do
      diagram = %{
        id: "defs1",
        expression_language: "",
        type_language: "",
        processes: [{:bpmn_process, %{id: "p1", lane_set: nil}, %{}}],
        item_definitions: %{},
        collaboration: nil
      }

      xml = Export.to_xml(diagram)
      refute xml =~ "laneSet"
      refute xml =~ "lane"
    end
  end

  # --- Round-trip tests ---

  describe "round-trip: simple.bpmn" do
    test "load -> export -> load produces equivalent structure" do
      xml = File.read!("test/fixtures/simple.bpmn")
      assert_round_trip(xml)
    end
  end

  describe "round-trip: user_login.bpmn" do
    test "load -> export -> load produces equivalent structure" do
      xml = File.read!("priv/bpmn/examples/user_login.bpmn")
      assert_round_trip(xml)
    end
  end

  describe "round-trip: elements.bpmn" do
    test "load -> export -> load produces equivalent structure" do
      xml = File.read!("priv/bpmn/examples/elements.bpmn")
      assert_round_trip(xml)
    end
  end

  describe "round-trip: hiring.bpmn2" do
    test "load -> export -> load produces equivalent structure" do
      xml = File.read!("priv/bpmn/examples/hiring/hiring.bpmn2")
      assert_round_trip(xml)
    end
  end

  describe "round-trip: lanes.bpmn" do
    test "load -> export -> load preserves lane_set structure" do
      xml = File.read!("test/fixtures/lanes.bpmn")
      d1 = Diagram.load(xml)
      xml2 = Export.to_xml(d1)
      d2 = Diagram.load(xml2)

      {:bpmn_process, attrs1, _} = hd(d1.processes)
      {:bpmn_process, attrs2, _} = hd(d2.processes)

      assert attrs1.lane_set == attrs2.lane_set
    end
  end

  describe "round-trip idempotence" do
    test "load(export(load(xml))) == load(export(load(export(load(xml)))))" do
      xml = File.read!("test/fixtures/simple.bpmn")
      d1 = Diagram.load(xml)
      xml2 = Export.to_xml(d1)
      d2 = Diagram.load(xml2)
      xml3 = Export.to_xml(d2)
      d3 = Diagram.load(xml3)

      assert_structures_equivalent(d2, d3)
    end
  end

  describe "Diagram.export/1 delegate" do
    test "delegates to Export.to_xml/1" do
      xml = File.read!("test/fixtures/simple.bpmn")
      diagram = Diagram.load(xml)
      assert Diagram.export(diagram) == Export.to_xml(diagram)
    end
  end

  # --- Helpers ---

  defp minimal_diagram do
    %{
      id: "Definitions_1",
      expression_language: "",
      type_language: "",
      processes: [],
      item_definitions: %{},
      collaboration: nil
    }
  end

  defp diagram_with_element(id, element) do
    %{
      id: "Definitions_1",
      expression_language: "",
      type_language: "",
      processes: [
        {:bpmn_process, %{id: "process1", name: "Test"}, %{id => element}}
      ],
      item_definitions: %{},
      collaboration: nil
    }
  end

  defp assert_round_trip(xml) do
    d1 = Diagram.load(xml)
    xml2 = Export.to_xml(d1)
    d2 = Diagram.load(xml2)
    assert_structures_equivalent(d1, d2)
  end

  defp assert_structures_equivalent(d1, d2) do
    assert d1.id == d2.id

    assert length(d1.processes) == length(d2.processes)

    Enum.zip(d1.processes, d2.processes)
    |> Enum.each(fn {{:bpmn_process, attrs1, elems1}, {:bpmn_process, attrs2, elems2}} ->
      assert attrs1[:id] == attrs2[:id]
      assert_elements_equivalent(elems1, elems2)
    end)
  end

  defp assert_elements_equivalent(elems1, elems2) do
    # Compare element IDs present in both
    ids1 = elems1 |> Map.keys() |> MapSet.new()
    ids2 = elems2 |> Map.keys() |> MapSet.new()

    # Only compare IDs present in the exported version (some vendor-specific
    # elements like dataObjectReference may not round-trip)
    common_ids = MapSet.intersection(ids1, ids2)

    # All exported elements should be present
    assert MapSet.subset?(ids2, ids1),
           "Extra elements in re-parsed: #{inspect(MapSet.difference(ids2, ids1))}"

    Enum.each(common_ids, fn id ->
      {type1, attrs1} = Map.get(elems1, id)
      {type2, attrs2} = Map.get(elems2, id)

      assert type1 == type2, "Type mismatch for #{id}: #{type1} vs #{type2}"

      # Compare key structural attributes
      assert clean_attrs(attrs1)[:id] == clean_attrs(attrs2)[:id],
             "ID mismatch for element #{id}"

      # Compare incoming/outgoing if present
      if Map.has_key?(attrs1, :incoming) do
        assert Enum.sort(attrs1[:incoming] || []) == Enum.sort(attrs2[:incoming] || []),
               "Incoming mismatch for #{id}"
      end

      if Map.has_key?(attrs1, :outgoing) do
        assert Enum.sort(attrs1[:outgoing] || []) == Enum.sort(attrs2[:outgoing] || []),
               "Outgoing mismatch for #{id}"
      end

      # For sequence flows, compare structural refs
      if type1 == :bpmn_sequence_flow do
        assert attrs1[:sourceRef] == attrs2[:sourceRef]
        assert attrs1[:targetRef] == attrs2[:targetRef]
      end

      # For embedded subprocesses, compare nested elements
      if type1 == :bpmn_activity_subprocess_embeded do
        sub_elems1 = Map.get(attrs1, :elements, %{})
        sub_elems2 = Map.get(attrs2, :elements, %{})
        assert_elements_equivalent(sub_elems1, sub_elems2)
      end
    end)
  end

  defp clean_attrs(attrs) do
    attrs
    |> Map.drop([:_elems])
    |> Enum.reject(fn {k, _v} ->
      k_str = Atom.to_string(k)
      String.contains?(k_str, ":")
    end)
    |> Map.new()
  end
end
