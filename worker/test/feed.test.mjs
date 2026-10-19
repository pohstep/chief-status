import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const exec = promisify(execFile);

const workerDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const port = 8891;
const token = "test-token-chief";
const devVarsPath = path.join(workerDir, ".dev.vars");
const previousDevVars = fs.existsSync(devVarsPath) ? fs.readFileSync(devVarsPath, "utf8") : null;

function assert(condition, message) {
	if (!condition) throw new Error(message);
}

async function request(url, options = {}) {
	const response = await fetch(url, options);
	const text = await response.text();
	let body = text;
	try {
		body = JSON.parse(text);
	} catch {
		// plain text is fine
	}
	return { status: response.status, body, headers: response.headers };
}

function postStatus(body) {
	return request(`http://127.0.0.1:${port}/status`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${token}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify(body),
	});
}

function startWorker(options = {}) {
	const listenPort = options.port ?? port;
	const inspectorPort = options.inspectorPort ?? 8892;
	const persist = fs.mkdtempSync(path.join(os.tmpdir(), "chief-status-"));
	const bin = path.join(workerDir, "node_modules", ".bin", "wrangler");
	const args = [
		"dev",
		"--ip",
		"127.0.0.1",
		"--port",
		String(listenPort),
		"--inspector-port",
		String(inspectorPort),
		"--local",
		"--persist-to",
		persist,
		"--show-interactive-dev-session=false",
		"--log-level",
		"warn",
	];
	if (options.readToken) {
		args.push("--var", `READ_TOKEN:${options.readToken}`);
	}
	// Pin the vars the tests depend on, so a deploy config with a real bot list,
	// time zone or windows still runs the same tests.
	const vars = { BOTS: "", BOT_URLS: "", TZ: "UTC", STALE_MINUTES: "60", IDLE_AFTER_MINUTES: "20", ...(options.vars ?? {}) };
	for (const [key, value] of Object.entries(vars)) {
		args.push("--var", `${key}:${value}`);
	}
	const child = spawn(bin, args, {
		cwd: workerDir,
		env: { ...process.env, CI: "1" },
		stdio: ["ignore", "pipe", "pipe"],
	});

	let log = "";
	let exited = false;
	child.stdout.on("data", (chunk) => {
		log += chunk.toString();
	});
	child.stderr.on("data", (chunk) => {
		log += chunk.toString();
	});
	child.on("exit", (code) => {
		exited = true;
		log += `\nwrangler exited ${code}\n`;
	});

	const ready = (async () => {
		const deadline = Date.now() + 45000;
		while (Date.now() < deadline) {
			if (exited) throw new Error(`wrangler exited before it was ready\n${log}`);
			try {
				const response = await fetch(`http://127.0.0.1:${listenPort}/`);
				if (response.status > 0) return;
			} catch {
				// not listening yet
			}
			await new Promise((resolve) => setTimeout(resolve, 250));
		}
		throw new Error(`wrangler did not start\n${log}`);
	})();

	return {
		ready,
		stop() {
			return new Promise((resolve) => {
				if (exited) {
					resolve();
					return;
				}
				const timer = setTimeout(() => {
					child.kill("SIGKILL");
				}, 3000);
				child.on("exit", () => {
					clearTimeout(timer);
					resolve();
				});
				child.kill("SIGTERM");
			});
		},
		log: () => log,
	};
}

function emptyBody(body) {
	return body === "";
}

async function liveSnapshot(url, headers) {
	return new Promise((resolve, reject) => {
		const ws = headers ? new WebSocket(url, { headers }) : new WebSocket(url);
		const messages = [];
		const timer = setTimeout(() => {
			ws.close();
			reject(new Error(`websocket timed out after ${messages.length} message(s)`));
		}, 8000);
		ws.addEventListener("error", () => {
			clearTimeout(timer);
			reject(new Error("websocket error"));
		});
		ws.addEventListener("message", (event) => {
			messages.push(JSON.parse(String(event.data)));
			if (messages.length >= 1) {
				clearTimeout(timer);
				ws.close();
				resolve(messages);
			}
		});
	});
}

async function liveRejected(url) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(url);
		let settled = false;
		const finish = (ok, error) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			try {
				ws.close();
			} catch {
				// already closed
			}
			if (ok) resolve();
			else reject(error);
		};
		const timer = setTimeout(() => finish(false, new Error("unauthorized websocket stayed open")), 4000);
		ws.addEventListener("message", () => finish(false, new Error("unauthorized websocket received a message")));
		ws.addEventListener("error", () => finish(true));
		ws.addEventListener("close", () => finish(true));
	});
}

/** A second worker with READ_TOKEN set. The first worker leaves the secret unset. */
async function runReadTokenTests() {
	const readToken = "test-read-chief";
	const listenPort = 8893;
	const worker = startWorker({ port: listenPort, inspectorPort: 8894, readToken });
	const base = `http://127.0.0.1:${listenPort}`;
	try {
		await worker.ready;
		await new Promise((resolve) => setTimeout(resolve, 300));

		const root = await request(`${base}/`);
		assert(root.status === 200, `GET / stays open when a read token is set, was ${root.status}`);

		const missing = await request(`${base}/status`);
		assert(missing.status === 401, `GET /status without a read token ${missing.status}`);
		assert(emptyBody(missing.body), `GET /status without a read token should have an empty body, was ${JSON.stringify(missing.body)}`);

		const wrong = await request(`${base}/status`, { headers: { Authorization: "Bearer wrong-token" } });
		assert(wrong.status === 401, `GET /status with the wrong read token ${wrong.status}`);
		assert(emptyBody(wrong.body), "wrong read token should have an empty body");

		const postPassword = await request(`${base}/status`, { headers: { Authorization: `Bearer ${token}` } });
		assert(postPassword.status === 401, `the post password must not count as the read token, was ${postPassword.status}`);
		assert(emptyBody(postPassword.body), "refusing the post password should have an empty body");

		const liveMissing = await request(`${base}/status/live`);
		assert(liveMissing.status === 401, `GET /status/live without a read token ${liveMissing.status}`);
		assert(emptyBody(liveMissing.body), "live feed without a read token should have an empty body");
		await liveRejected(`${base.replace("http", "ws")}/status/live`);

		const opened = await request(`${base}/status`, { headers: { Authorization: `Bearer ${readToken}` } });
		assert(opened.status === 200, `GET /status with the read token ${opened.status} ${JSON.stringify(opened.body)}`);
		assert(Array.isArray(opened.body.bots) && opened.body.bots.length === 0, "a protected feed still starts empty");

		const posted = await request(`${base}/status`, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${token}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({ bot: "Reader", status: "working", task: "behind the token" }),
		});
		assert(posted.status === 200, `POST still uses the post password, was ${posted.status} ${JSON.stringify(posted.body)}`);

		const afterPost = await request(`${base}/status`, { headers: { Authorization: `Bearer ${readToken}` } });
		assert(
			afterPost.body.bots.some((bot) => bot.bot === "Reader" && bot.status === "working"),
			"the read token should see the post",
		);

		const live = await liveSnapshot(`${base.replace("http", "ws")}/status/live`, {
			Authorization: `Bearer ${readToken}`,
		});
		assert(live[0].type === "snapshot", "an authorized live feed should send a snapshot");
		assert(
			live[0].bots.some((bot) => bot.bot === "Reader"),
			"the authorized snapshot should include the posted bot",
		);

		const byQuery = await liveSnapshot(`${base.replace("http", "ws")}/status/live?token=${readToken}`);
		assert(byQuery[0].type === "snapshot", "the live feed should also accept ?token=<read token>");
		await liveRejected(`${base.replace("http", "ws")}/status/live?token=wrong-token`);
		const queryOnGet = await request(`${base}/status?token=${readToken}`);
		assert(queryOnGet.status === 401, `?token= is only for the live feed, GET /status was ${queryOnGet.status}`);

		const upgrade = await request(`${base}/status/live`, { headers: { Authorization: `Bearer ${readToken}` } });
		assert(upgrade.status === 426, `authorized live feed without an upgrade should stay 426, was ${upgrade.status}`);
	} finally {
		await worker.stop();
	}
}

