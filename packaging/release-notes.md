# Release notes template

Paste the body below into the GitHub release. For a new release, put in the SHA-256 that `./packaging/make-dmg.sh` prints.

---

**Chief Status 1.5.0**: a bot that needs you is spoken once, and the menu bar cube stays the still **?**.

What's new:

- **A sound when a bot needs you.** When a bot posts `needs_input`, the Mac speaks "<Bot> needs your approval" or "<Bot> needs you", once, if **Sound alert when a bot needs you** is on. That switch is off until you turn it on. A sound-only reminder is off until you set 2, 5, 10 or 15 minutes, and then it speaks at most 3 times.
- **The menu bar cube is unchanged.** A bot that needs you still shows the still **?** cube. Red still wins when a bot has failed. A working bot goes black only after 30 minutes without a post, not 30 minutes after the job started.
- **Send a test post** lights the panel, then removes that one `ChiefStatusTest-<time>` bot so it does not stay on the feed.
- **A locked feed can be set up from the link.** `chiefstatus://setup?feed=…&password=…&token=…` saves the read token. You can also add `READ_TOKEN` in the Cloudflare dashboard, with no Terminal.
- **About → Check for updates** compares this app with the latest GitHub release when you click it.
- **No update in N min.** A working or idle bot that hasn't posted for a while (10 minutes unless you change **No update after** in Settings) says **no update in N min**. No sound, no banner. `worker/scripts/heartbeat.sh` keeps a long job fresh. Update your feed Worker to get `last_posted_at`.

**Install:** download `Chief-Status-1.5.0.dmg`, open it, and drag Chief Status into Applications. The app is free and not signed by Apple, so the first time you open it macOS will block it.

- **macOS 15 or newer:** System Settings → Privacy & Security → **Open Anyway**.
- **macOS 13 or 14:** in Applications, right-click Chief Status, choose **Open**, then **Open** again.

Or with Homebrew: `brew install --cask pohstep/tap/chief-status`.

**Updating from an older install:** the first time 1.5.0 opens, it removes the old start-at-login file (`~/Library/LaunchAgents/com.chiefstatus.menubar.plist`) that an older `./install.sh` left behind. From now on **Settings → Open at login** is the only switch for that. Turn it on there if you want the app to start when you log in.

Full steps in the [README](https://github.com/pohstep/chief-status#download-and-install).

Runs on macOS 13 or newer, Apple silicon or Intel. You also need your own free feed. The Deploy to Cloudflare button first copies the code into your own GitHub or GitLab account, so you need one of those plus Cloudflare. See [Set up the feed](https://github.com/pohstep/chief-status#set-up-the-feed).

**Check your download:** `shasum -a 256 Chief-Status-1.5.0.dmg` should print

SHA-256: `09963100ddba0a8b0c01f97dcc8f9e23c1de85deaf91323cc71e13f4eb70263e`

Full list of changes: [CHANGELOG.md](https://github.com/pohstep/chief-status/blob/main/CHANGELOG.md#v150--2026-10-18).

**Support:** Chief Status is free. If it saves you time, a dollar is appreciated, never expected.

| Chain | Address |
| --- | --- |
| Ethereum | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Polygon | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Bitcoin | `bc1qp33c2ltr9l56gr0qhkydwhrs659ex87l8xhu5t` |

Send only on the matching network.
