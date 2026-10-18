# Changelog

## v1.3.1 — 2026-10-18

In plain words:

- **You can now keep your feed private.** Set a read token on the feed, paste the same token into the app, and nobody else can read your bots' names or tasks. Without the token, the feed replies with an empty "401 Unauthorized". See [Keep your feed private](README.md#keep-your-feed-private).
- **Settings has a new Read token (optional) field.** It's hidden as you type, kept on this Mac only, and sent whenever the app reads the feed.
- **A clear message** when the feed is locked and the app has no token, or the wrong one: *"This feed is locked. Add its read token in Settings."*
- **Your bots don't change.** Posting still uses the same password. A feed without a read token works exactly as before.

Details:

- Worker: the `READ_TOKEN` secret is optional and is not in `secrets.required`. When it's set, `GET /status` and `/status/live` need `Authorization: Bearer <token>`; `/status/live` also accepts `?token=<token>`. A missing or wrong token gets 401 with an empty body. The post password is not accepted as a read token. `POST` and `DELETE` are unchanged. `GET /` stays open.
- App: the token is in UserDefaults (`com.chiefstatus.menubar`, key `readToken`), not the Keychain, so updates don't bring Keychain prompts. It's sent as a Bearer header on the feed read and on the live connection, only when it's not empty.
- Tests: `npm test` now also starts a second local feed with `READ_TOKEN` set and checks 401 with an empty body for no token, a wrong token and the post password, then 200 and a live snapshot with the right token (header or `?token=`).

## v1.3.0 — 2026-10-18

In plain words:

- **A bot that went quiet now looks different.** If a bot says "working" and then posts nothing for 30 minutes, its card turns black, its face shows **404**, and the label reads **maybe stale · 34m**. Before, the old task kept showing as if it were current.
- **Every row says when that bot last posted**, like `Done · 12m ago` or `Idle · 3h ago`.
- **Quiet bots drop below busy ones** in the working list.
- **The menu bar cube follows the same rule.** Red still wins, then indigo for a bot that needs you. Orange while any bot is really working, with a small black dot if another working bot has gone quiet. A black **404** cube when every working bot has gone quiet. Grey still only means idle.
- **stale?** still appears after an hour.
- **New status: `needs_input`.** A bot that's waiting on you gets an indigo card with a **?** face at the very top of the panel, labelled **needs you · 5m ago**. It never goes stale. The header counts it, and the menu bar cube turns indigo with a **?**. Idea from [@TheXSami](https://x.com/TheXSami) on X. Thank you!
- **Check on it, or Clear.** Every black maybe-stale card shows two small buttons. **Check on it** opens its chat. **Clear** hides the warning on this Mac for 30 minutes: the bot stays working and shows **last update 36m ago**. Nothing is posted. Clicking the rest of a black card does nothing, so it never opens a chat without asking. Right-click offers the same choices.
- **The header counts quiet bots apart**, like `1 needs you · 1 working · 2 maybe stale · 27 done today`.
- **Chat links that stay on your Mac.** Put links in `links.json` and clicking a row opens that chat, even when the bot never sent a link.
- **Appearance setting.** **Settings → Appearance**: System, Light or Dark. It's kept when you quit and reopen.
- **Spoken failure alert.** With **Alert when a bot fails** on, a new failure is spoken aloud, like "Chief task failed", in place of the old sound. The macOS banner stays.
- **Remove a bot.** `./scripts/delete-bot.sh Agent9` takes a bot off the feed, with its jobs for today. It needs the feed password.
- The feed accepts `needs_input` and the new delete route. Everything else about the feed is unchanged, and older apps still work with it.

Details:

