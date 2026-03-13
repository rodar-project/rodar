defmodule Rodar.Conformance.ExecutionTest do
  use ExUnit.Case, async: false

  alias Rodar.{
    Compensation,
    Context,
    Event.Bus,
    Event.Intermediate.Catch,
    Event.Timer,
    TaskRegistry
  }

  alias Rodar.Conformance.{ErrorHandler, PassThroughHandler, TestHelper}

  @moduletag :conformance

  setup do
    TaskRegistry.register(:bpmn_activity_task, PassThroughHandler)
    on_exit(fn -> TaskRegistry.unregister(:bpmn_activity_task) end)
  end

  describe "01 — Sequential Flow" do
    test "executes all tasks in sequence" do
      diagram = TestHelper.load_fixture(:execution, "01_sequential_flow.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_A", "Task_B", "End_1"])
    end
  end

  describe "02 — Exclusive Gateway" do
    test "takes path A when choice is A" do
      diagram = TestHelper.load_fixture(:execution, "02_exclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements, %{"choice" => "A"})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_A", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_B", "Task_Default"])
    end

    test "takes path B when choice is B" do
      diagram = TestHelper.load_fixture(:execution, "02_exclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements, %{"choice" => "B"})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_B", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_A", "Task_Default"])
    end

    test "takes default path when no condition matches" do
      diagram = TestHelper.load_fixture(:execution, "02_exclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements, %{"choice" => "Z"})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_Default", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_A", "Task_B"])
    end
  end

  describe "03 — Parallel Gateway" do
    test "executes both branches and joins" do
      diagram = TestHelper.load_fixture(:execution, "03_parallel_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_A", "Task_B", "PGW_Join", "End_1"])
    end
  end

  describe "04 — Inclusive Gateway" do
    test "activates both paths when both flags are true" do
      diagram = TestHelper.load_fixture(:execution, "04_inclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)

      {result, context} =
        TestHelper.execute_from_start(elements, %{"flag_a" => true, "flag_b" => true})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_A", "Task_B", "IGW_Join", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_C"])
    end

    test "activates only path A when only flag_a is true" do
      diagram = TestHelper.load_fixture(:execution, "04_inclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)

      {result, context} =
        TestHelper.execute_from_start(elements, %{"flag_a" => true, "flag_b" => false})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_A", "IGW_Join", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_B", "Task_C"])
    end

    test "takes default path when no conditions match" do
      diagram = TestHelper.load_fixture(:execution, "04_inclusive_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)

      {result, context} =
        TestHelper.execute_from_start(elements, %{"flag_a" => false, "flag_b" => false})

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_C", "IGW_Join", "End_1"])
      TestHelper.assert_not_visited(context, ["Task_A", "Task_B"])
    end
  end

  describe "05 — Timer Catch Event" do
    test "pauses at timer catch event" do
      # Build a timer catch programmatically since PT0S is not supported by the parser
      timer_catch =
        {:bpmn_event_intermediate_catch,
         %{
           id: "Timer_Catch",
           outgoing: ["Flow_3"],
           messageEventDefinition: nil,
           signalEventDefinition: nil,
           timerEventDefinition: {:bpmn_event_definition_timer, %{timeDuration: "PT1S"}}
         }}

      {:ok, context} = Context.start_link(%{}, %{})
      {:manual, task_data} = Catch.token_in(timer_catch, context)

      assert task_data.id == "Timer_Catch"
      assert task_data.type == :timer_catch
      assert task_data.duration_ms == 1000

      # Verify the timer metadata was set
      meta = Context.get_meta(context, "Timer_Catch")
      assert meta.active == true
      assert meta.completed == false

      # Cancel the timer to avoid side effects
      if meta[:timer_ref], do: Timer.cancel(meta.timer_ref)
    end
  end

  describe "06 — Message Catch Event" do
    test "pauses at message catch and subscription is created" do
      msg_name = "order_ready_#{:erlang.unique_integer()}"

      catch_event =
        {:bpmn_event_intermediate_catch,
         %{
           id: "Msg_Catch",
           outgoing: ["Flow_2"],
           messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: msg_name}},
           signalEventDefinition: nil,
           timerEventDefinition: nil
         }}

      {:ok, context} = Context.start_link(%{}, %{})
      {:manual, task_data} = Catch.token_in(catch_event, context)

      assert task_data.id == "Msg_Catch"
      assert task_data.type == :message_catch

      # Verify subscription exists
      subs = Bus.subscriptions(:message, msg_name)
      assert length(subs) == 1

      # Publish message to consume the subscription
      Bus.publish(:message, msg_name, %{})
      Process.sleep(50)

      # Subscription should be consumed (point-to-point)
      assert Bus.subscriptions(:message, msg_name) == []
    end

    test "pauses execution at message catch from parsed fixture" do
      diagram = TestHelper.load_fixture(:execution, "06_message_event.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:manual, _} = result
      TestHelper.assert_visited(context, ["Msg_Catch"])
      TestHelper.assert_not_visited(context, ["Task_A"])
    end
  end

  describe "07 — Signal Event" do
    test "signal catch subscribes and broadcast publishes to all" do
      sig_name = "alert_signal_#{:erlang.unique_integer()}"

      catch1 =
        {:bpmn_event_intermediate_catch,
         %{
           id: "catch1",
           outgoing: ["f1"],
           messageEventDefinition: nil,
           signalEventDefinition: {:bpmn_event_definition_signal, %{signalRef: sig_name}},
           timerEventDefinition: nil
         }}

      catch2 =
        {:bpmn_event_intermediate_catch,
         %{
           id: "catch2",
           outgoing: ["f2"],
           messageEventDefinition: nil,
           signalEventDefinition: {:bpmn_event_definition_signal, %{signalRef: sig_name}},
           timerEventDefinition: nil
         }}

      {:ok, ctx1} = Context.start_link(%{}, %{})
      {:ok, ctx2} = Context.start_link(%{}, %{})

      {:manual, _} = Catch.token_in(catch1, ctx1)
      {:manual, _} = Catch.token_in(catch2, ctx2)

      # Both subscriptions exist (signal = broadcast, not consumed)
      subs = Bus.subscriptions(:signal, sig_name)
      assert length(subs) == 2

      # Verify subscription metadata contains correct node_id
      node_ids = Enum.map(subs, & &1.node_id) |> Enum.sort()
      assert node_ids == ["catch1", "catch2"]

      # Broadcast signal — returns :ok (no errors)
      assert :ok = Bus.publish(:signal, sig_name, %{})
    end

    test "signal from parsed fixture pauses at catch event" do
      diagram = TestHelper.load_fixture(:execution, "07_signal_event.bpmn")

      # The catch process has a signal catch event
      catch_process =
        Enum.find(diagram.processes, fn {:bpmn_process, attrs, _} ->
          attrs[:id] == "Process_07_catch"
        end)

      {:bpmn_process, _attrs, catch_elements} = catch_process
      {result, context} = TestHelper.execute_from_start(catch_elements)

      # Catch event pauses at signal subscription (returns :manual)
      assert {:manual, _} = result
      TestHelper.assert_visited(context, ["Signal_Catch"])
    end
  end

  describe "08 — Error Boundary Event" do
    test "error in subprocess activates error boundary path" do
      # Register an error handler for the risky task
      TaskRegistry.register("Task_Main", ErrorHandler)
      on_exit(fn -> TaskRegistry.unregister("Task_Main") end)

      diagram = TestHelper.load_fixture(:execution, "08_error_boundary.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_Error", "End_Error"])
      TestHelper.assert_not_visited(context, ["Task_Normal", "End_Normal"])
    end

    test "successful subprocess takes normal path" do
      diagram = TestHelper.load_fixture(:execution, "08_error_boundary.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_Normal", "End_Normal"])
      TestHelper.assert_not_visited(context, ["Task_Error", "End_Error"])
    end
  end

  describe "09 — Compensation (programmatic)" do
    test "compensation handlers execute in reverse order" do
      end_event = {:bpmn_event_end, %{id: "end", incoming: ["f3"], outgoing: []}}

      f1 =
        {:bpmn_sequence_flow,
         %{
           id: "f1",
           sourceRef: "start",
           targetRef: "task_a",
           conditionExpression: nil,
           isImmediate: nil
         }}

      task_a =
        {:bpmn_activity_task, %{id: "task_a", name: "Book", incoming: ["f1"], outgoing: ["f2"]}}

      f2 =
        {:bpmn_sequence_flow,
         %{
           id: "f2",
           sourceRef: "task_a",
           targetRef: "task_b",
           conditionExpression: nil,
           isImmediate: nil
         }}

      task_b =
        {:bpmn_activity_task,
         %{id: "task_b", name: "Confirm", incoming: ["f2"], outgoing: ["f3"]}}

      f3 =
        {:bpmn_sequence_flow,
         %{
           id: "f3",
           sourceRef: "task_b",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }}

      start = {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}}

      # Compensation handler tasks (no outgoing — they are leaf nodes)
      comp_a =
        {:bpmn_activity_task, %{id: "comp_a", name: "Cancel Book", incoming: [], outgoing: []}}

      comp_b =
        {:bpmn_activity_task, %{id: "comp_b", name: "Cancel Confirm", incoming: [], outgoing: []}}

      process = %{
        "start" => start,
        "f1" => f1,
        "task_a" => task_a,
        "f2" => f2,
        "task_b" => task_b,
        "f3" => f3,
        "end" => end_event,
        "comp_a" => comp_a,
        "comp_b" => comp_b
      }

      {:ok, context} = Context.start_link(process, %{})

      # Execute the process
      result = Rodar.execute(start, context)
      assert {:ok, _} = result

      # Manually register compensation handlers
      Compensation.register_handler(context, "task_a", "comp_a")
      Compensation.register_handler(context, "task_b", "comp_b")

      # Verify handlers are registered
      handlers = Compensation.handlers(context)
      assert length(handlers) == 2

      # Execute compensation for all (reverse order)
      assert {:ok, _} = Compensation.compensate_all(context)

      # Verify compensation handlers were visited
      TestHelper.assert_visited(context, ["comp_b", "comp_a"])
    end
  end

  describe "10 — Embedded Subprocess" do
    test "executes subprocess elements and continues" do
      diagram = TestHelper.load_fixture(:execution, "10_embedded_subprocess.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      assert {:ok, _} = result
      TestHelper.assert_visited(context, ["Task_Before", "Sub_1", "Task_After", "End_1"])
    end
  end

  describe "11 — Script Task (programmatic)" do
    test "executes elixir script and stores result" do
      # Build programmatically because the parser uses :scriptFormat
      # but the handler expects :type
      end_event = {:bpmn_event_end, %{id: "end", incoming: ["f2"], outgoing: []}}

      f1 =
        {:bpmn_sequence_flow,
         %{
           id: "f1",
           sourceRef: "start",
           targetRef: "script1",
           conditionExpression: nil,
           isImmediate: nil
         }}

      script_task =
        {:bpmn_activity_task_script,
         %{
           id: "script1",
           outgoing: ["f2"],
           type: "elixir",
           script: ~S|data["x"] + data["y"]|
         }}

      f2 =
        {:bpmn_sequence_flow,
         %{
           id: "f2",
           sourceRef: "script1",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }}

      start = {:bpmn_event_start, %{id: "start", incoming: [], outgoing: ["f1"]}}

      process = %{
        "start" => start,
        "f1" => f1,
        "script1" => script_task,
        "f2" => f2,
        "end" => end_event
      }

      {:ok, context} = Context.start_link(process, %{})
      Context.put_data(context, "x", 10)
      Context.put_data(context, "y", 32)

      result = Rodar.execute(start, context)
      assert {:ok, _} = result

      TestHelper.assert_visited(context, ["script1", "end"])
      assert Context.get_data(context, :script_result) == 42
    end
  end

  describe "12 — Event-Based Gateway" do
    test "returns manual for event-based gateway awaiting events" do
      diagram = TestHelper.load_fixture(:execution, "12_event_based_gateway.bpmn")
      elements = TestHelper.first_process_elements(diagram)
      {result, context} = TestHelper.execute_from_start(elements)

      # Event-based gateway returns {:manual, _} setting up catch events
      assert {:manual, _} = result
      TestHelper.assert_visited(context, ["EBG_1"])
    end
  end
end
