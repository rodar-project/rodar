defmodule Rodar.Event.End.PublishingTest do
  use ExUnit.Case, async: true

  alias Rodar.Context
  alias Rodar.Event.{Bus, End}

  describe "message end event" do
    test "publishes message to event bus" do
      {:ok, context} = Context.start_link(%{}, %{})
      Context.put_data(context, :order_id, "ORD-1")
      msg_name = "order_completed_#{:erlang.unique_integer()}"

      Bus.subscribe(:message, msg_name, %{node_id: "catch_1"})

      end_event =
        {:bpmn_event_end,
         %{
           id: "end_msg",
           incoming: ["flow_1"],
           messageEventDefinition: {:bpmn_event_definition_message, %{messageRef: msg_name}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :message, ^msg_name,
                      %{source: "end_msg", data: %{order_id: "ORD-1"}}, %{node_id: "catch_1"}}
    end

    test "uses element id as message name when messageRef is absent" do
      {:ok, context} = Context.start_link(%{}, %{})
      element_id = "end_msg_fallback_#{:erlang.unique_integer()}"

      Bus.subscribe(:message, element_id, %{node_id: "catch_1"})

      end_event =
        {:bpmn_event_end,
         %{
           id: element_id,
           incoming: ["flow_1"],
           messageEventDefinition: {:bpmn_event_definition_message, %{}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :message, ^element_id, %{source: ^element_id}, _}
    end

    test "includes correlation key when present" do
      {:ok, context} = Context.start_link(%{}, %{})
      Context.put_data(context, :order_id, "ORD-42")
      msg_name = "correlated_msg_#{:erlang.unique_integer()}"

      Bus.subscribe(:message, msg_name, %{
        node_id: "catch_1",
        correlation: %{key: :order_id, value: "ORD-42"}
      })

      end_event =
        {:bpmn_event_end,
         %{
           id: "end_corr",
           incoming: ["flow_1"],
           messageEventDefinition:
             {:bpmn_event_definition_message, %{messageRef: msg_name, correlationKey: :order_id}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :message, ^msg_name,
                      %{
                        source: "end_corr",
                        correlation: %{key: :order_id, value: "ORD-42"}
                      }, _}
    end
  end

  describe "signal end event" do
    test "publishes signal to event bus (broadcast)" do
      {:ok, context} = Context.start_link(%{}, %{})
      Context.put_data(context, :status, "done")
      signal_name = "process_ended_#{:erlang.unique_integer()}"

      Bus.subscribe(:signal, signal_name, %{node_id: "catch_sig"})

      end_event =
        {:bpmn_event_end,
         %{
           id: "end_sig",
           incoming: ["flow_1"],
           signalEventDefinition: {:bpmn_event_definition_signal, %{signalRef: signal_name}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :signal, ^signal_name,
                      %{source: "end_sig", data: %{status: "done"}}, %{node_id: "catch_sig"}}
    end

    test "uses element id as signal name when signalRef is absent" do
      {:ok, context} = Context.start_link(%{}, %{})
      element_id = "end_sig_fallback_#{:erlang.unique_integer()}"

      Bus.subscribe(:signal, element_id, %{node_id: "catch_1"})

      end_event =
        {:bpmn_event_end,
         %{
           id: element_id,
           incoming: ["flow_1"],
           signalEventDefinition: {:bpmn_event_definition_signal, %{}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :signal, ^element_id, %{source: ^element_id}, _}
    end

    test "broadcasts to multiple subscribers" do
      {:ok, context} = Context.start_link(%{}, %{})
      signal_name = "broadcast_sig_#{:erlang.unique_integer()}"
      parent = self()

      Bus.subscribe(:signal, signal_name, %{node_id: "catch_1"})

      spawn(fn ->
        Bus.subscribe(:signal, signal_name, %{node_id: "catch_2"})
        send(parent, :subscribed)

        receive do
          msg -> send(parent, {:child_received, msg})
        end
      end)

      receive do
        :subscribed -> :ok
      end

      end_event =
        {:bpmn_event_end,
         %{
           id: "end_broadcast",
           incoming: ["flow_1"],
           signalEventDefinition: {:bpmn_event_definition_signal, %{signalRef: signal_name}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :signal, ^signal_name, _, %{node_id: "catch_1"}}

      assert_receive {:child_received,
                      {:bpmn_event, :signal, ^signal_name, _, %{node_id: "catch_2"}}}
    end
  end

  describe "escalation end event" do
    test "publishes escalation to event bus" do
      {:ok, context} = Context.start_link(%{}, %{})
      Context.put_data(context, :reason, "timeout")
      escalation_code = "esc_code_#{:erlang.unique_integer()}"

      Bus.subscribe(:escalation, escalation_code, %{node_id: "catch_esc"})

      end_event =
        {:bpmn_event_end,
         %{
           id: "end_esc",
           incoming: ["flow_1"],
           escalationEventDefinition:
             {:bpmn_event_definition_escalation, %{escalationRef: escalation_code}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :escalation, ^escalation_code,
                      %{source: "end_esc", data: %{reason: "timeout"}}, %{node_id: "catch_esc"}}
    end

    test "uses element id as escalation code when escalationRef is absent" do
      {:ok, context} = Context.start_link(%{}, %{})
      element_id = "end_esc_fallback_#{:erlang.unique_integer()}"

      Bus.subscribe(:escalation, element_id, %{node_id: "catch_1"})

      end_event =
        {:bpmn_event_end,
         %{
           id: element_id,
           incoming: ["flow_1"],
           escalationEventDefinition: {:bpmn_event_definition_escalation, %{}}
         }}

      assert {:ok, ^context} = End.token_in(end_event, context)

      assert_receive {:bpmn_event, :escalation, ^element_id, %{source: ^element_id}, _}
    end
  end
end