async function main() {
	fs.writeFileSync(devVarsPath, `STATUS_TOKEN=${token}\n`);
	const worker = startWorker();
	const base = `http://127.0.0.1:${port}`;
	try {
		await worker.ready;
		await new Promise((resolve) => setTimeout(resolve, 300));

		const root = await request(`${base}/`);
		assert(root.status === 200, `GET / status ${root.status}`);
		assert(String(root.body).includes("/status"), "GET / should point at /status");

		const missing = await request(`${base}/nope`);
		assert(missing.status === 404, `unknown path status ${missing.status}`);

		const first = await request(`${base}/status`);
		assert(first.status === 200, `GET /status ${first.status} ${JSON.stringify(first.body)}`);
		assert(Array.isArray(first.body.bots), "bots should be an array");
		assert(
			first.body.bots.length === 0,
			`a new feed should start empty, saw ${first.body.bots.map((bot) => bot.bot).join(",")}`,
		);
		assert(first.headers.get("cache-control") === "no-store", "GET should not be cached");

		const again = await request(`${base}/status/`);
		assert(again.status === 200, "trailing slash should work");
		assert(again.body.bots.length === 0, "second read should stay empty");

		const noAuth = await request(`${base}/status`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				bot: "Agent1",
				status: "working",
				task: "drafting",
				started_at: "2026-10-18T10:00:00Z",
			}),
		});
		assert(noAuth.status === 401, `missing token status ${noAuth.status}`);

		const badAuth = await request(`${base}/status`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: "Bearer wrong-token",
			},
			body: JSON.stringify({
				bot: "Agent1",
				status: "working",
				task: "drafting",
				started_at: "2026-10-18T10:00:00Z",
			}),
		});
		assert(badAuth.status === 401, `wrong token status ${badAuth.status}`);

		const posted = await request(`${base}/status`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${token}`,
			},
			body: JSON.stringify({
				bot: "Agent1",
				status: "working",
				task: "drafting the homepage",
				started_at: "2026-10-18T10:00:00Z",
			}),
		});
		assert(posted.status === 200, `POST ${posted.status} ${JSON.stringify(posted.body)}`);
		assert(posted.body.bot.status === "working", "POST should echo the new status");
		assert(posted.body.bot.started_at === "2026-10-18T10:00:00.000Z", "started_at should be normalized");

		const after = await request(`${base}/status`);
		const agent1 = after.body.bots.find((bot) => bot.bot === "Agent1");
		const agent2 = after.body.bots.find((bot) => bot.bot === "Agent2");
		assert(agent1, "Agent1 should exist after its first post");
		assert(agent1.status === "working", "Agent1 should be working");
		assert(agent1.task === "drafting the homepage", "task should be stored");
		assert(!agent2, "a bot that has not posted should not be seeded");

		const replaced = await request(`${base}/status`, {
			method: "POST",
			headers: {
				Authorization: `bearer ${token}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				bot: " Agent1 ",
				status: "done",
				task: "homepage is up",
				started_at: "2026-10-18T11:00:00Z",
			}),
		});
		assert(replaced.status === 200, `replace ${replaced.status} ${JSON.stringify(replaced.body)}`);
		const afterReplace = await request(`${base}/status`);
		const agents = afterReplace.body.bots.filter((bot) => bot.bot === "Agent1");
		assert(agents.length === 1, "upsert should keep one Agent1");
		assert(agents[0].status === "done", "Agent1 should now be done");
		assert(
			agents[0].started_at === "2026-10-18T10:00:00.000Z",
			`done should keep the working start, was ${agents[0].started_at}`,
		);

		const added = await request(`${base}/status`, {
			method: "POST",
			headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				bot: "Sprocket",
				status: "failed",
				task: "build broke",
				started_at: "2026-10-18T12:00:00Z",
			}),
		});
		assert(added.status === 200, `add bot ${added.status}`);
		const withExtra = await request(`${base}/status`);
		assert(
			withExtra.body.bots.map((bot) => bot.bot).join(",") === "Agent1,Sprocket",
			`order ${withExtra.body.bots.map((bot) => bot.bot).join(",")}`,
		);

		const badStatus = await request(`${base}/status`, {
			method: "POST",
			headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				bot: "Agent1",
				status: "busy",
				task: "nope",
				started_at: "2026-10-18T10:00:00Z",
			}),
		});
		assert(badStatus.status === 400, `bad status ${badStatus.status}`);

		const badDate = await request(`${base}/status`, {
			method: "POST",
			headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
			body: JSON.stringify({
				bot: "Agent1",
				status: "idle",
				task: "",
				started_at: "yesterday",
			}),
		});
		assert(badDate.status === 400, `bad date ${badDate.status}`);

		const put = await request(`${base}/status`, { method: "PUT" });
		assert(put.status === 405, `PUT ${put.status}`);

		const huge = await request(`${base}/status`, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${token}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({ task: "x".repeat(9000) }),
		});
		assert(huge.status === 413, `large body ${huge.status} ${JSON.stringify(huge.body)}`);

		const script = path.join(workerDir, "scripts", "post-status.sh");
		const postedByScript = await exec(script, ["Agent2", "WORKING", 'say "hi"'], {
			env: {
				...process.env,
				CHIEF_STATUS_URL: base,
				CHIEF_STATUS_TOKEN: token,
			},
		});
		assert(postedByScript.stdout.includes('"ok":true'), `script output ${postedByScript.stdout}`);
		const afterScript = await request(`${base}/status`);
		const scripted = afterScript.body.bots.find((bot) => bot.bot === "Agent2");
		assert(scripted.status === "working", "script should mark Agent2 working");
		assert(scripted.task === 'say "hi"', `script task was ${scripted.task}`);
		assert(scripted.url === "", "script without a link should leave url empty");
		assert(scripted.color === "", "script without a colour should leave color empty");

		assert(afterScript.body.stale_after_minutes === 60, `stale ${afterScript.body.stale_after_minutes}`);
		assert(afterScript.body.timezone === "UTC", `timezone ${afterScript.body.timezone}`);
		assert(Array.isArray(afterScript.body.today), "today should be an array");
		const finished = afterScript.body.today.map((job) => `${job.bot}:${job.result}`);
		assert(finished.includes("Agent1:done"), `today missing Agent1 done: ${finished.join(",")}`);
		assert(finished.includes("Sprocket:failed"), `today missing Sprocket failed: ${finished.join(",")}`);
		assert(
			!afterScript.body.today.some((job) => job.bot === "Agent2"),
			"a working post should not land in today's log",
		);
		for (const job of afterScript.body.today) {
			assert(typeof job.task === "string", "job task");
			assert(typeof job.started_at === "string" && job.started_at.length > 0, "job start");
			assert(typeof job.ended_at === "string" && job.ended_at.length > 0, "job end");
			assert(typeof job.duration_ms === "number" && job.duration_ms >= 0, "job duration");
		}

		const agent1Job = afterScript.body.today.find((job) => job.bot === "Agent1" && job.result === "done");
		assert(agent1Job, "Agent1 should have a finished job");
		assert(
			agent1Job.started_at === "2026-10-18T10:00:00.000Z",
			`job start was ${agent1Job.started_at}`,
		);
		assert(agent1Job.duration_ms > 60_000, `job duration was ${agent1Job.duration_ms}, expected the working clock`);

		const beforeDedupe = afterScript.body.today.length;
		const duplicate = await postStatus({
			bot: "Agent1",
			status: "done",
			task: "homepage is up",
		});
		assert(duplicate.status === 200, `dedupe post ${duplicate.status}`);
		assert(
			duplicate.body.bot.started_at === "2026-10-18T10:00:00.000Z",
			"a repeated done without a clock should keep the stored start",
		);
		const afterDedupe = await request(`${base}/status`);
		assert(
			afterDedupe.body.today.length === beforeDedupe,
			`same finish should not be logged twice (${beforeDedupe} -> ${afterDedupe.body.today.length})`,
		);

		const linked = await postStatus({
			bot: "Agent1",
			status: "idle",
			task: "",
			started_at: "2026-10-18T11:05:00Z",
			url: "https://example.com/agent1",
		});
		assert(linked.status === 200, `url post ${linked.status} ${JSON.stringify(linked.body)}`);
		assert(linked.body.bot.url === "https://example.com/agent1", "POST should echo the link");
		const withLink = await request(`${base}/status`);
		assert(
			withLink.body.bots.find((bot) => bot.bot === "Agent1").url === "https://example.com/agent1",
			"GET should return the link",
		);

		const kept = await postStatus({
			bot: "Agent1",
			status: "idle",
			task: "still linked",
			started_at: "2026-10-18T11:06:00Z",
		});
		assert(kept.status === 200, `omit url ${kept.status}`);
		assert(kept.body.bot.url === "https://example.com/agent1", "omitting url should keep the stored link");

		const cleared = await postStatus({
			bot: "Agent1",
			status: "idle",
			task: "",
			started_at: "2026-10-18T11:07:00Z",
			url: "",
		});
		assert(cleared.status === 200, `clear url ${cleared.status}`);
		assert(cleared.body.bot.url === "", "empty url should clear the link");

		const badUrl = await postStatus({
			bot: "Agent1",
			status: "idle",
			task: "",
			started_at: "2026-10-18T11:08:00Z",
			url: "javascript:alert(1)",
		});
		assert(badUrl.status === 400, `bad url ${badUrl.status}`);

		const deep = await postStatus({
			bot: "Agent2",
			status: "working",
			task: "still going",
			started_at: "2026-10-18T10:00:00Z",
			url: "cursor://chat/Agent2",
		});
		assert(deep.status === 200, `deep link ${deep.status} ${JSON.stringify(deep.body)}`);
		assert(deep.body.bot.url === "cursor://chat/Agent2", "a deep link should be stored");

		const postedByScriptWithUrl = await exec(script, ["Agent2", "WORKING", "linked job"], {
			env: {
				...process.env,
				CHIEF_STATUS_URL: base,
				CHIEF_STATUS_TOKEN: token,
				CHIEF_STATUS_BOT_URL: "https://example.com/agent2",
			},
		});
		assert(
			postedByScriptWithUrl.stdout.includes('"ok":true'),
			`script url output ${postedByScriptWithUrl.stdout}`,
		);
		const scriptedLink = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "Agent2");
		assert(scriptedLink.url === "https://example.com/agent2", `script url was ${scriptedLink.url}`);

		const registeredAt = Date.now();
		const registered = await postStatus({
			bot: "Widget",
			status: "working",
			task: "first job",
			color: "#3B82F6",
		});
		assert(registered.status === 200, `register ${registered.status} ${JSON.stringify(registered.body)}`);
		assert(registered.body.bot.color === "#3b82f6", `stored colour ${registered.body.bot.color}`);
		const registeredStart = Date.parse(registered.body.bot.started_at);
		assert(
			Math.abs(registeredStart - registeredAt) < 15000,
			`working without started_at should default to now, was ${registered.body.bot.started_at}`,
		);
		const names = (await request(`${base}/status`)).body.bots.map((bot) => bot.bot);
		assert(names.includes("Widget"), `Widget should register itself, saw ${names.join(",")}`);
		assert(names.indexOf("Agent1") < names.indexOf("Widget"), "bots stay in the order they first posted");

		const keptColor = await postStatus({
			bot: "Widget",
			status: "working",
			task: "still first job",
		});
		assert(keptColor.body.bot.color === "#3b82f6", "omitting color should keep the stored colour");

		const finishedWidget = await postStatus({
			bot: "Widget",
			status: "done",
			task: "first job",
			started_at: new Date().toISOString(),
		});
		assert(finishedWidget.status === 200, `widget done ${finishedWidget.status}`);
		assert(
			finishedWidget.body.bot.started_at === registered.body.bot.started_at,
			"done should ignore a fresh started_at when the bot was working",
		);
		const widgetJob = (await request(`${base}/status`)).body.today.find(
			(job) => job.bot === "Widget" && job.task === "first job",
		);
		assert(widgetJob, "Widget should be in today's log");
		assert(widgetJob.started_at === registered.body.bot.started_at, "the job uses the working start");
		assert(widgetJob.duration_ms < 20000, `a just-finished job was ${widgetJob.duration_ms}ms`);

		const clearedColor = await postStatus({
			bot: "Widget",
			status: "idle",
			task: "",
			color: "",
		});
		assert(clearedColor.status === 200, `clear color ${clearedColor.status}`);
		assert(clearedColor.body.bot.color === "", "empty color should clear the stored colour");

		const badColor = await postStatus({
			bot: "Widget",
			status: "idle",
			task: "",
			color: "blue",
		});
		assert(badColor.status === 400, `bad color ${badColor.status}`);

		const postedByScriptWithColor = await exec(script, ["Widget", "IDLE", ""], {
			env: {
				...process.env,
				CHIEF_STATUS_URL: base,
				CHIEF_STATUS_TOKEN: token,
				CHIEF_STATUS_BOT_COLOR: "#EC4899",
			},
		});
		assert(
			postedByScriptWithColor.stdout.includes('"ok":true'),
			`script color output ${postedByScriptWithColor.stdout}`,
		);
		const colored = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "Widget");
		assert(colored.color === "#ec4899", `script colour was ${colored.color}`);

		const notLive = await request(`${base}/status/live`);
		assert(notLive.status === 426, `live without upgrade ${notLive.status} ${JSON.stringify(notLive.body)}`);

		const liveMessages = await new Promise((resolve, reject) => {
			const ws = new WebSocket(`${base.replace("http", "ws")}/status/live`);
			const messages = [];
			const timer = setTimeout(() => {
				ws.close();
				reject(new Error(`websocket timed out after ${messages.length} message(s)`));
			}, 8000);
			ws.addEventListener("error", () => {
				clearTimeout(timer);
				reject(new Error("websocket error"));
			});
			ws.addEventListener("message", (event) => {
				messages.push(JSON.parse(String(event.data)));
				if (messages.length === 1) {
					postStatus({
						bot: "Agent2",
						status: "idle",
						task: "",
						started_at: "2026-10-18T11:09:00Z",
					}).then((res) => {
						if (res.status !== 200) {
							clearTimeout(timer);
							ws.close();
							reject(new Error(`post during live ${res.status} ${JSON.stringify(res.body)}`));
						}
					});
				}
				if (messages.length >= 2) {
					clearTimeout(timer);
					ws.close();
					resolve(messages);
				}
			});
		});
		assert(liveMessages[0].type === "snapshot", "first live message should be a snapshot");
		assert(Array.isArray(liveMessages[0].bots), "live snapshot should include bots");
		assert(liveMessages[0].stale_after_minutes === 60, "live snapshot should include the stale window");
		const liveAgent2 = liveMessages[1].bots.find((bot) => bot.bot === "Agent2");
		assert(liveAgent2.status === "idle", `live update status ${liveAgent2 && liveAgent2.status}`);
		assert(
			liveAgent2.url === "https://example.com/agent2",
			"live update should keep the link when url is omitted",
		);

		// needs_input: accepted, gets a fresh clock when the status changes, keeps it on a repeat, records no job.
		const jobsBeforeNeeds = (await request(`${base}/status`)).body.today.length;
		await postStatus({ bot: "AskBot", status: "working", task: "drafting", started_at: "2026-10-18T09:00:00Z" });
		const asked = await postStatus({ bot: "AskBot", status: "needs_input", task: "which logo?" });
		assert(asked.status === 200, `needs_input post ${asked.status} ${JSON.stringify(asked.body)}`);
		assert(asked.body.bot.status === "needs_input", "needs_input should be stored");
		assert(asked.body.bot.approval === false, "needs_input without approval stays false");
		assert(asked.body.bot.started_at !== "2026-10-18T09:00:00.000Z", "needs_input should start a new clock");
		assert(Date.now() - Date.parse(asked.body.bot.started_at) < 60000, "needs_input clock should be now");
		const askedAgain = await postStatus({ bot: "AskBot", status: "needs_input", task: "still waiting" });
		assert(askedAgain.body.bot.started_at === asked.body.bot.started_at, "a repeat needs_input keeps its clock");
		assert(askedAgain.body.bot.approval === false, "omitting approval on a repeat clears it");
		const afterNeeds = await request(`${base}/status`);
		assert(afterNeeds.body.today.length === jobsBeforeNeeds, "needs_input must not record a job");
		assert(
			afterNeeds.body.bots.some((bot) => bot.bot === "AskBot" && bot.status === "needs_input" && bot.approval === false),
			"GET should list needs_input with approval false",
		);

		const approved = await postStatus({
			bot: "AskBot",
			status: "needs_input",
			task: "approve the homepage copy",
			approval: true,
		});
		assert(approved.status === 200, `approval post ${approved.status} ${JSON.stringify(approved.body)}`);
		assert(approved.body.bot.approval === true, "approval true should be stored with needs_input");
		assert(approved.body.bot.status === "needs_input", "approval does not change the status");
		const approvedGet = await request(`${base}/status`);
		const approvedRow = approvedGet.body.bots.find((bot) => bot.bot === "AskBot");
		assert(approvedRow && approvedRow.approval === true, "GET /status should return approval");
		assert(approvedRow.task === "approve the homepage copy", "GET should return the approval task");
		const approvedLive = await liveSnapshot(`${base.replace("http", "ws")}/status/live`);
		const liveApproved = approvedLive[0].bots.find((bot) => bot.bot === "AskBot");
		assert(liveApproved && liveApproved.approval === true, "the live feed should return approval");

		const explicitNo = await postStatus({
			bot: "AskBot",
			status: "needs_input",
			task: "which font?",
			approval: false,
		});
		assert(explicitNo.body.bot.approval === false, "approval false should be stored");
		const omittedAgain = await postStatus({ bot: "AskBot", status: "needs_input", task: "which font?" });
		assert(omittedAgain.body.bot.approval === false, "leaving approval out means false");
		const nullApproval = await postStatus({
			bot: "AskBot",
			status: "needs_input",
			task: "which font?",
			approval: null,
		});
		assert(nullApproval.status === 200, `null approval ${nullApproval.status}`);
		assert(nullApproval.body.bot.approval === false, "null approval means false");

		const badApproval = await postStatus({
			bot: "AskBot",
			status: "needs_input",
			task: "which font?",
			approval: "yes",
		});
		assert(badApproval.status === 400, `non-boolean approval should be 400, was ${badApproval.status}`);
		assert(String(badApproval.body.error).includes("approval"), "the error should mention approval");

		const ignoredApproval = await postStatus({
			bot: "AskBot",
			status: "working",
			task: "continuing",
			approval: true,
		});
		assert(ignoredApproval.status === 200, `approval on working ${ignoredApproval.status}`);
		assert(ignoredApproval.body.bot.approval === false, "approval is only stored for needs_input");
		assert(ignoredApproval.body.bot.status === "working", "the working post should still apply");

		const approvedAgain = await postStatus({
			bot: "AskBot",
			status: "needs_input",
			task: "approve the footer",
			approval: true,
		});
		assert(approvedAgain.body.bot.approval === true, "a later needs_input can set approval again");
		const clearedApproval = await postStatus({ bot: "AskBot", status: "idle", task: "" });
		assert(clearedApproval.body.bot.approval === false, "leaving needs_input clears approval");

		const unknownStatus = await postStatus({ bot: "AskBot", status: "waiting", task: "" });
		assert(unknownStatus.status === 400, `unknown status should be 400, was ${unknownStatus.status}`);
		assert(String(unknownStatus.body.error).includes("needs_input"), "the error should list needs_input");

		const scriptEnv = {
			...process.env,
			CHIEF_STATUS_URL: base,
			CHIEF_STATUS_TOKEN: token,
		};
		const postedApproval = await exec(script, ["AskBot", "needs_input", "approve the homepage copy", "--approval"], {
			env: scriptEnv,
		});
		assert(postedApproval.stdout.includes('"approval":true'), `script --approval output ${postedApproval.stdout}`);
		const scriptedApproval = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "AskBot");
		assert(scriptedApproval.status === "needs_input", "script --approval should post needs_input");
		assert(scriptedApproval.approval === true, "script --approval should set approval");
		assert(scriptedApproval.task === "approve the homepage copy", `script approval task was ${scriptedApproval.task}`);

		const postedApprovalEnv = await exec(script, ["AskBot", "needs_input", "ship the footer?"], {
			env: { ...scriptEnv, CHIEF_STATUS_APPROVAL: "1" },
		});
		assert(postedApprovalEnv.stdout.includes('"approval":true'), `script env approval output ${postedApprovalEnv.stdout}`);
		const envApproval = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "AskBot");
		assert(envApproval.approval === true && envApproval.task === "ship the footer?", "CHIEF_STATUS_APPROVAL=1 should set approval");

		const postedPlainNeeds = await exec(script, ["AskBot", "needs_input", "which font?"], { env: scriptEnv });
		assert(postedPlainNeeds.stdout.includes('"ok":true'), `plain needs_input script ${postedPlainNeeds.stdout}`);
		const plainNeeds = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "AskBot");
		assert(plainNeeds.approval === false, "needs_input without --approval should be approval false");
		assert(plainNeeds.task === "which font?", `plain needs_input task was ${plainNeeds.task}`);

		let approvalOnWorking = false;
		try {
			await exec(script, ["AskBot", "working", "nope", "--approval"], { env: scriptEnv });
		} catch (error) {
			approvalOnWorking = true;
			const stderr = `${error.stderr || ""}\n${error.message || ""}`;
			assert(stderr.includes("needs_input"), `script --approval on working said ${stderr}`);
		}
		assert(approvalOnWorking, "--approval with a status other than needs_input should fail");

		await postStatus({ bot: "AskBot", status: "idle", task: "" });

		// DELETE /status/<bot>: password required, removes the bot and its jobs, unknown is 404.
		await postStatus({ bot: "GoneBot", status: "working", task: "temp", started_at: "2026-10-18T08:00:00Z" });
		await postStatus({ bot: "GoneBot", status: "done", task: "temp" });
		const delUrl = `${base}/status/GoneBot`;
		const delNoAuth = await request(delUrl, { method: "DELETE" });
		assert(delNoAuth.status === 401, `delete without password ${delNoAuth.status}`);
		const delBadAuth = await request(delUrl, { method: "DELETE", headers: { Authorization: "Bearer wrong-token" } });
		assert(delBadAuth.status === 401, `delete with wrong password ${delBadAuth.status}`);
		const stillThere = await request(`${base}/status`);
		assert(stillThere.body.bots.some((bot) => bot.bot === "GoneBot"), "a refused delete must keep the bot");
		const deleted = await request(delUrl, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(deleted.status === 200, `delete ${deleted.status} ${JSON.stringify(deleted.body)}`);
		assert(deleted.body.deleted === "GoneBot" && deleted.body.jobs_removed >= 1, "delete should report the jobs it removed");
		const afterDelete = await request(`${base}/status`);
		assert(!afterDelete.body.bots.some((bot) => bot.bot === "GoneBot"), "deleted bot should leave the feed");
		assert(!afterDelete.body.today.some((job) => job.bot === "GoneBot"), "deleted bot's jobs should go too");
		assert(afterDelete.body.bots.some((bot) => bot.bot === "Agent2"), "other bots stay after a delete");
		const deleteAgain = await request(delUrl, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(deleteAgain.status === 404, `deleting a missing bot ${deleteAgain.status}`);
		const deleteBadName = await request(`${base}/status/%00bad`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(deleteBadName.status === 400, `bad bot name ${deleteBadName.status}`);
		const deleteRoot = await request(`${base}/status`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(deleteRoot.status === 405, `DELETE /status should be 405, was ${deleteRoot.status}`);
		const liveStill = await request(`${base}/status/live`);
		assert(liveStill.status === 426, `GET /status/live without upgrade should stay 426, was ${liveStill.status}`);

		await runReadTokenTests();
		await runRulesTests();

		for (let i = 0; i < 201; i += 1) {
			const stamp = new Date(Date.UTC(2026, 9, 18, 0, 0, i)).toISOString();
			const cappedPost = await postStatus({
				bot: "CapBot",
				status: i % 2 === 0 ? "done" : "failed",
				task: `job ${i}`,
				started_at: stamp,
			});
			assert(cappedPost.status === 200, `cap post ${i} ${cappedPost.status}`);
		}
		const capped = await request(`${base}/status`);
		assert(capped.body.today.length === 200, `today should cap at 200, was ${capped.body.today.length}`);
		assert(
			capped.body.today.some((job) => job.task === "job 200"),
			"the newest finished job should stay",
		);
		assert(
			!capped.body.today.some((job) => job.bot === "Agent1"),
			"jobs older than the cap should be dropped",
		);

		const oldStart = "2020-01-01T00:00:00Z";
		const postedAt = Date.now();
		const longJob = await postStatus({
			bot: "QuietBot",
			status: "working",
			task: "long job",
			started_at: oldStart,
		});
		assert(longJob.status === 200, `long job ${longJob.status} ${JSON.stringify(longJob.body)}`);
		assert(longJob.body.bot.started_at === "2020-01-01T00:00:00.000Z", "an old job start is kept");
		const lastPosted = Date.parse(longJob.body.bot.last_posted_at);
		assert(
			Math.abs(lastPosted - postedAt) < 15000,
			`last_posted_at should be this post, was ${longJob.body.bot.last_posted_at}`,
		);
		const stillGoing = await postStatus({
			bot: "QuietBot",
			status: "working",
			task: "still the long job",
		});
		assert(stillGoing.status === 200, `repeat working ${stillGoing.status}`);
		assert(
			stillGoing.body.bot.started_at === "2020-01-01T00:00:00.000Z",
			"a repeat working post keeps the job start",
		);
		assert(
			Date.parse(stillGoing.body.bot.last_posted_at) >= lastPosted,
			"a repeat working post refreshes last_posted_at",
		);
		await postStatus({ bot: "QuietBot", status: "idle", task: "" });
		const resumedAt = Date.now();
		const resumed = await postStatus({ bot: "QuietBot", status: "working", task: "new job" });
		assert(resumed.status === 200, `resume working ${resumed.status}`);
		assert(
			Math.abs(Date.parse(resumed.body.bot.started_at) - resumedAt) < 15000,
			`working with no started_at, after a non-working row, starts now, was ${resumed.body.bot.started_at}`,
		);
		assert(
			Math.abs(Date.parse(resumed.body.bot.last_posted_at) - resumedAt) < 15000,
			`last_posted_at on that post was ${resumed.body.bot.last_posted_at}`,
		);
		const listedQuiet = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "QuietBot");
		assert(listedQuiet.last_posted_at === resumed.body.bot.last_posted_at, "GET should return last_posted_at");

		const noZone = await postStatus({
			bot: "QuietBot",
			status: "idle",
			task: "",
			started_at: "2026-01-01T10:00:00",
		});
		assert(noZone.status === 400, `started_at without a time zone should be 400, was ${noZone.status}`);
		const zoned = await postStatus({
			bot: "QuietBot",
			status: "idle",
			task: "",
			started_at: "2026-01-01T10:00:00+08:00",
		});
		assert(zoned.status === 200, `offset started_at ${zoned.status} ${JSON.stringify(zoned.body)}`);
		assert(
			zoned.body.bot.started_at === "2026-01-01T02:00:00.000Z",
			`offset should be normalized, was ${zoned.body.bot.started_at}`,
		);
		const soon = new Date(Date.now() + 60 * 1000).toISOString();
		const almostNow = await postStatus({
			bot: "QuietBot",
			status: "idle",
			task: "",
			started_at: soon,
		});
		assert(almostNow.status === 200, `started_at one minute ahead should be accepted, was ${almostNow.status}`);
		const ahead = new Date(Date.now() + 3 * 60 * 1000).toISOString();
		const tooFar = await postStatus({
			bot: "QuietBot",
			status: "idle",
			task: "",
			started_at: ahead,
		});
		assert(tooFar.status === 400, `started_at more than 2 minutes ahead should be 400, was ${tooFar.status}`);

		const beatStart = await postStatus({
			bot: "BeatBot",
			status: "working",
			task: "draft",
			started_at: "2020-01-01T00:00:00Z",
			color: "#3B82F6",
		});
		assert(beatStart.status === 200, `beat start ${beatStart.status} ${JSON.stringify(beatStart.body)}`);
		const beatPosted = Date.parse(beatStart.body.bot.last_posted_at);
		const beatKept = await postStatus({
			bot: "BeatBot",
			status: "working",
			task: "still draft",
			heartbeat: true,
			started_at: "2030-01-01T00:00:00Z",
		});
		assert(beatKept.status === 200, `heartbeat ${beatKept.status} ${JSON.stringify(beatKept.body)}`);
		assert(
			beatKept.body.bot.started_at === "2020-01-01T00:00:00.000Z",
			`heartbeat must keep started_at, was ${beatKept.body.bot.started_at}`,
		);
		assert(
			Date.parse(beatKept.body.bot.last_posted_at) >= beatPosted,
			"heartbeat must refresh last_posted_at",
		);
		assert(beatKept.body.bot.task === "still draft", "heartbeat updates the task");
		assert(beatKept.body.bot.color === "#3b82f6", "heartbeat keeps the stored colour");
		const heartNewAt = Date.now();
		const heartNew = await postStatus({
			bot: "HeartNew",
			status: "working",
			task: "first beat",
			heartbeat: true,
			started_at: "2020-01-01T00:00:00Z",
		});
		assert(heartNew.status === 200, `first heartbeat ${heartNew.status} ${JSON.stringify(heartNew.body)}`);
		assert(
			heartNew.body.bot.started_at !== "2020-01-01T00:00:00.000Z",
			"a first heartbeat ignores the client started_at",
		);
		assert(
			Math.abs(Date.parse(heartNew.body.bot.started_at) - heartNewAt) < 15000,
			`a first heartbeat starts now, was ${heartNew.body.bot.started_at}`,
		);
		const beatIdle = await postStatus({ bot: "BeatBot", status: "idle", task: "", heartbeat: true });
		assert(beatIdle.status === 400, `heartbeat on idle should be 400, was ${beatIdle.status}`);
		assert(
			String(beatIdle.body.error || "").toLowerCase().includes("heartbeat"),
			`heartbeat error was ${JSON.stringify(beatIdle.body)}`,
		);
		const beatWord = await postStatus({ bot: "BeatBot", status: "working", task: "x", heartbeat: "yes" });
		assert(beatWord.status === 400, `non-boolean heartbeat should be 400, was ${beatWord.status}`);
		const beatStill = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "BeatBot");
		assert(beatStill.status === "working", "a rejected heartbeat must not change the row");
		assert(beatStill.started_at === "2020-01-01T00:00:00.000Z", "a rejected heartbeat must not move started_at");

		// Open feed (BOTS empty): names still match without case, so "quietbot" is QuietBot.
		const rowsBeforeCase = (await request(`${base}/status`)).body.bots.length;
		const lower = await postStatus({ bot: "quietbot", status: "idle", task: "lowercase post" });
		assert(lower.status === 200, `lowercase post ${lower.status} ${JSON.stringify(lower.body)}`);
		assert(lower.body.bot.bot === "QuietBot", `lowercase post should keep the stored name, was ${lower.body.bot.bot}`);
		const afterLower = (await request(`${base}/status`)).body;
		assert(afterLower.bots.length === rowsBeforeCase, "a lowercase post must not add a row");
		assert(!afterLower.bots.some((bot) => bot.bot === "quietbot"), "no lowercase row should appear");
		assert(
			afterLower.bots.find((bot) => bot.bot === "QuietBot").task === "lowercase post",
			"the lowercase post should update QuietBot",
		);
		assert(afterLower.idle_after_minutes === 20, `idle_after_minutes default ${afterLower.idle_after_minutes}`);
		await postStatus({ bot: "CaseGone", status: "idle", task: "" });
		const delLower = await request(`${base}/status/casegone`, {
			method: "DELETE",
			headers: { Authorization: `Bearer ${token}` },
		});
		assert(delLower.status === 200, `lowercase delete ${delLower.status} ${JSON.stringify(delLower.body)}`);
		assert(delLower.body.deleted === "CaseGone", `lowercase delete removed ${delLower.body.deleted}`);
		assert(
			!(await request(`${base}/status`)).body.bots.some((bot) => bot.bot === "CaseGone"),
			"lowercase delete should remove CaseGone",
		);

		await runHeartbeatScript(base);

		console.log("feed tests passed");
	} finally {
		await worker.stop();
		if (previousDevVars === null) fs.rmSync(devVarsPath, { force: true });
		else fs.writeFileSync(devVarsPath, previousDevVars);
	}
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * A third worker with a closed bot list and a 3-second idle window:
 * case-insensitive names, unknown names refused, same-task heartbeat, post-status.sh heartbeat,
 * auto-idle on read and by alarm over the live feed, needs_input never expiring.
 */
async function runRulesTests() {
	const listenPort = 8895;
	const worker = startWorker({
		port: listenPort,
		inspectorPort: 8896,
		vars: { BOTS: "Alpha,Beta Bot", IDLE_AFTER_MINUTES: "0.05" },
	});
	const base = `http://127.0.0.1:${listenPort}`;
	const post = (body) =>
		request(`${base}/status`, {
			method: "POST",
			headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
			body: JSON.stringify(body),
		});
	const feed = async () => (await request(`${base}/status`)).body;
	const row = async (name) => (await feed()).bots.find((bot) => bot.bot === name);
	const script = path.join(workerDir, "scripts", "post-status.sh");
	const env = { ...process.env, CHIEF_STATUS_URL: base, CHIEF_STATUS_TOKEN: token };
	try {
		await worker.ready;
		await sleep(300);

		const start = await feed();
		assert(start.bots.map((bot) => bot.bot).join(",") === "Alpha,Beta Bot", `seeded ${start.bots.map((b) => b.bot)}`);
		assert(start.idle_after_minutes === 0.05, `idle_after_minutes ${start.idle_after_minutes}`);

		// Names: case-insensitive, canonical name kept, unknown refused with no row.
		const lower = await post({ bot: "alpha", status: "idle", task: "lower" });
		assert(lower.status === 200, `lowercase listed bot ${lower.status} ${JSON.stringify(lower.body)}`);
		assert(lower.body.bot.bot === "Alpha", `stored name ${lower.body.bot.bot}`);
		const upper = await post({ bot: "BETA BOT", status: "idle", task: "upper" });
		assert(upper.status === 200 && upper.body.bot.bot === "Beta Bot", `uppercase listed bot ${JSON.stringify(upper.body)}`);
		const unknown = await post({ bot: "Zzztest", status: "working", task: "should be refused" });
		assert(unknown.status === 403, `unknown bot should be 403, was ${unknown.status}`);
		assert(String(unknown.body.error).includes("unknown bot"), `unknown bot error ${JSON.stringify(unknown.body)}`);
		const afterNames = await feed();
		assert(afterNames.bots.length === 2, `rows after name posts ${afterNames.bots.map((b) => b.bot)}`);
		assert(afterNames.bots.find((b) => b.bot === "Alpha").task === "lower", "lowercase post should update Alpha");
		const delUnknown = await request(`${base}/status/zzztest`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(delUnknown.status === 404, `deleting an unknown bot ${delUnknown.status}`);
		const delLower = await request(`${base}/status/alpha`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } });
		assert(delLower.status === 200 && delLower.body.deleted === "Alpha", `lowercase delete ${JSON.stringify(delLower.body)}`);
		const back = await post({ bot: "ALPHA", status: "idle", task: "" });
		assert(back.status === 200 && back.body.bot.bot === "Alpha", "a listed bot can post again with its listed name");

		// Same status and task: started_at kept even with a fresh started_at, last_posted_at moves.
		const t0 = new Date(Date.now() - 1000).toISOString();
		const w1 = await post({ bot: "Alpha", status: "working", task: "same task", started_at: t0 });
		assert(w1.status === 200, `working ${w1.status}`);
		await sleep(60);
		const w2 = await post({ bot: "Alpha", status: "working", task: "same task", started_at: new Date().toISOString() });
		assert(w2.body.bot.started_at === w1.body.bot.started_at, `same-task re-post moved started_at to ${w2.body.bot.started_at}`);
		assert(Date.parse(w2.body.bot.last_posted_at) > Date.parse(w1.body.bot.last_posted_at), "same-task re-post refreshes last_posted_at");

		// post-status.sh heartbeat: no task keeps the task, keeps the clock, moves last_posted_at.
		await sleep(60);
		const beat = await exec(script, ["alpha", "heartbeat"], { env, timeout: 15000 });
		assertNoToken(beat, "post-status heartbeat");
		assert(beat.stdout.includes('"ok":true'), `heartbeat output ${beat.stdout}`);
		const beaten = await row("Alpha");
		assert(beaten.status === "working" && beaten.task === "same task", `heartbeat row ${JSON.stringify(beaten)}`);
		assert(beaten.started_at === w1.body.bot.started_at, "post-status heartbeat keeps started_at");
		assert(Date.parse(beaten.last_posted_at) > Date.parse(w2.body.bot.last_posted_at), "post-status heartbeat moves last_posted_at");
		const beatText = await exec(script, ["Alpha", "heartbeat", "new", "words"], { env, timeout: 15000 });
		assert(beatText.stdout.includes('"task":"new words"'), `heartbeat with task ${beatText.stdout}`);
		assert((await row("Alpha")).started_at === w1.body.bot.started_at, "heartbeat with a task keeps started_at");
		let refused = false;
		try {
			await exec(script, ["Beta Bot", "heartbeat"], { env, timeout: 15000 });
		} catch (error) {
			refused = true;
			assert(String(error.stdout).includes("not working"), `idle heartbeat said ${error.stdout}`);
		}
		assert(refused, "a heartbeat for a bot that is not working should fail");
		assert((await row("Beta Bot")).status === "idle", "a refused heartbeat leaves the row alone");
		const rawBeat = await post({ bot: "Beta Bot", status: "working", heartbeat: true });
		assert(rawBeat.status === 409, `taskless heartbeat on idle should be 409, was ${rawBeat.status}`);

		// Auto-idle on read: a working row quiet for the window reads as idle, with no job recorded.
		const jobsBefore = (await feed()).today.length;
		const quiet = await post({ bot: "Beta Bot", status: "working", task: "goes quiet" });
		await sleep(3600);
		const expired = await row("Beta Bot");
		assert(expired.status === "idle", `quiet working row should be idle, was ${expired.status}`);
		assert(expired.task === "", `auto-idle clears the task, was ${expired.task}`);
		assert(expired.last_posted_at === quiet.body.bot.last_posted_at, "auto-idle keeps last_posted_at");
		assert(Date.parse(expired.started_at) >= Date.parse(quiet.body.bot.last_posted_at) + 2900, "idle clock starts when the window ran out");
		assert((await feed()).today.length === jobsBefore, "auto-idle records no job");
		assert((await row("Alpha")).status === "idle", "Alpha went quiet too");

		// needs_input never expires.
		await post({ bot: "Alpha", status: "needs_input", task: "which logo?" });
		await sleep(3600);
		const asking = await row("Alpha");
		assert(asking.status === "needs_input" && asking.task === "which logo?", `needs_input expired: ${JSON.stringify(asking)}`);

		// Auto-idle by alarm: a live client hears the change with no read in between.
		const pushed = await new Promise((resolve, reject) => {
			const ws = new WebSocket(`${base.replace("http", "ws")}/status/live`);
			let posted = false;
			const timer = setTimeout(() => {
				ws.close();
				reject(new Error("the live feed never pushed the auto-idle"));
			}, 15000);
			ws.addEventListener("error", () => {
				clearTimeout(timer);
				reject(new Error("websocket error"));
			});
			ws.addEventListener("message", (event) => {
				const message = JSON.parse(String(event.data));
				const beta = message.bots.find((bot) => bot.bot === "Beta Bot");
				if (!posted) {
					posted = true;
					post({ bot: "Beta Bot", status: "working", task: "alarm job" });
					return;
				}
				if (beta && beta.status === "idle" && beta.task === "") {
					clearTimeout(timer);
					ws.close();
					resolve(message);
				}
			});
		});
		const pushedAlpha = pushed.bots.find((bot) => bot.bot === "Alpha");
		assert(pushedAlpha.status === "needs_input", "the alarm must not touch needs_input");
	} finally {
		await worker.stop();
	}
}

