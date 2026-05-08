defmodule Discord.GatewaysTest do
  use ExUnit.Case

  test "connect/2 rejects non-binary or empty tokens" do
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, nil) end
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, "") end
  end
end
