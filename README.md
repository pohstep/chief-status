<p align="center">
  <img src="docs/icon.png" width="112" alt="Chief Status icon: an orange cube with two eyes">
</p>

<h1 align="center">Chief Status</h1>

<p align="center">
  A tiny face in your Mac's menu bar that shows which of your AI bots are working, done, or stuck,<br>
  so you don't have to open every chat to check.
</p>

<p align="center">
  <a href="#download-and-install"><b>Download</b></a> &nbsp;·&nbsp;
  <a href="#teach-your-bots-to-report"><b>Set up your bots</b></a> &nbsp;·&nbsp;
  <a href="#build-it-yourself"><b>Build it yourself</b></a> &nbsp;·&nbsp;
  <a href="#support"><b>Support</b></a>
</p>

<p align="center">
  <img src="docs/hero.png" alt="The Chief Status panel open under the menu bar cube: two bots working, one failed, one done, and today's finished jobs">
</p>

## What it does

- **Shows status at a glance.** The cube in the menu bar is grey when every bot is idle, orange (and gently bobbing) while any bot is working, and red when one has failed.
- **One panel for the whole team.** Click the cube and a frosted panel drops down. Bots that are working get their own orange card, longest-running first. A failed bot gets a red row, a finished one a green check.
- **Every bot has its own colour.** Each bot's face is filled with its own colour, so you can tell them apart in a second. The bot picks the colour itself the first time it reports (see [Colours](#colours)).
- **Real job times.** Each card shows how long the job has been running. **Finished today** lists every job that finished today and how long it took.
- **Live.** A change shows up within a second or two, with no refresh button.
- **Failure alert, if you want one.** Switch on **Alert when a bot fails** and a new failure plays a sound and shows a macOS banner. It is off until you turn it on.
- **Stale warning.** A bot that has said "working" for over an hour gets a **stale?** tag, which usually means it forgot to say it was done.
- **Click to open the chat.** If a bot gives a link to its chat, clicking its row opens that chat.
- **Costs nothing to run.** The app uses no AI at all. The feed it reads runs on Cloudflare's free plan. Each bot sends one short line when a job starts and one when it ends.

Chief Status is a small native Swift app. There is no Electron, no account, and no tracking.

<p align="center">
  <img src="docs/demo.gif" width="720" alt="Animation: the menu bar cube goes from grey to orange as Agent1 and Agent2 start working, then turns red when Agent3 fails. Each bot's face is filled with its own colour.">
</p>

## How it works, in one picture

```
 your bots ──(one short line: "working" / "done" / "failed")──▶ your feed ──▶ Chief Status in your menu bar
                                                         (a free Cloudflare Worker)
```

There are three parts:

1. **The app** on your Mac. It only reads.
2. **The feed**, a tiny free web service you put on your own Cloudflare account. It remembers each bot's latest line. Setting it up takes about ten minutes, once.
3. **Your bots.** You paste a short instruction into each bot so it reports to the feed.

## Download and install

