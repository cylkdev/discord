defmodule Discord.Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Discord.Webhooks.Signature

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    timestamp = "1730000000"
    body = ~s({"version":1,"application_id":"1","type":0})
    sig = :crypto.sign(:eddsa, :none, timestamp <> body, [priv, :ed25519])

    %{
      public_key: Base.encode16(pub, case: :lower),
      signature: Base.encode16(sig, case: :lower),
      timestamp: timestamp,
      body: body
    }
  end

  test "accepts a valid signature", ctx do
    assert :ok = Signature.verify(ctx.body, ctx.timestamp, ctx.signature, ctx.public_key)
  end

  test "accepts mixed-case hex", ctx do
    assert :ok =
             Signature.verify(
               ctx.body,
               ctx.timestamp,
               String.upcase(ctx.signature),
               String.upcase(ctx.public_key)
             )
  end

  test "rejects a tampered body", ctx do
    assert {:error, :invalid_signature} =
             Signature.verify(ctx.body <> "x", ctx.timestamp, ctx.signature, ctx.public_key)
  end

  test "rejects a tampered timestamp", ctx do
    assert {:error, :invalid_signature} =
             Signature.verify(ctx.body, ctx.timestamp <> "0", ctx.signature, ctx.public_key)
  end

  test "rejects an unrelated key of correct length", ctx do
    {other_pub, _other_priv} = :crypto.generate_key(:eddsa, :ed25519)
    other_pub_hex = Base.encode16(other_pub, case: :lower)

    assert {:error, :invalid_signature} =
             Signature.verify(ctx.body, ctx.timestamp, ctx.signature, other_pub_hex)
  end

  test "rejects a signature of the wrong length", ctx do
    short = String.slice(ctx.signature, 0..-3//1)

    assert {:error, :malformed_signature} =
             Signature.verify(ctx.body, ctx.timestamp, short, ctx.public_key)
  end

  test "rejects a public key of the wrong length", ctx do
    short = String.slice(ctx.public_key, 0..-3//1)

    assert {:error, :malformed_public_key} =
             Signature.verify(ctx.body, ctx.timestamp, ctx.signature, short)
  end

  test "rejects non-hex signature", ctx do
    assert {:error, :malformed_signature} =
             Signature.verify(ctx.body, ctx.timestamp, "zz" <> ctx.signature, ctx.public_key)
  end

  test "rejects non-hex public key", ctx do
    assert {:error, :malformed_public_key} =
             Signature.verify(ctx.body, ctx.timestamp, ctx.signature, "zz" <> ctx.public_key)
  end
end
