defmodule Rodar.Activity.DataMapperTest do
  use ExUnit.Case, async: true

  alias Rodar.Activity.DataMapper
  alias Rodar.Activity.Task.Service
  alias Rodar.Activity.Task.User
  alias Rodar.Context

  # Helper to build a minimal process with an end event and flow
  defp build_process do
    %{
      "flow_out" =>
        {:bpmn_sequence_flow,
         %{
           id: "flow_out",
           sourceRef: "task",
           targetRef: "end",
           conditionExpression: nil,
           isImmediate: nil
         }},
      "end" => {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
    }
  end

  defp start_context(data \\ %{}) do
    {:ok, ctx} = Context.start_link(build_process(), %{})

    Enum.each(data, fn {key, value} ->
      Context.put_data(ctx, key, value)
    end)

    ctx
  end

  defp io_spec do
    {:bpmn_io_specification,
     %{
       dataInput: [{:bpmn_data_input, %{id: "din_1", name: "order_id"}}],
       dataOutput: [{:bpmn_data_output, %{id: "dout_1", name: "result"}}],
       inputSet: [],
       outputSet: []
     }}
  end

  defp input_assoc(source_ref, target_ref) do
    {:bpmn_data_input_association,
     %{
       id: "dia_#{source_ref}",
       sourceRef: source_ref,
       targetRef: target_ref,
       dataInputRefs: [],
       assignment: []
     }}
  end

  defp output_assoc(source_ref, target_ref) do
    {:bpmn_data_output_association,
     %{
       id: "doa_#{source_ref}",
       sourceRef: source_ref,
       targetRef: target_ref,
       dataOutputRefs: [],
       assignment: []
     }}
  end

  defp assignment(from, to) do
    {:bpmn_assignment,
     %{
       from: {:bpmn_from, %{content: from}},
       to: {:bpmn_to, %{content: to}}
     }}
  end

  describe "has_io_spec?/1" do
    test "returns false when ioSpecification is empty list" do
      refute DataMapper.has_io_spec?(%{ioSpecification: []})
    end

    test "returns false when ioSpecification is missing" do
      refute DataMapper.has_io_spec?(%{})
    end

    test "returns true when ioSpecification is present" do
      assert DataMapper.has_io_spec?(%{ioSpecification: [io_spec()]})
    end
  end

  describe "map_inputs/2" do
    test "returns full context data when no ioSpecification" do
      ctx = start_context(%{order_id: 42, name: "test"})
      attrs = %{ioSpecification: [], dataInputAssociation: []}

      result = DataMapper.map_inputs(attrs, ctx)
      assert result == %{order_id: 42, name: "test"}
    end

    test "scopes data through input associations" do
      ctx = start_context(%{"order_id" => 42, "name" => "test", "extra" => "ignored"})

      attrs = %{
        ioSpecification: [io_spec()],
        dataInputAssociation: [input_assoc("order_id", "din_1")]
      }

      result = DataMapper.map_inputs(attrs, ctx)
      # Only the mapped key is present; target_ref is used as key when no assignment
      assert result == %{"din_1" => 42}
    end

    test "returns empty map when ioSpecification present but no associations" do
      ctx = start_context(%{"order_id" => 42})
      attrs = %{ioSpecification: [io_spec()], dataInputAssociation: []}

      result = DataMapper.map_inputs(attrs, ctx)
      assert result == %{}
    end

    test "uses assignment from/to to remap keys" do
      ctx = start_context(%{"order_id" => 42, "extra" => "ignored"})

      assoc =
        {:bpmn_data_input_association,
         %{
           id: "dia_1",
           sourceRef: nil,
           targetRef: nil,
           dataInputRefs: [],
           assignment: [assignment("order_id", "mapped_order")]
         }}

      attrs = %{ioSpecification: [io_spec()], dataInputAssociation: [assoc]}

      result = DataMapper.map_inputs(attrs, ctx)
      assert result == %{"mapped_order" => 42}
      refute Map.has_key?(result, "extra")
    end

    test "handles multiple input associations" do
      ctx = start_context(%{"a" => 1, "b" => 2, "c" => 3})

      attrs = %{
        ioSpecification: [io_spec()],
        dataInputAssociation: [
          input_assoc("a", "input_a"),
          input_assoc("b", "input_b")
        ]
      }

      result = DataMapper.map_inputs(attrs, ctx)
      assert result == %{"input_a" => 1, "input_b" => 2}
      refute Map.has_key?(result, "c")
    end

    test "returns nil for missing source keys" do
      ctx = start_context(%{})

      attrs = %{
        ioSpecification: [io_spec()],
        dataInputAssociation: [input_assoc("missing_key", "din_1")]
      }

      result = DataMapper.map_inputs(attrs, ctx)
      assert result == %{"din_1" => nil}
    end
  end

  describe "map_outputs/3" do
    test "writes all result keys when no ioSpecification" do
      ctx = start_context()
      attrs = %{ioSpecification: [], dataOutputAssociation: []}

      DataMapper.map_outputs(attrs, %{status: "done", count: 5}, ctx)

      assert Context.get_data(ctx, :status) == "done"
      assert Context.get_data(ctx, :count) == 5
    end

    test "maps result keys through output associations" do
      ctx = start_context()

      attrs = %{
        ioSpecification: [io_spec()],
        dataOutputAssociation: [output_assoc("handler_result", "order_status")]
      }

      DataMapper.map_outputs(attrs, %{"handler_result" => "approved"}, ctx)

      assert Context.get_data(ctx, "order_status") == "approved"
      # The raw key should not be written
      assert Context.get_data(ctx, "handler_result") == nil
    end

    test "uses assignment from/to to remap output keys" do
      ctx = start_context()

      assoc =
        {:bpmn_data_output_association,
         %{
           id: "doa_1",
           sourceRef: nil,
           targetRef: nil,
           dataOutputRefs: [],
           assignment: [assignment("result_code", "status_code")]
         }}

      attrs = %{ioSpecification: [io_spec()], dataOutputAssociation: [assoc]}

      DataMapper.map_outputs(attrs, %{"result_code" => 200}, ctx)

      assert Context.get_data(ctx, "status_code") == 200
    end

    test "handles multiple output associations" do
      ctx = start_context()

      attrs = %{
        ioSpecification: [io_spec()],
        dataOutputAssociation: [
          output_assoc("status", "order_status"),
          output_assoc("total", "order_total")
        ]
      }

      DataMapper.map_outputs(attrs, %{"status" => "ok", "total" => 99}, ctx)

      assert Context.get_data(ctx, "order_status") == "ok"
      assert Context.get_data(ctx, "order_total") == 99
    end

    test "handles non-map result gracefully" do
      ctx = start_context()
      attrs = %{ioSpecification: [io_spec()], dataOutputAssociation: []}

      assert DataMapper.map_outputs(attrs, "not a map", ctx) == :ok
    end
  end

  describe "integration with service task" do
    defmodule EchoHandler do
      @behaviour Rodar.Activity.Task.Service.Handler

      @impl true
      def execute(_attrs, data), do: {:ok, data}
    end

    test "service task with ioSpecification receives only mapped inputs" do
      process = build_process()
      {:ok, ctx} = Context.start_link(process, %{})
      Context.put_data(ctx, "order_id", 42)
      Context.put_data(ctx, "secret", "hidden")

      # Register a handler that echoes back the data it receives
      defmodule CaptureHandler do
        @behaviour Rodar.Activity.Task.Service.Handler

        @impl true
        def execute(_attrs, data) do
          send(self(), {:captured_data, data})
          {:ok, %{"echoed" => true}}
        end
      end

      elem =
        {:bpmn_activity_task_service,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: CaptureHandler,
           ioSpecification: [io_spec()],
           dataInputAssociation: [input_assoc("order_id", "mapped_id")],
           dataOutputAssociation: [output_assoc("echoed", "was_echoed")]
         }}

      {:ok, _ctx} = Service.token_in(elem, ctx)

      assert_received {:captured_data, captured}
      assert captured == %{"mapped_id" => 42}
      refute Map.has_key?(captured, "secret")

      # Output should be mapped
      assert Context.get_data(ctx, "was_echoed") == true
    end

    test "service task without ioSpecification passes full data (backward compat)" do
      process = build_process()
      {:ok, ctx} = Context.start_link(process, %{})
      Context.put_data(ctx, "order_id", 42)
      Context.put_data(ctx, "secret", "visible")

      defmodule FullDataHandler do
        @behaviour Rodar.Activity.Task.Service.Handler

        @impl true
        def execute(_attrs, data) do
          send(self(), {:full_data, data})
          {:ok, %{result: "done"}}
        end
      end

      elem =
        {:bpmn_activity_task_service,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: FullDataHandler,
           ioSpecification: [],
           dataInputAssociation: [],
           dataOutputAssociation: []
         }}

      {:ok, _ctx} = Service.token_in(elem, ctx)

      assert_received {:full_data, data}
      assert data == %{"order_id" => 42, "secret" => "visible"}

      # Output should be written directly
      assert Context.get_data(ctx, :result) == "done"
    end
  end

  describe "integration with user task" do
    test "user task with ioSpecification includes mapped data" do
      process = build_process()
      {:ok, ctx} = Context.start_link(process, %{})
      Context.put_data(ctx, "name", "Alice")
      Context.put_data(ctx, "internal", "hidden")

      elem =
        {:bpmn_activity_task_user,
         %{
           id: "task",
           name: "Review",
           outgoing: ["flow_out"],
           ioSpecification: [io_spec()],
           dataInputAssociation: [input_assoc("name", "user_name")],
           dataOutputAssociation: [output_assoc("approved", "is_approved")]
         }}

      {:manual, task_data} = User.token_in(elem, ctx)

      assert task_data.data == %{"user_name" => "Alice"}
      refute Map.has_key?(task_data.data, "internal")

      # Resume with output mapping
      {:ok, _ctx} = User.resume(elem, ctx, %{"approved" => true})

      assert Context.get_data(ctx, "is_approved") == true
      assert Context.get_data(ctx, "approved") == nil
    end

    test "user task without ioSpecification passes full data (backward compat)" do
      process = build_process()
      {:ok, ctx} = Context.start_link(process, %{})
      Context.put_data(ctx, "name", "Alice")

      elem =
        {:bpmn_activity_task_user,
         %{
           id: "task",
           name: "Review",
           outgoing: ["flow_out"],
           ioSpecification: [],
           dataInputAssociation: [],
           dataOutputAssociation: []
         }}

      {:manual, task_data} = User.token_in(elem, ctx)

      assert task_data.data == %{"name" => "Alice"}
    end
  end
end
