# Gateway end-to-end test

This walks you through proving, start to finish, that your bot can:

- connect to Discord
- hold the Gateway connection open
- read real `MESSAGE_CREATE` events
- detect when someone tagged the bot
- reply to that tagged message
- optionally match on message text and send a response back

You'll need about ten minutes, a Discord account, and a server you own
(or any server where you can give a bot access).

## What "working" looks like

By the end of this guide you'll have:

- a bot account on Discord
- a local process holding an open WebSocket to `gateway.discord.gg`
- a `curl localhost:4000/health` that shows your gateway as connected
- real events buffered at `/gateways/default/events`
- a successful `Discord.Gateways.reply/4` to a message that tagged the bot
- an optional successful text match against a live `MESSAGE_CREATE` event
  followed by a response

If you can tag the bot, see that message in the buffer, and make the
bot reply, the default flow is working.

## Before you start

You need a bot token and the bot has to be a member of at least one
server.

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   and either pick an existing application or click **New Application**.
2. Open the **Bot** tab. Click **Reset Token** and copy the token. This
   is the only time Discord shows it, so paste it somewhere safe.
3. Open **OAuth2 -> URL Generator**, tick `bot` under scopes, and tick
   *View Channels*, *Read Message History*, and *Send Messages* under
   permissions. Copy the generated URL, paste it in your browser, and
   add the bot to a server you control.

When the bot joins, you'll see it appear offline in your server's
member list. It stays offline until you run the gateway in the next
step.

## Step 1 - check the token works

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

## Step 2 - start the gateway under IEx

From the project root:

```bash
iex -S mix discord.gateway.start --token "$DISCORD_BOT_TOKEN"
```

This default mode requests `GUILDS` and `GUILD_MESSAGES` only. It is
safe for mention-based replies.

You'll see log lines stream past as the bot connects. The ones that
matter, in order:

```text
[info] [discord :default] websocket upgraded
[info] [discord :default] hello (heartbeat 41250ms)
Discord Gateways running.
```

At this point the bot's status in your Discord server should flip from
grey to green within a second or two. That's the visible signal that
Discord accepted the connection.

Leave this terminal running. Because you started under `iex`, you can
also use the Elixir API directly from the same shell in later steps.
Open a second terminal for the `curl` checks.

## Step 3 - confirm the bot is fully ready

Connecting and being ready are not the same thing. The bot is ready
once Discord has sent a `READY` event with your session info.

```bash
curl -s localhost:4000/health | jq
```

You want one gateway entry whose `connected` field is `true`:

```json
{
  "status": "ok",
  "gateways": [
    {
      "name": "default",
      "connected": true,
      "status": "ready",
      "bot_user_id": "123456789012345678",
      "bot_username": "my-test-bot",
      "intents": ["guilds", "guild_messages"],
      "session_id": "8d5c9e1f2a3b4c5d",
      "resume_gateway_url": "wss://gateway-us-east1-d.discord.gg",
      "event_count": 2
    }
  ]
}
```

If `connected` stays `false` for more than a few seconds, jump to
*Troubleshooting* below.

## Step 4 - inspect the live event buffer

Every dispatch from Discord goes into an in-memory buffer that the
endpoint exposes per connection:

```bash
curl -s localhost:4000/gateways/default/events | jq '.events[] | {type, seq}'
```

The first thing you'll usually see is `READY`, followed by one
`GUILD_CREATE` for every server the bot is in.

`READY` is the most informative event because it tells you who Discord
thinks you are:

```bash
curl -s localhost:4000/gateways/default/events/READY \
  | jq '.events[] | .data | {user: .user.username, guilds: (.guilds | length), session_id, resume_gateway_url}'
```

If `user` matches the bot you set up and `guilds` matches the number
of servers it is in, you have a real authenticated session.

## Step 5 - trigger and read a real message event

Open Discord, go to your test server, and post a message in any channel
the bot can see. Then, in the second terminal:

```bash
curl -s localhost:4000/gateways/default/events/MESSAGE_CREATE?limit=5 \
  | jq '.events[] | {channel_id: .data.channel_id, author: .data.author.username, content: .data.content}'
```

You should see your message appear in the buffer:

