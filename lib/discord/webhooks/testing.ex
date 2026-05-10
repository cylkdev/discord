defmodule Discord.Webhooks.Testing do
  @moduledoc """
  Helper module for testing Discord webhooks locally.
  """

  @discord_version "1"
  # PING handshake (what Discord sends to verify the webhook URL)
  @discord_event_type_ping 0
  # Webhook event (what Discord sends when an real event occurs)
  @discord_event_type_event 1

  @request_types [:ping, :event]

  def request_types, do: @request_types

  @doc """
  Returns a map containing a freshly-signed webhook request envelope for local testing.

  ## Parameters

    - `application_id` - `String.t()`. The Discord application ID to embed in the body.
    - `type` - `atom()`. The Discord event type: `:ping` for PING handshake, `:event` for a webhook event.

  ## Returns

  A map with four string fields:

    - `:signature` — lowercase hex Ed25519 signature (128 chars / 64 bytes) over `timestamp <> body`.
    - `:public_key` — lowercase hex Ed25519 public key (64 chars / 32 bytes) that verifies `:signature`.
    - `:timestamp` — Unix epoch seconds as a decimal string.
    - `:body` — JSON-encoded envelope built from the three arguments.

  The keypair and timestamp are generated fresh on every call, so no two return values are
  equal. The signature is always consistent with the public key: passing `:public_key` to
  `Discord.Endpoint.WebhooksPlug.init/1` and submitting the remaining fields as request
  headers and body will produce a 204 response.

  ## Examples

      iex> %{signature: sig_hex, public_key: pub_hex, timestamp: ts, body: body} = Discord.Webhooks.Testing.build_signed_request("123456789", :ping)
  """
  @spec build_signed_request(application_id :: String.t(), type :: atom()) :: %{
          signature: String.t(),
          public_key: String.t(),
          timestamp: String.t(),
          body: String.t()
        }
  def build_signed_request(application_id, type) when type in @request_types do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    body = %{
      version: @discord_version,
      application_id: application_id,
      type: type_to_request_int(type)
    }

    encoded_body = JSON.encode!(body)
    timestamp = Integer.to_string(System.system_time(:second))
    sig = :crypto.sign(:eddsa, :none, timestamp <> encoded_body, [priv, :ed25519])

    sig_hex = Base.encode16(sig, case: :lower)
    pub_hex = Base.encode16(pub, case: :lower)

    %{signature: sig_hex, public_key: pub_hex, timestamp: timestamp, body: encoded_body}
  end

  defp type_to_request_int(:ping), do: @discord_event_type_ping
  defp type_to_request_int(:event), do: @discord_event_type_event

  @doc """
  Posts a signed request to the webhook endpoint.

  ## Parameters

    - `sig_hex` - `String.t()`. The signature as a lowercase hex string.
    - `public_key` - `String.t()`. The public key as a lowercase hex string.
    - `timestamp` - `String.t()`. The timestamp as a decimal string.
    - `body` - `String.t()`. The JSON-encoded body.

  ## Returns

  A `Req.Response.t()` struct.

  ## Examples

      ...> application_id = "123456789"
      ...> %{signature: sig_hex, public_key: pub_hex, timestamp: ts, body: body} = Discord.Webhooks.Testing.build_signed_request(application_id, :ping)
      ...> Discord.Webhooks.Testing.post_signed_request(sig_hex, pub_hex, ts, body)
      ...> # => %Req.Response{...}
  """
  def post_signed_request(sig_hex, public_key, timestamp, body) do
    Req.post("http://localhost:4000/webhooks",
      headers: [
        {"content-type", "application/json"},
        {"x-signature-ed25519", sig_hex},
        {"x-signature-timestamp", timestamp},
        {"x-signature-public-key", public_key}
      ],
      body: body
    )
  end
end
