defmodule Rodar.Event.Start do
  @moduledoc """
  Handles BPMN start event elements.

  The start event is the entry point of a process. When a token arrives, it is
  released to the first outgoing sequence flow. If there are no outgoing flows
  (e.g., a degenerate single-node process), it returns `{:ok, context}` immediately.

  For message- and signal-triggered start events that automatically create process
  instances, see `Rodar.Event.Start.Trigger`.

  ## Examples

      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> {:ok, pid} = Rodar.Event.Start.token_in({:bpmn_event_start, %{outgoing: []}}, context)
      iex> context == pid
      true

      iex> {:ok, context} = Rodar.Context.start_link(%{"to" => {:bpmn_activity_task_script, %{}}}, %{})
      iex> {:not_implemented} = Rodar.Event.Start.token_in({:bpmn_event_start, %{outgoing: ["to"]}}, context)
      iex> true
      true

  """

  alias Rodar.Activity.Subprocess.Event, as: SubprocessEvent

  @doc """
  Accepts the initial token and releases it to the first outgoing sequence flow.

  Before releasing the token, registers any event subprocesses found in the
  current process definition so their start event triggers are active.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in({:bpmn_event_start, %{outgoing: []}}, context), do: {:ok, context}
  def token_in(elem, context), do: execute(elem, context)

  @doc """
  Execute the start event business logic
  """
  @spec execute(Rodar.element(), Rodar.context()) :: Rodar.result()
  def execute({:bpmn_event_start, %{outgoing: outgoing} = _event}, context) do
    register_event_subprocesses(context)
    token_out(outgoing, context)
  end

  defp register_event_subprocesses(context) do
    process = Rodar.Context.get(context, :process)
    SubprocessEvent.register(process, context)
  end

  defp token_out(targets, context), do: Rodar.release_token(targets, context)
end
