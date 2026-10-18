# Changelog

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
