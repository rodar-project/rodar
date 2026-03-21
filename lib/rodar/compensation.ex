defmodule Rodar.Compensation do
  @moduledoc """
  Compensation handler tracking and execution.

  Tracks completed activities and their associated compensation handlers.
  When a compensate event is triggered, executes compensation handlers
  in reverse completion order (last completed activity compensated first).

  Compensation handlers are registered automatically when an activity with
  an attached compensation boundary event completes successfully. The
  boundary event's outgoing flow leads to the compensation handler activity.

  ## Storage

  Handlers are stored in context metadata under the `:compensation_handlers` key
  as a list of maps with `activity_id`, `handler_id`, and `completed_at` fields.
  """

  @doc """
  Register a compensation handler for a completed activity.

  Appends a handler entry to the `:compensation_handlers` list in context metadata.
  """
  @spec register_handler(pid(), String.t(), String.t()) :: :ok
  def register_handler(context, activity_id, handler_id) do
    current = handlers(context)

    entry = %{
      activity_id: activity_id,
      handler_id: handler_id,
      registered_at: :erlang.unique_integer([:monotonic])
    }

    Rodar.Context.put_meta(context, :compensation_handlers, current ++ [entry])
  end

  @doc """
  Execute the compensation handler for a specific activity.

  Returns `{:ok, context}` if the handler executes successfully,
  or `{:error, reason}` if no handler is registered for the activity.
  """
  @spec compensate_activity(pid(), String.t()) :: Rodar.result()
  def compensate_activity(context, activity_id) do
    case Enum.find(handlers(context), &(&1.activity_id == activity_id)) do
      nil ->
        {:error, "No compensation handler registered for activity '#{activity_id}'"}

      handler ->
        execute_handler(context, handler)
    end
  end

  @doc """
  Execute all registered compensation handlers in reverse completion order.

  Returns `{:ok, context}` after all handlers have executed.
  If no handlers are registered, returns `{:ok, context}` immediately.
  """
  @spec compensate_all(pid()) :: Rodar.result()
  def compensate_all(context) do
    context
    |> handlers()
    |> Enum.sort_by(& &1.registered_at, :desc)
    |> Enum.reduce({:ok, context}, fn handler, acc ->
      case acc do
        {:ok, _} -> execute_handler(context, handler)
        error -> error
      end
    end)
  end

  @doc """
  Execute compensation handlers scoped to a transaction.

  Only compensates activities whose IDs are in the given `scope` (a MapSet
  or list of activity IDs). Handlers are executed in reverse completion order.
  Returns `{:ok, context}` after all scoped handlers have executed.
  """
  @spec compensate_scope(pid(), MapSet.t() | [String.t()]) :: Rodar.result()
  def compensate_scope(context, scope) do
    scope_set =
      case scope do
        %MapSet{} -> scope
        list when is_list(list) -> MapSet.new(list)
      end

    context
    |> handlers()
    |> Enum.filter(&MapSet.member?(scope_set, &1.activity_id))
    |> Enum.sort_by(& &1.registered_at, :desc)
    |> Enum.reduce({:ok, context}, fn handler, acc ->
      case acc do
        {:ok, _} -> execute_handler(context, handler)
        error -> error
      end
    end)
  end

  @doc """
  Remove all compensation handlers registered for a specific activity.

  Called when an activity fails, to undo the pre-registration.
  """
  @spec remove_handlers(pid(), String.t()) :: :ok
  def remove_handlers(context, activity_id) do
    updated = Enum.reject(handlers(context), &(&1.activity_id == activity_id))
    Rodar.Context.put_meta(context, :compensation_handlers, updated)
  end

  @doc """
  Returns the list of registered compensation handlers.
  """
  @spec handlers(pid()) :: [map()]
  def handlers(context) do
    Rodar.Context.get_meta(context, :compensation_handlers) || []
  end

  defp execute_handler(context, %{handler_id: handler_id}) do
    process = Rodar.Context.get(context, :process)

    case Map.get(process, handler_id) do
      nil -> {:error, "Compensation handler '#{handler_id}' not found in process"}
      elem -> Rodar.execute(elem, context)
    end
  end
end
