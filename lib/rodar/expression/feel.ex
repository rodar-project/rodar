defmodule Rodar.Expression.Feel do
  @moduledoc "Delegates to `RodarFeel`. See `RodarFeel` for full documentation."

  defdelegate eval(expr, bindings), to: RodarFeel
end
