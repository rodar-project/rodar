defmodule Rodar.Activity.Task.User do
  @moduledoc """
  Handle passing the token through a user task element.

  A user task pauses execution and returns `{:manual, task_data}` to signal
  that external input is required. The caller should use `resume/3` to
  continue execution once the input is available.

  ## Examples

      iex> elem = {:bpmn_activity_task_user, %{id: "task_1", name: "Review", outgoing: ["flow_out"]}}
      iex> {:ok, context} = Rodar.Context.start_link(%{}, %{})
      iex> {:manual, task_data} = Rodar.Activity.Task.User.token_in(elem, context)
      iex> task_data.id
      "task_1"

  """

  @doc """
  Receive the token for the element. Pauses execution and returns task data.

  When the element has an `ioSpecification`, only the mapped input data is
  included in the returned task data under the `:data` key. Otherwise, the
  full context data is available.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in(
        {:bpmn_activity_task_user, %{id: id, outgoing: outgoing} = attrs},
        context
      ) do
    alias Rodar.Activity.DataMapper

    mapped_data = DataMapper.map_inputs(attrs, context)

    task_data = %{
      id: id,
      name: Map.get(attrs, :name),
      outgoing: outgoing,
      context: context,
      data: mapped_data
    }

    Rodar.Context.put_meta(context, id, %{active: true, completed: false, type: :user_task})

    {:manual, task_data}
  end

  @doc """
  Resume execution of a paused user task with the provided input data.

  When the element has an `ioSpecification` with data output associations,
  the `input` map keys are mapped through those associations before being
  written to the context. Otherwise, all input keys are merged directly.
  """
  @spec resume(Rodar.element(), Rodar.context(), map()) :: Rodar.result()
  def resume({:bpmn_activity_task_user, %{id: id, outgoing: outgoing} = attrs}, context, input)
      when is_map(input) do
    alias Rodar.Activity.DataMapper

    DataMapper.map_outputs(attrs, input, context)

    Rodar.Context.put_meta(context, id, %{active: false, completed: true, type: :user_task})

    Rodar.release_token(outgoing, context)
  end
end
