defmodule Rodar.Activity.MultiInstance do
  @moduledoc """
  Multi-instance activity execution for BPMN loop characteristics.

  Wraps any activity handler to execute it multiple times based on BPMN
  `multiInstanceLoopCharacteristics`. Supports both parallel and sequential
  execution modes, with optional completion conditions for early termination.

  ## Execution Modes

  - **Parallel** (`isSequential: "false"` or absent): Forks child tokens via
    `Token.fork/1` and executes all instances concurrently. Joins when all
    complete (or when the completion condition is met).
  - **Sequential** (`isSequential: "true"`): Executes instances one-by-one in
    order using `Enum.reduce_while/3`.

  ## Data Isolation

  Each iteration receives a loop variable set via `Context.put_data/3`:
  - `"loopCounter"` — 1-based index of the current iteration
  - The input data item variable (if `:inputDataItem` is specified) — the
    element from the input collection for this iteration

  After all iterations complete, results are collected into an output list
  stored under the output data item variable (or `"_mi_results"` by default).

  ## Completion Condition

  An optional `completionCondition` expression (Elixir or FEEL) is evaluated
  after each instance completes. If it returns `true`, remaining instances
  are skipped and the activity completes with results collected so far.

  ## Integration

  The `Rodar` dispatcher checks for `:loop_characteristics` on element attrs
  before dispatching to the inner handler. When present, execution is delegated
  to this module, which wraps the inner handler transparently. Any activity
  type automatically supports multi-instance without handler changes.
  """

  require Logger

  alias Rodar.Context
  alias Rodar.Expression
  alias Rodar.Token

  @doc """
  Execute a multi-instance activity.

  Determines the number of instances from `loopCardinality` or the input
  collection size, then dispatches to parallel or sequential execution.

  Returns the result of the inner activity execution.
  """
  @spec execute(Rodar.element(), Rodar.context(), (Rodar.element(), Rodar.context() ->
                                                     Rodar.result())) ::
          Rodar.result()
  def execute({_type, attrs} = elem, context, inner_dispatch) do
    loop = attrs[:loop_characteristics]

    case resolve_instance_count(loop, context) do
      {:ok, 0} ->
        # Zero instances — skip activity and release token directly
        Rodar.release_token(attrs[:outgoing], context)

      {:ok, count} ->
        input_collection = resolve_input_collection(loop, context)
        output_var = loop[:outputDataItem] || "_mi_results"

        if loop[:isSequential] == "true" do
          execute_sequential(
            elem,
            context,
            inner_dispatch,
            count,
            input_collection,
            output_var,
            loop
          )
        else
          execute_parallel(
            elem,
            context,
            inner_dispatch,
            count,
            input_collection,
            output_var,
            loop
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Sequential execution ---

  defp execute_sequential(
         {_type, attrs} = elem,
         context,
         inner_dispatch,
         count,
         input_collection,
         output_var,
         loop
       ) do
    input_var = loop[:inputDataItem]

    result =
      Enum.reduce_while(1..count, {:ok, []}, fn index, {:ok, results} ->
        set_loop_variables(context, index, input_var, input_collection)

        case invoke_inner(elem, context, inner_dispatch) do
          {:ok, _ctx} ->
            collect_and_check(context, results, loop)

          {:manual, _} = manual ->
            store_mi_progress(context, attrs[:id], index, count, results, output_var)
            {:halt, manual}

          error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, results} ->
        Context.put_data(context, output_var, results)
        cleanup_loop_variables(context, loop[:inputDataItem])
        Rodar.release_token(attrs[:outgoing], context)

      other ->
        other
    end
  end

  # --- Parallel execution ---

  defp execute_parallel(
         {_type, attrs} = elem,
         context,
         inner_dispatch,
         count,
         input_collection,
         output_var,
         loop
       ) do
    input_var = loop[:inputDataItem]
    parent_token = Context.get_meta(context, :current_token)

    results =
      1..count
      |> Task.async_stream(fn index ->
        set_loop_variables(context, index, input_var, input_collection)

        if parent_token do
          child_token = Token.fork(parent_token)
          Context.put_meta(context, :current_token, child_token)
        end

        case invoke_inner(elem, context, inner_dispatch) do
          {:ok, _ctx} ->
            result_value = Context.get_data(context, "_mi_current_result")
            {:ok, result_value}

          other ->
            other
        end
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, value}}, {:ok, acc} ->
          new_acc = acc ++ [value]

          if completion_condition_met?(loop, context, new_acc) do
            {:halt, {:ok, new_acc}}
          else
            {:cont, {:ok, new_acc}}
          end

        {:ok, {:manual, _} = manual}, _acc ->
          {:halt, manual}

        {:ok, error}, _acc ->
          {:halt, error}

        {:exit, reason}, _acc ->
          {:halt, {:error, "Multi-instance task failed: #{inspect(reason)}"}}
      end)

    case results do
      {:ok, collected} ->
        Context.put_data(context, output_var, collected)
        cleanup_loop_variables(context, input_var)

        # Restore parent token
        if parent_token do
          Context.put_meta(context, :current_token, parent_token)
        end

        Rodar.release_token(attrs[:outgoing], context)

      other ->
        other
    end
  end

  defp collect_and_check(context, results, loop) do
    result_value = Context.get_data(context, "_mi_current_result")
    new_results = results ++ [result_value]

    if completion_condition_met?(loop, context, new_results) do
      {:halt, {:ok, new_results}}
    else
      {:cont, {:ok, new_results}}
    end
  end

  defp store_mi_progress(context, activity_id, index, count, results, output_var) do
    Context.put_meta(context, {:_mi_state, activity_id}, %{
      index: index,
      count: count,
      results: results,
      output_var: output_var
    })
  end

  # --- Helpers ---

  defp invoke_inner({type, attrs}, context, inner_dispatch) do
    # Strip loop_characteristics and outgoing to prevent the inner handler
    # from releasing the token (we manage that ourselves)
    inner_attrs =
      attrs
      |> Map.delete(:loop_characteristics)
      |> Map.put(:outgoing, [])

    inner_dispatch.({type, inner_attrs}, context)
  end

  defp resolve_instance_count(loop, context) do
    cond do
      loop[:loopCardinality] != nil ->
        parse_cardinality(loop[:loopCardinality], context)

      loop[:inputDataItem] != nil && loop[:loopDataInputRef] != nil ->
        collection = Context.get_data(context, loop[:loopDataInputRef])

        if is_list(collection) do
          {:ok, length(collection)}
        else
          {:error, "loopDataInputRef '#{loop[:loopDataInputRef]}' does not reference a list"}
        end

      loop[:loopDataInputRef] != nil ->
        collection = Context.get_data(context, loop[:loopDataInputRef])

        if is_list(collection) do
          {:ok, length(collection)}
        else
          {:error, "loopDataInputRef '#{loop[:loopDataInputRef]}' does not reference a list"}
        end

      true ->
        {:error, "Multi-instance activity requires loopCardinality or loopDataInputRef"}
    end
  end

  defp parse_cardinality(cardinality, context) when is_binary(cardinality) do
    case Integer.parse(cardinality) do
      {n, ""} ->
        {:ok, n}

      _ ->
        # Try evaluating as an expression
        try do
          result = Expression.evaluate("feel", cardinality, context)

          cond do
            is_integer(result) -> {:ok, result}
            is_float(result) -> {:ok, trunc(result)}
            true -> {:error, "loopCardinality expression did not evaluate to a number"}
          end
        rescue
          _ -> {:error, "Invalid loopCardinality: #{cardinality}"}
        end
    end
  end

  defp parse_cardinality(cardinality, _context) when is_integer(cardinality),
    do: {:ok, cardinality}

  defp parse_cardinality(_, _context), do: {:error, "Invalid loopCardinality"}

  defp resolve_input_collection(loop, context) do
    ref = loop[:loopDataInputRef]

    if ref do
      case Context.get_data(context, ref) do
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  end

  defp set_loop_variables(context, index, input_var, input_collection) do
    Context.put_data(context, "loopCounter", index)

    if input_var && input_collection != [] do
      item = Enum.at(input_collection, index - 1)
      Context.put_data(context, input_var, item)
    end
  end

  defp cleanup_loop_variables(context, input_var) do
    Context.put_data(context, "loopCounter", nil)
    Context.put_data(context, "_mi_current_result", nil)

    if input_var do
      Context.put_data(context, input_var, nil)
    end
  end

  defp completion_condition_met?(loop, context, _results) do
    condition = loop[:completionCondition]

    if condition do
      try do
        result = Expression.evaluate("feel", condition, context)
        result == true
      rescue
        _ -> false
      end
    else
      false
    end
  end
end