```json
{
  "channel_id": "1234567890123456789",
  "author": "your-discord-name",
  "content": ""
}
```

For ordinary guild messages, `content` may be empty in the default
configuration. That does not mean the gateway is broken. It means the
gateway is not requesting `MESSAGE_CONTENT`.

## Step 6 - reply when someone tags the bot

Now prove the bot can tell when it was tagged and reply directly to
that message.

1. In Discord, send a message that mentions the bot.
2. In the `iex` terminal where the gateway is running, inspect the most
   recent message event and check whether it mentioned the bot.

```elixir
alias Discord.Gateways.Messages

{:ok, %{bot_user_id: bot_user_id}} = Discord.Gateways.connection_info(:default)
[event | _rest] = Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 1)

Messages.mentioned?(event, bot_user_id)
event.data["content"]
```

If the last line returns `true`, reply to that exact message:

```elixir
Discord.Gateways.reply(
  :default,
  Messages.channel_id(event),
  Messages.message_id(event),
  %{"content" => "I saw the tag."}
)
```

Expected result:

```elixir
{:ok,
 %{
   "channel_id" => "1234567890123456789",
   "content" => "I saw the tag.",
   "id" => "987654321098765432",
   "message_reference" => %{"message_id" => event.data["id"]}
 }}
```

Discord should show the bot's response as a reply to the message that
mentioned it.

If you want to make the check and reply in one expression, use:

```elixir
alias Discord.Gateways.Messages

{:ok, %{bot_user_id: bot_user_id}} = Discord.Gateways.connection_info(:default)

case Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 1) do
  [event | _] ->
    if Messages.mentioned?(event, bot_user_id) do
      Discord.Gateways.reply(
        :default,
        Messages.channel_id(event),
        Messages.message_id(event),
        %{"content" => "Thanks for the tag."}
      )
    else
      :not_tagged
    end

  [] ->
    :no_messages
end
```

## Step 7 - read plain message text

Matching on arbitrary guild message text requires `MESSAGE_CONTENT`.
This gateway requests that intent by default from
`Discord.Gateways.default_intents/0`.

Start or restart the gateway normally:

```bash
iex -S mix discord.gateway.start --token "$DISCORD_BOT_TOKEN"
```

After reconnecting, post a plain message like `ping` in Discord and
check that recent message events now contain the message body:

```bash
curl -s localhost:4000/gateways/default/events/MESSAGE_CREATE?limit=5 \
  | jq '.events[] | {author: .data.author.username, content: .data.content}'
```

Once `data.content` is present, you can match on it.

## Step 8 - match on text and respond

The same message buffer can drive simple text-based replies.

In Discord, post a message like `ping`. Then, in `iex`:

```elixir
alias Discord.Gateways.Messages

Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 5)
|> Enum.map(fn event ->
  {event.data["author"]["username"], event.data["content"], Messages.text_matches?(event, "ping")}
end)
```

That lets you inspect recent messages and see which ones matched your
text rule.

To find the newest matching event and reply to it:

```elixir
alias Discord.Gateways.Messages

case Enum.find(
       Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 10),
       &Messages.text_matches?(&1, "ping")
     ) do
  nil ->
    :no_match

  event ->
    Discord.Gateways.reply(
      :default,
      Messages.channel_id(event),
      Messages.message_id(event),
      %{"content" => "pong"}
    )
end
```

If you want a looser rule, `text_matches?/2` also accepts a regex:

```elixir
alias Discord.Gateways.Messages

case Enum.find(
       Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 10),
       &Messages.text_matches?(&1, ~r/\bhello\b/i)
     ) do
  nil ->
    :no_match

  event ->
    Discord.Gateways.send_message(
      :default,
      Messages.channel_id(event),
      %{"content" => "hello to you too"}
    )
end
```

Use `reply/4` when you want Discord to show a threaded reply to the
original message. Use `send_message/3` when you just want to post into
the same channel.

## Step 9 - confirm the connection survives

The gateway is supposed to stay open indefinitely. To check that it is
not dying silently, leave it running for a couple of minutes and re-run:

```bash
curl -s localhost:4000/health | jq '.gateways[] | {name, connected, status, event_count}'
```