1. Download `Chief-Status-1.2.0.dmg` from the [latest release](https://github.com/pohstep/chief-status/releases/latest).
2. Open the `.dmg` file and drag **Chief Status** onto the **Applications** folder next to it.
3. Open **Chief Status** from Applications. The first time, macOS stops it and says *"Apple could not verify…"*. That is because the app is free and not signed with a paid Apple developer account ([why](#why-does-macos-warn-me)). Let it through once:
   - **macOS 15 Sequoia or newer:** click **Done**. Open **System Settings → Privacy & Security**, scroll down to *"Chief Status was blocked…"*, click **Open Anyway**, and type your Mac password.
   - **macOS 13 Ventura or 14 Sonoma:** in the Applications folder, right-click (or Control-click) **Chief Status**, choose **Open**, then click **Open** again.
   - **Or, in Terminal:** `xattr -dr com.apple.quarantine "/Applications/Chief Status.app"`
4. Look for the small cube in your menu bar, near the clock. There is no Dock icon and no window. Click the cube.
5. Paste your feed address (from [Set up the feed](#set-up-the-feed)) and click **Save**.
6. To have it start every time you turn on your Mac: **System Settings → General → Login Items**, click **+** and pick **Chief Status**.

On a Mac with an Apple chip (M1 or newer), macOS may first ask to install **Rosetta**. Click **Install**. The app is built for Intel Macs, and Rosetta lets it run on Apple chips.

What's new in each version: [CHANGELOG.md](CHANGELOG.md).

### Why does macOS warn me?

Apple charges $99 a year for a developer account that "signs" apps so macOS trusts them without asking. Chief Status is free, so it skips that. The code is all here for anyone to read, and you can [build it yourself](#build-it-yourself) instead of downloading.

### Remove it

Click the cube, then **Quit**. Drag **Chief Status** from Applications to the Trash. To also remove your saved feed address, delete the folder `~/Library/Application Support/Chief Status/`.

If you installed with `./install.sh`, run `./uninstall.sh` instead. It also removes the start-at-login setting.

## Requirements

| | |
| --- | --- |
| Mac | macOS 13 Ventura or newer. Intel, or Apple chip with Rosetta |
| For the feed | A free [Cloudflare](https://dash.cloudflare.com/sign-up) account, and [Node.js](https://nodejs.org) 20 or newer on any computer, used once to set it up |
| Only to build it yourself | Apple's Command Line Tools (`xcode-select --install`). The full Xcode app is not needed |

## Using it

| Do this | To get this |
| --- | --- |
| Look at the cube | Grey: all idle. Orange: someone is working. Red: someone failed |
| Click the cube | Open or close the panel |
| Click a bot's row | Open that bot's chat, if it sent a link |
| Click **Finished today** | Fold or unfold today's finished jobs. It remembers your choice |
| Click **Settings** | Change the feed address, or turn **Alert when a bot fails** on or off |
| Click **Quit**, or press `⌘Q` | Close the app |

<p align="center">
  <img src="docs/panel.png" width="328" alt="The panel up close">
</p>

How to read the panel:

| You see | It means |
| --- | --- |
| An orange card with a timer | The bot is working, and has been for that long |
| **stale?** on a card | It has said "working" for over an hour. It probably forgot to say "done" |
| A red row and **Failed** | The bot's last job failed |
| A green check by the name | The bot finished its last job |
| A plain row | The bot is idle |
| The face colour | Just which bot it is. The colour never means status |

While a bot is working, the cube bobs, and every few seconds does a little move: a twirl, a hop, a wiggle, a look around, or a blink. When everything is idle it only blinks now and then. When a bot fails it shakes once, then stays red.

## Set up the feed

The feed is a tiny program that runs for free on Cloudflare (it's called a "Worker"). Your bots send their status to it, and the app reads from it. You set it up once, from a Terminal window.

You need a free Cloudflare account and Node.js 20 or newer. If `npm install` is very slow where you are, run `npm config set registry https://registry.npmmirror.com` and try again.

1. **Get the code and go into the `worker` folder.**

   ```bash
   git clone https://github.com/pohstep/chief-status.git
   cd chief-status/worker
   npm install
   ```

2. **Sign in to Cloudflare.** A browser window opens. Log in and click **Allow**.

   ```bash
   npx wrangler login
   ```

3. **Make a small storage box** for the feed. The command prints an `id`. Open `worker/wrangler.toml` in any text editor and paste that id in place of `00000000000000000000000000000001`.

   ```bash
   npx wrangler kv namespace create STATUS
   ```

4. **Choose a password** that your bots will use to post. Make up a long one and type it when asked. Nothing shows while you type; that's normal. The password is stored inside Cloudflare, never in these files.

   ```bash
   npx wrangler secret put STATUS_TOKEN
   ```

5. **Put the feed online.**

   ```bash
   npx wrangler deploy
   ```

   It prints your feed's address, like `https://chief-status.<your-subdomain>.workers.dev`. Open it in a browser. You should see a short note that Chief Status is running.

6. **Paste that address into the app** (click the cube → **Settings**). Either the plain address or the same address ending in `/status` works.

Keep the address and the password somewhere safe, like a password manager. Your bots need both.

> [!NOTE]
> Anyone who knows the address can **read** the bot names and their one-line task. Only someone with the password can **change** anything. So never put passwords or private details in a task line.

To see the raw feed yourself, open `https://chief-status.<your-subdomain>.workers.dev/status` in a browser.

To change the password later, run `npx wrangler secret put STATUS_TOKEN` again in the `worker` folder, then give every bot the new one.

## Teach your bots to report

Chief Status only knows what your bots tell it. Each bot needs two things:

1. **The feed address and password**, saved on the computer the bot runs on as `CHIEF_STATUS_URL` and `CHIEF_STATUS_TOKEN`.
2. **A short instruction** in the bot's instructions (its system prompt, profile, or rules), so it reports when it starts and finishes a real job.

Paste this into each bot. Change `Agent1` to that bot's name, and `#3B82F6` to its colour (see [Colours](#colours) below):

```text
Your name is Agent1.
Your colour is #3B82F6.
Optional chat link: https://example.com/agent1

You cannot see your own colour. It is written here so you can pass it on. The panel fills your face with it. Delete the chat link line if this bot has none.

When you start a real job that will take more than a minute or two, post a status line to Chief Status. Skip quick chat replies and lookups.

Before each post, set:
  export CHIEF_STATUS_BOT_COLOR="#3B82F6"
  export CHIEF_STATUS_BOT_URL="https://example.com/agent1"

Start of job:   ./worker/scripts/post-status.sh Agent1 working "one short line about the job"
Job finished:   ./worker/scripts/post-status.sh Agent1 done "what finished"
Job failed:     ./worker/scripts/post-status.sh Agent1 failed "what broke"
Then always:    ./worker/scripts/post-status.sh Agent1 idle ""

If you hand work to a background helper or a cloud coding agent, post working for yourself while it runs, and done when it comes back.
Never put passwords or secrets in the task line.
```

That's it. **The first time a bot posts, it shows up in the panel by itself**, with its name and colour. You don't have to add it anywhere first.

A longer version, plus a one-line `curl` command for bots that can't run the script, is in [docs/BOT-SETUP.md](docs/BOT-SETUP.md).

### Colours

Each bot's face in the panel is filled with that bot's own colour. Here is how a bot gets it:

1. **You choose the colour** and write it in that bot's instruction, like `Your colour is #3B82F6.`
2. **The bot sends it with its first status line** (that's what `CHIEF_STATUS_BOT_COLOR` does).
3. **The feed remembers it.** Later posts don't need to send it again. A post without a colour keeps the saved one.
4. **No colour sent?** The app picks a steady colour from the bot's name, so the same name always gets the same colour.

A colour is written as `#` and six letters or numbers, called a hex code (`#RRGGBB`). You can pick one with any online "colour picker" and copy the code it shows. Some that look good:

| Bot | Colour | Hex code |
| --- | --- | --- |
| Agent1 | Blue | `#3B82F6` |
| Agent2 | Soft yellow | `#F6E27A` |
| Agent3 | Pink | `#EC4899` |
| Agent4 | Charcoal | `#1F2937` |
| Agent5 | White | `#FFFFFF` |
| Agent6 | Teal | `#14B8A6` |

Light faces (like white or yellow) get dark eyes and dark faces get light eyes, so every face stays readable.

**Tips**

- Avoid plain orange, red and green for bot colours. Those are the status colours, and the face would blend into its card.
- To change a bot's colour, change it in the bot's instruction. Its next post updates the face.
- To go back to the automatic colour, remove the colour from the bot's instruction and send one post with an empty colour, using the `curl` line in [docs/BOT-SETUP.md](docs/BOT-SETUP.md) with `"color":""`. The script on its own never clears a colour; leaving the colour out just keeps the saved one.
- The menu bar cube itself always stays grey, orange or red. Bot colours only appear in the panel.

### Post a status by hand

Handy for testing. From the `worker` folder:

```bash
export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
export CHIEF_STATUS_TOKEN="the password from the deploy step"
./scripts/post-status.sh Agent1 working "drafting the homepage"
```

The status can be `working`, `done`, `failed` or `idle`. Each bot has one current line, and a new post replaces it. A `done` or `failed` post is also added to today's **Finished today** list, with how long the job took since its `working` post.

## A bot is working but not lighting up

Chief Status only shows what bots post. If a bot is busy but its face is not orange, go down this list in order. Most of the time it is step 1.

1. **The bot did not post.** The usual cause. The bot forgot, skipped the post because it thought the job was quick, or a later `idle` post (from a test, or from another job finishing) overwrote its `working` line. Ask the bot to post again:

   ```bash
   ./worker/scripts/post-status.sh Agent1 working "what it is doing"
   ```

   If this keeps happening, check that the "Teach your bots to report" text is really in that bot's instructions.

2. **Check the feed itself.** Open your feed address in a browser, for example `https://chief-status.<your-subdomain>.workers.dev/status`. You see a list of bots and their current status.
   - If the bot shows `working` there, the feed is fine and the problem is the app. Go to step 5.
   - If it shows `idle`, or the bot is missing, the post never arrived. Go to step 3.

3. **Read the error from the post.** Run the post by hand and look at what comes back.
   - `Set CHIEF_STATUS_URL…` or `Set CHIEF_STATUS_TOKEN…`: the bot's computer is missing the feed address or the password. Set both (see [Post a status by hand](#post-a-status-by-hand)).
   - `unauthorized` (error 401): the password is wrong. It must match the one you gave the worker with `npx wrangler secret put STATUS_TOKEN`.
   - `body must be JSON` or another 400 error: usually a stray quote in the task line. Keep the line plain.
   - `403` or a Cloudflare "blocked" page: some tools, such as Python's built-in web library, get blocked by Cloudflare. Use the script or `curl`.
   - No error, but nothing changes: check that the address points at your own worker, not an example address.

4. **Check the name.** The bot must post with exactly the same name every time, matching the spelling and capitals in `BOTS`. `Agent1` and `agent1` count as two different rows. A new spelling shows up as a new, separate row.

5. **Check the app.**
   - Is the cube in the menu bar? If not, open **Chief Status** from `~/Applications`.
   - Click the cube, choose **Settings**, and check the feed address is yours.
   - Close the panel and open it again. Opening it always checks the feed straight away.
   - Still stuck? Quit the app (click the cube, then **Quit**) and open it again, which reconnects the live link.

6. **Marked stale?** That is not a fault. A bot that has been `working` for over an hour (`STALE_MINUTES`) gets **stale?**, usually because it forgot to post `done`. Ask it to post `done`, then `idle`.

Quick test that everything works end to end: post a `working` line by hand for any bot name. Its face should turn orange within a second or two. Then post `idle` to clear it.

## Privacy

The app talks to one place only: the feed address you give it. There is no tracking, no analytics, and no account.

What is stored on your Mac, in `~/Library/Application Support/Chief Status/`:

| File | What's in it |
| --- | --- |
| `config.plist` | Your feed address (`feedURL`), whether alerts are on (`alertOnFailure`), and whether **Finished today** is folded (`todayExpanded`). No password: the app only reads the feed, so it never needs one |

What is stored in your feed, on your own Cloudflare account:

| What | What's in it |
| --- | --- |
| The `bots` list | Each bot's name, current status, one-line task, start time, colour and optional chat link |
| Today's finished jobs | Bot name, task line, start and end time, how long it took, and done or failed. Cleared every day at midnight in your `TZ`, and capped at 200 a day |
| The `STATUS_TOKEN` password | Kept as a Cloudflare secret. It is not in any file in this repository |
| The old `STATUS` key-value storage | Only used once, to copy over a feed made with version 1.1 |

None of this is in the repository, and nothing personal is built into the app or the `.dmg`. The feed can be read by anyone with its address, so keep task lines free of private details.

## Build it yourself

You can build the app from the code instead of downloading the `.dmg`. On your Mac, in Terminal:

```bash
git clone https://github.com/pohstep/chief-status.git
cd chief-status
./install.sh
```

That builds the app with Apple's free Command Line Tools, puts **Chief Status** in `~/Applications`, opens it, and sets it to open every time you log in. If macOS asks you to install the Command Line Tools, click **Install**, wait for it to finish, then run `./install.sh` again.

If you already have your feed address, you can give it straight away:

```bash
./install.sh https://chief-status.<your-subdomain>.workers.dev/status
```

To remove it: `./uninstall.sh`. That removes the app and the start-at-login setting, and keeps your saved feed address.

## Development notes

```
menubar/    the Mac app (Swift, AppKit + SwiftUI), built by install.sh with swiftc
worker/     the feed: a Cloudflare Worker with one SQLite Durable Object (StatusRoom) and a live WebSocket at /status/live
worker/scripts/post-status.sh   the one-line reporting script for bots (plain sh + curl)
docs/       BOT-SETUP.md, images, and render-demo.py, which draws the README images
packaging/  a Homebrew formula for a future tap (not published yet)
```

Feed settings live in `worker/wrangler.toml` under `[vars]`. The password is a secret, set with Wrangler:

| Setting | Where | What it does |
| --- | --- | --- |
| `BOTS` | `wrangler.toml` | Optional starter list and order of bots, like `Agent1,Agent2`. Leave it empty to start with none. Bots that post are added anyway. `Agent1\|https://example.com/agent1` adds a starter link |
| `BOT_URLS` | `wrangler.toml` | Optional starter chat links, like `Agent1=https://example.com/agent1` |
| `TZ` | `wrangler.toml` | Your timezone, like `Asia/Shanghai` or `Europe/London`. Decides when "today" resets. Default `UTC` |
| `STALE_MINUTES` | `wrangler.toml` | How long a bot can say "working" before it's marked **stale?**. Default `60` |
| `STATUS_TOKEN` | `npx wrangler secret put STATUS_TOKEN` | The password bots use to post. Never put it in a file |

What the reporting script reads on each bot's computer:

| Variable | What it does |
| --- | --- |
| `CHIEF_STATUS_URL` | Your feed address. Required |
| `CHIEF_STATUS_TOKEN` | The feed password. Required |
| `CHIEF_STATUS_BOT_COLOR` | The bot's colour, like `#3B82F6`. Optional. Left out or empty, the saved colour stays (to clear it, post `"color":""` with `curl`) |
| `CHIEF_STATUS_BOT_URL` | A link to the bot's chat. Optional. Same rules as the colour (`"url":""` clears it) |

The feed's web addresses:

| Address | What it does |
| --- | --- |
| `GET /status` | Everyone's current line, today's finished jobs, and the settings above. Public |
| `POST /status` | Update one bot. Needs `Authorization: Bearer <STATUS_TOKEN>`. JSON body: `bot`, `status`, `task`, and optionally `started_at`, `color`, `url` |
| `GET /status/live` | The live WebSocket the app listens on. If it drops, the app checks the feed every ~15 seconds instead |

Run the feed's tests, or try it on your own computer before deploying (copy `worker/.dev.vars.example` to `worker/.dev.vars` and put a test password in it first):

```bash
cd worker
npm test
npx wrangler dev
```

The README images are drawn by `python3 docs/render-demo.py` (needs Pillow and NumPy; it uses Inter if installed, otherwise DejaVu Sans).

The app is built as an Intel binary for macOS 13 and signed "ad hoc" (no Apple developer account). The release `.dmg` holds that app plus a shortcut to Applications, made with `hdiutil`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Support

Chief Status is free and open source. If it saves you time, a dollar is appreciated, never expected.

| Chain | Address |
| --- | --- |
| Ethereum | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Polygon | `0x13073220a7f565a6690466e4c73Cdf960b89767E` |
| Bitcoin | `bc1qp33c2ltr9l56gr0qhkydwhrs659ex87l8xhu5t` |

Send only on the matching network.

A star, a bug report or a suggestion helps just as much.

## About

Made by badcookie ([@pohstep_x027](https://x.com/pohstep_x027) on X) with his AI bot team. I'm new to vibe coding and building this in public, so suggestions, issues and pull requests are very welcome. I'm here to learn.

## License

[MIT](LICENSE)
