# Gateway end-to-end test

This walks you through proving — start to finish — that your bot can
connect to Discord, hold the connection open, and receive live events.

You'll need about ten minutes, a Discord account, and a server you own
(or any server where you can give a bot access).

## What "working" looks like

By the end of this guide you'll have:

- a bot account on Discord
- a process running locally that's holding an open WebSocket to
  `gateway.discord.gg`
- a `curl localhost:4000/gateways/health` that shows your gateway as `connected: true`
- a list of real events from your server (someone joining, a message
  being posted) flowing into a local buffer you can read over HTTP

If you can post a message in your test server and see it appear in the
local event list within a second, you're done.

## Before you start

You need a bot token and the bot has to be a member of at least one
server.

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   and either pick an existing application or click **New Application**.
2. Open the **Bot** tab. Click **Reset Token** and copy the token. This
   is the only time Discord shows it — paste it somewhere safe.
3. You don't need to enable any "Privileged Gateway Intents" for this
   test. Leave them off.
4. Still on the Developer Portal, open **OAuth2 → URL Generator**, tick
   `bot` under scopes, and tick *View Channels* and *Read Message
   History* under permissions. Copy the generated URL, paste it in your
   browser, and add the bot to a server you control.

When the bot joins, you'll see it appear (offline, greyed out) in your
server's member list. It stays offline until you run the gateway in the
next step.

## Step 1 — check the token works

Before opening a WebSocket, ask Discord whether your token is valid.
This is a one-line sanity check that saves you from chasing
WebSocket-level errors that are really just a bad token.

```bash
export DISCORD_BOT_TOKEN='paste-the-token-here'

curl -sS https://discord.com/api/v10/gateway/bot \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" | jq
```

A working token looks like this:

```json
{
  "url": "wss://gateway.discord.gg",
  "shards": 1,
  "session_start_limit": {
    "total": 1000,
    "remaining": 999,
    "reset_after": 86400000,
    "max_concurrency": 1
  }
}
```

If you see `{"message": "401: Unauthorized", ...}` instead, the token
is wrong or was reset. Go back and copy it again.

## Step 2 — start the gateway

In a fresh terminal, from the project root:

```bash
iex -S mix discord.gateway.start --token "$DISCORD_BOT_TOKEN"
```

You'll see log lines stream past as the bot connects. The ones that
matter, in order:

```
[info] [discord :main] websocket upgraded
[info] [discord :main] hello (heartbeat 41250ms)
Discord Gateway running.
```

At this point the bot's status in your Discord server should flip from
grey to green within a second or two. That's the visible signal that
Discord accepted the connection. If the bot stays grey after ~10
seconds, jump to *Troubleshooting* below.

Leave this terminal running. Open a second terminal for the rest of
the steps.

## Step 3 — confirm the bot is fully ready

Connecting and being *ready* aren't the same thing. The bot is ready
once Discord has sent a `READY` event with your session info.

```bash
curl -s localhost:4000/gateways/health | jq
```

You want:

```json
{
  "status": "ok",
  "gateways": {
    "main": { "connected": true }
  }
}
```

The `gateways` map has one entry per running gateway, keyed by its
`--name` (default `main`). If `main.connected` is `false`, wait a
couple of seconds and try again — Discord usually sends `READY` within
a second of the WebSocket upgrading. If it sits at `false` for more
than ~5 seconds, the connection is broken and you should re-check the
token and intents. If the `gateways` map is empty (`{}`), the gateway
process never started — check the `iex` terminal for boot errors.

## Step 4 — look at the events Discord sent

Every dispatch from Discord goes into an in-memory buffer that the
endpoint exposes:

```bash
curl -s localhost:4000/gateways/events | jq '.events[] | {type, seq}'
```

The first thing you'll see is `READY`, followed by one `GUILD_CREATE`
for every server the bot is in:

```
{ "type": "READY", "seq": 1 }
{ "type": "GUILD_CREATE", "seq": 2 }
```

`READY` is the most informative event — it tells you who Discord
thinks you are:

