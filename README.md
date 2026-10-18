# Chief Status

**See which of your AI agents are working, from your Mac menu bar.**

If you run several AI agents, you shouldn't have to open every chat to see who's busy. Chief Status puts a small orange cube with eyes in your menu bar. It sits grey while everything is idle, turns orange and bobs gently while any agent is working, and goes red when one fails.

### Features

- **Status at a glance.** Grey means idle, orange means working, and red means an agent failed.
- **One row per agent.** Click the cube to open a frosted-glass panel showing each agent's status dot, its current task and how long it has been running.
- **One curl line to report.** Any agent or script can post its status to a free Cloudflare Worker feed with a single command.
- **Close to zero cost.** The app itself uses no AI, and each agent posts just one line when it starts and one when it finishes.
- **Native Swift.** Runs on macOS 13 and later, on both Intel and Apple Silicon.
- **Quick setup.** Install with one command, then paste your feed URL on first launch.
- **Open source.** MIT licensed.

```bash
git clone https://github.com/pohstep/chief-status.git && cd chief-status && ./install.sh
```

### Does it cost anything?

No AI usage. The menu bar app only reads a tiny JSON feed you host on Cloudflare Workers' free plan (100,000 requests/day). The app polls every ~15s in the background (about 6,000 requests/day), refreshes instantly when you open the panel, and never calls your AI. Bots post a one-line status only when a job starts and ends.

## Screenshot

A screenshot of the menu bar cube and the frosted panel will go here.

## Deploy the feed

The feed is a Cloudflare Worker. You need a free Cloudflare account and Node.js 20 or newer. If `npm install` is slow, point npm at `https://registry.npmmirror.com` and try again.

From the `worker` folder:

1. Install the tool and sign in. A browser window opens for the login.

```bash
npm install
npx wrangler login
```

2. Create the storage, put its id into `worker/wrangler.toml` in place of `00000000000000000000000000000001`, and set the password. The password is not written in this folder. Type it when asked. It will not show as you type.

```bash
npx wrangler kv namespace create STATUS
npx wrangler secret put STATUS_TOKEN
```

3. Deploy. Wrangler prints an address like `https://chief-status.<your-subdomain>.workers.dev`. Open it in a browser. You should see a short note that Chief Status is running.

```bash
npx wrangler deploy
```

The first time something reads the feed, it creates one idle row per name in `BOTS` in `worker/wrangler.toml`. The default is `Agent1,Agent2`. Change that list before the first read if you want different starter names. Any other name can show up later, when something posts it.

A new line can take up to a minute to appear. Cloudflare copies the saved line out to its other sites, and the menu bar checks on its own schedule.

Anyone with the address can read the names and the short task text. They cannot change a line without the password. Do not put secrets in the task text.

To read the list yourself:

```bash
curl https://chief-status.<your-subdomain>.workers.dev/status
```

To try the feed on this computer before deploying, copy `worker/.dev.vars.example` to `worker/.dev.vars`, put a password in it, and run `npx wrangler dev` from the `worker` folder.

## Install the menu bar app

On the Mac, in this folder:

```bash
./install.sh
```

If you already know the feed address, you can pass it. A worker root or a full `/status` address both work.

```bash
./install.sh https://chief-status.<your-subdomain>.workers.dev/status
```

That builds the app with the Swift compiler that comes with Apple's command line tools, puts **Chief Status** in `~/Applications`, opens it, and opens it again each time you log in. It does not need the full Xcode app. The build target is an Intel binary for macOS 13, which also runs on Apple Silicon.

The first time, the Mac may need those command line tools. If the script asks, run `xcode-select --install`, click Install, wait until it finishes, then run `./install.sh` again.

If you did not pass an address, click the cube. Paste the feed address and click Save. The panel stores it in:

`~/Library/Application Support/Chief Status/config.plist`

Click the cube again any time and choose **Settings** to paste a different address.

The panel checks the feed as soon as it opens, then about every 5 seconds while it stays open. In the background it checks about every 15 seconds, and waits about a minute if the network keeps failing. Grey dot is idle, orange is working, red is failed, green is done. A working row shows how long that task has been running. The app does not send notifications.

While any agent is working, the cube bobs. Every few seconds it plays one short move (a twirl, a hop, a wiggle, a look, or a blink), then goes back to the bob. Idle, it only blinks now and then. If an agent fails, it gives one small shake and then stays red and still.

To take it off the Mac:

```bash
./uninstall.sh
```

That removes the app and the login item. The saved feed address stays.

## Post a status

Each agent has one line. Posting again replaces that line. Nothing older is kept.

`working` can also be `idle`, `failed`, or `done`. For `working`, the time in the panel counts from `started_at`.

From the `worker` folder:

```bash
export CHIEF_STATUS_URL="https://chief-status.<your-subdomain>.workers.dev"
export CHIEF_STATUS_TOKEN="the password from the deploy step"
./scripts/post-status.sh Agent1 working "drafting the homepage"
```

The same call, without the script:

```bash
curl -X POST "https://chief-status.<your-subdomain>.workers.dev/status" \
  -H "Authorization: Bearer YOUR-TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"bot":"Agent1","status":"working","task":"drafting the homepage","started_at":"2026-10-18T10:00:00Z"}'
```

`started_at` is the time the work began, in UTC, like `2026-10-18T10:00:00Z`.

To change the password, run `npx wrangler secret put STATUS_TOKEN` again from the `worker` folder.

## Unsigned app

The build is signed on your Mac, but not with an Apple Developer ID. The first time you open it, macOS may say it cannot be opened. In Finder, go to `~/Applications`, right-click **Chief Status**, choose **Open**, then choose **Open** again. You only need to do that once.

## License

MIT. See [LICENSE](LICENSE).

## About

Made by badcookie (X: @pohstep_x027, https://x.com/pohstep_x027) with his AI bot team. I'm new to vibe coding and building this in public, so suggestions, issues and PRs are very welcome. I'm here to learn.
