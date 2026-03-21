defmodule Rodar.Engine.DiagramTest do
  use ExUnit.Case, async: true

  alias Rodar.Engine.Diagram

  doctest Rodar.Engine.Diagram

  describe "parser support for task types" do
    test "parses sendTask elements" do
      %{processes: [process]} = load_elements()
      {:bpmn_process, _, elements} = process
      assert {:bpmn_activity_task_send, attrs} = elements["Task_10yp281"]
      assert is_list(attrs.incoming)
      assert is_list(attrs.outgoing)
    end

    test "parses receiveTask elements" do
      %{processes: [process]} = load_elements()
      {:bpmn_process, _, elements} = process
      assert {:bpmn_activity_task_receive, attrs} = elements["Task_0k0tvr8"]
      assert is_list(attrs.incoming)
      assert is_list(attrs.outgoing)
    end

    test "parses subProcess elements" do
      %{processes: [process]} = load_elements()
      {:bpmn_process, _, elements} = process
      assert {:bpmn_activity_subprocess_embeded, attrs} = elements["Task_188rh46"]
      assert is_list(attrs.incoming)
      assert is_list(attrs.outgoing)
      assert is_map(attrs.elements)
    end
  end

  describe "parser support for inline BPMN" do
    test "parses manualTask elements" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:manualTask id="ManualTask_1" name="Sign Doc">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
          </bpmn:manualTask>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      assert {:bpmn_activity_task_manual, attrs} = elements["ManualTask_1"]
      assert attrs.incoming == ["Flow_1"]
      assert attrs.outgoing == ["Flow_2"]
    end

    test "parses boundaryEvent elements" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:userTask id="Task_1" name="Do Work">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn:boundaryEvent id="Boundary_1" attachedToRef="Task_1" cancelActivity="true">
            <bpmn:outgoing>Flow_3</bpmn:outgoing>
            <bpmn:timerEventDefinition id="Timer_1" />
          </bpmn:boundaryEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      assert {:bpmn_event_boundary, attrs} = elements["Boundary_1"]
      assert attrs.outgoing == ["Flow_3"]
      assert attrs.attachedToRef == "Task_1"
      assert attrs.cancelActivity == true
    end
  end

  describe "parser support for callActivity" do
    test "parses callActivity as :bpmn_activity_subprocess" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:callActivity id="Call_1" name="Invoke Sub" calledElement="SubProcess_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
          </bpmn:callActivity>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      assert {:bpmn_activity_subprocess, attrs} = elements["Call_1"]
      assert attrs.calledElement == "SubProcess_1"
      assert attrs.incoming == ["Flow_1"]
      assert attrs.outgoing == ["Flow_2"]
    end
  end

  describe "parser support for collaboration" do
    test "parses collaboration with participants and message flows" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:collaboration id="Collab_1">
          <bpmn:participant id="Part_A" name="Process A" processRef="Process_A" />
          <bpmn:participant id="Part_B" name="Process B" processRef="Process_B" />
          <bpmn:messageFlow id="MF_1" name="Order" sourceRef="Throw_1" targetRef="Catch_1" />
        </bpmn:collaboration>
        <bpmn:process id="Process_A" isExecutable="true">
          <bpmn:startEvent id="Start_A">
            <bpmn:outgoing>Flow_A1</bpmn:outgoing>
          </bpmn:startEvent>
        </bpmn:process>
        <bpmn:process id="Process_B" isExecutable="true">
          <bpmn:startEvent id="Start_B">
            <bpmn:outgoing>Flow_B1</bpmn:outgoing>
          </bpmn:startEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      assert diagram.collaboration != nil
      assert diagram.collaboration.id == "Collab_1"

      assert length(diagram.collaboration.participants) == 2
      [p1, p2] = diagram.collaboration.participants
      assert p1.id == "Part_A"
      assert p1.processRef == "Process_A"
      assert p2.id == "Part_B"
      assert p2.processRef == "Process_B"

      assert length(diagram.collaboration.message_flows) == 1
      [mf] = diagram.collaboration.message_flows
      assert mf.id == "MF_1"
      assert mf.name == "Order"
      assert mf.sourceRef == "Throw_1"
      assert mf.targetRef == "Catch_1"

      assert length(diagram.processes) == 2
    end

    test "collaboration is nil for single-process diagrams" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      assert diagram.collaboration == nil
    end
  end

  describe "parser support for timer event definitions" do
    test "extracts timeDuration from timerEventDefinition" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition>
              <bpmn:timeDuration>PT5S</bpmn:timeDuration>
            </bpmn:timerEventDefinition>
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_intermediate_catch, attrs} = elements["Catch_1"]
      {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition
      assert def_attrs.timeDuration == "PT5S"
    end

    test "extracts timeCycle from timerEventDefinition" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition>
              <bpmn:timeCycle>R3/PT10S</bpmn:timeCycle>
            </bpmn:timerEventDefinition>
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_intermediate_catch, attrs} = elements["Catch_1"]
      {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition
      assert def_attrs.timeCycle == "R3/PT10S"
    end

    test "extracts timeDate from timerEventDefinition" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:intermediateCatchEvent id="Catch_1">
            <bpmn:incoming>Flow_1</bpmn:incoming>
            <bpmn:outgoing>Flow_2</bpmn:outgoing>
            <bpmn:timerEventDefinition>
              <bpmn:timeDate>2025-12-31T23:59:59Z</bpmn:timeDate>
            </bpmn:timerEventDefinition>
          </bpmn:intermediateCatchEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, _, elements} = process
      {:bpmn_event_intermediate_catch, attrs} = elements["Catch_1"]
      {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition
      assert def_attrs.timeDate == "2025-12-31T23:59:59Z"
    end

    test "existing elements.bpmn timeDuration is extracted correctly" do
      %{processes: [process]} = load_elements()
      {:bpmn_process, _, elements} = process
      {:bpmn_event_start, attrs} = elements["StartEvent_1tyknaj"]
      {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition
      assert def_attrs.timeDuration == "PT1H"
    end

    test "existing elements.bpmn timeCycle is extracted correctly" do
      %{processes: [process]} = load_elements()
      {:bpmn_process, _, elements} = process
      {:bpmn_event_intermediate_catch, attrs} = elements["IntermediateThrowEvent_188s9i3"]
      {:bpmn_event_definition_timer, def_attrs} = attrs.timerEventDefinition
      assert def_attrs.timeCycle == "P1MT14H"
    end
  end

  describe "load/2 with handler_map option" do
    @service_task_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
      <bpmn:process id="Process_1" isExecutable="true">
        <bpmn:startEvent id="Start_1">
          <bpmn:outgoing>Flow_1</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:serviceTask id="Task_Validate" name="Validate">
          <bpmn:incoming>Flow_1</bpmn:incoming>
          <bpmn:outgoing>Flow_2</bpmn:outgoing>
        </bpmn:serviceTask>
        <bpmn:serviceTask id="Task_Fulfill" name="Fulfill">
          <bpmn:incoming>Flow_2</bpmn:incoming>
          <bpmn:outgoing>Flow_3</bpmn:outgoing>
        </bpmn:serviceTask>
        <bpmn:endEvent id="End_1">
          <bpmn:incoming>Flow_3</bpmn:incoming>
        </bpmn:endEvent>
      </bpmn:process>
    </bpmn:definitions>
    """

    test "injects handler into matching service task elements" do
      handler_map = %{
        "Task_Validate" => Rodar.Activity.Task.Service.TestHandler
      }

      diagram = Diagram.load(@service_task_xml, handler_map: handler_map)
      {:bpmn_process, _, elements} = hd(diagram.processes)

      {:bpmn_activity_task_service, attrs} = elements["Task_Validate"]
      assert attrs.handler == Rodar.Activity.Task.Service.TestHandler
    end

    test "does not inject handler into elements not in the map" do
      handler_map = %{
        "Task_Validate" => Rodar.Activity.Task.Service.TestHandler
      }

      diagram = Diagram.load(@service_task_xml, handler_map: handler_map)
      {:bpmn_process, _, elements} = hd(diagram.processes)

      {:bpmn_activity_task_service, attrs} = elements["Task_Fulfill"]
      refute Map.has_key?(attrs, :handler)
    end

    test "does not affect non-service-task elements" do
      handler_map = %{
        "Start_1" => Rodar.Activity.Task.Service.TestHandler
      }

      diagram = Diagram.load(@service_task_xml, handler_map: handler_map)
      {:bpmn_process, _, elements} = hd(diagram.processes)

      {:bpmn_event_start, attrs} = elements["Start_1"]
      refute Map.has_key?(attrs, :handler)
    end

    test "returns unchanged diagram when no handler_map option is given" do
      diagram_plain = Diagram.load(@service_task_xml)
      diagram_opts = Diagram.load(@service_task_xml, [])

      {:bpmn_process, _, elems_plain} = hd(diagram_plain.processes)
      {:bpmn_process, _, elems_opts} = hd(diagram_opts.processes)

      assert elems_plain == elems_opts
    end

    @subprocess_service_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
      <bpmn:process id="P1" isExecutable="true">
        <bpmn:startEvent id="Start_1">
          <bpmn:outgoing>Flow_1</bpmn:outgoing>
        </bpmn:startEvent>
        <bpmn:subProcess id="Sub_1">
          <bpmn:incoming>Flow_1</bpmn:incoming>
          <bpmn:outgoing>Flow_2</bpmn:outgoing>
          <bpmn:startEvent id="Sub_Start">
            <bpmn:outgoing>Sub_Flow</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="Sub_Task" name="Nested Service">
            <bpmn:incoming>Sub_Flow</bpmn:incoming>
            <bpmn:outgoing>Sub_Flow_2</bpmn:outgoing>
          </bpmn:serviceTask>
          <bpmn:endEvent id="Sub_End">
            <bpmn:incoming>Sub_Flow_2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="Sub_Flow" sourceRef="Sub_Start" targetRef="Sub_Task" />
          <bpmn:sequenceFlow id="Sub_Flow_2" sourceRef="Sub_Task" targetRef="Sub_End" />
        </bpmn:subProcess>
        <bpmn:endEvent id="End_1">
          <bpmn:incoming>Flow_2</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Sub_1" />
        <bpmn:sequenceFlow id="Flow_2" sourceRef="Sub_1" targetRef="End_1" />
      </bpmn:process>
    </bpmn:definitions>
    """

    test "injects handler into service task inside embedded subprocess" do
      handler_map = %{
        "Sub_Task" => Rodar.Activity.Task.Service.TestHandler
      }

      diagram = Diagram.load(@subprocess_service_xml, handler_map: handler_map)
      {:bpmn_process, _, elements} = hd(diagram.processes)

      {:bpmn_activity_subprocess_embeded, sub_attrs} = elements["Sub_1"]
      {:bpmn_activity_task_service, task_attrs} = sub_attrs.elements["Sub_Task"]
      assert task_attrs.handler == Rodar.Activity.Task.Service.TestHandler
    end
  end

  describe "parser support for lanes" do
    test "parses laneSet with lanes and flowNodeRefs" do
      diagram = Diagram.load(File.read!("./test/fixtures/lanes.bpmn"))
      {:bpmn_process, attrs, _elements} = hd(diagram.processes)

      assert attrs.lane_set != nil
      assert attrs.lane_set.id == "LaneSet_1"
      assert length(attrs.lane_set.lanes) == 2

      [hr_lane, mgr_lane] = attrs.lane_set.lanes
      assert hr_lane.id == "Lane_HR"
      assert hr_lane.name == "HR"
      assert hr_lane.flow_node_refs == ["Start_1", "Task_1"]
      assert hr_lane.child_lane_set == nil

      assert mgr_lane.id == "Lane_Manager"
      assert mgr_lane.flow_node_refs == ["Task_2", "End_1"]
    end

    test "parses nested childLaneSet" do
      diagram = Diagram.load(File.read!("./test/fixtures/lanes.bpmn"))
      {:bpmn_process, attrs, _elements} = hd(diagram.processes)

      mgr_lane = Enum.at(attrs.lane_set.lanes, 1)
      assert mgr_lane.child_lane_set != nil
      assert mgr_lane.child_lane_set.id == "ChildLaneSet_1"
      assert length(mgr_lane.child_lane_set.lanes) == 1

      [senior] = mgr_lane.child_lane_set.lanes
      assert senior.id == "Lane_Senior"
      assert senior.name == "Senior Manager"
      assert senior.flow_node_refs == ["Task_2"]
    end

    test "lane_set is nil when no lanes present" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, attrs, _} = process
      assert attrs.lane_set == nil
    end

    test "parses lane with empty flowNodeRefs" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="Definitions_1">
        <bpmn:process id="Process_1" isExecutable="true">
          <bpmn:laneSet id="LS1">
            <bpmn:lane id="Lane_Empty" name="Empty Lane" />
          </bpmn:laneSet>
          <bpmn:startEvent id="Start_1">
            <bpmn:outgoing>Flow_1</bpmn:outgoing>
          </bpmn:startEvent>
        </bpmn:process>
      </bpmn:definitions>
      """

      %{processes: [process]} = Diagram.load(xml)
      {:bpmn_process, attrs, _} = process

      assert attrs.lane_set.lanes == [
               %{id: "Lane_Empty", name: "Empty Lane", flow_node_refs: [], child_lane_set: nil}
             ]
    end
  end

  defp load_elements do
    Diagram.load(File.read!("./priv/bpmn/examples/elements.bpmn"))
  end
end
