defmodule Rodar.Validation do
  @moduledoc """
  Structural validation for parsed BPMN process element maps.

  Validates a process map (`%{"id" => {type_atom, attrs_map}}`) against
  structural rules before execution. Returns accumulated errors so users
  see all issues at once.

  ## Validation Functions

  - `validate/1` -- 9 structural rules for a single process map
  - `validate!/1` -- raising variant of `validate/1`
  - `validate_lanes/2` -- lane referential integrity (`:lane_flow_node_ref`,
    `:lane_duplicate_ref`)
  - `validate_collaboration/2` -- cross-process participant and message flow checks

  ## See Also

  - `Rodar.Lane` -- lane assignment queries
  - `Rodar.Engine.Diagram` -- parser that produces the maps this module validates

  ## Examples

      iex> start = {:bpmn_event_start, %{id: "s", incoming: [], outgoing: ["f1"]}}
      iex> end_ev = {:bpmn_event_end, %{id: "e", incoming: ["f1"], outgoing: []}}
      iex> flow = {:bpmn_sequence_flow, %{id: "f1", sourceRef: "s", targetRef: "e", conditionExpression: nil}}
      iex> process_map = %{"s" => start, "e" => end_ev, "f1" => flow}
      iex> {:ok, ^process_map} = Rodar.Validation.validate(process_map)
      iex> true
      true

      iex> {:error, issues} = Rodar.Validation.validate(%{})
      iex> Enum.any?(issues, & &1.rule == :start_event_exists)
      true

  """

  @type issue :: %{
          rule: atom(),
          node_id: String.t() | nil,
          message: String.t(),
          severity: :error | :warning
        }

  @doc """
  Validate a parsed process element map.

  Returns `{:ok, process_map}` when no `:error`-severity issues are found
  (warnings are allowed). Returns `{:error, issues}` otherwise.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [issue()]}
  def validate(process_map) do
    issues =
      [
        &validate_start_event_exists/1,
        &validate_start_event_outgoing/1,
        &validate_end_event_exists/1,
        &validate_end_event_incoming/1,
        &validate_sequence_flow_refs/1,
        &validate_orphan_nodes/1,
        &validate_gateway_outgoing/1,
        &validate_exclusive_gateway_default/1,
        &validate_boundary_attachment/1,
        &validate_multi_instance/1
      ]
      |> Enum.flat_map(& &1.(process_map))

    errors = Enum.filter(issues, &(&1.severity == :error))

    if errors == [] do
      {:ok, process_map}
    else
      {:error, issues}
    end
  end

  @doc """
  Validate a parsed process element map, raising on errors.
  """
  @spec validate!(map()) :: map()
  def validate!(process_map) do
    case validate(process_map) do
      {:ok, map} -> map
      {:error, issues} -> raise "Validation failed: #{inspect(issues)}"
    end
  end

  @doc """
  Validate lane referential integrity for a process.

  Checks that all `flowNodeRef` entries in the lane set reference existing
  elements in the process map, and that no node appears in multiple lanes
  at the same nesting level.

  ## Examples

      iex> lane_set = %{id: "ls1", lanes: [
      ...>   %{id: "l1", name: "A", flow_node_refs: ["start_1"], child_lane_set: nil}
      ...> ]}
      iex> process_map = %{
      ...>   "start_1" => {:bpmn_event_start, %{id: "start_1", incoming: [], outgoing: ["f1"]}},
      ...>   "end_1" => {:bpmn_event_end, %{id: "end_1", incoming: ["f1"], outgoing: []}},
      ...>   "f1" => {:bpmn_sequence_flow, %{id: "f1", sourceRef: "start_1", targetRef: "end_1", conditionExpression: nil}}
      ...> }
      iex> {:ok, ^lane_set} = Rodar.Validation.validate_lanes(lane_set, process_map)
      iex> true
      true

  """
  @spec validate_lanes(map() | nil, map()) :: {:ok, map() | nil} | {:error, [issue()]}
  def validate_lanes(nil, _process_map), do: {:ok, nil}

  def validate_lanes(lane_set, process_map) do
    issues =
      validate_lane_flow_node_refs(lane_set, process_map) ++
        validate_lane_duplicate_refs(lane_set)

    errors = Enum.filter(issues, &(&1.severity == :error))

    if errors == [] do
      {:ok, lane_set}
    else
      {:error, issues}
    end
  end

  @doc """
  Validate collaboration structure against its processes.

  Checks that participant processRefs match process IDs, and that
  message flow source/target refs exist in some process.
  """
  @spec validate_collaboration(map(), [tuple()]) :: {:ok, map()} | {:error, [issue()]}
  def validate_collaboration(collaboration, processes) do
    issues =
      [
        &validate_participant_refs(&1, &2),
        &validate_message_flow_refs(&1, &2),
        &validate_message_flow_cross_process(&1, &2)
      ]
      |> Enum.flat_map(& &1.(collaboration, processes))

    errors = Enum.filter(issues, &(&1.severity == :error))

    if errors == [] do
      {:ok, collaboration}
    else
      {:error, issues}
    end
  end

  # --- Helpers ---

  @doc false
  def elements_by_type(process_map, type) do
    Enum.filter(process_map, fn
      {_id, {^type, _attrs}} -> true
      _ -> false
    end)
  end

  @doc false
  def sequence_flows(process_map) do
    elements_by_type(process_map, :bpmn_sequence_flow)
  end

  # --- Validation rules ---

  defp validate_start_event_exists(process_map) do
    case elements_by_type(process_map, :bpmn_event_start) do
      [] ->
        [
          %{
            rule: :start_event_exists,
            node_id: nil,
            message: "Process has no start event",
            severity: :error
          }
        ]

      _ ->
        []
    end
  end

  defp validate_start_event_outgoing(process_map) do
    process_map
    |> elements_by_type(:bpmn_event_start)
    |> Enum.flat_map(fn {id, {_, attrs}} ->
      if empty_list?(Map.get(attrs, :outgoing, [])) do
        [
          %{
            rule: :start_event_outgoing,
            node_id: id,
            message: "Start event '#{id}' has no outgoing flows",
            severity: :error
          }
        ]
      else
        []
      end
    end)
  end

  defp validate_end_event_exists(process_map) do
    case elements_by_type(process_map, :bpmn_event_end) do
      [] ->
        [
          %{
            rule: :end_event_exists,
            node_id: nil,
            message: "Process has no end event",
            severity: :error
          }
        ]

      _ ->
        []
    end
  end

  defp validate_end_event_incoming(process_map) do
    process_map
    |> elements_by_type(:bpmn_event_end)
    |> Enum.flat_map(fn {id, {_, attrs}} ->
      if empty_list?(Map.get(attrs, :incoming, [])) do
        [
          %{
            rule: :end_event_incoming,
            node_id: id,
            message: "End event '#{id}' has no incoming flows",
            severity: :error
          }
        ]
      else
        []
      end
    end)
  end

  defp validate_sequence_flow_refs(process_map) do
    process_map
    |> sequence_flows()
    |> Enum.flat_map(fn {id, {_, attrs}} ->
      source_issues =
        if Map.has_key?(process_map, attrs[:sourceRef]) do
          []
        else
          [
            %{
              rule: :sequence_flow_refs,
              node_id: id,
              message:
                "Sequence flow '#{id}' references non-existent source '#{attrs[:sourceRef]}'",
              severity: :error
            }
          ]
        end

      target_issues =
        if Map.has_key?(process_map, attrs[:targetRef]) do
          []
        else
          [
            %{
              rule: :sequence_flow_refs,
              node_id: id,
              message:
                "Sequence flow '#{id}' references non-existent target '#{attrs[:targetRef]}'",
              severity: :error
            }
          ]
        end

      source_issues ++ target_issues
    end)
  end

  defp validate_orphan_nodes(process_map) do
    flow_targets =
      process_map
      |> sequence_flows()
      |> Enum.map(fn {_id, {_, attrs}} -> attrs[:targetRef] end)
      |> MapSet.new()

    process_map
    |> Enum.flat_map(fn
      {id, {:bpmn_event_start, _}} ->
        # Start events don't need incoming
        if id, do: [], else: []

      {id, {:bpmn_event_boundary, _}} ->
        # Boundary events don't need incoming flows
        if id, do: [], else: []

      {_id, {:bpmn_sequence_flow, _}} ->
        []

      {id, {_type, _attrs}} ->
        if MapSet.member?(flow_targets, id) do
          []
        else
          [
            %{
              rule: :orphan_nodes,
              node_id: id,
              message: "Node '#{id}' is not targeted by any sequence flow",
              severity: :error
            }
          ]
        end

      _ ->
        []
    end)
  end

  @gateway_types [
    :bpmn_gateway_exclusive,
    :bpmn_gateway_inclusive,
    :bpmn_gateway_complex,
    :bpmn_gateway_parallel
  ]

  defp validate_gateway_outgoing(process_map) do
    process_map
    |> Enum.flat_map(fn
      {id, {type, attrs}} when type in @gateway_types ->
        incoming = Map.get(attrs, :incoming, [])
        outgoing = Map.get(attrs, :outgoing, [])

        # A fork gateway has <=1 incoming flow
        if length(incoming) <= 1 and length(outgoing) < 2 do
          [
            %{
              rule: :gateway_outgoing,
              node_id: id,
              message: "Fork gateway '#{id}' must have at least 2 outgoing flows",
              severity: :error
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp validate_exclusive_gateway_default(process_map) do
    process_map
    |> elements_by_type(:bpmn_gateway_exclusive)
    |> Enum.flat_map(fn {id, {_, attrs}} ->
      outgoing = Map.get(attrs, :outgoing, [])
      has_default = Map.has_key?(attrs, :default) and attrs[:default] != nil
      has_conditional = has_conditional_flow?(outgoing, process_map)

      if has_conditional and not has_default do
        [
          %{
            rule: :exclusive_gateway_default,
            node_id: id,
            message: "Exclusive gateway '#{id}' has conditional flows but no default",
            severity: :warning
          }
        ]
      else
        []
      end
    end)
  end

  defp has_conditional_flow?(outgoing, process_map) do
    Enum.any?(outgoing, fn flow_id ->
      case Map.get(process_map, flow_id) do
        {:bpmn_sequence_flow, flow_attrs} -> flow_attrs[:conditionExpression] != nil
        _ -> false
      end
    end)
  end

  defp validate_boundary_attachment(process_map) do
    process_map
    |> elements_by_type(:bpmn_event_boundary)
    |> Enum.flat_map(fn {id, {_, attrs}} ->
      attached_to = Map.get(attrs, :attachedToRef)

      cond do
        attached_to == nil ->
          [
            %{
              rule: :boundary_attachment,
              node_id: id,
              message: "Boundary event '#{id}' has no attachedToRef",
              severity: :error
            }
          ]

        not Map.has_key?(process_map, attached_to) ->
          [
            %{
              rule: :boundary_attachment,
              node_id: id,
              message: "Boundary event '#{id}' attached to non-existent node '#{attached_to}'",
              severity: :error
            }
          ]

        true ->
          []
      end
    end)
  end

  # --- Collaboration validation rules ---

  defp validate_participant_refs(collaboration, processes) do
    process_ids =
      Enum.map(processes, fn {:bpmn_process, attrs, _} -> attrs[:id] |> to_string() end)
      |> MapSet.new()

    (collaboration[:participants] || [])
    |> Enum.flat_map(fn participant ->
      if participant.processRef == "" or MapSet.member?(process_ids, participant.processRef) do
        []
      else
        [
          %{
            rule: :participant_process_ref,
            node_id: participant.id,
            message:
              "Participant '#{participant.id}' references non-existent process '#{participant.processRef}'",
            severity: :error
          }
        ]
      end
    end)
  end

  defp validate_message_flow_refs(collaboration, processes) do
    all_element_ids = collect_all_element_ids(processes)

    (collaboration[:message_flows] || [])
    |> Enum.flat_map(fn flow ->
      source_issues =
        if MapSet.member?(all_element_ids, flow.sourceRef) do
          []
        else
          [
            %{
              rule: :message_flow_refs,
              node_id: flow.id,
              message:
                "Message flow '#{flow.id}' references non-existent source '#{flow.sourceRef}'",
              severity: :error
            }
          ]
        end

      target_issues =
        if MapSet.member?(all_element_ids, flow.targetRef) do
          []
        else
          [
            %{
              rule: :message_flow_refs,
              node_id: flow.id,
              message:
                "Message flow '#{flow.id}' references non-existent target '#{flow.targetRef}'",
              severity: :error
            }
          ]
        end

      source_issues ++ target_issues
    end)
  end

  defp validate_message_flow_cross_process(collaboration, processes) do
    element_to_process = build_element_to_process_map(processes)

    (collaboration[:message_flows] || [])
    |> Enum.flat_map(fn flow ->
      source_process = Map.get(element_to_process, flow.sourceRef)
      target_process = Map.get(element_to_process, flow.targetRef)

      if source_process != nil and target_process != nil and source_process == target_process do
        [
          %{
            rule: :message_flow_cross_process,
            node_id: flow.id,
            message: "Message flow '#{flow.id}' source and target must be in different processes",
            severity: :error
          }
        ]
      else
        []
      end
    end)
  end

  defp collect_all_element_ids(processes) do
    Enum.flat_map(processes, fn {:bpmn_process, _attrs, elements} ->
      Map.keys(elements)
    end)
    |> MapSet.new()
  end

  defp build_element_to_process_map(processes) do
    Enum.flat_map(processes, fn {:bpmn_process, attrs, elements} ->
      process_id = attrs[:id] |> to_string()
      Enum.map(Map.keys(elements), fn elem_id -> {elem_id, process_id} end)
    end)
    |> Map.new()
  end

  # --- Lane validation rules ---

  defp validate_lane_flow_node_refs(lane_set, process_map) do
    collect_all_lane_refs(lane_set.lanes)
    |> Enum.flat_map(fn {ref, lane_id} ->
      if Map.has_key?(process_map, ref) do
        []
      else
        [
          %{
            rule: :lane_flow_node_ref,
            node_id: lane_id,
            message: "Lane '#{lane_id}' references non-existent flow node '#{ref}'",
            severity: :error
          }
        ]
      end
    end)
  end

  defp validate_lane_duplicate_refs(lane_set) do
    check_duplicate_refs_at_level(lane_set.lanes)
  end

  defp check_duplicate_refs_at_level(lanes) do
    # Check for duplicates at this nesting level
    level_issues =
      lanes
      |> Enum.flat_map(fn lane ->
        Enum.map(lane.flow_node_refs, fn ref -> {ref, lane.id} end)
      end)
      |> Enum.group_by(fn {ref, _} -> ref end, fn {_, lane_id} -> lane_id end)
      |> Enum.flat_map(fn {ref, lane_ids} ->
        if length(lane_ids) > 1 do
          [
            %{
              rule: :lane_duplicate_ref,
              node_id: ref,
              message:
                "Node '#{ref}' appears in multiple lanes at the same level: #{Enum.join(Enum.uniq(lane_ids), ", ")}",
              severity: :error
            }
          ]
        else
          []
        end
      end)

    # Recurse into child lane sets
    child_issues =
      Enum.flat_map(lanes, fn lane ->
        case lane[:child_lane_set] do
          %{lanes: child_lanes} -> check_duplicate_refs_at_level(child_lanes)
          nil -> []
        end
      end)

    level_issues ++ child_issues
  end

  defp collect_all_lane_refs(lanes) do
    Enum.flat_map(lanes, fn lane ->
      own_refs = Enum.map(lane.flow_node_refs, fn ref -> {ref, lane.id} end)

      child_refs =
        case lane[:child_lane_set] do
          %{lanes: child_lanes} -> collect_all_lane_refs(child_lanes)
          nil -> []
        end

      own_refs ++ child_refs
    end)
  end

  @multi_instance_activity_types [
    :bpmn_activity_task,
    :bpmn_activity_task_user,
    :bpmn_activity_task_script,
    :bpmn_activity_task_service,
    :bpmn_activity_task_manual,
    :bpmn_activity_task_send,
    :bpmn_activity_task_receive,
    :bpmn_activity_subprocess,
    :bpmn_activity_subprocess_embeded
  ]

  defp validate_multi_instance(process_map) do
    process_map
    |> Enum.flat_map(fn
      {id, {type, attrs}} when type in @multi_instance_activity_types ->
        case Map.get(attrs, :loop_characteristics) do
          %{type: :multi_instance} = loop ->
            validate_multi_instance_loop(id, loop)

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp validate_multi_instance_loop(id, loop) do
    has_cardinality = loop[:loopCardinality] != nil
    has_data_input = loop[:loopDataInputRef] != nil

    if has_cardinality or has_data_input do
      []
    else
      [
        %{
          rule: :multi_instance_cardinality,
          node_id: id,
          message: "Multi-instance activity '#{id}' requires loopCardinality or loopDataInputRef",
          severity: :error
        }
      ]
    end
  end

  defp empty_list?([]), do: true
  defp empty_list?(_), do: false
end
