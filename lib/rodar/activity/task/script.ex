defmodule Rodar.Activity.Task.Script do
  @moduledoc """
  Handles passing the token through a script task element.

  Executes an inline script defined on the BPMN element. The script language
  and content come from the element's attributes. Results are written back
  to the context under the task's `:output_variable` (defaults to `:script_result`).

  ## Language Resolution

  The script language is resolved from element attributes in this order:

  1. `:type` — legacy/explicit attribute (e.g., `type: "elixir"`)
  2. `:scriptFormat` — standard BPMN 2.0 attribute (e.g., `scriptFormat="feel"`)
  3. Defaults to `"elixir"` when neither is present

  ## Supported Languages

  - `"elixir"` -- sandboxed AST evaluation via `Rodar.Expression.Sandbox`
  - `"feel"` -- FEEL expression language via `Rodar.Expression.Feel`
  - Any other language string -- resolved through `Rodar.Expression.ScriptRegistry`

  For custom languages, register an engine module implementing the
  `Rodar.Expression.ScriptEngine` behaviour before executing processes
  that use that language. If no engine is registered for the language,
  the task returns `{:error, "Unsupported script language: ..."}`.

  ## See Also

  - `Rodar.Expression.ScriptEngine` -- behaviour for custom script engines
  - `Rodar.Expression.ScriptRegistry` -- runtime registration of engines

  ## Examples

      iex> end_event = {:bpmn_event_end, %{id: "end", incoming: ["flow_out"], outgoing: []}}
      iex> flow_out = {:bpmn_sequence_flow, %{id: "flow_out", sourceRef: "task", targetRef: "end", conditionExpression: nil, isImmediate: nil}}
      iex> elem = {:bpmn_activity_task_script, %{id: "task", outgoing: ["flow_out"], type: "elixir", script: "2 + 2"}}
      iex> process = %{"flow_out" => flow_out, "end" => end_event}
      iex> {:ok, context} = Context.start_link(process, %{})
      iex> {:ok, ^context} = Rodar.Activity.Task.Script.token_in(elem, context)
      iex> Context.get_data(context, :script_result)
      4

  """

  alias Rodar.Context
  alias Rodar.Expression.Feel
  alias Rodar.Expression.Sandbox
  alias Rodar.Expression.ScriptRegistry

  @doc """
  Receives the token for a script task element and executes the script.

  Delegates to `execute/2`.
  """
  @spec token_in(Rodar.element(), Rodar.context()) :: Rodar.result()
  def token_in(elem, context), do: execute(elem, context)

  @doc """
  Executes the script task business logic.

  Extracts the script language (`type`), script content, and optional
  `:output_variable` from the element attributes. Evaluates the script
  via the appropriate engine and stores the result in the context under
  the output variable key. On success, releases the token to outgoing
  sequence flows.

  Returns `{:ok, context}` on success, `{:error, reason}` on script
  evaluation failure, or `{:not_implemented}` for unrecognized elements.
  """
  @spec execute(Rodar.element(), Rodar.context()) :: Rodar.result()
  def execute(
        {:bpmn_activity_task_script, %{outgoing: outgoing, script: script} = attrs},
        context
      )
      when not is_nil(script) do
    alias Rodar.Activity.DataMapper

    data = DataMapper.map_inputs(attrs, context)
    lang = script_language(attrs)
    output_var = Map.get(attrs, :output_variable, :script_result)

    case run_script(lang, script, data) do
      {:ok, result} ->
        Context.put_data(context, output_var, result)
        token_out(outgoing, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_elem, _context), do: {:not_implemented}

  defp script_language(attrs) do
    Map.get(attrs, :type) || Map.get(attrs, :scriptFormat, "elixir")
  end

  defp token_out(targets, context), do: Rodar.release_token(targets, context)

  defp run_script("elixir", {:bpmn_script, %{expression: script}}, data) do
    Sandbox.eval(script, %{"data" => data})
  end

  defp run_script("elixir", script, data) when is_binary(script) do
    Sandbox.eval(script, %{"data" => data})
  end

  defp run_script("feel", {:bpmn_script, %{expression: script}}, data) do
    Feel.eval(script, data)
  end

  defp run_script("feel", script, data) when is_binary(script) do
    Feel.eval(script, data)
  end

  defp run_script(lang, script, data) do
    case ScriptRegistry.lookup(lang) do
      {:ok, engine} ->
        script_text =
          case script do
            {:bpmn_script, %{expression: expr}} -> expr
            bin when is_binary(bin) -> bin
          end

        engine.eval(script_text, data)

      :error ->
        {:error, "Unsupported script language: #{inspect(lang)}"}
    end
  end
end
