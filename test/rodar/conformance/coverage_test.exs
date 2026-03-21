defmodule Rodar.Conformance.CoverageTest do
  use ExUnit.Case, async: true

  alias Rodar.Conformance.TestHelper

  @moduletag :conformance

  @supported_types [
    :bpmn_event_start,
    :bpmn_event_end,
    :bpmn_event_intermediate_throw,
    :bpmn_event_intermediate_catch,
    :bpmn_event_boundary,
    :bpmn_activity_task,
    :bpmn_activity_task_user,
    :bpmn_activity_task_script,
    :bpmn_activity_task_service,
    :bpmn_activity_task_business_rule,
    :bpmn_activity_task_send,
    :bpmn_activity_task_receive,
    :bpmn_activity_task_manual,
    :bpmn_activity_subprocess,
    :bpmn_activity_subprocess_embeded,
    :bpmn_gateway_exclusive,
    :bpmn_gateway_parallel,
    :bpmn_gateway_inclusive,
    :bpmn_gateway_complex,
    :bpmn_gateway_exclusive_event,
    :bpmn_sequence_flow
  ]

  describe "element type coverage" do
    test "reports supported element types found in MIWG B.2.0" do
      diagram = TestHelper.load_fixture(:miwg, "B.2.0.bpmn")

      all_types =
        diagram.processes
        |> Enum.flat_map(fn {:bpmn_process, _, elements} ->
          Enum.map(elements, fn {_id, {type, _}} -> type end)
        end)
        |> Enum.uniq()

      supported = Enum.filter(all_types, &(&1 in @supported_types))
      unsupported = all_types -- @supported_types

      coverage = length(supported) / length(all_types) * 100

      assert coverage > 50.0,
             "Expected >50% element type coverage, got #{Float.round(coverage, 1)}%"

      IO.puts("\n--- BPMN Element Type Coverage (B.2.0) ---")

      IO.puts(
        "Supported: #{length(supported)}/#{length(all_types)} types " <>
          "(#{Float.round(coverage, 1)}%)"
      )

      IO.puts("Supported types: #{inspect(Enum.sort(supported))}")

      unless Enum.empty?(unsupported) do
        IO.puts("Unsupported types: #{inspect(Enum.sort(unsupported))}")
      end
    end

    test "all execution fixtures parse without errors" do
      fixtures = [
        "01_sequential_flow.bpmn",
        "02_exclusive_gateway.bpmn",
        "03_parallel_gateway.bpmn",
        "04_inclusive_gateway.bpmn",
        "05_timer_event.bpmn",
        "06_message_event.bpmn",
        "07_signal_event.bpmn",
        "08_error_boundary.bpmn",
        "09_compensation.bpmn",
        "10_embedded_subprocess.bpmn",
        "11_script_task.bpmn",
        "12_event_based_gateway.bpmn"
      ]

      for fixture <- fixtures do
        diagram = TestHelper.load_fixture(:execution, fixture)
        assert is_map(diagram), "Failed to parse #{fixture}"
        assert diagram.processes != [], "No processes in #{fixture}"
      end
    end

    test "all MIWG fixtures parse without errors" do
      # Fixtures that our parser fully supports
      fixtures = [
        "A.1.0.bpmn",
        "A.2.0.bpmn",
        "A.2.1.bpmn",
        "A.3.0.bpmn",
        "A.4.0.bpmn",
        "B.1.0.bpmn",
        "B.2.0.bpmn",
        "C.2.0.bpmn",
        "C.4.0.bpmn",
        "C.5.0.bpmn",
        "C.6.0.bpmn",
        "C.7.0.bpmn",
        "C.8.0.bpmn",
        "C.8.1.bpmn",
        "C.9.0.bpmn",
        "C.9.1.bpmn",
        "C.9.2.bpmn"
      ]

      for fixture <- fixtures do
        diagram = TestHelper.load_fixture(:miwg, fixture)
        assert is_map(diagram), "Failed to parse #{fixture}"
        assert diagram.processes != [], "No processes in #{fixture}"
      end
    end

    test "MIWG fixtures requiring extended namespace support parse without crash" do
      # These files use namespace conventions our parser doesn't fully handle yet,
      # resulting in 0 processes. We verify they don't crash.
      fixtures = ["A.4.1.bpmn", "C.1.0.bpmn", "C.1.1.bpmn", "C.3.0.bpmn"]

      for fixture <- fixtures do
        diagram = TestHelper.load_fixture(:miwg, fixture)
        assert is_map(diagram), "Failed to parse #{fixture}"
      end
    end
  end
end