It should still report `connected: true`. Post another message. It
should still show up in `/gateways/default/events`. If the connection
drops, the client reconnects on its own. When it does, you'll see a
`RESUMED` event in the buffer:

```bash
curl -s localhost:4000/gateways/default/events/RESUMED | jq
```

## Optional - expose the HTTP endpoints with a Cloudflare tunnel

Everything above runs against `localhost:4000`. The Gateway WebSocket
itself is outbound, so it does not need a tunnel. Discord never calls
back to your machine for gateway traffic.

What a tunnel buys you is remote access to the introspection HTTP
endpoints (`/health`, `/gateways/default/events`) so you can hit them
from another machine, share the URL with a teammate, or wire up a
remote dashboard.

In a third terminal:

```bash
mix discord.gateway.tunnel
```

Defaults: `--name discord-gateway`, `--hostname
discord-gateway-cloudflared.cylk.dev`, forwarding to
`http://localhost:4000`. Override with `--name` and `--hostname` if you
want a personal dev tunnel:

```bash
mix discord.gateway.tunnel \
  --name kurt-discord-gateway \
  --hostname kurt-discord-gateway-cloudflared.cylk.dev
```

Once `cloudflared` reports connected, the same checks from Steps 3-5
work from anywhere:

```bash
curl -s https://discord-gateway-cloudflared.cylk.dev/health | jq
curl -s https://discord-gateway-cloudflared.cylk.dev/gateways/default/events/MESSAGE_CREATE | jq '.events[] | {type, seq}'
```

The tunnel does not affect the gateway WebSocket. Stopping or
restarting `cloudflared` will not drop the bot's Discord session.
Cloudflare-side state is torn down automatically when the tunnel task
exits.

> Note: do not point the Discord application's **Webhook Event URL**
> at this hostname. That's a separate flow with its own tunnel
> (`mix discord.webhook.tunnel`) - see `docs/webhook-end-to-end-test.md`.

## Pass criteria

You're done when all of these are true:

- [ ] `GET /gateway/bot` returned 200 with your token
- [ ] The bot's status in Discord went from grey to green
- [ ] `/health` shows the `default` gateway as connected
- [ ] `/gateways/default/events/READY` contains your bot's username
- [ ] Mentioning the bot makes `Discord.Gateways.Messages.mentioned?/2`
      return `true`
- [ ] `Discord.Gateways.reply/4` successfully replies to the tagged
      message
- [ ] Posting `ping` lets you match on text and respond with `pong`

## Troubleshooting

**Bot stays grey in Discord.** The WebSocket is not connecting. Check
the gateway terminal for errors. Common causes: wrong token, token got
reset since you copied it, or no internet from the machine running the
gateway.

**`connected: false` and it stays that way.** The WebSocket upgraded but
Discord rejected the `IDENTIFY`. Look for a close code in the gateway
logs. `4004` means the token is invalid. `4013` or `4014` usually mean
you asked for an intent the app is not allowed to use.

**No `MESSAGE_CREATE` when you post.** Make sure you're posting in a
channel the bot can see. Check the channel's permissions and confirm
the bot has *View Channel*.

**`MESSAGE_CREATE` arrives but `data.content` is empty.** That is
not expected once the app is allowed to use Message Content Intent and
the gateway has reconnected. Mention messages should still include
content even if Discord is redacting ordinary guild messages.

**The bot can read messages but cannot reply.** Re-check the bot's role
and channel permissions. It needs *Send Messages* in the target
channel.

**`mentioned?/2` returns `false` even though you tagged the bot.**
Re-run the message-event fetch with a larger limit and inspect the most
recent events:

```elixir
Discord.Gateways.events(:default, "MESSAGE_CREATE", limit: 5)
```

You may be looking at a different event than the one that contained the
tag.

## Shutting down

In the gateway terminal, press Ctrl-C. If you're in `iex`, press
Ctrl-C twice (or pick `a` from the BREAK menu). The bot's status in
Discord will go back to grey within a few seconds.

## References

- [Discord Gateway - Connection Lifecycle](https://docs.discord.com/developers/topics/gateway)
- [Discord Gateway Events](https://docs.discord.com/developers/events/gateway-events)
