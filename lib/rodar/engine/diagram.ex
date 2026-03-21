defmodule Rodar.Engine.Diagram do
  @moduledoc """
  Parses BPMN 2.0 XML into Elixir data structures.

  Uses `:erlsom.simple_form/2` to parse XML, then transforms the result into a
  map containing `:processes`, `:item_definitions`, and `:collaboration`. Each
  process is a map of element ID to `{:bpmn_type, %{...}}` tuples that the
  `Rodar` dispatcher can execute.

  Element types are mapped from XML tag names (e.g., `intermediateThrowEvent` becomes
  `:bpmn_event_intermediate_throw`, `intermediateCatchEvent` becomes
  `:bpmn_event_intermediate_catch`). Condition expressions are emitted as
  `{:bpmn_expression, {language, expression}}` tuples.

  Lane sets (`laneSet`, `lane`, `flowNodeRef`, `childLaneSet`) are extracted from
  process elements and stored in the process attrs under the `:lane_set` key. When
  a process has no lanes, `:lane_set` is `nil`. Use `Rodar.Lane` to query lane
  assignments at runtime.

  `export/1` delegates to `Rodar.Engine.Diagram.Export.to_xml/1` for the
  inverse operation.

  `load/2` accepts options for post-parse transformations. The `:handler_map`
  option injects handler modules into service task elements, enabling handler
  wiring at parse time instead of at runtime via `Rodar.TaskRegistry`.

  When `:bpmn_file` and `:app_name` are provided, convention-based handler
  auto-discovery is enabled by default. Discovered handlers are merged with
  any explicit `:handler_map` (explicit entries win). Set `discover_handlers: false`
  to disable. The discovery result is stored under the `:discovery` key in the
  returned map.

  ## See Also

  - `Rodar.Lane` -- lane assignment queries
  - `Rodar.Engine.Diagram.Export` -- inverse XML export
  - `Rodar.Validation` -- structural validation including lane integrity

  ## Examples

      iex> diagram = Rodar.Engine.Diagram.load(File.read!("./priv/bpmn/examples/hiring/hiring.bpmn2"))
      iex> is_map(diagram)
      true

      iex> %{processes: processes} = Rodar.Engine.Diagram.load(File.read!("./priv/bpmn/examples/user_login.bpmn"))
      iex> is_list(processes)
      true

      iex> %{processes: processes} = Rodar.Engine.Diagram.load(File.read!("./priv/bpmn/examples/elements.bpmn"))
      iex> Enum.map(processes, &IO.inspect/1)
      iex> is_list(processes)
      true

  """

  alias Rodar.Scaffold.Discovery

  @doc """
  Parses a BPMN 2.0 XML string into Elixir data structures.
  """
  @spec load(binary()) :: map()
  def load(diagram) do
    {:ok, bpmn, _} = :erlsom.simple_form(diagram, nameFun: &format_tag/3)
    load_definition(bpmn)
  end

  @doc """
  Parses a BPMN 2.0 XML string with options.

  ## Options

    * `:handler_map` — a map of element ID (string) to handler module. For each
      service task whose `id` appears as a key in the map, the corresponding
      module is injected as the `:handler` attribute. This allows wiring service
      task handlers at parse time rather than at runtime via `Rodar.TaskRegistry`.
    * `:bpmn_file` — the BPMN file path (e.g., `"order_processing.bpmn"`). When
      present together with `:app_name`, triggers convention-based handler
      auto-discovery.
    * `:app_name` — the PascalCase application name (e.g., `"MyApp"`). Required
      for auto-discovery.
    * `:discover_handlers` — boolean, defaults to `true`. Set to `false` to
      disable auto-discovery even when `:bpmn_file` and `:app_name` are provided.

  When discovery is active, discovered service task handlers are merged with any
  explicit `:handler_map` (explicit entries take precedence). The discovery result
  is stored under the `:discovery` key in the returned map.

  ## Examples

      iex> xml = \"\"\"
      ...> <?xml version="1.0" encoding="UTF-8"?>
      ...> <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" id="D1">
      ...>   <bpmn:process id="P1" isExecutable="true">
      ...>     <bpmn:serviceTask id="Task_1" name="My Service">
      ...>       <bpmn:outgoing>Flow_1</bpmn:outgoing>
      ...>     </bpmn:serviceTask>
      ...>   </bpmn:process>
      ...> </bpmn:definitions>
      ...> \"\"\"
      iex> diagram = Rodar.Engine.Diagram.load(xml, handler_map: %{"Task_1" => Rodar.Activity.Task.Service.TestHandler})
      iex> {:bpmn_process, _, elements} = hd(diagram.processes)
      iex> {:bpmn_activity_task_service, attrs} = elements["Task_1"]
      iex> attrs.handler
      Rodar.Activity.Task.Service.TestHandler

  """
  @spec load(binary(), keyword()) :: map()
  def load(diagram, opts) when is_list(opts) do
    result = load(diagram)
    apply_opts(result, opts)
  end

  defdelegate export(diagram), to: Rodar.Engine.Diagram.Export, as: :to_xml

  defp apply_opts(result, opts) do
    {result, discovery} = maybe_discover(result, opts)
    explicit_map = Keyword.get(opts, :handler_map, %{})

    merged_map =
      case discovery do
        nil -> explicit_map
        %{handler_map: discovered} -> Map.merge(discovered, explicit_map)
      end

    result =
      if merged_map == %{} do
        result
      else
        inject_handlers(result, merged_map)
      end

    if discovery do
      Map.put(result, :discovery, discovery)
    else
      result
    end
  end

  defp maybe_discover(result, opts) do
    bpmn_file = Keyword.get(opts, :bpmn_file)
    app_name = Keyword.get(opts, :app_name)
    discover? = Keyword.get(opts, :discover_handlers, true)

    if bpmn_file && app_name && discover? do
      discovery =
        Discovery.discover_from_file(result, bpmn_file, app_name: app_name)

      {result, discovery}
    else
      {result, nil}
    end
  end

  defp inject_handlers(result, handler_map) do
    updated_processes =
      Enum.map(result.processes, fn {:bpmn_process, proc_attrs, elements} ->
        {:bpmn_process, proc_attrs, inject_handlers_into_elements(elements, handler_map)}
      end)

    %{result | processes: updated_processes}
  end

  defp inject_handlers_into_elements(elements, handler_map) do
    Map.new(elements, fn
      {id, {:bpmn_activity_task_service, attrs}} ->
        {id, maybe_inject_handler({:bpmn_activity_task_service, attrs}, id, handler_map)}

      {id, {:bpmn_activity_subprocess_embeded, %{elements: nested} = attrs}}
      when is_map(nested) ->
        updated = inject_handlers_into_elements(nested, handler_map)
        {id, {:bpmn_activity_subprocess_embeded, %{attrs | elements: updated}}}

      {id, {:bpmn_activity_subprocess_event, %{elements: nested} = attrs}}
      when is_map(nested) ->
        updated = inject_handlers_into_elements(nested, handler_map)
        {id, {:bpmn_activity_subprocess_event, %{attrs | elements: updated}}}

      {id, elem} ->
        {id, elem}
    end)
  end

  defp maybe_inject_handler({:bpmn_activity_task_service, attrs}, id, handler_map) do
    case Map.fetch(handler_map, id) do
      {:ok, handler} -> {:bpmn_activity_task_service, Map.put(attrs, :handler, handler)}
      :error -> {:bpmn_activity_task_service, attrs}
    end
  end

  defp format_tag(name, _namespace, []) do
    "#{name}"
  end

  defp format_tag(name, ~c"http://www.omg.org/spec/BPMN/20100524/MODEL", _prefix),
    do: "bpmn2:#{name}"

  defp format_tag(name, _namespace, prefix) do
    "#{prefix}:#{name}"
  end

  defp load_definition({_tag, attrs, elems}) do
    attrs = format_attributes(attrs)

    %{
      id: attrs[:id] |> to_string,
      expression_language: attrs[:expressionLanguage] |> to_string,
      type_language: attrs[:typeLanguage] |> to_string,
      processes: load_processes(elems),
      item_definitions: load_item_definitions(elems),
      collaboration: load_collaboration(elems)
    }
  end

  defp format_attributes(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      Map.put(acc, key |> to_string |> String.to_atom(), val |> to_string)
    end)
  end

  defp load_item_definitions(elems) do
    elems
    |> Enum.flat_map(fn elem ->
      case elem do
        {"bpmn2:itemDefinition", attrs, _} ->
          [{:bpmn_item_definition, format_attributes(attrs)}]

        _ ->
          []
      end
    end)
    |> Enum.reduce(%{}, fn {:bpmn_item_definition, attrs} = elem, acc ->
      Map.put(acc, attrs[:id], elem)
    end)
  end

  defp load_processes(elems) do
    elems
    |> Enum.flat_map(fn elem ->
      case elem do
        {"bpmn2:process", attrs, process} ->
          [load_process("bpmn2:process", attrs, process)]

        _ ->
          []
      end
    end)
  end

  defp load_process("bpmn2:process", attrs, elems) do
    proc_attrs = format_attributes(attrs)
    lane_set = load_lane_set(elems)
    {:bpmn_process, Map.put(proc_attrs, :lane_set, lane_set), map_process_elements(elems)}
  end

  defp map_process_elements(elems) do
    elems
    |> Enum.flat_map(&preload_element/1)
    |> Enum.reduce(%{}, fn
      {_, attrs} = elem, acc -> Map.put(acc, attrs[:id], elem)
      _non_element, acc -> acc
    end)
  end

  defp preload_element({type, attrs, elems}) do
    attrs = format_attributes(attrs)

    case load_element(type, attrs, elems) do
      nil -> []
      elem -> [elem]
    end
  end

  defp load_elements(type, elems) do
    elems |> Enum.flat_map(&flat_find(type, &1))
  end

  defp load_first_element(type, elems) do
    elems
    |> Enum.flat_map(&flat_find(type, &1))
    |> Enum.at(0)
  end

  defp flat_find(type, {type, _, _} = elem), do: preload_element(elem)
  defp flat_find(_, _), do: []

  defp load_element("bpmn2:sequenceFlow", attrs, elems),
    do:
      {:bpmn_sequence_flow,
       %{
         id: attrs[:id] |> to_string,
         name: attrs[:name] |> to_string,
         sourceRef: attrs[:sourceRef] |> to_string,
         targetRef: attrs[:targetRef] |> to_string,
         conditionExpression: load_first_element("bpmn2:conditionExpression", elems),
         isImmediate: attrs[:isImmediate]
       }}

  defp load_element("bpmn2:incoming", _, [id]), do: id |> to_string
  defp load_element("bpmn2:outgoing", _, [id]), do: id |> to_string
  defp load_element("bpmn2:sourceRef", _, [id]), do: id |> to_string
  defp load_element("bpmn2:targetRef", _, [id]), do: id |> to_string
  defp load_element("bpmn2:property", attrs, _), do: {:bpmn_property, attrs}
  defp load_element("bpmn2:dataInput", attrs, _), do: {:bpmn_data_input, attrs}
  defp load_element("bpmn2:dataOutput", attrs, _), do: {:bpmn_data_output, attrs}
  defp load_element("bpmn2:dataOutputRefs", _, [id]), do: id |> to_string
  defp load_element("bpmn2:dataInputRefs", _, [id]), do: id |> to_string

  defp load_element("bpmn2:inputSet", attrs, elems),
    do:
      {:bpmn_input_set,
       Map.merge(attrs, %{dataInputRefs: load_elements("bpmn2:dataInputRefs", elems)})}

  defp load_element("bpmn2:outputSet", attrs, elems),
    do:
      {:bpmn_output_set,
       Map.merge(attrs, %{dataOutputRefs: load_elements("bpmn2:dataOutputRefs", elems)})}

  defp load_element("bpmn2:dataInputAssociation", attrs, elems),
    do:
      {:bpmn_data_input_association,
       Map.merge(attrs, %{
         dataInputRefs: load_elements("bpmn2:dataInputRefs", elems),
         sourceRef: load_first_element("bpmn2:sourceRef", elems),
         targetRef: load_first_element("bpmn2:targetRef", elems),
         assignment: load_elements("bpmn2:assignment", elems)
       })}

  defp load_element("bpmn2:dataOutputAssociation", attrs, elems),
    do:
      {:bpmn_output_set,
       Map.merge(attrs, %{dataOutputRefs: load_elements("bpmn2:dataOutputRefs", elems)})}

  defp load_element("bpmn2:ioSpecification", attrs, elems),
    do:
      {:bpmn_io_specification,
       Map.merge(attrs, %{
         dataInput: load_elements("bpmn2:dataInput", elems),
         dataOutput: load_elements("bpmn2:dataOutput", elems),
         inputSet: load_elements("bpmn2:inputSet", elems),
         outputSet: load_elements("bpmn2:outputSet", elems)
       })}

  defp load_element("bpmn2:assignment", attrs, elems),
    do:
      {:bpmn_assignment,
       Map.merge(attrs, %{
         from: load_first_element("bpmn2:from", elems),
         to: load_first_element("bpmn2:to", elems)
       })}

  defp load_element("bpmn2:from", attrs, [content]),
    do: {:bpmn_from, Map.merge(attrs, %{content: content |> to_string})}

  defp load_element("bpmn2:to", attrs, [content]),
    do: {:bpmn_to, Map.merge(attrs, %{content: content |> to_string})}

  defp load_element("bpmn2:conditionExpression", attrs, [content]) do
    lang = Map.get(attrs, :language, "elixir") |> to_string()
    {:bpmn_expression, {lang, content |> to_string()}}
  end

  defp load_element("bpmn2:conditionExpression", _attrs, []) do
    {:bpmn_expression, {"elixir", ""}}
  end

  defp load_element("bpmn2:script", attrs, [content]),
    do: {:bpmn_script, Map.merge(attrs, %{expression: content |> to_string})}

  defp load_element("bpmn2:startEvent", attrs, elems),
    do:
      {:bpmn_event_start,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         conditionalEventDefinition:
           load_first_element("bpmn2:conditionalEventDefinition", elems),
         compensateEventDefinition: load_first_element("bpmn2:compensateEventDefinition", elems),
         escalationEventDefinition: load_first_element("bpmn2:escalationEventDefinition", elems),
         errorEventDefinition: load_first_element("bpmn2:errorEventDefinition", elems),
         messageEventDefinition: load_first_element("bpmn2:messageEventDefinition", elems),
         signalEventDefinition: load_first_element("bpmn2:signalEventDefinition", elems),
         terminateEventDefinition: load_first_element("bpmn2:terminateEventDefinition", elems),
         timerEventDefinition: load_first_element("bpmn2:timerEventDefinition", elems)
       })}

  defp load_element("bpmn2:endEvent", attrs, elems),
    do:
      {:bpmn_event_end,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         conditionalEventDefinition:
           load_first_element("bpmn2:conditionalEventDefinition", elems),
         compensateEventDefinition: load_first_element("bpmn2:compensateEventDefinition", elems),
         escalationEventDefinition: load_first_element("bpmn2:escalationEventDefinition", elems),
         errorEventDefinition: load_first_element("bpmn2:errorEventDefinition", elems),
         messageEventDefinition: load_first_element("bpmn2:messageEventDefinition", elems),
         signalEventDefinition: load_first_element("bpmn2:signalEventDefinition", elems),
         terminateEventDefinition: load_first_element("bpmn2:terminateEventDefinition", elems),
         timerEventDefinition: load_first_element("bpmn2:timerEventDefinition", elems)
       })}

  defp load_element("bpmn2:intermediateThrowEvent", attrs, elems),
    do:
      {:bpmn_event_intermediate_throw,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         conditionalEventDefinition:
           load_first_element("bpmn2:conditionalEventDefinition", elems),
         compensateEventDefinition: load_first_element("bpmn2:compensateEventDefinition", elems),
         escalationEventDefinition: load_first_element("bpmn2:escalationEventDefinition", elems),
         errorEventDefinition: load_first_element("bpmn2:errorEventDefinition", elems),
         messageEventDefinition: load_first_element("bpmn2:messageEventDefinition", elems),
         signalEventDefinition: load_first_element("bpmn2:signalEventDefinition", elems),
         terminateEventDefinition: load_first_element("bpmn2:terminateEventDefinition", elems),
         timerEventDefinition: load_first_element("bpmn2:timerEventDefinition", elems)
       })}

  defp load_element("bpmn2:intermediateCatchEvent", attrs, elems),
    do:
      {:bpmn_event_intermediate_catch,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         conditionalEventDefinition:
           load_first_element("bpmn2:conditionalEventDefinition", elems),
         compensateEventDefinition: load_first_element("bpmn2:compensateEventDefinition", elems),
         escalationEventDefinition: load_first_element("bpmn2:escalationEventDefinition", elems),
         errorEventDefinition: load_first_element("bpmn2:errorEventDefinition", elems),
         messageEventDefinition: load_first_element("bpmn2:messageEventDefinition", elems),
         signalEventDefinition: load_first_element("bpmn2:signalEventDefinition", elems),
         terminateEventDefinition: load_first_element("bpmn2:terminateEventDefinition", elems),
         timerEventDefinition: load_first_element("bpmn2:timerEventDefinition", elems)
       })}

  defp load_element("bpmn2:exclusiveGateway", attrs, elems),
    do:
      {:bpmn_gateway_exclusive,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:inclusiveGateway", attrs, elems),
    do:
      {:bpmn_gateway_inclusive,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:parallelGateway", attrs, elems),
    do:
      {:bpmn_gateway_parallel,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:complexGateway", attrs, elems),
    do:
      {:bpmn_gateway_complex,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:eventGateway", attrs, elems),
    do:
      {:bpmn_gateway_exclusive_event,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:serviceTask", attrs, elems),
    do:
      {:bpmn_activity_task_service,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:userTask", attrs, elems),
    do:
      {:bpmn_activity_task_user,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         ioSpecification: load_elements("bpmn2:ioSpecification", elems),
         dataInputAssociation: load_elements("bpmn2:dataInputAssociation", elems),
         dataOutputAssociation: load_elements("bpmn2:dataOutputAssociation", elems)
       })}

  defp load_element("bpmn2:scriptTask", attrs, elems),
    do:
      {:bpmn_activity_task_script,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         ioSpecification: load_elements("bpmn2:ioSpecification", elems),
         dataInputAssociation: load_elements("bpmn2:dataInputAssociation", elems),
         dataOutputAssociation: load_elements("bpmn2:dataOutputAssociation", elems),
         script: load_first_element("bpmn2:script", elems)
       })}

  defp load_element("bpmn2:dataStoreReference", attrs, elems),
    do: {:bpmn_data_store_reference, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:task", attrs, elems),
    do:
      {:bpmn_activity_task,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         _elems: elems
       })}

  defp load_element("bpmn2:conditionalEventDefinition", attrs, elems) do
    {condition, condition_language} =
      Enum.find_value(elems, {nil, "elixir"}, fn
        {"bpmn2:condition", cond_attrs, [value]} ->
          lang =
            cond_attrs
            |> format_attributes()
            |> Map.get(:language, "elixir")
            |> to_string()

          {to_string(value), lang}

        _ ->
          nil
      end)

    merged =
      Map.merge(attrs, %{
        condition: condition,
        condition_language: condition_language,
        _elems: elems
      })

    {:bpmn_event_definition_conditional, merged}
  end

  defp load_element("bpmn2:compensateEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_compensate, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:escalationEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_escalation, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:errorEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_error, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:messageEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_message, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:signalEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_signal, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:terminateEventDefinition", attrs, elems),
    do: {:bpmn_event_definition_terminate, Map.merge(attrs, %{_elems: elems})}

  defp load_element("bpmn2:timerEventDefinition", attrs, elems) do
    timer_attrs =
      Enum.reduce(elems, %{}, fn
        {"bpmn2:timeDuration", _, [value]}, acc -> Map.put(acc, :timeDuration, to_string(value))
        {"bpmn2:timeCycle", _, [value]}, acc -> Map.put(acc, :timeCycle, to_string(value))
        {"bpmn2:timeDate", _, [value]}, acc -> Map.put(acc, :timeDate, to_string(value))
        _, acc -> acc
      end)

    {:bpmn_event_definition_timer, Map.merge(attrs, timer_attrs)}
  end

  defp load_element("bpmn2:sendTask", attrs, elems),
    do:
      {:bpmn_activity_task_send,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:receiveTask", attrs, elems),
    do:
      {:bpmn_activity_task_receive,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:manualTask", attrs, elems),
    do:
      {:bpmn_activity_task_manual,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems)
       })}

  defp load_element("bpmn2:subProcess", attrs, elems) do
    type =
      if to_string(Map.get(attrs, :triggeredByEvent, "false")) == "true" do
        :bpmn_activity_subprocess_event
      else
        :bpmn_activity_subprocess_embeded
      end

    {type,
     Map.merge(attrs, %{
       incoming: load_elements("bpmn2:incoming", elems),
       outgoing: load_elements("bpmn2:outgoing", elems),
       elements: map_process_elements(elems)
     })}
  end

  defp load_element("bpmn2:boundaryEvent", attrs, elems),
    do:
      {:bpmn_event_boundary,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         conditionalEventDefinition:
           load_first_element("bpmn2:conditionalEventDefinition", elems),
         compensateEventDefinition: load_first_element("bpmn2:compensateEventDefinition", elems),
         escalationEventDefinition: load_first_element("bpmn2:escalationEventDefinition", elems),
         errorEventDefinition: load_first_element("bpmn2:errorEventDefinition", elems),
         messageEventDefinition: load_first_element("bpmn2:messageEventDefinition", elems),
         signalEventDefinition: load_first_element("bpmn2:signalEventDefinition", elems),
         timerEventDefinition: load_first_element("bpmn2:timerEventDefinition", elems)
       })}

  defp load_element("bpmn2:callActivity", attrs, elems),
    do:
      {:bpmn_activity_subprocess,
       Map.merge(attrs, %{
         incoming: load_elements("bpmn2:incoming", elems),
         outgoing: load_elements("bpmn2:outgoing", elems),
         calledElement: (attrs[:calledElement] || "") |> to_string()
       })}

  defp load_element("bpmn2:extensionElements", attrs, elems),
    do: {:bpmn_extension_elements, Map.merge(attrs, %{_elems: elems})}

  defp load_element(_type, _attrs, _elems), do: nil

  # --- Lane parsing ---

  defp load_lane_set(elems) do
    Enum.find_value(elems, fn
      {"bpmn2:laneSet", attrs, children} ->
        attrs = format_attributes(attrs)

        %{
          id: (attrs[:id] || "") |> to_string(),
          lanes: load_lanes(children)
        }

      _ ->
        nil
    end)
  end

  defp load_lanes(elems) do
    Enum.flat_map(elems, fn
      {"bpmn2:lane", attrs, children} ->
        attrs = format_attributes(attrs)

        [
          %{
            id: attrs[:id] |> to_string(),
            name: (attrs[:name] || "") |> to_string(),
            flow_node_refs: load_flow_node_refs(children),
            child_lane_set: load_child_lane_set(children)
          }
        ]

      _ ->
        []
    end)
  end

  defp load_flow_node_refs(elems) do
    Enum.flat_map(elems, fn
      {"bpmn2:flowNodeRef", _, [ref]} -> [to_string(ref)]
      _ -> []
    end)
  end

  defp load_child_lane_set(elems) do
    Enum.find_value(elems, fn
      {"bpmn2:childLaneSet", attrs, children} ->
        attrs = format_attributes(attrs)

        %{
          id: (attrs[:id] || "") |> to_string(),
          lanes: load_lanes(children)
        }

      _ ->
        nil
    end)
  end

  # --- Collaboration parsing ---

  defp load_collaboration(elems) do
    Enum.find_value(elems, fn
      {"bpmn2:collaboration", attrs, children} ->
        attrs = format_attributes(attrs)

        %{
          id: attrs[:id] |> to_string(),
          participants: load_participants(children),
          message_flows: load_message_flows(children)
        }

      _ ->
        nil
    end)
  end

  defp load_participants(elems) do
    Enum.flat_map(elems, fn
      {"bpmn2:participant", attrs, _} ->
        attrs = format_attributes(attrs)

        [
          %{
            id: attrs[:id] |> to_string(),
            name: (attrs[:name] || "") |> to_string(),
            processRef: (attrs[:processRef] || "") |> to_string()
          }
        ]

      _ ->
        []
    end)
  end

  defp load_message_flows(elems) do
    Enum.flat_map(elems, fn
      {"bpmn2:messageFlow", attrs, _} ->
        attrs = format_attributes(attrs)

        [
          %{
            id: attrs[:id] |> to_string(),
            name: (attrs[:name] || "") |> to_string(),
            sourceRef: attrs[:sourceRef] |> to_string(),
            targetRef: attrs[:targetRef] |> to_string()
          }
        ]

      _ ->
        []
    end)
  end
end
