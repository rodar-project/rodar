defmodule Rodar.Activity.Task.ServiceTest do
  use ExUnit.Case, async: true

  alias Rodar.{Activity.Task.Service, Context}

  doctest Rodar.Activity.Task.Service

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

  defp build_process_with_error_boundary do
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

    error_end = {:bpmn_event_end, %{id: "error_end", incoming: ["error_flow"], outgoing: []}}

    error_flow =
      {:bpmn_sequence_flow,
       %{
         id: "error_flow",
         sourceRef: "error_boundary",
         targetRef: "error_end",
         conditionExpression: nil,
         isImmediate: nil
       }}

    error_boundary =
      {:bpmn_event_boundary,
       %{
         id: "error_boundary",
         attachedToRef: "task",
         cancelActivity: "true",
         incoming: [],
         outgoing: ["error_flow"],
         errorEventDefinition: {:bpmn_event_definition_error, %{errorRef: "err1"}}
       }}

    %{
      "flow_out" => flow_out,
      "end" => end_event,
      "error_flow" => error_flow,
      "error_end" => error_end,
      "error_boundary" => error_boundary
    }
  end

  describe "with a handler that returns {:ok, map}" do
    test "invokes handler and merges result into context" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service,
         %{
           id: "task",
           outgoing: ["flow_out"],
           handler: Service.TestHandler
         }}

      assert {:ok, ^context} = Service.token_in(elem, context)
      assert Context.get_data(context, :result) == "handled"
    end
  end

  describe "with a handler that returns {:error, reason}" do
    defmodule ErrorHandler do
      @moduledoc false
      @behaviour Service.Handler

      @impl true
      def execute(_attrs, _data), do: {:error, "something went wrong"}
    end

    test "returns the error" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service,
         %{id: "task", outgoing: ["flow_out"], handler: ErrorHandler}}

      assert {:error, "something went wrong"} =
               Service.token_in(elem, context)
    end
  end

  describe "with a handler that returns {:bpmn_error, code, message}" do
    defmodule BpmnErrorHandler do
      @moduledoc false
      @behaviour Service.Handler

      @impl true
      def execute(_attrs, _data), do: {:bpmn_error, "ERR_001", "validation failed"}
    end

    test "routes to error boundary when attached" do
      process = build_process_with_error_boundary()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service,
         %{id: "task", outgoing: ["flow_out"], handler: BpmnErrorHandler}}

      assert {:ok, ^context} = Service.token_in(elem, context)

      meta = Context.get_meta(context, "task")
      assert meta.error == true
      assert meta.error_code == "ERR_001"
      assert meta.error_message == "validation failed"
    end

    test "returns {:error, message} when no error boundary attached" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service,
         %{id: "task", outgoing: ["flow_out"], handler: BpmnErrorHandler}}

      assert {:error, "validation failed"} = Service.token_in(elem, context)

      meta = Context.get_meta(context, "task")
      assert meta.error == true
      assert meta.error_code == "ERR_001"
    end
  end

  describe "with a handler that returns {:async, ref}" do
    defmodule AsyncHandler do
      @moduledoc false
      @behaviour Service.Handler

      @impl true
      def execute(_attrs, _data), do: {:async, "job-123"}
    end

    test "returns {:manual, _} with async metadata" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service,
         %{id: "task", outgoing: ["flow_out"], handler: AsyncHandler}}

      assert {:manual, task_data} = Service.token_in(elem, context)
      assert task_data.id == "task"
      assert task_data.type == :async_service_task
      assert task_data.async_ref == "job-123"

      meta = Context.get_meta(context, "task")
      assert meta.active == true
      assert meta.completed == false
      assert meta.async_ref == "job-123"
    end

    test "complete_async/3 resumes and releases token" do
      task_elem =
        {:bpmn_activity_task_service,
         %{id: "task", outgoing: ["flow_out"], handler: AsyncHandler}}

      process = Map.put(build_process(), "task", task_elem)
      {:ok, context} = Context.start_link(process, %{})

      assert {:manual, _task_data} = Service.token_in(task_elem, context)

      assert {:ok, ^context} = Service.complete_async(context, "task", %{output: "done"})

      assert Context.get_data(context, :output) == "done"

      meta = Context.get_meta(context, "task")
      assert meta.active == false
      assert meta.completed == true
    end

    test "complete_async/3 returns error for unknown task" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      assert {:error, "Service task 'nonexistent' not found in process"} =
               Service.complete_async(context, "nonexistent", %{})
    end
  end

  describe "TaskRegistry fallback" do
    test "uses handler from TaskRegistry when no inline handler is present" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      Rodar.TaskRegistry.register("task", Service.TestHandler)

      elem =
        {:bpmn_activity_task_service, %{id: "task", outgoing: ["flow_out"]}}

      assert {:ok, ^context} = Service.token_in(elem, context)
      assert Context.get_data(context, :result) == "handled"

      Rodar.TaskRegistry.unregister("task")
    end

    test "returns {:not_implemented} when no handler and no registry entry" do
      process = build_process()
      {:ok, context} = Context.start_link(process, %{})

      elem =
        {:bpmn_activity_task_service, %{id: "unregistered_task", outgoing: ["flow_out"]}}

      assert {:not_implemented} = Service.token_in(elem, context)
    end
  end

  describe "fallback" do
    test "returns {:not_implemented} for unrecognized element shape" do
      assert {:not_implemented} = Service.execute(:bad, nil)
    end
  end
end
