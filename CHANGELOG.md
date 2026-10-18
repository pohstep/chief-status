# Changelog

## v1.5.0 — 2026-10-18

In plain words:

- **A sound when a bot needs you, off until you turn it on.** The moment a bot posts `needs_input`, and **Sound alert when a bot needs you** is on, the Mac speaks "<Bot> needs your approval" when the post sets `approval`, and "<Bot> needs you" otherwise. It speaks once, through the same voice as a failure. The menu bar stays the still **?** cube from 1.4. Red still wins. The spoken line does not check Focus.
- **A sound-only reminder is off.** Settings can set 2, 5, 10 or 15 minutes. It speaks at most 3 times, then stops until a new bot starts waiting. A new waiter restarts the interval, so a reminder does not land right after the first spoken line.
- The feed accepts an optional `approval` boolean on a status post. It is stored and returned only as meaningful for `needs_input`. Older apps ignore it. `post-status.sh` takes `--approval` or `CHIEF_STATUS_APPROVAL=1`.
- README, version and the Homebrew cask move to 1.5.0. The cask checksum is `REPLACE_WITH_SHA256` until the disk image is built. Nothing in 1.5.0 is released yet.
- **Send a test post** uses a one-off name, `ChiefStatusTest-<unix time>`, then posts that bot as idle and deletes only that name.
- **The 404 follows the last post.** The feed stores `last_posted_at` on every post. A long job that keeps posting stays orange. A working post with no `started_at`, for a bot that was not already working, sets `started_at` to now.
- **Open at login is only the Settings switch.** `./install.sh` no longer writes a LaunchAgent. The app removes `com.chiefstatus.menubar` if an older install left it.
- A spoken failure waits 10 minutes before that bot can set it off again. Switching feeds forgets which bots were already waiting.
- The Deploy to Cloudflare button is documented as copying the code into your own GitHub or GitLab account first. A read token can be added in the Cloudflare dashboard, and the setup link can carry it as `token`.
- Install steps lead with **Open Anyway** on macOS 15. Right-click → Open is the macOS 13–14 note. The cask quits the app on uninstall, and `brew uninstall --zap` deletes `com.chiefstatus.menubar` preferences.
- Settings → **About** shows the bundle version and **Check for updates**. It looks up the latest GitHub release only when you click, and it downloads nothing.

Details:

- Worker: `POST /status` accepts optional `approval` (a boolean). Omitted, null, or any status other than `needs_input` stores `false`. A non-boolean is `400`. `GET /status` and the live snapshot include `approval` on each bot. Existing rows gain the column with default `0`. `READ_TOKEN` is unchanged: tests in `worker/test/feed.test.mjs` still cover a missing token, a wrong token, the post password not counting as the read token, and `?token=` on the live feed only. New tests cover storing and returning `approval`, ignoring it on other statuses, the script flag, and the env var.
- `worker/scripts/post-status.sh` accepts `needs_input "what is needed" --approval`. `CHIEF_STATUS_APPROVAL=1` (also `true`, `yes`, `on`) does the same on a `needs_input` post and is ignored for other statuses. `--approval` on another status exits with an error. The header says the task must say exactly what is needed.
- App: a transition into `needs_input` speaks through `FailureSpeaker` (the same `NSSpeechSynthesizer` queue as "<Bot> task failed") when `needsYouSound` is on. It speaks once per entry. The first snapshot after launch does not speak for a wait that was already there. The menu bar cube is unchanged from 1.4: red, then the still **?** cube in the icon colour. Needs-you does not schedule a redraw timer, and nothing redraws at 30 fps. The working and idle faces keep the 1.4 motion, at 12 or 20 fps, only while that face is showing.
- `NSSpeechSynthesizer` does not consult Focus or Do Not Disturb. Reading Focus status needs the Focus Status entitlement, which an unsigned app cannot ship, so the spoken line can play while Focus is on.
- The reminder is one repeating timer and speech only. It runs when the sound alert is on, the interval is 2, 5, 10 or 15, and someone is still waiting, and fewer than 3 reminders have been spoken in this episode. A bot that newly enters `needs_input` resets that count and restarts the timer. Missing interval means off. Nobody waiting resets the count.
- Settings keys in `com.chiefstatus.menubar`: `needsYouSound` (missing means off) and `needsYouReminderMinutes` (missing means off). The panel card says **approve** when `approval` is true.
- Notification permission is requested only when **Alert when a bot fails** is turned on. Needs-you has no banner. `com.chiefstatus.togglePanel` is observed only when the app is launched with `--test` or `--render-preview`. `NSApp.activate(ignoringOtherApps:)` runs only for a click on the menu bar cube.
- A spoken failure alert waits 10 minutes per bot. The banner can still post on a new failure inside that window. Changing the feed address clears known statuses, the failure cooldown, and the reminder count before the next snapshot is applied.
- Worker: every post stores `last_posted_at` (server time) and returns it on the bot. The 404 and **stale?** use that when it is present, and `started_at` when an older feed omits it. A `working` post with no `started_at`, for a bot that was not already working, sets `started_at` to now. A repeat of the same status keeps the job start. `parseStartedAt` rejects a timestamp with no time zone and one more than 2 minutes ahead. An older app ignores `last_posted_at` and keeps using `started_at`.
- `--render-preview` writes `about-light.png` and `about-dark.png`.
- **Send a test post** posts `{"bot":"ChiefStatusTest-<unix time>","status":"working","task":"test post"}`, then that same bot as `idle`, then `DELETE /status/<that name>` with the post password. A delete that answers `200` or `404` counts as cleaned up. The password is still memory only.
- Open at login uses `SMAppService` only. `install.sh` boots out and deletes `~/Library/LaunchAgents/com.chiefstatus.menubar.plist` instead of creating it. The app disables that label and deletes the plist on launch and when the switch changes. It does not boot the job out, because that would quit the app if the old agent had launched it.
- Setup link: `chiefstatus://setup?feed=…&password=…&token=…`. `token` is optional. A non-empty value is saved to the existing `readToken` preference before the first read. An omitted token does not clear one already saved. The URL is not logged.
- **Check for updates** calls `https://api.github.com/repos/pohstep/chief-status/releases/latest` from the button only. `tag_name` is compared with `CFBundleShortVersionString` after a leading `v` is stripped. A match says "You're up to date". Anything else says "Version X is available", with **Download** opening `html_url` and the hint `brew upgrade --cask chief-status`. A network or parse failure says to try again when online. Nothing from the check is stored.
- Cask: `uninstall quit: "com.chiefstatus.menubar"`. `zap` already deletes `~/Library/Application Support/Chief Status` and `~/Library/Preferences/com.chiefstatus.menubar.plist`. The caveat leads with Open Anyway for macOS 15, and right-click → Open for macOS 13–14.
- Version `1.5.0` (`CFBundleVersion` 6). User-Agent `ChiefStatus/1.5.0`. The cask URL follows the version. `sha256` is `REPLACE_WITH_SHA256`.

