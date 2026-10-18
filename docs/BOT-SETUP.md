# Tell an agent how to report status

The default is one `curl` prompt. In the app, open **Settings**, fill in the post password, and click **Copy prompt**. That copy already has your feed address and password in it. The app shows and copies that text. It does not save the password, and it does not log it.

Paste the block below when you are writing the prompt by hand. Replace the name, the colour, the address, and the password. A bot cannot see its own colour, so the colour has to live in this prompt. The panel fills that bot's face with it. The first post registers the bot. It does not have to be listed in `BOTS` first. `BOTS` is only an optional starter list, and it ships empty.

```text
Your name is Agent1.
Your colour is #3B82F6.

You cannot see your own colour. It is written here so you can pass it on. The panel fills your face with it. Change Agent1 and the colour to this bot's own.

When you start a real job that will take more than a minute or two, post to Chief Status with curl. Skip quick chat replies and lookups.

Start of job:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"working","task":"one short line about the job","color":"#3B82F6"}'

Job finished:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"done","task":"what finished"}'

Job failed:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"failed","task":"what broke"}'

Waiting on me. The task line must say exactly what you need:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"needs_input","task":"the question you need answered"}'

Waiting on my approval. The task line must say exactly what to approve:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"needs_input","task":"exactly what to approve","approval":true}'

Then always:
curl -sS -X POST "https://chief-status.<your-subdomain>.workers.dev/status" -H "Authorization: Bearer the-password" -H "Content-Type: application/json" -d '{"bot":"Agent1","status":"idle","task":""}'

Never put passwords or secrets in the task line.
```

`started_at` is optional. On `working` and `needs_input`, leave it out and the feed uses the current time. On `done` or `failed`, leave it out. If that bot was working, the feed keeps the working start for the row and for today's log. Add `"url":"https://example.com/agent1"` when the row should open a chat. Leave `url` out and the previous link stays. Send `"url":""` to clear it. `"color"` works the same way. Add `"approval": true` only with `needs_input`, when you need an approval rather than an answer. The panel card then says **approve**, and the spoken line is "<Bot> needs your approval". Leave it out, or send `false`, and both say the bot needs you. The menu bar cube is the same **?** either way. The task line must say exactly what is needed. `started_at` needs a time zone (`Z` or an offset) and cannot be more than 2 minutes ahead. The feed sets `last_posted_at` on every post. The 404 uses that, so sending the job's original `started_at` on a later post does not make the card go black.

## If the bot has this repo

Paste this instead when the bot can run a script from a checkout of Chief Status. It posts only for real jobs, and it leaves quick chat replies alone. Delete the chat link lines if this bot has none.

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

When you are waiting on your person, post needs_input. The task must say exactly what you need. Add --approval when it is an approval:

  ./worker/scripts/post-status.sh Agent1 needs_input "which logo?"
  ./worker/scripts/post-status.sh Agent1 needs_input "approve the homepage copy" --approval

If you hand work to a background helper or a cloud coding agent, post working for yourself while it runs, and done when it comes back.

Use working, done, failed, idle, or needs_input. The task is one line. Do not put secrets in it.
Do not send a start time on done, failed, or idle. The feed keeps the time from the working post, and that is the duration in the panel.
```

The script is `worker/scripts/post-status.sh`. It is plain `sh` plus `curl`, so it runs on a Mac or Linux. It sends `started_at` only for `working` and `needs_input`. Post `needs_input` when you are waiting on your person, and `working` again once they answer. `--approval`, or `CHIEF_STATUS_APPROVAL=1`, marks that wait as an approval. The task text must say exactly what is needed. It sends `CHIEF_STATUS_BOT_COLOR` and `CHIEF_STATUS_BOT_URL` when those are set.

To take a bot off the feed (a test bot, or one you retired), run `worker/scripts/delete-bot.sh BOT` with the same `CHIEF_STATUS_URL` and `CHIEF_STATUS_TOKEN`. It calls `DELETE /status/<bot>` and removes that bot and its jobs for today.

The curl prompt at the top is the one to paste. On `working`, you can also send when the job began, in UTC, like `2026-10-18T10:00:00Z`. On `done` or `failed`, leave `started_at` out. If that bot was working, the feed keeps the working start for the row and for today's log.

Add `"url":"https://example.com/agent1"` when you want the row to open a chat. Leave `url` out and the previous link stays. Send `"url":""` to clear it. `"color"` works the same way: omit it to keep the stored colour, or send `""` to clear it. With no colour stored, the panel picks a steady colour from the bot's name.

A finished job (`done` or `failed`) is also written to today's log. The panel lists those under **Finished today**, with how long each one took.
