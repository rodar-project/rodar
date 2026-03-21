defmodule Rodar.Activity.DataMapper do
  @moduledoc """
  Maps data inputs and outputs for BPMN task elements using I/O specifications.

  BPMN tasks can declare `ioSpecification` with `dataInputAssociation` and
  `dataOutputAssociation` elements to control which data flows into and out
  of a task. This module resolves those associations at runtime.

  ## Opt-in Behavior

  If an element has no `ioSpecification` (or it is empty), the full context
  data map is passed through unchanged. When an `ioSpecification` is present,
  only the data keys referenced by input associations are included.

  ## Input Mapping

  Each `dataInputAssociation` has a `sourceRef` that names a context data key
  and a `targetRef` that names the input slot on the task. Assignments within
  associations can rename keys via `from`/`to` content fields.

  ## Output Mapping

  Each `dataOutputAssociation` has a `sourceRef` (the result key from the task)
  and a `targetRef` (the context data key to write to). Assignments can also
  remap keys.

  ## Examples

      iex> attrs = %{ioSpecification: [], dataInputAssociation: [], dataOutputAssociation: []}
      iex> Rodar.Activity.DataMapper.has_io_spec?(attrs)
      false

      iex> io_spec = {:bpmn_io_specification, %{dataInput: [], dataOutput: [], inputSet: [], outputSet: []}}
      iex> attrs = %{ioSpecification: [io_spec], dataInputAssociation: [], dataOutputAssociation: []}
      iex> Rodar.Activity.DataMapper.has_io_spec?(attrs)
      true

  """

  alias Rodar.Context

  @doc """
  Returns `true` if the element attributes contain a non-empty `ioSpecification`.
  """
  @spec has_io_spec?(map()) :: boolean()
  def has_io_spec?(attrs) do
    case Map.get(attrs, :ioSpecification, []) do
      [_ | _] -> true
      _ -> false
    end
  end

  @doc """
  Resolves input data for a task based on its data input associations.

  When the element has an `ioSpecification`, only the data keys referenced
  by `dataInputAssociation` entries are included in the returned map. Keys
  are mapped according to assignment `from`/`to` fields when present,
  otherwise the `sourceRef` value is used as-is.

  When there is no `ioSpecification`, the full context data map is returned
  unchanged (backward compatible).

  ## Parameters

    - `attrs` — the element's attribute map (must contain `:ioSpecification`
      and `:dataInputAssociation` keys)
    - `context` — the process context pid

  ## Returns

  A map of input data for the task.
  """
  @spec map_inputs(map(), pid()) :: map()
  def map_inputs(attrs, context) do
    if has_io_spec?(attrs) do
      data = Context.get(context, :data)
      input_assocs = Map.get(attrs, :dataInputAssociation, [])
      resolve_input_associations(input_assocs, data)
    else
      Context.get(context, :data)
    end
  end

  @doc """
  Writes task output data back to the context using data output associations.

  When the element has an `ioSpecification`, each key in `result` is mapped
  through the `dataOutputAssociation` entries. The association's `sourceRef`
  matches a result key, and the `targetRef` determines the context data key
  to write to. Assignments can override this mapping.

  When there is no `ioSpecification`, all result keys are written directly
  to the context (backward compatible).

  ## Parameters

    - `attrs` — the element's attribute map
    - `result` — the result map from the task handler
    - `context` — the process context pid
  """
  @spec map_outputs(map(), map(), pid()) :: :ok
  def map_outputs(attrs, result, context) when is_map(result) do
    if has_io_spec?(attrs) do
      output_assocs = Map.get(attrs, :dataOutputAssociation, [])
      apply_output_associations(output_assocs, result, context)
    else
      Enum.each(result, fn {key, value} ->
        Context.put_data(context, key, value)
      end)
    end
  end

  def map_outputs(_attrs, _result, _context), do: :ok

  # --- Private ---

  defp resolve_input_associations(assocs, data) do
    Enum.reduce(assocs, %{}, fn assoc, acc ->
      {_tag, assoc_attrs} = assoc
      assignments = Map.get(assoc_attrs, :assignment, [])

      if assignments != [] do
        apply_input_assignments(assignments, data, acc)
      else
        source_key = resolve_ref(Map.get(assoc_attrs, :sourceRef))
        target_key = resolve_ref(Map.get(assoc_attrs, :targetRef))
        key = target_key || source_key

        if key do
          value = get_data_value(data, source_key)
          Map.put(acc, key, value)
        else
          acc
        end
      end
    end)
  end

  defp apply_input_assignments(assignments, data, acc) do
    Enum.reduce(assignments, acc, fn {:bpmn_assignment, assignment_attrs}, inner_acc ->
      from_key = extract_content(Map.get(assignment_attrs, :from))
      to_key = extract_content(Map.get(assignment_attrs, :to))

      if from_key && to_key do
        value = get_data_value(data, from_key)
        Map.put(inner_acc, to_key, value)
      else
        inner_acc
      end
    end)
  end

  defp apply_output_associations(assocs, result, context) do
    Enum.each(assocs, fn assoc ->
      {_tag, assoc_attrs} = assoc
      assignments = Map.get(assoc_attrs, :assignment, [])

      if assignments != [] do
        apply_output_assignments(assignments, result, context)
      else
        source_key = resolve_ref(Map.get(assoc_attrs, :sourceRef))
        target_key = resolve_ref(Map.get(assoc_attrs, :targetRef))

        if source_key && target_key do
          value = get_result_value(result, source_key)
          Context.put_data(context, target_key, value)
        end
      end
    end)
  end

  defp apply_output_assignments(assignments, result, context) do
    Enum.each(assignments, fn {:bpmn_assignment, assignment_attrs} ->
      from_key = extract_content(Map.get(assignment_attrs, :from))
      to_key = extract_content(Map.get(assignment_attrs, :to))

      if from_key && to_key do
        value = get_result_value(result, from_key)
        Context.put_data(context, to_key, value)
      end
    end)
  end

  defp extract_content({:bpmn_from, %{content: content}}), do: content
  defp extract_content({:bpmn_to, %{content: content}}), do: content
  defp extract_content(_), do: nil

  defp resolve_ref(nil), do: nil
  defp resolve_ref(ref) when is_binary(ref), do: ref
  defp resolve_ref(_), do: nil

  defp get_data_value(data, key) when is_map(data) do
    # Try string key first, then atom key
    case Map.fetch(data, key) do
      {:ok, val} -> val
      :error -> Map.get(data, String.to_atom(key), nil)
    end
  rescue
    ArgumentError -> nil
  end

  defp get_result_value(result, key) when is_map(result) do
    case Map.fetch(result, key) do
      {:ok, val} ->
        val

      :error ->
        # Try atom key
        try do
          Map.get(result, String.to_atom(key), nil)
        rescue
          ArgumentError -> nil
        end
    end
  end
end