```bash
curl -s localhost:4000/gateways/events \
  | jq '.events[] | select(.type=="READY") | .data | {user: .user.username, guilds: (.guilds | length), session_id, resume_gateway_url}'
```

Sample output:

```json
{
  "user": "my-test-bot",
  "guilds": 1,
  "session_id": "8d5c9e1f2a3b4c5d",
  "resume_gateway_url": "wss://gateway-us-east1-d.discord.gg"
}
```

If `user` matches the bot you set up and `guilds` matches the number
of servers it's in, you have a real, authenticated session.

## Step 5 — trigger a real event from Discord

This is the proof you can't fake: open Discord, go to your test
server, and **post a message in any channel the bot can see**. Then,
back in the terminal:

```bash
curl -s localhost:4000/gateways/events \
  | jq '.events[] | select(.type=="MESSAGE_CREATE") | {channel_id: .data.channel_id, author: .data.author.username, has_content: (.data.content != "")}'
```

You should see your message appear:

```json
{
  "channel_id": "1234567890123456789",
  "author": "your-discord-name",
  "has_content": false
}
```

`has_content: false` is **expected and correct**. The actual text of
the message is gated behind a privileged intent (`MESSAGE_CONTENT`)
that this build deliberately doesn't request. What you're proving is
that Discord is pushing real-time events into your process. The fact
that the event arrived at all — with the right channel and the right
author — is the test passing.

Try a few more things to convince yourself:

- Add or remove a reaction → `MESSAGE_REACTION_ADD` /
  `MESSAGE_REACTION_REMOVE`
- Have someone (or another account) join the server → `GUILD_MEMBER_ADD`
  (this one needs the *Server Members* privileged intent, so it's
  optional)
- Edit a channel name → `CHANNEL_UPDATE`

Each one shows up in `/gateways/events` within a second.

## Step 6 — confirm the connection survives

The gateway is supposed to stay open forever. To check it isn't dying
silently, leave it running for a couple of minutes and re-run:

```bash
curl -s localhost:4000/gateways/health | jq
```

It should still report `gateways.main.connected: true`. Post another message — it
should still show up in `/gateways/events`. If the connection drops,
the client reconnects on its own; you'll see a `RESUMED` event in the
buffer when it does.

## Pass criteria

You're done when all of these are true:

- [ ] `GET /gateway/bot` returned 200 with your token
- [ ] The bot's status in Discord went from grey to green
- [ ] `/gateways/health` shows `gateways.main.connected: true`
- [ ] `/gateways/events` contains a `READY` with your bot's username
- [ ] `/gateways/events` contains a `GUILD_CREATE` for every server the
      bot is in
- [ ] Posting a message in Discord produces a `MESSAGE_CREATE` event
      within a second

## Troubleshooting

**Bot stays grey in Discord.** The WebSocket isn't connecting. Check
the gateway terminal for errors. Common causes: wrong token, token
got reset since you copied it, no internet from the machine running
the gateway.

**`gateways.main.connected: false` and stays that way.** The WebSocket upgraded but
Discord rejected the IDENTIFY. Look for a close code in the gateway
logs. `4004` means the token is invalid. `4013`/`4014` mean you asked
for an intent the bot isn't allowed to use — for this build that
shouldn't happen, since only non-privileged intents are requested.

**No `MESSAGE_CREATE` when you post.** Make sure you're posting in a
channel the bot can see. Right-click the channel → *Edit Channel* →
*Permissions* and confirm the bot's role has *View Channel*.

**Event content is empty.** That's by design — see Step 5. The bot
isn't asking for `MESSAGE_CONTENT`, which is a privileged intent.

## Shutting down

In the gateway terminal, press Ctrl-C. If you're in `iex`, press
Ctrl-C twice (or pick `a` from the BREAK menu). The bot's status in
Discord will go back to grey within a few seconds.

## References

- [Discord Gateway — Connection Lifecycle](https://docs.discord.com/developers/topics/gateway)
- [Discord Gateway Events](https://docs.discord.com/developers/events/gateway-events)
