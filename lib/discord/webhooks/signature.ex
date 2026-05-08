defmodule Discord.Webhooks.Signature do
  @moduledoc """
  Ed25519 signature verification for Discord webhook events.

  Discord signs every webhook delivery with the application's Ed25519 private
  key over the concatenation of the `X-Signature-Timestamp` header and the
  raw request body. Verification uses the application's public key (visible
  in the Discord developer portal under "General Information").

  Backed by Erlang/OTP's native `:crypto.verify/5` — no extra dependency.
  """

  @signature_bytes 64
  @public_key_bytes 32

  @typedoc "`:ok` on a valid signature, otherwise a tagged reason."
  @type result ::
          :ok
          | {:error,
             :invalid_signature
             | :malformed_signature
             | :malformed_public_key}

  @doc """
  Verifies that `signature_hex` is a valid Ed25519 signature over
  `timestamp <> body` under `public_key_hex`.

  All hex inputs are case-insensitive. Returns `{:error, :malformed_signature}`
  or `{:error, :malformed_public_key}` if the inputs aren't valid hex of the
  right length, and `{:error, :invalid_signature}` if they are well-formed but
  the signature does not verify.
  """
  @spec verify(binary, binary, binary, binary) :: result
  def verify(body, timestamp, signature_hex, public_key_hex)
      when is_binary(body) and is_binary(timestamp) and
             is_binary(signature_hex) and is_binary(public_key_hex) do
    with {:ok, sig} <- decode_signature(signature_hex),
         {:ok, pub} <- decode_public_key(public_key_hex) do
      if :crypto.verify(:eddsa, :none, timestamp <> body, sig, [pub, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp decode_signature(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == @signature_bytes -> {:ok, bin}
      _ -> {:error, :malformed_signature}
    end
  end

  defp decode_public_key(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == @public_key_bytes -> {:ok, bin}
      _ -> {:error, :malformed_public_key}
    end
  end
end
