defmodule Rodar.Activity.Subprocess.TransactionTest do
  use ExUnit.Case, async: true

  alias Rodar.Activity.Subprocess.Transaction
  alias Rodar.Compensation
  alias Rodar.Context
  alias Rodar.Engine.Diagram

  doctest Rodar.Activity.Subprocess.Transaction

  defp build_nested_elements do
    start = {:bpmn_event_start, %{id: "sub_start", incoming: [], outgoing: ["sub_flow"]}}
    sub_end = {:bpmn_event_end, %{id: "sub_end", incoming: ["sub_flow"], outgoing: []}}

    sub_flow =
      {:bpmn_sequence_flow,
       %{
         id: "sub_flow",
         sourceRef: "sub_start",
         targetRef: "sub_end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    %{"sub_start" => start, "sub_end" => sub_end, "sub_flow" => sub_flow}
  end

  defp build_cancel_nested_elements do
    start = {:bpmn_event_start, %{id: "sub_start", incoming: [], outgoing: ["sub_flow"]}}

    cancel_end =
      {:bpmn_event_end,
       %{
         id: "cancel_end",
         incoming: ["sub_flow"],
         outgoing: [],
         cancelEventDefinition: {:bpmn_event_definition_cancel, %{}}
       }}

    sub_flow =
      {:bpmn_sequence_flow,
       %{
         id: "sub_flow",
         sourceRef: "sub_start",
         targetRef: "cancel_end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    %{
      "sub_start" => start,
      "sub_flow" => sub_flow,
      "cancel_end" => cancel_end
    }
  end

  defp build_parent_process do
    end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}

    flow_out =
      {:bpmn_sequence_flow,
       %{
         id: "flow_out",
         sourceRef: "txn",
         targetRef: "end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    %{"flow_out" => flow_out, "end" => end_event}
  end

  defp build_parent_with_cancel_boundary do
    end_ok = {:bpmn_event_end, %{id: "end_ok", incoming: ["flow_out"], outgoing: []}}

    flow_out =
      {:bpmn_sequence_flow,
       %{
         id: "flow_out",
         sourceRef: "txn",
         targetRef: "end_ok",
         conditionExpression: nil,
         isImmediate: nil
       }}

    end_cancelled =
      {:bpmn_event_end, %{id: "end_cancelled", incoming: ["flow_cancel"], outgoing: []}}

    flow_cancel =
      {:bpmn_sequence_flow,
       %{
         id: "flow_cancel",
         sourceRef: "boundary_cancel",
         targetRef: "end_cancelled",
         conditionExpression: nil,
         isImmediate: nil
       }}

    boundary =
      {:bpmn_event_boundary,
       %{
         id: "boundary_cancel",
         outgoing: ["flow_cancel"],
         attachedToRef: "txn",
         cancelEventDefinition: {:bpmn_event_definition_cancel, %{}},
         errorEventDefinition: nil,
         messageEventDefinition: nil,
         signalEventDefinition: nil,
         timerEventDefinition: nil,
         escalationEventDefinition: nil,
         conditionalEventDefinition: nil,
         compensateEventDefinition: nil
       }}

    %{
      "flow_out" => flow_out,
      "end_ok" => end_ok,
      "flow_cancel" => flow_cancel,
      "end_cancelled" => end_cancelled,
      "boundary_cancel" => boundary
    }
  end

  describe "token_in/2" do
    test "normal transaction completes and releases token to parent" do
      nested = build_nested_elements()
      process = build_parent_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      assert {:ok, ^context} = Transaction.token_in(elem, context)

      meta = Context.get_meta(context, "txn")
      assert meta.active == false
      assert meta.completed == true
      assert meta.type == :transaction
    end

    test "cancel end event triggers cancel boundary event" do
      nested = build_cancel_nested_elements()
      process = build_parent_with_cancel_boundary()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      assert {:ok, ^context} = Transaction.token_in(elem, context)

      meta = Context.get_meta(context, "txn")
      assert meta.cancelled == true
      assert meta.active == false
    end

    test "cancel end event triggers scoped compensation" do
      nested = build_cancel_nested_elements()
      process = build_parent_with_cancel_boundary()
      {:ok, context} = Context.start_link(process, %{})

      # Pre-register compensation handlers: one inside scope, one outside
      Compensation.register_handler(context, "sub_start", "compensate_start")
      Compensation.register_handler(context, "outer_task", "compensate_outer")

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      Transaction.token_in(elem, context)

      # After cancel with scoped compensation, the outer handler should remain
      remaining = Compensation.handlers(context)
      assert Enum.any?(remaining, &(&1.activity_id == "outer_task"))
    end

    test "returns error when no start event" do
      nested = %{
        "sub_end" => {:bpmn_event_end, %{id: "sub_end", incoming: [], outgoing: []}}
      }

      process = build_parent_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      assert {:error, "Transaction subprocess 'txn': no start event found"} =
               Transaction.token_in(elem, context)
    end

    test "restores parent process after execution" do
      nested = build_nested_elements()
      process = build_parent_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      {:ok, ^context} = Transaction.token_in(elem, context)

      current_process = Context.get(context, :process)
      assert Map.has_key?(current_process, "flow_out")
      assert Map.has_key?(current_process, "end")
    end

    test "clears transaction scope and cancelled flag after execution" do
      nested = build_cancel_nested_elements()
      process = build_parent_with_cancel_boundary()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_subprocess_transaction,
         %{id: "txn", outgoing: ["flow_out"], elements: nested}}

      Transaction.token_in(elem, context)

      assert Context.get_meta(context, :transaction_scope) == nil
      assert Context.get_meta(context, :cancelled) == nil
    end
  end

  describe "parsing" do
    test "parses transaction from BPMN XML" do
      xml = File.read!("./test/fixtures/conformance/execution/15_transaction.bpmn")
      diagram = Diagram.load(xml)
      {:bpmn_process, _attrs, elements} = hd(diagram.processes)

      assert {:bpmn_activity_subprocess_transaction, txn_attrs} = elements["Txn_1"]
      assert txn_attrs.id == "Txn_1"
      assert is_map(txn_attrs.elements)

      # Verify nested elements were parsed
      assert Map.has_key?(txn_attrs.elements, "Txn_Start")
      assert Map.has_key?(txn_attrs.elements, "Task_Book")
      assert Map.has_key?(txn_attrs.elements, "Txn_Cancel_End")

      # Verify cancel end event has cancelEventDefinition
      {:bpmn_event_end, cancel_attrs} = txn_attrs.elements["Txn_Cancel_End"]
      assert {:bpmn_event_definition_cancel, _} = cancel_attrs.cancelEventDefinition

      # Verify cancel boundary event
      {:bpmn_event_boundary, boundary_attrs} = elements["Boundary_Cancel"]
      assert {:bpmn_event_definition_cancel, _} = boundary_attrs.cancelEventDefinition
      assert boundary_attrs.attachedToRef == "Txn_1"
    end

    test "round-trips transaction through export" do
      xml = File.read!("./test/fixtures/conformance/execution/15_transaction.bpmn")
      diagram = Diagram.load(xml)
      exported = Diagram.export(diagram)

      assert String.contains?(exported, "bpmn2:transaction")
      assert String.contains?(exported, "bpmn2:cancelEventDefinition")

      # Re-parse the exported XML
      re_parsed = Diagram.load(exported)
      {:bpmn_process, _attrs, elements} = hd(re_parsed.processes)

      assert {:bpmn_activity_subprocess_transaction, _} = elements["Txn_1"]
    end
  end
end