- Stale is measured from `started_at`, which `post-status.sh` sends on every `working` post, so a new working post clears it at once. No `updated_at` field is needed.
- `StaleRule.fadeAfterMinutes = 30` in `Config.swift`. It is clamped to one minute below `stale_after_minutes` (`STALE_MINUTES`, default 60) when that is set lower.
- The "ago" time on done and failed rows uses that bot's newest `ended_at` in `today`, then `started_at` if it has no job today. Idle rows use `started_at`.
- Maybe-stale cards: a near-black card and face (`#111113`; `#050506` card in dark mode), a 1 px white rim at 28–32% opacity so they read on a dark panel, a hollow ring with no pulse, and white text. The face shows "404" in place of the eyes and mouth.
- The menu bar cube is re-checked every second, so it turns black without waiting for a new post. The black cube has a 1 pt white rim at 55% so it shows on a dark menu bar. The tooltip and VoiceOver label say how many bots may be stale.
- VoiceOver reads "last update 34 minutes ago, maybe stale" on a quiet card, and "last update 12 minutes ago" on other rows.
- Menu bar priority: failed (red) > needs_input (indigo `#4F5BE8` cube, white "?") > fresh working (orange, plus the stale dot) > all working stale (black 404) > grey.
- `needs_input` card: indigo `#4F5BE8` (dark mode `#6B76F5`), hue 235°, at least 19° from every bot colour in use (the nearest are `#8762F3` at 255° and `#3A86F4` at 215°). The bot's own colour fills the face with a "?" in place of the eyes and mouth. The label counts from `started_at`.
- Worker: `needs_input` is in `STATUSES`. It is not a finish, so it records no job. A change into it gets `started_at` = now when none is sent, and a repeat keeps the clock. `post-status.sh` accepts it and sends `started_at` with it. New test in `feed.test.mjs`.
- Worker: `DELETE /status/<bot>` with the same `Authorization: Bearer` password as `POST`. It removes the bot row and its jobs, broadcasts the new snapshot to live clients, and answers `{"ok":true,"deleted":"…","jobs_removed":N}`, `401` without the password, `404` for an unknown bot, `400` for a bad name. `DELETE /status` stays `405`. New tests in `feed.test.mjs`. Helper: `worker/scripts/delete-bot.sh`.
- Local chat links: `links.json` next to `config.plist`, `{"Bot": "link"}`. The feed `url` wins when set. The scheme block list (`javascript`, `data`, `file`, `vbscript`) applies to both. Example in `docs/links.example.json`.
- Clear is local and in memory only. It stores the bot's `started_at` and the time of the click. While that `started_at` is unchanged and less than one fade window (30 min) has passed, the card is a normal working card with "last update Xm ago". A new `started_at` or status drops it.
- Spoken alert: `NSSpeechSynthesizer` with the system voice (the one `say` uses) says "<Bot> task failed". It fires only when a bot changes into `failed`, once per bot per failure; polls and reconnects don't repeat it. Several failures at once are queued and spoken in turn. The banner no longer plays a sound. Each alert writes a `ChiefStatus spoken alert` line to the system log.
- Appearance is stored in UserDefaults (`com.chiefstatus.menubar`, key `appearance`: `system`, `light`, `dark`) and applied to `NSApp.appearance` and the popover, so the frosted materials follow it.
- A distributed notification, `com.chiefstatus.togglePanel`, opens or closes the panel, for scripted screenshots and tests.
- `ChiefStatus --render-preview <folder>` writes sample panels (light and dark), the 404 faces, and every menu bar cube to PNG files without touching the feed.

## v1.2.0 — 2026-10-18

In plain words:

- **Live updates.** A change shows up in a second or two. The feed now uses a Cloudflare Durable Object with a live WebSocket, still on the free plan. The app falls back to checking every ~15s if the live link drops.
- **Redesigned frosted panel.** Working bots get their own cards, longest-running first. Everyone else sits in one list.
- **Each bot's face is filled with its own colour.** Status shows in the card around the face; the menu bar cube stays grey, orange or red.
- **Finished today** is open by default and shows how long each job took.
- **Real job durations.** A `done` or `failed` post keeps the start time from the `working` post.
- **Bots register themselves.** A bot's first post adds it to the panel with its name and colour. `BOTS` is now just an optional starter list.
- **Failure alerts** (off by default): a sound and a banner when a bot newly fails.
- **Troubleshooting docs:** "A bot is working but not lighting up", plus a full README rebuild with colour setup.
- **Download a `.dmg`** from Releases instead of building it yourself. It is unsigned; the README shows how to open it the first time.

Details:

- The panel shows working bots in their own cards, longest first, and the other bots in one list. **Finished today** is open by default, with a count and a total. The header and footer stay put. The window material is `.popover` only.
- A `done` or `failed` post keeps the start time from the working row, so today's durations are the length of the job. `post-status.sh` sends `started_at` only for `working`.
- A bot's first post registers it. `BOTS` is an optional starter list and order. Each bot can store a `#RRGGBB` colour. With none stored, the app picks a stable colour from the name. In the panel that colour fills the face, and the eyes are dark or light so they still read. Status is the card: an orange working card and elapsed pill, a red tint and a red failed label, a green check beside a done name, and a plain row when idle. The menu bar cube stays grey, orange, or red.
- Opt-in alert when a bot fails. It is off until you turn on **Alert when a bot fails**. A sound and a macOS banner fire only when a bot newly becomes failed.
- Live updates over a hibernating WebSocket on the Workers free plan. The 15s poll remains the fallback when that connection drops. `GET /status` and `POST /status` stay compatible.
- Bot setup notes in `docs/BOT-SETUP.md`, plus an optional chat link on each row. Clicking a row with a link opens it.
- Today's finished jobs, capped at 200 and reset on the clock of `TZ` (default UTC).
- A working row that has run longer than `STALE_MINUTES` (default 60) shows **stale?**.
- A Homebrew formula for a separate `pohstep/homebrew-tap`. `./install.sh` is unchanged.
- README demo of the menu bar cube, and a still of the panel with each face in its bot colour.

## v1.1

- Public, generic defaults: `Agent1` and `Agent2`. No personal feed address.
- First launch asks you to paste the feed address.
- Livelier menu bar motion: bob, twirl, hop, wiggle, look, and blink while working. A slow blink while idle. One shake when something fails.
- The panel refreshes as soon as it opens, then about every 5s while it stays open. Background checks are about every 15s, and about 60s after repeated network errors.
- Menu bar drawing uses an `NSImage` drawing handler, and the single-instance lock uses `lockf`, so it builds on macOS 13 Intel.

## v1.0

- Cloudflare Worker feed: public `GET /status`, token-protected `POST /status`.
- Native macOS 13 menu bar app, built with `swiftc` by `./install.sh`, installed into `~/Applications` and opened at login.
- Grey, orange, and red menu bar face. Frosted panel with one row per bot.
