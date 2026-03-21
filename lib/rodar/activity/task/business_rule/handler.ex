defmodule Rodar.Activity.Task.BusinessRule.Handler do
  @moduledoc """
  Behaviour for business rule task handlers.

  Implement `execute/2` to define the decision logic for a business rule task.
  The callback receives the task element attributes and the current context data,
  and should return `{:ok, result_map}` or `{:error, reason}`.

  This mirrors `Rodar.Activity.Task.Service.Handler` exactly, keeping the door
  open for future DMN (Decision Model and Notation) integration via pluggable
  handlers without mandating a specific decision engine.

  ## Example

      defmodule MyApp.EvaluateDiscount do
        @behaviour Rodar.Activity.Task.BusinessRule.Handler

        @impl true
        def execute(_attrs, data) do
          discount =
            cond do
              data[:total] > 1000 -> 0.15
              data[:total] > 500 -> 0.10
              true -> 0.0
            end

          {:ok, %{discount: discount}}
        end
      end

  """

  @callback execute(attrs :: map(), data :: map()) ::
              {:ok, map()} | {:error, String.t()}
end
