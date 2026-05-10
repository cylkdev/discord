# Webhook End-to-End Test

How to receive Discord webhook events on this app end-to-end: boot the
receiver, expose it to the public internet, register the URL with Discord,
and verify that real events land in the in-memory buffer.

Outbound webhooks (posting messages *to* a channel webhook URL) are not
covered here — this is about Discord delivering events *to us* over HTTPS.
See https://docs.discord.com/developers/events/webhook-events for the
event catalogue and payload shapes.

## Architecture

```
Discord ──HTTPS POST──▶ Cloudflare tunnel ──▶ Bandit (:4000)
                                                  │
                                                  ▼
                                    Discord.Endpoint.RequestPlug
                                      ├─ /gateways/* ─▶ GatewayPlug
                                      └─ /webhooks ───▶ WebhooksPlug
                                                         ├─ verify Ed25519 sig
                                                         ├─ type 0 ──▶ 204 (PING ack)
                                                         └─ type 1 ──▶ EventBuffer.push + 204
                                                                         │
                                                                         ▼
                                                             Discord.Webhooks.events/0
```

`Discord.Endpoint` is supervised by `Discord.Application`, so the Bandit
listener lives for the BEAM lifetime. The Mix tasks below configure the
listener by writing `port`/`public_key` into the application env under
`{:discord, Discord.Endpoint}` *before* starting `:discord`; the supervised
endpoint then reads that env at init time. Calling
`Discord.Endpoint.start_link/1` directly from a Mix task is wrong (and was
the previous bug — see `lib/discord/application.ex` moduledoc).

Routes the listener actually serves (everything else returns `404 not_found`):

| Path                | Owner                              | Methods | Purpose                                                |
|---------------------|------------------------------------|---------|--------------------------------------------------------|
| `/webhooks`         | `Discord.Endpoint.WebhooksPlug`    | POST    | Receive signed event POSTs from Discord                |
| `/gateways/health`  | `Discord.Endpoint.GatewayPlug`     | GET     | Per-gateway connection status — also a no-config probe |
| `/gateways/events`  | `Discord.Endpoint.GatewayPlug`     | GET     | List buffered Gateway dispatch events                  |

There is no `/health` route. Use `/gateways/health` for a tunnel
reachability check — it's a `GET` that always returns `200` regardless of
whether any gateway is connected.

## Prerequisites

- A Discord application (https://discord.com/developers/applications). You
  do **not** need a bot user for webhook events — the application itself
  owns the public key and the webhook URL.
- The application's **Public Key** (Developer Portal → your app → General
  Information → Public Key). Hex-encoded, 64 chars.
- A Cloudflare tunnel hostname you can route to `localhost:4000`. Wired
  through `flared` — see `mix help discord.webhook.tunnel`.
- `cloudflared` installed locally (the tunnel task shells out to it).

## Step 1 — Start the receiver

In terminal 1, boot the webhook receiver with the application public key:

```bash
mix discord.webhook.start --public-key <hex public key>
```

This writes `[port: 4000, public_key: <hex>]` into
`Application.get_env(:discord, Discord.Endpoint)`, then starts the
`:discord` application. `Discord.Application` brings up:

1. `Discord.Webhooks` — supervises `Discord.Webhooks.EventBuffer`, the
   in-memory ring that verified events get pushed into.
2. `Discord.Gateways` — registry + dynamic supervisor + Gateway event
   buffer (irrelevant to the webhook path, just along for the ride).
3. `Discord.Endpoint` — the Bandit listener on port 4000, reading the
   `public_key` you put in env above.

Without `--public-key`, the task refuses to start (`--public-key is
required`). If you ever boot the endpoint *without* a key by some other
path (e.g. `mix discord.endpoint.start` with no `--public-key`),
`POST /webhooks` answers `503 webhooks_not_configured` and Discord will
disable the URL when it tries to verify it.

For a REPL alongside the receiver:

```bash
iex -S mix discord.webhook.start --public-key "$DISCORD_WEBHOOK_PUBLIC_KEY"
```

Smoke-test the local listener before exposing it:

```bash
curl -i http://localhost:4000/webhooks            # -> 405 method_not_allowed
curl -i -X POST http://localhost:4000/webhooks    # -> 401 invalid_signature
curl -i http://localhost:4000/gateways/health     # -> 200 OK
```

