defmodule Discord.Bots.Setup do
  @permissions %{
    "view_channel" => 1024,
    "send_messages" => 2048,
    "read_message_history" => 65536
  }

  @default_permissions ["view_channel", "send_messages", "read_message_history"]

  @required_scope ["bot", "applications.commands"]

  def permissions, do: @permissions

  def required_scope, do: @required_scope

  @doc """
  Returns a URL to invite a bot to a server

  ## Examples

      iex> Discord.Bots.Setup.invite_url("1234567890")
      "https://discord.com/oauth2/authorize?client_id=1234567890&scope=bot%20applications.commands&permissions=66560"

      iex> Discord.Bots.Setup.invite_url("1234567890", ["bot"], ["view_channel", "send_messages"])
      "https://discord.com/oauth2/authorize?client_id=1234567890&scope=bot%20applications.commands&permissions=3072"
  """
  def invite_url(client_id, scope \\ [], permissions \\ []) do
    required_scope = @required_scope

    extra_scope =
      scope
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in required_scope))

    final_scope = Enum.join(required_scope ++ extra_scope, " ")

    permissions =
      case permissions do
        nil -> @default_permissions
        [] -> @default_permissions
        value -> value
      end

    final_permissions =
      permissions
      |> Enum.uniq()
      |> Enum.map(fn
        perm when is_integer(perm) -> perm
        perm when is_atom(perm) or is_binary(perm) -> Map.get(@permissions, to_string(perm), 0)
      end)
      |> Enum.sum()

    query =
      URI.encode_query(%{
        client_id: client_id,
        scope: final_scope,
        permissions: final_permissions
      })

    "https://discord.com/oauth2/authorize?#{query}"
  end
end
