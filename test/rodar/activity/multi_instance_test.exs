defmodule Rodar.Activity.MultiInstanceTest do
  use ExUnit.Case, async: false

  alias Rodar.Context
  alias Rodar.Engine.Diagram
  alias Rodar.TaskRegistry

  # A service handler that records invocation count and stores a result
  defmodule CountingHandler do
    @behaviour Rodar.Activity.Task.Service.Handler

    @impl true
    def execute(_attrs, data) do
      counter = Map.get(data, "loopCounter", 0)
      {:ok, %{"_mi_current_result" => "result_#{counter}"}}
    end
  end

  # A service handler that processes collection items
  defmodule CollectionHandler do
    @behaviour Rodar.Activity.Task.Service.Handler

    @impl true
    def execute(_attrs, data) do
      item = Map.get(data, "item", nil)
      {:ok, %{"_mi_current_result" => String.upcase(item)}}
    end
  end

  setup do
    on_exit(fn ->
      try do
        TaskRegistry.unregister("MI_Task")
      rescue
        _ -> :ok
      end

      try do
        TaskRegistry.unregister("MI_Task_Seq")
      rescue
        _ -> :ok
      end

      try do
        TaskRegistry.unregister("MI_Task_Coll")
      rescue
        _ -> :ok
      end

      try do
        TaskRegistry.unregister("MI_Task_CC")
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "parsing" do
    test "parses multiInstanceLoopCharacteristics from BPMN XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="T1" name="MI Task">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:multiInstanceLoopCharacteristics isSequential="true">
              <bpmn:loopCardinality>5</bpmn:loopCardinality>
              <bpmn:completionCondition>loopCounter >= 3</bpmn:completionCondition>
              <bpmn:inputDataItem name="item"/>
              <bpmn:outputDataItem name="results"/>
            </bpmn:multiInstanceLoopCharacteristics>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="T1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="T1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      [{:bpmn_process, _attrs, elements}] = diagram.processes
      {:bpmn_activity_task_service, attrs} = elements["T1"]

      assert attrs.loop_characteristics != nil
      assert attrs.loop_characteristics.type == :multi_instance
      assert attrs.loop_characteristics.isSequential == "true"
      assert attrs.loop_characteristics.loopCardinality == "5"
      assert attrs.loop_characteristics.completionCondition == "loopCounter >= 3"
      assert attrs.loop_characteristics.inputDataItem == "item"
      assert attrs.loop_characteristics.outputDataItem == "results"
    end

    test "parses standardLoopCharacteristics from BPMN XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="T1" name="Loop Task">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="10"/>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="T1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="T1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      [{:bpmn_process, _attrs, elements}] = diagram.processes
      {:bpmn_activity_task_service, attrs} = elements["T1"]

      assert attrs.loop_characteristics != nil
      assert attrs.loop_characteristics.type == :standard_loop
      assert attrs.loop_characteristics.testBefore == "true"
      assert attrs.loop_characteristics.loopMaximum == "10"
    end

    test "returns nil loop_characteristics when no loop is present" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="T1" name="Regular Task">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="T1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="T1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      [{:bpmn_process, _attrs, elements}] = diagram.processes
      {:bpmn_activity_task_service, attrs} = elements["T1"]

      assert attrs.loop_characteristics == nil
    end

    test "parses loop characteristics on all task types" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:userTask id="UT1" name="User MI">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:multiInstanceLoopCharacteristics>
              <bpmn:loopCardinality>2</bpmn:loopCardinality>
            </bpmn:multiInstanceLoopCharacteristics>
          </bpmn:userTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="UT1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="UT1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      [{:bpmn_process, _attrs, elements}] = diagram.processes
      {:bpmn_activity_task_user, attrs} = elements["UT1"]

      assert attrs.loop_characteristics != nil
      assert attrs.loop_characteristics.type == :multi_instance
      assert attrs.loop_characteristics.loopCardinality == "2"
    end
  end

  describe "sequential multi-instance execution" do
    test "executes service task N times with loopCardinality" do
      TaskRegistry.register("MI_Task_Seq", CountingHandler)

      diagram =
        Diagram.load(File.read!("test/fixtures/conformance/execution/13_multi_instance.bpmn"))

      # Use second process (sequential)
      {:bpmn_process, _attrs, elements} =
        Enum.find(diagram.processes, fn {:bpmn_process, attrs, _} ->
          attrs[:id] == "Process_MI_Sequential"
        end)

      {:ok, context} = Context.start_link(elements, %{})
      start = find_start_event(elements)
      result = Rodar.execute(start, context)

      assert {:ok, _} = result

      # Check results were collected
      mi_results = Context.get_data(context, "_mi_results")
      assert is_list(mi_results)
      assert length(mi_results) == 3
      assert mi_results == ["result_1", "result_2", "result_3"]
    end

    test "executes with collection input data" do
      TaskRegistry.register("MI_Task_Coll", CollectionHandler)

      diagram =
        Diagram.load(File.read!("test/fixtures/conformance/execution/13_multi_instance.bpmn"))

      {:bpmn_process, _attrs, elements} =
        Enum.find(diagram.processes, fn {:bpmn_process, attrs, _} ->
          attrs[:id] == "Process_MI_Collection"
        end)

      {:ok, context} = Context.start_link(elements, %{})
      Context.put_data(context, "items", ["apple", "banana", "cherry"])
      start = find_start_event(elements)
      result = Rodar.execute(start, context)

      assert {:ok, _} = result

      results = Context.get_data(context, "results")
      assert results == ["APPLE", "BANANA", "CHERRY"]
    end

    test "stops early with completion condition" do
      TaskRegistry.register("MI_Task_CC", CountingHandler)

      diagram =
        Diagram.load(File.read!("test/fixtures/conformance/execution/13_multi_instance.bpmn"))

      {:bpmn_process, _attrs, elements} =
        Enum.find(diagram.processes, fn {:bpmn_process, attrs, _} ->
          attrs[:id] == "Process_MI_Completion"
        end)

      {:ok, context} = Context.start_link(elements, %{})
      start = find_start_event(elements)
      result = Rodar.execute(start, context)

      assert {:ok, _} = result

      mi_results = Context.get_data(context, "_mi_results")
      assert is_list(mi_results)
      # Should stop at 3 (loopCounter >= 3), not execute all 10
      assert length(mi_results) <= 3
    end
  end

  describe "parallel multi-instance execution" do
    test "executes service task N times in parallel with loopCardinality" do
      TaskRegistry.register("MI_Task", CountingHandler)

      diagram =
        Diagram.load(File.read!("test/fixtures/conformance/execution/13_multi_instance.bpmn"))

      {:bpmn_process, _attrs, elements} =
        Enum.find(diagram.processes, fn {:bpmn_process, attrs, _} ->
          attrs[:id] == "Process_MI_Parallel"
        end)

      {:ok, context} = Context.start_link(elements, %{})
      start = find_start_event(elements)
      result = Rodar.execute(start, context)

      assert {:ok, _} = result

      mi_results = Context.get_data(context, "_mi_results")
      assert is_list(mi_results)
      assert length(mi_results) == 3
    end
  end

  describe "multi-instance with inline elements" do
    test "executes inline multi-instance service task" do
      end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}

      flow_out =
        {:bpmn_sequence_flow,
         %{
           id: "flow_out",
           sourceRef: "task",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }}

      elem =
        {:bpmn_activity_task_service,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: CountingHandler,
           loop_characteristics: %{
             type: :multi_instance,
             isSequential: "true",
             loopCardinality: "3",
             completionCondition: nil,
             inputDataItem: nil,
             outputDataItem: nil,
             loopDataInputRef: nil,
             loopDataOutputRef: nil
           }
         }}

      process = %{"flow_out" => flow_out, "end" => end_event}
      {:ok, context} = Context.start_link(process, %{})
      result = Rodar.execute(elem, context)

      assert {:ok, _} = result

      mi_results = Context.get_data(context, "_mi_results")
      assert length(mi_results) == 3
    end

    test "zero cardinality skips execution" do
      end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}

      flow_out =
        {:bpmn_sequence_flow,
         %{
           id: "flow_out",
           sourceRef: "task",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }}

      elem =
        {:bpmn_activity_task_service,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: CountingHandler,
           loop_characteristics: %{
             type: :multi_instance,
             isSequential: "true",
             loopCardinality: "0",
             completionCondition: nil,
             inputDataItem: nil,
             outputDataItem: nil,
             loopDataInputRef: nil,
             loopDataOutputRef: nil
           }
         }}

      process = %{"flow_out" => flow_out, "end" => end_event}
      {:ok, context} = Context.start_link(process, %{})
      result = Rodar.execute(elem, context)

      assert {:ok, _} = result
    end
  end

  describe "export" do
    test "exports multiInstanceLoopCharacteristics to XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="T1" name="MI Task">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:multiInstanceLoopCharacteristics isSequential="true">
              <bpmn:loopCardinality>5</bpmn:loopCardinality>
              <bpmn:completionCondition>loopCounter >= 3</bpmn:completionCondition>
              <bpmn:inputDataItem name="item"/>
              <bpmn:outputDataItem name="results"/>
            </bpmn:multiInstanceLoopCharacteristics>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="T1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="T1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      exported = Diagram.export(diagram)

      assert String.contains?(exported, "multiInstanceLoopCharacteristics")
      assert String.contains?(exported, "isSequential=\"true\"")
      assert String.contains?(exported, "loopCardinality")
      assert String.contains?(exported, "5")
      assert String.contains?(exported, "completionCondition")
      assert String.contains?(exported, "inputDataItem")
      assert String.contains?(exported, "outputDataItem")
    end

    test "exports standardLoopCharacteristics to XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:startEvent id="Start" name="Start">
            <bpmn:outgoing>F1</bpmn:outgoing>
          </bpmn:startEvent>
          <bpmn:serviceTask id="T1" name="Loop Task">
            <bpmn:incoming>F1</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
            <bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="10"/>
          </bpmn:serviceTask>
          <bpmn:endEvent id="End" name="End">
            <bpmn:incoming>F2</bpmn:incoming>
          </bpmn:endEvent>
          <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="T1"/>
          <bpmn:sequenceFlow id="F2" sourceRef="T1" targetRef="End"/>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      exported = Diagram.export(diagram)

      assert String.contains?(exported, "standardLoopCharacteristics")
      assert String.contains?(exported, "testBefore=\"true\"")
      assert String.contains?(exported, "loopMaximum=\"10\"")
    end
  end

  describe "validation" do
    test "validates multi-instance has cardinality or data input ref" do
      process_map = %{
        "start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}},
        "task" =>
          {:bpmn_activity_task_service,
           %{
             id: "task",
             incoming: ["f1"],
             outgoing: ["f2"],
             loop_characteristics: %{
               type: :multi_instance,
               isSequential: "false",
               loopCardinality: nil,
               loopDataInputRef: nil
             }
           }},
        "end" => {:bpmn_event_end, %{id: "end", incoming: ["f2"], outgoing: []}},
        "f1" =>
          {:bpmn_sequence_flow,
           %{id: "f1", sourceRef: "start", targetRef: "task", conditionExpression: nil}},
        "f2" =>
          {:bpmn_sequence_flow,
           %{id: "f2", sourceRef: "task", targetRef: "end", conditionExpression: nil}}
      }

      assert {:error, issues} = Rodar.Validation.validate(process_map)
      assert Enum.any?(issues, &(&1.rule == :multi_instance_cardinality))
    end

    test "passes validation with loopCardinality" do
      process_map = %{
        "start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}},
        "task" =>
          {:bpmn_activity_task_service,
           %{
             id: "task",
             incoming: ["f1"],
             outgoing: ["f2"],
             loop_characteristics: %{
               type: :multi_instance,
               isSequential: "false",
               loopCardinality: "3",
               loopDataInputRef: nil
             }
           }},
        "end" => {:bpmn_event_end, %{id: "end", incoming: ["f2"], outgoing: []}},
        "f1" =>
          {:bpmn_sequence_flow,
           %{id: "f1", sourceRef: "start", targetRef: "task", conditionExpression: nil}},
        "f2" =>
          {:bpmn_sequence_flow,
           %{id: "f2", sourceRef: "task", targetRef: "end", conditionExpression: nil}}
      }

      assert {:ok, _} = Rodar.Validation.validate(process_map)
    end

    test "passes validation with loopDataInputRef" do
      process_map = %{
        "start" => {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}},
        "task" =>
          {:bpmn_activity_task_service,
           %{
             id: "task",
             incoming: ["f1"],
             outgoing: ["f2"],
             loop_characteristics: %{
               type: :multi_instance,
               isSequential: "false",
               loopCardinality: nil,
               loopDataInputRef: "items"
             }
           }},
        "end" => {:bpmn_event_end, %{id: "end", incoming: ["f2"], outgoing: []}},
        "f1" =>
          {:bpmn_sequence_flow,
           %{id: "f1", sourceRef: "start", targetRef: "task", conditionExpression: nil}},
        "f2" =>
          {:bpmn_sequence_flow,
           %{id: "f2", sourceRef: "task", targetRef: "end", conditionExpression: nil}}
      }

      assert {:ok, _} = Rodar.Validation.validate(process_map)
    end
  end

  # Helper to find start event in elements map
  defp find_start_event(elements) do
    elements
    |> Enum.find(fn
      {_id, {:bpmn_event_start, %{outgoing: [_ | _]}}} -> true
      _ -> false
    end)
    |> case do
      {_id, event} -> event
      nil -> nil
    end
  end
end
