# Release notes template

Paste the body below into the GitHub release. Fill in the SHA-256 when `./packaging/make-dmg.sh` prints it. v1.5.0 is not released yet, so the checksum line stays `REPLACE_WITH_SHA256` until the disk image exists.

---

**Chief Status 1.5.0**: a bot that needs you calls you over, and the menu bar cube shakes until you answer.

What's new:

- **Needs-you alerts.** When a bot posts `needs_input`, you get a banner and a spoken line. The title is "<Bot> needs your approval" when the post sets `approval`, and "<Bot> needs you" otherwise. The body is the task line, so that line has to say exactly what is needed. A reminder repeats until the bot posts a different state. Click the banner to open that bot's chat.
- **The menu bar cube shakes and changes colour** while anyone is waiting, with a **?** or an **!** and a count. Shake, Banner and Voice are on by default. Reduce Motion, or switching Shake off, shows a still cube in your icon colour.
- **Send a test post** lights the panel, then removes the Test bot so it does not stay on the feed.
- **A locked feed can be set up from the link.** `chiefstatus://setup?feed=…&password=…&token=…` saves the read token. You can also add `READ_TOKEN` in the Cloudflare dashboard, with no Terminal.
- **About → Check for updates** compares this app with the latest GitHub release when you click it.

**Install:** download `Chief-Status-1.5.0.dmg`, open it, and drag Chief Status into Applications. The app is free and not signed by Apple, so the first time you open it macOS will block it.

- **macOS 15 or newer:** System Settings → Privacy & Security → **Open Anyway**.
- **macOS 13 or 14:** in Applications, right-click Chief Status, choose **Open**, then **Open** again.

Full steps in the [README](https://github.com/pohstep/chief-status#download-and-install).

Runs on macOS 13 or newer, Apple silicon or Intel. You also need your own free feed. The Deploy to Cloudflare button first copies the code into your own GitHub or GitLab account, so you need one of those plus Cloudflare. See [Set up the feed](https://github.com/pohstep/chief-status#set-up-the-feed).

**Check your download:** `shasum -a 256 Chief-Status-1.5.0.dmg` should print

SHA-256: `REPLACE_WITH_SHA256`

Full list of changes: [CHANGELOG.md](https://github.com/pohstep/chief-status/blob/main/CHANGELOG.md#v150--2026-10-18).

**Support:** Chief Status is free. If it saves you time, a dollar is appreciated, never expected.

| Chain | Address |
| --- | --- |
| Ethereum | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Polygon | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Bitcoin | `bc1qp33c2ltr9l56gr0qhkydwhrs659ex87l8xhu5t` |

Send only on the matching network.
