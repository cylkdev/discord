defmodule Discord.Endpoint.GatewayWriteAuth do
  @moduledoc """
  Signature verification helpers for mutating gateway HTTP routes.

  Observable behaviour:

    * Verifies one concrete signature at a time.
    * Does not inspect HTTP headers or plug state.
    * Performs no writes and no network I/O.
  """

  @freshness_window_seconds 300
  @ed25519_signature_bytes 64
  @ed25519_public_key_bytes 32

  @type result :: :ok | {:error, :invalid_signature | :stale_timestamp}

  @doc """
  Verifies that `timestamp` is within the accepted freshness window.

  Side effects: none.
  """
  @spec verify_timestamp(String.t()) :: :ok | {:error, :invalid_signature | :stale_timestamp}
  def verify_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {value, ""} ->
        now = System.system_time(:second)

        if abs(now - value) <= @freshness_window_seconds do
          :ok
        else
          {:error, :stale_timestamp}
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies one HMAC-SHA256 signature against `canonical_payload`.

  Side effects: none.
  """
  @spec verify_hmac_sha256(String.t(), String.t(), String.t()) :: result()
  def verify_hmac_sha256(canonical_payload, signature_hex, secret)
      when is_binary(canonical_payload) and is_binary(signature_hex) and is_binary(secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, canonical_payload)
      |> Base.encode16(case: :lower)

    if byte_size(signature_hex) == byte_size(expected) and
         Plug.Crypto.secure_compare(String.downcase(signature_hex), expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies one Ed25519 signature against `canonical_payload`.

  Side effects: none.
  """
  @spec verify_ed25519(String.t(), String.t(), String.t()) :: result()
  def verify_ed25519(canonical_payload, signature_hex, public_key_hex)
      when is_binary(canonical_payload) and is_binary(signature_hex) and is_binary(public_key_hex) do
    with {:ok, signature} <- decode_signature(signature_hex),
         {:ok, public_key} <- decode_public_key(public_key_hex) do
      if :crypto.verify(:eddsa, :none, canonical_payload, signature, [public_key, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp decode_signature(signature_hex) do
    case Base.decode16(signature_hex, case: :mixed) do
      {:ok, signature} when byte_size(signature) == @ed25519_signature_bytes -> {:ok, signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp decode_public_key(public_key_hex) do
    case Base.decode16(public_key_hex, case: :mixed) do
      {:ok, public_key} when byte_size(public_key) == @ed25519_public_key_bytes ->
        {:ok, public_key}

      _ ->
        {:error, :invalid_signature}
    end
  end
end
