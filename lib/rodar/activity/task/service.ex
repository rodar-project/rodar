defmodule Rodar.Activity.Task.Service do
  @moduledoc """
  Handle passing the token through a service task element.

  A service task invokes a user-defined callback module that implements
  the `Rodar.Activity.Task.Service.Handler` behaviour. The handler receives
  the task attributes and context data, and returns a result map that gets
  merged into the context.

  Handler resolution follows this priority:

  1. **Inline `:handler` attribute** — if the element has a `:handler` key (e.g.,
     injected by `Diagram.load/2` with `:handler_map`), that module is used directly.
  2. **`Rodar.TaskRegistry` lookup** — if no inline handler is present, the task's
     `:id` is looked up in the `TaskRegistry`. This allows registering handlers at
     runtime without modifying the parsed diagram.
  3. **Fallback** — if neither source provides a handler, `{:not_implemented}` is returned.

  ## Handler Behaviour

  Implement the `execute/2` callback:

      defmodule MyApp.CheckInventory do
        @behaviour Rodar.Activity.Task.Service.Handler

        @impl true
        def execute(attrs, data) do
          # ... business logic ...
          {:ok, %{in_stock: true}}
        end
      end

  Then reference the module in the BPMN element via the `:handler` attribute,
  or register it in `Rodar.TaskRegistry` using the task's ID.

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

  defp invoke_handler(handler, %{outgoing: outgoing} = attrs, context) do
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
    end
  end
end
