defmodule Rodar.Gateway.Inclusive do
  @moduledoc """
  Handle passing the token through an inclusive gateway element.

  An inclusive gateway (OR) is a hybrid of exclusive and parallel gateways:

  ## Fork (diverge)

  When the gateway has a single incoming flow, it evaluates conditions on
  **all** outgoing flows and releases tokens to every flow whose condition
  is `true`. If no conditions match, the default flow is used. The set of
  activated flows is recorded in context for join synchronization.

  ## Join (converge)

  When the gateway has multiple incoming flows, it waits until tokens have
  arrived from all flows that were activated at the corresponding fork.
  If no activation record exists (e.g. the join is used standalone),
  it falls back to waiting for all incoming flows (parallel behavior).

  ## Merge (pass-through)

  When the gateway has a single outgoing flow, the token passes through.

  ## Examples

      iex> end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
      iex> flow_out = {:bpmn_sequence_flow, %{id: "flow_out", sourceRef: "gw", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> gateway = {:bpmn_gateway_inclusive, %{id: "gw", incoming: ["in"], outgoing: ["flow_out"]}}
      iex> process = %{"flow_out" => flow_out, "end" => end_event}
      iex> {:ok, context} = Rodar.Context.start_link(process, %{})
      iex> {:ok, ^context} = Rodar.Gateway.Inclusive.token_in(gateway, context)
      iex> true
      true

  """

  @doc """
  Receive the token for the element and execute the gateway logic.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in(elem, context), do: token_in(elem, context, nil)

  @doc """
  Receive the token with the source flow ID for join tracking.
  """
  @spec token_in(Rodar.element(), Rodar.context(), String.t() | nil) :: Rodar.result()
  def token_in({:bpmn_gateway_inclusive, %{incoming: incoming}} = elem, context, from_flow)
      when length(incoming) > 1 do
    join(elem, context, from_flow)
  end

  def token_in(elem, context, _from_flow), do: fork(elem, context)

  @doc """
  Fork: evaluate conditions on all outgoing flows and release tokens to matching ones.
  """
  @spec fork(Rodar.element(), Rodar.context()) :: Rodar.result()
  def fork({:bpmn_gateway_inclusive, %{id: id, outgoing: outgoing} = attrs}, context) do
    process = Rodar.Context.get(context, :process)
    default_flow = Map.get(attrs, :default)

    matching =
      outgoing
      |> Enum.filter(fn flow_id ->
        flow_id != default_flow && flow_matches?(Map.get(process, flow_id), context)
      end)

    activated =
      case matching do
        [] when is_binary(default_flow) -> [default_flow]
        [] -> :none
        flows -> flows
      end

    case activated do
      :none ->
        {:error, "Inclusive gateway: no matching condition and no default flow"}

      flows ->
        Rodar.Context.record_activated_paths(context, id, flows)
        Rodar.release_token(flows, context)
    end
  end

  @doc """
  Join: wait for all activated incoming tokens before continuing.
  """
  @spec join(Rodar.element(), Rodar.context(), String.t() | nil) :: Rodar.result()
  def join(
        {:bpmn_gateway_inclusive, %{id: id, incoming: incoming, outgoing: outgoing}},
        context,
        from_flow
      ) do
    arrived =
      if from_flow do
        Rodar.Context.record_token(context, id, from_flow)
      else
        Rodar.Context.token_count(context, id)
      end

    process = Rodar.Context.get(context, :process)
    fork_id = find_fork_gateway_id(incoming, process)
    expected = expected_count(context, fork_id || id, incoming)

    if arrived >= expected do
      Rodar.Context.clear_tokens(context, id)
      if fork_id, do: Rodar.Context.clear_activated_paths(context, fork_id)
      Rodar.release_token(outgoing, context)
    else
      {:ok, context}
    end
  end

  defp expected_count(context, lookup_id, incoming) do
    case Rodar.Context.get_activated_paths(context, lookup_id) do
      nil -> length(incoming)
      paths -> length(paths)
    end
  end

  # Trace each incoming flow back through the process graph to find the upstream
  # inclusive gateway that forked into this join. Returns the fork's ID, or nil
  # if no matching fork is found (standalone join — falls back to parallel behavior).
  defp find_fork_gateway_id(incoming_flow_ids, process) do
    Enum.find_value(incoming_flow_ids, fn flow_id ->
      trace_to_inclusive_fork(flow_id, process, MapSet.new())
    end)
  end

  defp trace_to_inclusive_fork(flow_id, process, visited) do
    with {:bpmn_sequence_flow, %{sourceRef: source_id}} <- Map.get(process, flow_id),
         false <- MapSet.member?(visited, source_id),
         {type, attrs} <- Map.get(process, source_id) do
      trace_node(type, attrs, process, visited)
    else
      _ -> nil
    end
  end

  defp trace_node(:bpmn_gateway_inclusive, attrs, _process, _visited), do: attrs.id

  defp trace_node(_type, attrs, process, visited) do
    visited = MapSet.put(visited, Map.get(attrs, :id))

    attrs
    |> Map.get(:incoming, [])
    |> Enum.find_value(&trace_to_inclusive_fork(&1, process, visited))
  end

  defp flow_matches?({:bpmn_sequence_flow, %{conditionExpression: condition}}, context)
       when not is_nil(condition) do
    case Rodar.Expression.execute(condition, context) do
      {:ok, true} -> true
      {:ok, false} -> false
    end
  end

  defp flow_matches?(_flow, _context), do: true
end
