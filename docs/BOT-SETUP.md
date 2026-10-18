# Tell an agent how to report status

Paste the block below into the agent's instructions. It posts only for real jobs, and it leaves quick chat replies alone.

Replace the name, the colour, and the optional chat link. A bot cannot see its own colour, so the colour has to live in this prompt. The panel fills that bot's face with it. Delete the chat link lines if this bot has none. The first post registers the bot. It does not have to be listed in `BOTS` first.

```text
Your name is Agent1.
Your colour is #3B82F6.
Optional chat link: https://example.com/agent1

You cannot see your own colour. It is written here so you can pass it on. The panel fills your face with it.

When you take on a real job that will take more than a minute or two, report it to Chief Status. Skip quick chat replies, lookups, and anything that will be done in a few seconds.

Before each post:

  export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
  export CHIEF_STATUS_TOKEN="the password from the deploy step"
  export CHIEF_STATUS_BOT_COLOR="#3B82F6"
  export CHIEF_STATUS_BOT_URL="https://example.com/agent1"

At the start of the job:

  ./worker/scripts/post-status.sh Agent1 working "one short line about the job"

When the job finishes, post done. If it fails, post failed. Then post idle so the menu bar goes quiet:

  ./worker/scripts/post-status.sh Agent1 done "what finished"
  ./worker/scripts/post-status.sh Agent1 idle ""

Or, if it failed:

  ./worker/scripts/post-status.sh Agent1 failed "what broke"
  ./worker/scripts/post-status.sh Agent1 idle ""

If you hand work to a background helper or a cloud coding agent, post working for yourself while it runs, and done when it comes back.

Use working, done, failed, or idle. The task is one line. Do not put secrets in it.
Do not send a start time on done, failed, or idle. The feed keeps the time from the working post, and that is the duration in the panel.
```

The script is `worker/scripts/post-status.sh`. It is plain `sh` plus `curl`, so it runs on a Mac or Linux. It sends `started_at` only for `working`. It sends `CHIEF_STATUS_BOT_COLOR` and `CHIEF_STATUS_BOT_URL` when those are set.

The same post, as one curl line:

```bash
curl -X POST "https://chief-status.<your-subdomain>.workers.dev/status" \
  -H "Authorization: Bearer YOUR-TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"bot":"Agent1","status":"working","task":"one short line about the job","color":"#3B82F6"}'
```

`started_at` is optional. On `working`, leave it out and the feed uses the current time, or send when the job began, in UTC, like `2026-10-18T10:00:00Z`. On `done` or `failed`, leave it out. If that bot was working, the feed keeps the working start for the row and for today's log.

Add `"url":"https://example.com/agent1"` when you want the row to open a chat. Leave `url` out and the previous link stays. Send `"url":""` to clear it. `"color"` works the same way: omit it to keep the stored colour, or send `""` to clear it. With no colour stored, the panel picks a steady colour from the bot's name.

A finished job (`done` or `failed`) is also written to today's log. The panel lists those under **Finished today**, with how long each one took.
