defmodule Discord.Gateways.Messages do
  @moduledoc """
  Pure helper functions for Discord message events.

  Observable behaviour:

    * Never performs I/O.
    * Operates on buffered gateway event maps.
    * Returns safe falsey values on non-message events instead of raising.
  """

  @type gateway_event :: Discord.Gateways.gateway_event() | map()

  @doc """
  Returns `true` when the event is a `MESSAGE_CREATE` dispatch and one mention
  id matches `bot_user_id`.

  Parameters:

    * `event` - buffered gateway event map.
    * `bot_user_id` - Discord bot user id string.

  Side effects: none.

  ## Examples

      iex> Discord.Gateways.Messages.mentioned?(
      ...>   %{type: "MESSAGE_CREATE", data: %{"mentions" => [%{"id" => "4242"}]}},
      ...>   "4242"
      ...> )
      true
  """
  @spec mentioned?(gateway_event(), String.t()) :: boolean()
  def mentioned?(%{type: "MESSAGE_CREATE", data: %{"mentions" => mentions}}, bot_user_id)
      when is_list(mentions) and is_binary(bot_user_id) do
    Enum.any?(mentions, &match?(%{"id" => ^bot_user_id}, &1))
  end

  def mentioned?(_, _), do: false

  @doc """
  Returns `true` when the event is a `MESSAGE_CREATE` dispatch whose content
  matches `matcher`.

  Parameters:

    * `event` - buffered gateway event map.
    * `matcher` - string or regex matcher.

  Observable behaviour:

    * String matching is case-insensitive substring matching.
    * Regex matching uses `Regex.match?/2`.
    * Non-message events return `false`.

  Side effects: none.

  ## Examples

      iex> Discord.Gateways.Messages.text_matches?(
      ...>   %{type: "MESSAGE_CREATE", data: %{"content" => "Ping there"}},
      ...>   "ping"
      ...> )
      true
  """
  @spec text_matches?(gateway_event(), String.t() | Regex.t()) :: boolean()
  def text_matches?(%{type: "MESSAGE_CREATE", data: %{"content" => content}}, needle)
      when is_binary(content) and is_binary(needle) do
    String.contains?(String.downcase(content), String.downcase(needle))
  end

  def text_matches?(%{type: "MESSAGE_CREATE", data: %{"content" => content}}, %Regex{} = regex)
      when is_binary(content) do
    Regex.match?(regex, content)
  end

  def text_matches?(_, _), do: false

  @doc """
  Returns the Discord channel id string for a buffered message event.

  Parameters:

    * `event` - buffered gateway event map.

  Side effects: none.

  ## Examples

      iex> Discord.Gateways.Messages.channel_id(
      ...>   %{type: "MESSAGE_CREATE", data: %{"channel_id" => "123"}}
      ...> )
      "123"
  """
  @spec channel_id(gateway_event()) :: String.t() | nil
  def channel_id(%{type: "MESSAGE_CREATE", data: %{"channel_id" => channel_id}})
      when is_binary(channel_id),
      do: channel_id

  def channel_id(_), do: nil

  @doc """
  Returns the Discord message id string for a buffered message event.

  Parameters:

    * `event` - buffered gateway event map.

  Side effects: none.

  ## Examples

      iex> Discord.Gateways.Messages.message_id(
      ...>   %{type: "MESSAGE_CREATE", data: %{"id" => "9001"}}
      ...> )
      "9001"
  """
  @spec message_id(gateway_event()) :: String.t() | nil
  def message_id(%{type: "MESSAGE_CREATE", data: %{"id" => message_id}})
      when is_binary(message_id),
      do: message_id

  def message_id(_), do: nil
end
