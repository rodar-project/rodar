defmodule Rodar.Activity.Task.Service do
  @moduledoc """
  Handle passing the token through a service task element.

  A service task invokes a user-defined callback module that implements
  the `Rodar.Activity.Task.Service.Handler` behaviour. The handler receives
  the task attributes and context data, and returns a result that determines
  the next step in execution.

  Handler resolution follows this priority:

  1. **Inline `:handler` attribute** — if the element has a `:handler` key (e.g.,
     injected by `Diagram.load/2` with `:handler_map`), that module is used directly.
  2. **`Rodar.TaskRegistry` lookup** — if no inline handler is present, the task's
     `:id` is looked up in the `TaskRegistry`. This allows registering handlers at
     runtime without modifying the parsed diagram.
  3. **Fallback** — if neither source provides a handler, `{:not_implemented}` is returned.

  ## Handler Return Types

    * `{:ok, map()}` — result is merged into context data, token released to outgoing flows
    * `{:error, reason}` — error propagated to the caller
    * `{:bpmn_error, code, message}` — routes token to an attached error boundary event
      if present; otherwise falls back to `{:error, message}`
    * `{:async, reference}` — parks the token and returns `{:manual, _}`; use
      `complete_async/3` to resume execution

  ## Examples

      iex> end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
      iex> flow_out = {:bpmn_sequence_flow, %{id: "flow_out", sourceRef: "task", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> elem = {:bpmn_activity_task_service, %{id: "task", outgoing: ["flow_out"], handler: Rodar.Activity.Task.Service.TestHandler}}
      iex> process = %{"flow_out" => flow_out, "end" => end_event}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> {:ok, ^context} = Rodar.Activity.Task.Service.token_in(elem, context)
      iex> Rodar.Context.get_data(context, :result)
      "handled"

  """

  @doc """
  Receive the token for the element and invoke the service handler.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in(elem, context), do: execute(elem, context)

  @doc """
  Execute the service task business logic.

  Resolves the handler from the element's `:handler` attribute first, then
  falls back to `Rodar.TaskRegistry` lookup by the task's `:id`.
  """
  @spec execute(Rodar.element(), Rodar.context()) :: Rodar.result()
  def execute(
        {:bpmn_activity_task_service, %{handler: handler} = attrs},
        context
      ) do
    invoke_handler(handler, attrs, context)
  end

  def execute(
        {:bpmn_activity_task_service, %{id: id} = attrs},
        context
      ) do
    case Rodar.TaskRegistry.lookup(id) do
      {:ok, handler} -> invoke_handler(handler, attrs, context)
      :error -> {:not_implemented}
    end
  end

  def execute(_elem, _context), do: {:not_implemented}

  @doc """
  Complete an async service task and release the token to outgoing flows.

  Call this after a handler has returned `{:async, ref}` and the external
  work is done. The `result` map is merged into the context data.
  """
  @spec complete_async(Rodar.context(), String.t(), map()) :: Rodar.result()
  def complete_async(context, task_id, result) when is_map(result) do
    process_map = Rodar.Context.get(context, :process)

    case Map.get(process_map, task_id) do
      {:bpmn_activity_task_service, %{outgoing: outgoing}} ->
        Enum.each(result, fn {key, value} ->
          Rodar.Context.put_data(context, key, value)
        end)

        Rodar.Context.put_meta(context, task_id, %{
          active: false,
          completed: true,
          type: :service_task
        })

        Rodar.release_token(outgoing, context)

      nil ->
        {:error, "Service task '#{task_id}' not found in process"}

      {type, _attrs} ->
        {:error, "Task '#{task_id}' is #{type}, not a service task"}
    end
  end

  defp invoke_handler(handler, %{id: id, outgoing: outgoing} = attrs, context) do
    alias Rodar.Activity.DataMapper

    data = DataMapper.map_inputs(attrs, context)

    case handler.execute(attrs, data) do
      {:ok, result} when is_map(result) ->
        DataMapper.map_outputs(attrs, result, context)

        Rodar.release_token(outgoing, context)

      {:ok, _result} ->
        Rodar.release_token(outgoing, context)

      {:error, reason} ->
        {:error, reason}

      {:bpmn_error, code, message} ->
        Rodar.Context.put_meta(context, id, %{
          error: true,
          error_code: code,
          error_message: message
        })

        process = Rodar.Context.get(context, :process)

        case find_error_boundary(process, id) do
          {:bpmn_event_boundary, %{outgoing: boundary_outgoing}} ->
            Rodar.release_token(boundary_outgoing, context)

          nil ->
            {:error, message}
        end

      {:async, ref} ->
        Rodar.Context.put_meta(context, id, %{
          active: true,
          completed: false,
          type: :service_task,
          async_ref: ref
        })

        {:manual,
         %{
           id: id,
           type: :async_service_task,
           async_ref: ref,
           outgoing: outgoing,
           context: context
         }}
    end
  end

  defp find_error_boundary(process, task_id) do
    Enum.find_value(process, fn
      {_id, {:bpmn_event_boundary, %{attachedToRef: ^task_id} = attrs} = elem} ->
        if has_error_definition?(attrs), do: elem

      _ ->
        nil
    end)
  end

  defp has_error_definition?(attrs) do
    match?({:bpmn_event_definition_error, _}, Map.get(attrs, :errorEventDefinition))
  end
end
