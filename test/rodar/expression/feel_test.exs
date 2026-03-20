defmodule Rodar.Expression.FeelTest do
  use ExUnit.Case, async: true

  describe "integration with Rodar.Expression" do
    test "FEEL via expression execute" do
      {:ok, context} = Rodar.Context.start_link(%{}, %{})
      Rodar.Context.put_data(context, "count", 4)

      assert {:ok, true} =
               Rodar.Expression.execute({:bpmn_expression, {"feel", "count = 4"}}, context)
    end

    test "FEEL comparison via expression execute" do
      {:ok, context} = Rodar.Context.start_link(%{}, %{})
      Rodar.Context.put_data(context, "amount", 1500)

      assert {:ok, true} =
               Rodar.Expression.execute(
                 {:bpmn_expression, {"feel", "amount > 1000"}},
                 context
               )
    end

    test "empty FEEL expression returns true" do
      {:ok, context} = Rodar.Context.start_link(%{}, %{})
      assert {:ok, true} = Rodar.Expression.execute({:bpmn_expression, {"feel", ""}}, context)
    end
  end
end
