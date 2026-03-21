defmodule Rodar.Activity.Task.BusinessRuleTest do
  use ExUnit.Case, async: true

  alias Rodar.Activity.Task.BusinessRule
  alias Rodar.Context
  alias Rodar.Engine.Diagram
  alias Rodar.Scaffold

  doctest Rodar.Activity.Task.BusinessRule

  defp build_process do
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

    %{"flow_out" => flow_out, "end" => end_event}
  end

  describe "with a handler that returns {:ok, map}" do
    test "invokes handler and merges result into context" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_business_rule,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: BusinessRule.TestHandler
         }}

      assert {:ok, ^context} = BusinessRule.token_in(elem, context)
      assert Context.get_data(context, :result) == "handled"
    end
  end

  describe "with a handler that returns {:ok, non-map}" do
    defmodule NonMapHandler do
      @moduledoc false
      @behaviour BusinessRule.Handler

      @impl true
      def execute(_attrs, _data), do: {:ok, :done}
    end

    test "releases token without merging" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_business_rule,
         %{id: "task", outgoing: ["flow_out"], handler: NonMapHandler}}

      assert {:ok, ^context} = BusinessRule.token_in(elem, context)
    end
  end

  describe "with a handler that returns {:error, reason}" do
    defmodule ErrorHandler do
      @moduledoc false
      @behaviour BusinessRule.Handler

      @impl true
      def execute(_attrs, _data), do: {:error, "rule evaluation failed"}
    end

    test "returns the error" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_business_rule,
         %{id: "task", outgoing: ["flow_out"], handler: ErrorHandler}}

      assert {:error, "rule evaluation failed"} =
               BusinessRule.token_in(elem, context)
    end
  end

  describe "TaskRegistry fallback" do
    test "uses handler from TaskRegistry when no inline handler is present" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      Rodar.TaskRegistry.register("br_task", BusinessRule.TestHandler)

      elem =
        {:bpmn_activity_task_business_rule, %{id: "br_task", outgoing: ["flow_out"]}}

      assert {:ok, ^context} = BusinessRule.token_in(elem, context)
      assert Context.get_data(context, :result) == "handled"

      Rodar.TaskRegistry.unregister("br_task")
    end

    test "returns {:not_implemented} when no handler and no registry entry" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_business_rule, %{id: "unregistered_br_task", outgoing: ["flow_out"]}}

      assert {:not_implemented} = BusinessRule.token_in(elem, context)
    end
  end

  describe "fallback" do
    test "returns {:not_implemented} for unrecognized element shape" do
      assert {:not_implemented} = BusinessRule.execute(:bad, nil)
    end
  end

  describe "dispatcher integration" do
    test "Rodar dispatches business rule task to BusinessRule module" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_business_rule,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: BusinessRule.TestHandler
         }}

      assert {:ok, ^context} = Rodar.execute(elem, context)
      assert Context.get_data(context, :result) == "handled"
    end
  end

  describe "parser integration" do
    test "parses businessRuleTask from BPMN XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:businessRuleTask id="Task_BR" name="Evaluate Discount">
            <bpmn:incoming>Flow_in</bpmn:incoming>
            <bpmn:outgoing>Flow_out</bpmn:outgoing>
          </bpmn:businessRuleTask>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      {:bpmn_process, _attrs, elements} = hd(diagram.processes)
      assert {:bpmn_activity_task_business_rule, attrs} = elements["Task_BR"]
      assert attrs.id == "Task_BR"
      assert attrs.name == "Evaluate Discount"
      assert attrs.incoming == ["Flow_in"]
      assert attrs.outgoing == ["Flow_out"]
    end

    test "injects handler via handler_map" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:businessRuleTask id="Task_BR" name="Evaluate Discount">
            <bpmn:outgoing>Flow_out</bpmn:outgoing>
          </bpmn:businessRuleTask>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram =
        Diagram.load(xml,
          handler_map: %{"Task_BR" => BusinessRule.TestHandler}
        )

      {:bpmn_process, _attrs, elements} = hd(diagram.processes)
      {:bpmn_activity_task_business_rule, attrs} = elements["Task_BR"]
      assert attrs.handler == BusinessRule.TestHandler
    end
  end

  describe "export integration" do
    test "exports business rule task to XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:businessRuleTask id="Task_BR" name="Evaluate Discount">
            <bpmn:incoming>Flow_in</bpmn:incoming>
            <bpmn:outgoing>Flow_out</bpmn:outgoing>
          </bpmn:businessRuleTask>
          <bpmn:sequenceFlow id="Flow_in" sourceRef="start" targetRef="Task_BR" />
          <bpmn:sequenceFlow id="Flow_out" sourceRef="Task_BR" targetRef="end" />
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      exported = Diagram.export(diagram)

      assert String.contains?(exported, "bpmn2:businessRuleTask")
      assert String.contains?(exported, "Task_BR")
      assert String.contains?(exported, "Evaluate Discount")
    end
  end

  describe "scaffold integration" do
    test "extract_tasks includes business rule tasks" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
        <bpmn:process id="P1" isExecutable="true">
          <bpmn:businessRuleTask id="Task_BR" name="Evaluate Discount">
            <bpmn:outgoing>Flow_out</bpmn:outgoing>
          </bpmn:businessRuleTask>
        </bpmn:process>
      </bpmn:definitions>
      """

      diagram = Diagram.load(xml)
      tasks = Scaffold.extract_tasks(diagram)

      assert [
               %{
                 id: "Task_BR",
                 name: "Evaluate Discount",
                 bpmn_type: :bpmn_activity_task_business_rule
               }
             ] =
               tasks
    end

    test "behaviour_for_type returns BusinessRule.Handler" do
      {module, callback, _sig} =
        Scaffold.behaviour_for_type(:bpmn_activity_task_business_rule)

      assert module == Rodar.Activity.Task.BusinessRule.Handler
      assert callback == :execute
    end

    test "registration_type returns :handler_map" do
      assert :handler_map =
               Scaffold.registration_type(:bpmn_activity_task_business_rule)
    end

    test "generate_module produces correct scaffold" do
      task = %{
        id: "Task_BR",
        name: "Evaluate Discount",
        bpmn_type: :bpmn_activity_task_business_rule
      }

      {_name, _file, content} = Scaffold.generate_module(task, "MyApp.Handlers")
      assert content =~ "@behaviour Rodar.Activity.Task.BusinessRule.Handler"
      assert content =~ "def execute(_attrs, _data)"
    end
  end
end
