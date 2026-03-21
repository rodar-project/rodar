defmodule Rodar.Engine.Diagram.Export do
  @moduledoc """
  Exports a parsed BPMN diagram map back to BPMN 2.0 XML.

  This is the inverse of `Rodar.Engine.Diagram.load/1`. Given a diagram map
  produced by the parser, it generates normalized BPMN 2.0 XML using IO lists
  for efficient string building.

  Supports all element types including lane sets (with nested child lane sets),
  collaboration elements, event definitions, and item definitions. Vendor-specific
  attributes and internal keys (like `_elems` and `lane_set`) are stripped from
  XML attributes and handled structurally instead.

  ## See Also

  - `Rodar.Engine.Diagram` -- the parser (inverse of this module)

  ## Example

      iex> xml = File.read!("./test/fixtures/simple.bpmn")
      iex> diagram = Rodar.Engine.Diagram.load(xml)
      iex> exported = Rodar.Engine.Diagram.Export.to_xml(diagram)
      iex> String.contains?(exported, "bpmn2:startEvent")
      true

  """

  @type_to_tag %{
    bpmn_event_start: "bpmn2:startEvent",
    bpmn_event_end: "bpmn2:endEvent",
    bpmn_event_intermediate_throw: "bpmn2:intermediateThrowEvent",
    bpmn_event_intermediate_catch: "bpmn2:intermediateCatchEvent",
    bpmn_event_boundary: "bpmn2:boundaryEvent",
    bpmn_gateway_exclusive: "bpmn2:exclusiveGateway",
    bpmn_gateway_inclusive: "bpmn2:inclusiveGateway",
    bpmn_gateway_parallel: "bpmn2:parallelGateway",
    bpmn_gateway_complex: "bpmn2:complexGateway",
    bpmn_gateway_exclusive_event: "bpmn2:eventGateway",
    bpmn_activity_task: "bpmn2:task",
    bpmn_activity_task_user: "bpmn2:userTask",
    bpmn_activity_task_script: "bpmn2:scriptTask",
    bpmn_activity_task_service: "bpmn2:serviceTask",
    bpmn_activity_task_send: "bpmn2:sendTask",
    bpmn_activity_task_receive: "bpmn2:receiveTask",
    bpmn_activity_task_manual: "bpmn2:manualTask",
    bpmn_activity_subprocess: "bpmn2:callActivity",
    bpmn_activity_subprocess_embeded: "bpmn2:subProcess",
    bpmn_activity_subprocess_transaction: "bpmn2:transaction",
    bpmn_sequence_flow: "bpmn2:sequenceFlow",
    bpmn_data_store_reference: "bpmn2:dataStoreReference",
    bpmn_property: "bpmn2:property"
  }

  # Keys that are handled structurally, not as XML attributes
  @internal_keys ~w(
    _elems incoming outgoing elements script conditionExpression
    ioSpecification dataInputAssociation dataOutputAssociation
    messageEventDefinition signalEventDefinition errorEventDefinition
    escalationEventDefinition compensateEventDefinition terminateEventDefinition
    timerEventDefinition conditionalEventDefinition cancelEventDefinition
    timeDuration timeCycle timeDate
    condition condition_language
    lane_set
  )a

  @doc """
  Converts a parsed BPMN diagram map to a BPMN 2.0 XML string.

  ## Parameters

    * `diagram` - A diagram map as returned by `Rodar.Engine.Diagram.load/1`

  ## Returns

  A string containing valid BPMN 2.0 XML.
  """
  @spec to_xml(map()) :: String.t()
  def to_xml(diagram) do
    [build_xml_declaration(), build_definitions(diagram)]
    |> IO.iodata_to_binary()
  end

  # --- Top-level builders ---

  defp build_xml_declaration do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n)
  end

  defp build_definitions(diagram) do
    attrs =
      [
        {"id", diagram.id},
        {"xmlns:bpmn2", "http://www.omg.org/spec/BPMN/20100524/MODEL"},
        {"xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"},
        {"expressionLanguage", non_empty(diagram[:expression_language])},
        {"typeLanguage", non_empty(diagram[:type_language])}
      ]
      |> build_attrs()

    children =
      [
        build_collaboration(diagram[:collaboration], 1),
        build_item_definitions(diagram[:item_definitions], 1),
        Enum.map(diagram.processes, &build_process(&1, 1))
      ]

    tag("bpmn2:definitions", attrs, children, 0)
  end

  defp build_collaboration(nil, _depth), do: []

  defp build_collaboration(collab, depth) do
    attrs = build_attrs([{"id", collab.id}])

    children = [
      Enum.map(collab.participants, &build_participant(&1, depth + 1)),
      Enum.map(collab.message_flows, &build_message_flow(&1, depth + 1))
    ]

    tag("bpmn2:collaboration", attrs, children, depth)
  end

  defp build_participant(p, depth) do
    attrs =
      [
        {"id", p.id},
        {"name", non_empty(p[:name])},
        {"processRef", non_empty(p[:processRef])}
      ]
      |> build_attrs()

    self_closing_tag("bpmn2:participant", attrs, depth)
  end

  defp build_message_flow(mf, depth) do
    attrs =
      [
        {"id", mf.id},
        {"name", non_empty(mf[:name])},
        {"sourceRef", mf.sourceRef},
        {"targetRef", mf.targetRef}
      ]
      |> build_attrs()

    self_closing_tag("bpmn2:messageFlow", attrs, depth)
  end

  defp build_item_definitions(nil, _depth), do: []

  defp build_item_definitions(item_defs, depth) when map_size(item_defs) == 0 do
    _ = depth
    []
  end

  defp build_item_definitions(item_defs, depth) do
    item_defs
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {_id, {:bpmn_item_definition, attrs}} ->
      xml_attrs =
        attrs
        |> filter_exportable_attrs()
        |> sort_attrs()
        |> build_attrs()

      self_closing_tag("bpmn2:itemDefinition", xml_attrs, depth)
    end)
  end

  defp build_process({:bpmn_process, attrs, elements}, depth) do
    xml_attrs =
      attrs
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    children = [
      build_lane_set(Map.get(attrs, :lane_set), depth + 1),
      build_process_elements(elements, depth + 1)
    ]

    tag("bpmn2:process", xml_attrs, children, depth)
  end

  defp build_process_elements(elements, depth) do
    {seq_flows, others} =
      elements
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.split_with(fn {_id, {type, _}} -> type == :bpmn_sequence_flow end)

    Enum.map(others, fn {_id, elem} -> build_element(elem, depth) end) ++
      Enum.map(seq_flows, fn {_id, elem} -> build_element(elem, depth) end)
  end

  # --- Element dispatcher ---

  defp build_element({:bpmn_sequence_flow, attrs}, depth) do
    build_sequence_flow(attrs, depth)
  end

  defp build_element({:bpmn_property, attrs}, depth) do
    xml_attrs =
      attrs
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    self_closing_tag("bpmn2:property", xml_attrs, depth)
  end

  defp build_element({:bpmn_data_store_reference, attrs}, depth) do
    xml_attrs =
      attrs
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    self_closing_tag("bpmn2:dataStoreReference", xml_attrs, depth)
  end

  defp build_element({type, attrs}, depth) when type in [:bpmn_activity_subprocess_embeded] do
    build_subprocess(attrs, depth)
  end

  defp build_element({:bpmn_activity_subprocess_transaction, attrs}, depth) do
    build_transaction(attrs, depth)
  end

  defp build_element({type, attrs}, depth) do
    tag_name = Map.get(@type_to_tag, type)

    if tag_name do
      build_typed_element(type, tag_name, attrs, depth)
    else
      []
    end
  end

  # --- Typed element builders ---

  defp build_typed_element(type, tag_name, attrs, depth) do
    case element_category(type) do
      :event -> build_event(tag_name, type, attrs, depth)
      :gateway -> build_gateway(tag_name, attrs, depth)
      :task -> build_task(tag_name, type, attrs, depth)
      :other -> build_generic(tag_name, attrs, depth)
    end
  end

  defp element_category(type) do
    cond do
      type in [
        :bpmn_event_start,
        :bpmn_event_end,
        :bpmn_event_intermediate_throw,
        :bpmn_event_intermediate_catch,
        :bpmn_event_boundary
      ] ->
        :event

      type in [
        :bpmn_gateway_exclusive,
        :bpmn_gateway_inclusive,
        :bpmn_gateway_parallel,
        :bpmn_gateway_complex,
        :bpmn_gateway_exclusive_event
      ] ->
        :gateway

      type in [
        :bpmn_activity_task,
        :bpmn_activity_task_user,
        :bpmn_activity_task_script,
        :bpmn_activity_task_service,
        :bpmn_activity_task_send,
        :bpmn_activity_task_receive,
        :bpmn_activity_task_manual,
        :bpmn_activity_subprocess,
        :bpmn_activity_subprocess_transaction
      ] ->
        :task

      true ->
        :other
    end
  end

  # --- Events ---

  defp build_event(tag_name, type, attrs, depth) do
    xml_attrs = build_event_attrs(type, attrs)

    children = [
      build_incoming_outgoing(attrs, depth + 1),
      build_event_definitions(attrs, depth + 1)
    ]

    tag(tag_name, xml_attrs, children, depth)
  end

  defp build_event_attrs(:bpmn_event_boundary, attrs) do
    attrs
    |> Map.take([:id, :name, :attachedToRef, :cancelActivity])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_event_attrs(_type, attrs) do
    attrs
    |> Map.take([:id, :name])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_event_definitions(attrs, depth) do
    [
      build_event_def(:messageEventDefinition, attrs, depth),
      build_event_def(:signalEventDefinition, attrs, depth),
      build_event_def(:errorEventDefinition, attrs, depth),
      build_event_def(:escalationEventDefinition, attrs, depth),
      build_event_def(:compensateEventDefinition, attrs, depth),
      build_event_def(:terminateEventDefinition, attrs, depth),
      build_event_def(:timerEventDefinition, attrs, depth),
      build_event_def(:conditionalEventDefinition, attrs, depth),
      build_event_def(:cancelEventDefinition, attrs, depth)
    ]
  end

  defp build_event_def(:messageEventDefinition, attrs, depth) do
    case Map.get(attrs, :messageEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_message, def_attrs} ->
        xml_attrs =
          def_attrs
          |> Map.take([:messageRef, :correlationKey])
          |> filter_exportable_attrs()
          |> sort_attrs()
          |> build_attrs()

        self_closing_or_empty("bpmn2:messageEventDefinition", xml_attrs, depth)
    end
  end

  defp build_event_def(:signalEventDefinition, attrs, depth) do
    case Map.get(attrs, :signalEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_signal, def_attrs} ->
        xml_attrs =
          def_attrs
          |> Map.take([:signalRef])
          |> filter_exportable_attrs()
          |> sort_attrs()
          |> build_attrs()

        self_closing_or_empty("bpmn2:signalEventDefinition", xml_attrs, depth)
    end
  end

  defp build_event_def(:errorEventDefinition, attrs, depth) do
    case Map.get(attrs, :errorEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_error, def_attrs} ->
        xml_attrs =
          def_attrs
          |> Map.take([:errorRef])
          |> filter_exportable_attrs()
          |> sort_attrs()
          |> build_attrs()

        self_closing_or_empty("bpmn2:errorEventDefinition", xml_attrs, depth)
    end
  end

  defp build_event_def(:escalationEventDefinition, attrs, depth) do
    case Map.get(attrs, :escalationEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_escalation, def_attrs} ->
        xml_attrs =
          def_attrs
          |> Map.take([:escalationRef])
          |> filter_exportable_attrs()
          |> sort_attrs()
          |> build_attrs()

        self_closing_or_empty("bpmn2:escalationEventDefinition", xml_attrs, depth)
    end
  end

  defp build_event_def(:compensateEventDefinition, attrs, depth) do
    case Map.get(attrs, :compensateEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_compensate, def_attrs} ->
        xml_attrs =
          def_attrs
          |> Map.take([:activityRef, :waitForCompletion])
          |> filter_exportable_attrs()
          |> sort_attrs()
          |> build_attrs()

        self_closing_or_empty("bpmn2:compensateEventDefinition", xml_attrs, depth)
    end
  end

  defp build_event_def(:terminateEventDefinition, attrs, depth) do
    case Map.get(attrs, :terminateEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_terminate, _} ->
        self_closing_tag("bpmn2:terminateEventDefinition", "", depth)
    end
  end

  defp build_event_def(:timerEventDefinition, attrs, depth) do
    case Map.get(attrs, :timerEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_timer, def_attrs} ->
        children = build_timer_children(def_attrs, depth + 1)
        tag("bpmn2:timerEventDefinition", "", children, depth)
    end
  end

  defp build_event_def(:cancelEventDefinition, attrs, depth) do
    case Map.get(attrs, :cancelEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_cancel, _} ->
        self_closing_tag("bpmn2:cancelEventDefinition", "", depth)
    end
  end

  defp build_event_def(:conditionalEventDefinition, attrs, depth) do
    case Map.get(attrs, :conditionalEventDefinition) do
      nil ->
        []

      {:bpmn_event_definition_conditional, def_attrs} ->
        children = build_conditional_children(def_attrs, depth + 1)

        if children == [] do
          self_closing_tag("bpmn2:conditionalEventDefinition", "", depth)
        else
          tag("bpmn2:conditionalEventDefinition", "", children, depth)
        end
    end
  end

  defp build_timer_children(def_attrs, depth) do
    [
      build_timer_child("bpmn2:timeDuration", Map.get(def_attrs, :timeDuration), depth),
      build_timer_child("bpmn2:timeCycle", Map.get(def_attrs, :timeCycle), depth),
      build_timer_child("bpmn2:timeDate", Map.get(def_attrs, :timeDate), depth)
    ]
  end

  defp build_timer_child(_tag_name, nil, _depth), do: []

  defp build_timer_child(tag_name, value, depth) do
    text_tag(tag_name, "", value, depth)
  end

  defp build_conditional_children(def_attrs, depth) do
    case Map.get(def_attrs, :condition) do
      nil ->
        []

      condition ->
        lang = Map.get(def_attrs, :condition_language, "elixir")

        lang_attr =
          if lang != "" do
            build_attrs([{"language", lang}])
          else
            ""
          end

        text_tag("bpmn2:condition", lang_attr, condition, depth)
    end
  end

  # --- Lane Set ---

  defp build_lane_set(nil, _depth), do: []

  defp build_lane_set(lane_set, depth) do
    attrs = build_attrs([{"id", non_empty(lane_set[:id])}])
    children = Enum.map(lane_set.lanes, &build_lane(&1, depth + 1))
    tag("bpmn2:laneSet", attrs, children, depth)
  end

  defp build_lane(lane, depth) do
    attrs =
      [
        {"id", lane.id},
        {"name", non_empty(lane[:name])}
      ]
      |> build_attrs()

    children = [
      Enum.map(lane.flow_node_refs, &text_tag("bpmn2:flowNodeRef", "", &1, depth + 1)),
      build_child_lane_set(lane[:child_lane_set], depth + 1)
    ]

    tag("bpmn2:lane", attrs, children, depth)
  end

  defp build_child_lane_set(nil, _depth), do: []

  defp build_child_lane_set(child_lane_set, depth) do
    attrs = build_attrs([{"id", non_empty(child_lane_set[:id])}])
    children = Enum.map(child_lane_set.lanes, &build_lane(&1, depth + 1))
    tag("bpmn2:childLaneSet", attrs, children, depth)
  end

  # --- Gateways ---

  defp build_gateway(tag_name, attrs, depth) do
    xml_attrs =
      attrs
      |> Map.take([:id, :name, :default])
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    children = build_incoming_outgoing(attrs, depth + 1)

    tag(tag_name, xml_attrs, children, depth)
  end

  # --- Tasks ---

  defp build_task(tag_name, type, attrs, depth) do
    xml_attrs = build_task_attrs(type, attrs)
    children = build_task_children(type, attrs, depth + 1)

    tag(tag_name, xml_attrs, children, depth)
  end

  defp build_task_attrs(:bpmn_activity_task_script, attrs) do
    attrs
    |> Map.take([:id, :name, :scriptFormat])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_task_attrs(:bpmn_activity_task_send, attrs) do
    attrs
    |> Map.take([:id, :name, :messageRef])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_task_attrs(:bpmn_activity_task_receive, attrs) do
    attrs
    |> Map.take([:id, :name, :messageRef])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_task_attrs(:bpmn_activity_subprocess, attrs) do
    attrs
    |> Map.take([:id, :name, :calledElement])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_task_attrs(_type, attrs) do
    attrs
    |> Map.take([:id, :name])
    |> filter_exportable_attrs()
    |> sort_attrs()
    |> build_attrs()
  end

  defp build_task_children(:bpmn_activity_task_script, attrs, depth) do
    [
      build_incoming_outgoing(attrs, depth),
      build_io_specification(attrs, depth),
      build_data_associations(attrs, depth),
      build_script(attrs, depth)
    ]
  end

  defp build_task_children(:bpmn_activity_task_user, attrs, depth) do
    [
      build_incoming_outgoing(attrs, depth),
      build_io_specification(attrs, depth),
      build_data_associations(attrs, depth)
    ]
  end

  defp build_task_children(_type, attrs, depth) do
    [
      build_incoming_outgoing(attrs, depth),
      build_properties(attrs, depth),
      build_data_associations(attrs, depth)
    ]
  end

  defp build_properties(attrs, depth) do
    # Some tasks like scriptTask have properties stored directly
    attrs
    |> Enum.filter(fn
      {_key, {:bpmn_property, _}} -> true
      _ -> false
    end)
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {_key, {:bpmn_property, prop_attrs}} ->
      xml_attrs =
        prop_attrs
        |> filter_exportable_attrs()
        |> sort_attrs()
        |> build_attrs()

      self_closing_tag("bpmn2:property", xml_attrs, depth)
    end)
  end

  defp build_script(attrs, depth) do
    case Map.get(attrs, :script) do
      nil -> []
      {:bpmn_script, %{expression: expr}} -> text_tag("bpmn2:script", "", expr, depth)
    end
  end

  defp build_io_specification(attrs, depth) do
    case Map.get(attrs, :ioSpecification) do
      nil -> []
      [] -> []
      specs when is_list(specs) -> Enum.map(specs, &build_io_spec(&1, depth))
    end
  end

  defp build_io_spec({:bpmn_io_specification, spec_attrs}, depth) do
    children = [
      build_data_inputs(Map.get(spec_attrs, :dataInput, []), depth + 1),
      build_data_outputs(Map.get(spec_attrs, :dataOutput, []), depth + 1),
      build_input_sets(Map.get(spec_attrs, :inputSet, []), depth + 1),
      build_output_sets(Map.get(spec_attrs, :outputSet, []), depth + 1)
    ]

    tag("bpmn2:ioSpecification", "", children, depth)
  end

  defp build_data_inputs(inputs, depth) do
    Enum.map(inputs, fn {:bpmn_data_input, input_attrs} ->
      xml_attrs =
        input_attrs
        |> filter_exportable_attrs()
        |> sort_attrs()
        |> build_attrs()

      self_closing_tag("bpmn2:dataInput", xml_attrs, depth)
    end)
  end

  defp build_data_outputs(outputs, depth) do
    Enum.map(outputs, fn {:bpmn_data_output, output_attrs} ->
      xml_attrs =
        output_attrs
        |> filter_exportable_attrs()
        |> sort_attrs()
        |> build_attrs()

      self_closing_tag("bpmn2:dataOutput", xml_attrs, depth)
    end)
  end

  defp build_input_sets(sets, depth) do
    Enum.map(sets, fn {:bpmn_input_set, set_attrs} ->
      refs =
        Map.get(set_attrs, :dataInputRefs, [])
        |> Enum.map(&text_tag("bpmn2:dataInputRefs", "", &1, depth + 1))

      tag("bpmn2:inputSet", "", refs, depth)
    end)
  end

  defp build_output_sets(sets, depth) do
    Enum.map(sets, fn {:bpmn_output_set, set_attrs} ->
      refs =
        Map.get(set_attrs, :dataOutputRefs, [])
        |> Enum.map(&text_tag("bpmn2:dataOutputRefs", "", &1, depth + 1))

      tag("bpmn2:outputSet", "", refs, depth)
    end)
  end

  defp build_data_associations(attrs, depth) do
    input_assocs = Map.get(attrs, :dataInputAssociation, [])
    output_assocs = Map.get(attrs, :dataOutputAssociation, [])

    [
      Enum.map(input_assocs, &build_data_input_association(&1, depth)),
      Enum.map(output_assocs, &build_data_output_association(&1, depth))
    ]
  end

  defp build_data_input_association({:bpmn_data_input_association, assoc_attrs}, depth) do
    xml_attrs =
      assoc_attrs
      |> Map.take([:id])
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    children = [
      build_source_target_ref(:sourceRef, assoc_attrs, depth + 1),
      build_source_target_ref(:targetRef, assoc_attrs, depth + 1),
      build_assignments(Map.get(assoc_attrs, :assignment, []), depth + 1)
    ]

    tag("bpmn2:dataInputAssociation", xml_attrs, children, depth)
  end

  defp build_data_output_association({:bpmn_output_set, assoc_attrs}, depth) do
    xml_attrs =
      assoc_attrs
      |> Map.take([:id])
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    refs =
      Map.get(assoc_attrs, :dataOutputRefs, [])
      |> Enum.map(&text_tag("bpmn2:dataOutputRefs", "", &1, depth + 1))

    tag("bpmn2:dataOutputAssociation", xml_attrs, refs, depth)
  end

  defp build_source_target_ref(key, attrs, depth) do
    case Map.get(attrs, key) do
      nil -> []
      ref -> text_tag("bpmn2:#{key}", "", ref, depth)
    end
  end

  defp build_assignments(assignments, depth) do
    Enum.map(assignments, fn {:bpmn_assignment, assoc_attrs} ->
      children = [
        build_from_to(:from, assoc_attrs, depth + 1),
        build_from_to(:to, assoc_attrs, depth + 1)
      ]

      tag("bpmn2:assignment", "", children, depth)
    end)
  end

  defp build_from_to(:from, attrs, depth) do
    case Map.get(attrs, :from) do
      nil -> []
      {:bpmn_from, %{content: content}} -> text_tag("bpmn2:from", "", content, depth)
    end
  end

  defp build_from_to(:to, attrs, depth) do
    case Map.get(attrs, :to) do
      nil -> []
      {:bpmn_to, %{content: content}} -> text_tag("bpmn2:to", "", content, depth)
    end
  end

  # --- Transaction Subprocess ---

  defp build_transaction(attrs, depth) do
    xml_attrs =
      attrs
      |> Map.take([:id, :name])
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    elements = Map.get(attrs, :elements, %{})

    children = [
      build_incoming_outgoing(attrs, depth + 1),
      build_process_elements(elements, depth + 1)
    ]

    tag("bpmn2:transaction", xml_attrs, children, depth)
  end

  # --- Embedded Subprocess ---

  defp build_subprocess(attrs, depth) do
    xml_attrs =
      attrs
      |> Map.take([:id, :name])
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    elements = Map.get(attrs, :elements, %{})

    children = [
      build_incoming_outgoing(attrs, depth + 1),
      build_process_elements(elements, depth + 1)
    ]

    tag("bpmn2:subProcess", xml_attrs, children, depth)
  end

  # --- Sequence Flow ---

  defp build_sequence_flow(attrs, depth) do
    xml_attrs =
      [
        {"id", attrs[:id]},
        {"name", non_empty(attrs[:name])},
        {"sourceRef", attrs[:sourceRef]},
        {"targetRef", attrs[:targetRef]}
      ]
      |> build_attrs()

    children = build_condition_expression(attrs[:conditionExpression], depth + 1)

    if children == [] do
      self_closing_tag("bpmn2:sequenceFlow", xml_attrs, depth)
    else
      tag("bpmn2:sequenceFlow", xml_attrs, children, depth)
    end
  end

  defp build_condition_expression(nil, _depth), do: []

  defp build_condition_expression({:bpmn_expression, {lang, expr}}, depth) do
    lang_attr =
      build_attrs([
        {"xsi:type", "bpmn2:tFormalExpression"},
        {"language", non_empty(lang)}
      ])

    if expr == "" do
      self_closing_tag("bpmn2:conditionExpression", lang_attr, depth)
    else
      text_tag("bpmn2:conditionExpression", lang_attr, expr, depth)
    end
  end

  # --- Incoming/Outgoing ---

  defp build_incoming_outgoing(attrs, depth) do
    incoming = Map.get(attrs, :incoming, [])
    outgoing = Map.get(attrs, :outgoing, [])

    [
      Enum.map(incoming, &text_tag("bpmn2:incoming", "", &1, depth)),
      Enum.map(outgoing, &text_tag("bpmn2:outgoing", "", &1, depth))
    ]
  end

  # --- Generic fallback ---

  defp build_generic(tag_name, attrs, depth) do
    xml_attrs =
      attrs
      |> filter_exportable_attrs()
      |> sort_attrs()
      |> build_attrs()

    children = build_incoming_outgoing(attrs, depth + 1)

    tag(tag_name, xml_attrs, children, depth)
  end

  # --- XML helpers ---

  defp tag(name, attrs, children, depth) do
    flat_children = List.flatten(children)

    if flat_children == [] do
      self_closing_tag(name, attrs, depth)
    else
      [
        indent(depth),
        "<",
        name,
        attrs,
        ">\n",
        flat_children,
        indent(depth),
        "</",
        name,
        ">\n"
      ]
    end
  end

  defp self_closing_tag(name, attrs, depth) do
    [indent(depth), "<", name, attrs, " />\n"]
  end

  defp self_closing_or_empty(name, attrs, depth) do
    self_closing_tag(name, attrs, depth)
  end

  defp text_tag(name, attrs, text, depth) do
    [indent(depth), "<", name, attrs, ">", escape_xml(to_string(text)), "</", name, ">\n"]
  end

  defp build_attrs(pairs) when is_list(pairs) do
    pairs
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Enum.map(fn {k, v} -> [" ", to_string(k), ~s(="), escape_xml(to_string(v)), ~s(")] end)
  end

  defp filter_exportable_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {k, v} ->
      k in @internal_keys or v == nil or vendor_attr?(k)
    end)
  end

  defp filter_exportable_attrs(attrs) when is_list(attrs), do: attrs

  defp sort_attrs(pairs) when is_list(pairs) do
    Enum.sort_by(pairs, fn
      {k, _v} when is_atom(k) -> Atom.to_string(k)
      {k, _v} -> to_string(k)
    end)
  end

  defp vendor_attr?(key) do
    key_str = Atom.to_string(key)
    String.contains?(key_str, ":")
  end

  defp escape_xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp indent(depth) do
    String.duplicate("  ", depth)
  end

  defp non_empty(""), do: nil
  defp non_empty(nil), do: nil
  defp non_empty(val), do: val
end