A `401 invalid_signature` from a missing-header POST means the plug is
live and verification is engaged. That is the desired pre-tunnel state.
A `200` from `/gateways/health` confirms the listener is actually bound
(if the receiver crashed silently you'll get connection refused instead).

To boot on a non-default port, pass `--port` — both `mix discord.webhook.start`
and `mix discord.endpoint.start` accept it and write it into the same env
key.

## Step 2 — Expose the listener with a Cloudflare tunnel

In terminal 2, start the webhook tunnel:

```bash
mix discord.webhook.tunnel
```

This provisions a remote-managed Cloudflare tunnel (via `Flared.MixTask`)
that routes `https://discord-webhook-cloudflared.cylk.dev/` to
`http://localhost:4000`. The defaults are webhook-specific — name
`discord-webhook` and hostname `discord-webhook-cloudflared.cylk.dev` —
so no flags are required for the common case. Override `--name` and
`--hostname` for personal dev tunnels under a Cloudflare zone you
control. The other flags (`--scheme`, `--service-domain`,
`--service-port`) default to `http`, `localhost`, and `4000`
respectively, which match the receiver listener — leave them alone
unless you've moved the listener.

Once `cloudflared` reports connected, sanity-check from the public side:

```bash
curl -i https://discord-webhook-cloudflared.cylk.dev/gateways/health
# -> 200 OK
curl -i -X POST https://discord-webhook-cloudflared.cylk.dev/webhooks
# -> 401 invalid_signature
```

If `/gateways/health` is `200` and `POST /webhooks` is `401`, the path
from Discord → your laptop is open and signature verification is
enforced. Cloudflare state is torn down automatically when the task
exits.

## Step 3 — Register the webhook URL with Discord

In the Developer Portal:

1. Open your application.
2. **General Information** → set **Interactions Endpoint URL** to
   `https://<your-tunnel-hostname>/webhooks` *only if you also handle
   interactions*. For event webhooks specifically, use the
   **Webhooks Event URL** field (Webhooks tab) — same path.
3. Subscribe to the event types you want delivered (e.g.
   `APPLICATION_AUTHORIZED`, `ENTITLEMENT_CREATE`, lobby/DM SDK events).
4. Save.

On save, Discord posts a **PING** (envelope `type: 0`) to the URL. The
plug answers `204` with a JSON content-type header. If verification or
the response shape is wrong, Discord rejects the URL in the UI and
disables the endpoint server-side. Watch the receiver logs for:

```
[info] [Discord.Endpoint.WebhooksPlug] PING handshake — replying 204
```

Discord will *also* periodically send POSTs with intentionally-bad
signatures to make sure you're still rejecting them. `WebhooksPlug`
returns `401 invalid_signature` for those, which is correct — do not try
to "fix" the warnings in the log.

## Step 4 — Trigger a real event and verify it landed

Pick an event you've subscribed to and trigger it in Discord (e.g.
authorize the app on a server for `APPLICATION_AUTHORIZED`).

In the receiver logs you should see:

```
[debug] [Discord.Endpoint.WebhooksPlug] POST /webhooks received body_size=...
[debug] [Discord.Endpoint.WebhooksPlug] payload decoded type=1
[info]  [Discord.Endpoint.WebhooksPlug] webhook event received
        type=APPLICATION_AUTHORIZED application_id=...
```

Then, from the IEx prompt (or a one-off `iex -S mix run`):

```elixir
iex> Discord.Webhooks.events()
[
  %{
    type: "APPLICATION_AUTHORIZED",
    received_at: "2026-05-10T12:34:56.789Z",
    payload: %{
      "version" => 1,
      "application_id" => "...",
      "type" => 1,
      "event" => %{"type" => "APPLICATION_AUTHORIZED", "data" => %{...}}
    }
  }
]
```

Newest event first. The buffer is in-memory and per-node — restarting the
receiver clears it. Only envelopes shaped `%{"type" => 1, "event" => %{...}}`
are pushed; PINGs (`type: 0`) and any `type: 1` envelope without an inner
`event` map are still acked with `204` but skipped — see
`Discord.Endpoint.WebhooksPlug.dispatch/2`.

## Local test without Discord (no tunnel needed)

`Discord.Webhooks.Testing.build_signed_request/2` returns a freshly-signed
request envelope under an ephemeral keypair. The signing key is generated
fresh on every call, so the listener has to be started with the public key
that `Testing` just produced — there's no way to "swap" the key on a
running listener.

The cleanest way to exercise the full HTTP path without round-tripping
through Discord:

```bash
# Boot WITHOUT auto-starting :discord — we need to put env first, then start.
iex -S mix run --no-start
```

```elixir
iex> alias Discord.Webhooks.Testing
iex> req = Testing.build_signed_request("123456789", :ping)
iex> Application.put_env(:discord, Discord.Endpoint, public_key: req.public_key)
iex> {:ok, _} = Application.ensure_all_started(:discord)
iex> Testing.post_signed_request(req.signature, req.public_key, req.timestamp, req.body)
%Req.Response{status: 204, ...}
```

That exercises `WebhooksPlug` end-to-end over real HTTP: signature
verification, JSON decoding, and the PING ack path.

`Testing.build_signed_request("...", :event)` works the same way and gets
a `204`, but the helper builds a minimal envelope (`{"version":"1",
"application_id":..., "type":1}`) with no inner `event` field. That
matches the plug's "unknown payload shape — acked" branch and does NOT
push to the buffer — `Discord.Webhooks.events()` will still return `[]`
afterward. To exercise the `EventBuffer.push` path with a real-shaped
event, hand-construct a body with an `"event"` map and sign it the same
way; `test/discord/endpoint/webhooks_plug_test.exs` has a complete
example.

## Troubleshooting

| Symptom                                                | Likely cause                                                                 |
|--------------------------------------------------------|------------------------------------------------------------------------------|
| `curl localhost:4000/...` → connection refused         | The listener didn't actually bind. Check the receiver logs for a Bandit `Running ... at 0.0.0.0:4000` line; if it's missing, the `:discord` application failed to start (look upstream for an exception). |
| `POST /webhooks` → `503 webhooks_not_configured`       | `--public-key` was not written into env before `:discord` started — typically only happens with `mix discord.endpoint.start` without `--public-key`, or with a custom boot path. |
| `POST /webhooks` → `401 invalid_signature` from Discord | Public key in env does not match the Discord application's public key       |
| Discord rejects the URL on save                        | Tunnel down, wrong path, or `204` is not coming back within 3 seconds        |
| PING works, real events never arrive                   | Event subscriptions not enabled in the Developer Portal                      |
| Events arrive (`204` in logs) but `events/0` returns `[]` | Envelope didn't match the `type: 1, event: %{...}` shape — see the "unknown payload shape — acked" log line and the `Testing` note above |
| `cloudflared` never connects                           | Missing `cloudflared` binary, or Cloudflare credentials not configured for `flared` |

## Shutdown

Ctrl-C in each terminal. Bandit drains cleanly; the tunnel task
deprovisions its Cloudflare-side state on exit. Under `iex`, Ctrl-C twice
or pick `a` from the BREAK menu.