function assertNoToken(result, label) {
	const out = `${result.stdout || ""}\n${result.stderr || ""}`;
	assert(!out.includes(token), `${label} printed the token`);
}

async function waitUntilDead(pid) {
	for (let i = 0; i < 25; i += 1) {
		try {
			process.kill(pid, 0);
		} catch (error) {
			if (error.code === "ESRCH") return;
			throw error;
		}
		await new Promise((resolve) => setTimeout(resolve, 40));
	}
	throw new Error("heartbeat process still running");
}

async function runHeartbeatScript(base) {
	const script = path.join(workerDir, "scripts", "heartbeat.sh");
	const postScript = path.join(workerDir, "scripts", "post-status.sh");
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "chief-heartbeats-"));
	const env = {
		...process.env,
		CHIEF_STATUS_URL: base,
		CHIEF_STATUS_TOKEN: token,
		CHIEF_STATUS_HEARTBEAT_DIR: dir,
		CHIEF_STATUS_HEARTBEAT_SECONDS: "3600",
	};
	const pidFile = path.join(dir, "BeatBot.pid");
	try {
		const before = Date.parse(
			(await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "BeatBot").last_posted_at,
		);
		const launched = await exec(script, ["BeatBot", "draft"], { env, timeout: 15000 });
		assertNoToken(launched, "heartbeat start");
		let listed = null;
		const deadline = Date.now() + 10000;
		while (Date.now() < deadline) {
			const snap = await request(`${base}/status`);
			listed = snap.body.bots.find((bot) => bot.bot === "BeatBot");
			if (listed && Date.parse(listed.last_posted_at) > before) break;
			await new Promise((resolve) => setTimeout(resolve, 200));
		}
		assert(listed && Date.parse(listed.last_posted_at) > before, "heartbeat.sh did not refresh last_posted_at");
		assert(
			listed.started_at === "2020-01-01T00:00:00.000Z",
			`heartbeat.sh moved started_at to ${listed.started_at}`,
		);
		assert(listed.task === "draft", `heartbeat.sh task was ${listed.task}`);
		assert(listed.color === "#3b82f6", "heartbeat.sh should keep the stored colour");
		assert(fs.existsSync(pidFile), "heartbeat pid file missing");
		const pid = Number(String(fs.readFileSync(pidFile, "utf8")).trim());
		assert(Number.isInteger(pid) && pid > 0, "heartbeat pid file was not a pid");
		process.kill(pid, 0);

		const stopped = await exec(script, ["stop", "BeatBot"], { env, timeout: 10000 });
		assertNoToken(stopped, "heartbeat stop");
		assert(!fs.existsSync(pidFile), "heartbeat stop should remove the pid file");
		await waitUntilDead(pid);
		const missing = await exec(script, ["stop", "BeatBot"], { env, timeout: 10000 });
		assertNoToken(missing, "heartbeat stop with no pid");

		const again = await exec(script, ["BeatBot", "draft"], { env, timeout: 15000 });
		assertNoToken(again, "heartbeat restart");
		const pidDeadline = Date.now() + 5000;
		while (!fs.existsSync(pidFile) && Date.now() < pidDeadline) {
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
		assert(fs.existsSync(pidFile), "heartbeat pid file missing after restart");
		const pid2 = Number(String(fs.readFileSync(pidFile, "utf8")).trim());
		const idled = await exec(postScript, ["BeatBot", "idle", "paused"], { env, timeout: 15000 });
		assertNoToken(idled, "post-status idle");
		await waitUntilDead(pid2);
		const afterIdle = (await request(`${base}/status`)).body.bots.find((bot) => bot.bot === "BeatBot");
		assert(afterIdle.status === "idle", `post-status should leave BeatBot idle, was ${afterIdle.status}`);
	} finally {
		try {
			await exec(script, ["stop", "BeatBot"], { env, timeout: 5000 });
		} catch {
			// already stopped
		}
	}
}

/** The deploy config keeps a 20-minute auto-idle window. */
function checkConfig() {
	const toml = fs.readFileSync(path.join(workerDir, "wrangler.toml"), "utf8");
	const match = /^IDLE_AFTER_MINUTES\s*=\s*"([^"]*)"/m.exec(toml);
	assert(match && match[1] === "20", `wrangler.toml IDLE_AFTER_MINUTES should be "20", was ${match && match[1]}`);
}

checkConfig();
main().catch((error) => {
	console.error(error);
	process.exit(1);
});