## v1.4.0 — 2026-10-19

In plain words:

- **One download for Apple silicon and Intel.** `./install.sh` and `./packaging/make-dmg.sh` each build both chip types and join them with `lipo`.
- **A new feed starts empty.** `BOTS` ships as `""`, and the worker no longer falls back to Agent1 and Agent2.
- **First run has a next step.** Settings says **No feed yet? Set one up**, **Send a test post**, and **Deploy to Cloudflare**, instead of only "Paste your feed address to begin."
- **A curl prompt with the address and password filled in**, plus a `chiefstatus://setup?feed=…` link that fills in the app. The app shows and copies them. It does not save the post password, and it does not log it.
- **Open at login** in Settings, using the macOS 13 login-item switch.
- **No storage box for new feeds.** The KV binding is gone. A short note covers moving from v1.1. Setup asks for your time zone and writes `TZ`.
- **Optional read token.** When the `READ_TOKEN` secret is set, `GET /status` and the live feed need `Authorization: Bearer <token>` and answer `401` with an empty body without it. When it is unset, reading stays open. The app keeps the token in its private preferences (not the Keychain) and sends it on GET and on the WebSocket.
- **Icon colour.** Settings → Icon colour: Default (today's orange), eleven swatches, or a custom colour. It colours the working cube, the stale **404** cube and the needs-you **?** cube, updates the menu bar at once, and is kept in preferences (`iconColor`). Idle grey and failed red stay as they are. The **404**, the **?** and the eyes are dark or white, whichever reads better on the colour. No outlines.
- **Stale and needs-you faces keep the bot's colour.** In the panel, a maybe-stale bot's face stays in its own colour with **404** on it, and a needs-you face stays in its own colour with a **?**. The cards and the sort order are unchanged.
- **Homebrew cask** at `packaging/homebrew/Casks/chief-status.rb`, with the unsigned-app caveat. The old `--HEAD` formula is gone.
- README paths say `/Applications` for the disk image and `~/Applications` for `./install.sh`, and they say what `BOTS` is.

Details:

- Targets are `-target arm64-apple-macos13` and `-target x86_64-apple-macos13`, then `lipo -create`. `ServiceManagement` is linked for the login-item switch.
- URL scheme `chiefstatus` in `Info.plist`. `chiefstatus://setup?feed=…&password=…` fills the feed address and the in-memory post password. The Apple event handler and `application(_:open:)` do not log the URL.
- Read token: `UserDefaults` key `readToken` in `com.chiefstatus.menubar`. Sent as `Authorization: Bearer` on `GET /status` and the live WebSocket only. The test post uses the post password, which stays in memory.
- Worker: `configuredReadToken` treats a missing or blank `READ_TOKEN` as unset. A refusal is `new Response(null, { status: 401 })`. `GET /status` takes the Bearer header only. `/status/live` also accepts `?token=<token>`. `POST` and `DELETE` still use `STATUS_TOKEN`. Tests in `worker/test/feed.test.mjs` cover the empty feed, a missing token, a wrong token, the post password not being accepted as the read token, an authorized WebSocket, and `?token=` on the live feed only.
- `worker/scripts/set-tz.sh` writes `TZ`. The deploy button is `https://deploy.workers.cloudflare.com/?url=https://github.com/pohstep/chief-status/tree/main/worker`.
- The cask URL points at `Chief-Status-1.4.0.dmg`. `sha256` is the checksum of that disk image.
- Icon colour: UserDefaults key `iconColor` (`default` or `#RRGGBB`). Presets, in order: White `#FFFFFF`, Brown `#9A6D42`, Red `#E94347`, Deep orange `#E8663A`, Orange `#E9983A`, Green `#5ABF78`, Teal `#3BB5B0`, Blue `#3A86F4`, Purple `#8762F3`, Pink `#E85FA8`, Grey `#8E8E93`. The working, stale (404) and needs-you (?) cubes use it; Default is `#F39C28`. Fixed: idle `#8E8E93`, failed `#E5484D`. The mark and eye ink is `#1A1410` or white, whichever has the higher contrast ratio with the fill. The old black stale cube, its light rim, the indigo `#4F5BE8` menu bar cube and the contrast outline are gone. The small black stale dot on the working cube stays. `--render-preview` writes `icon-colours-light.png` and `icon-colours-dark.png` with Default and all eleven presets, in normal, stale, and needs-you.

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
