defmodule Rodar.Activity.Task.BusinessRule.TestHandler do
  @moduledoc false
  @behaviour Rodar.Activity.Task.BusinessRule.Handler

  @impl true
  def execute(_attrs, _data) do
    {:ok, %{result: "handled"}}
  end
end
