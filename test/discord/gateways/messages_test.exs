defmodule Discord.Gateways.MessagesTest do
  use ExUnit.Case, async: true

  alias Discord.Gateways.Messages

  test "mentioned?/2 returns true when the bot id is present in mentions" do
    assert Messages.mentioned?(
             %{type: "MESSAGE_CREATE", data: %{"mentions" => [%{"id" => "4242"}]}},
             "4242"
           )
  end

  test "text_matches?/2 uses case-insensitive substring matching for strings" do
    assert Messages.text_matches?(
             %{type: "MESSAGE_CREATE", data: %{"content" => "Ping there"}},
             "ping"
           )
  end

  test "text_matches?/2 supports regex matchers" do
    assert Messages.text_matches?(
             %{type: "MESSAGE_CREATE", data: %{"content" => "Ping there"}},
             ~r/^ping/i
           )
  end

  test "channel_id/1 returns nil for non-message events" do
    assert Messages.channel_id(%{type: "READY", data: %{}}) == nil
  end

  test "message_id/1 returns the message id for message events" do
    assert Messages.message_id(%{type: "MESSAGE_CREATE", data: %{"id" => "9001"}}) == "9001"
  end
end
