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
		assert(Array.isArray(opened.body.bots), "the read token should get the bot list");

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
			first.body.bots.map((bot) => bot.bot).join(",") === "Agent1,Agent2",
			`seed order was ${first.body.bots.map((bot) => bot.bot).join(",")}`,
		);
		assert(
			first.body.bots.every((bot) => bot.status === "idle" && bot.task === ""),
			"seed bots should be idle",
		);
		assert(first.headers.get("cache-control") === "no-store", "GET should not be cached");

		const again = await request(`${base}/status/`);
		assert(again.status === 200, "trailing slash should work");
		assert(again.body.bots[0].bot === "Agent1", "second read should keep the seed");

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
		assert(agent1.status === "working", "Agent1 should be working");
		assert(agent1.task === "drafting the homepage", "task should be stored");
		assert(agent2.status === "idle", "other bots should stay idle");

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
			withExtra.body.bots.map((bot) => bot.bot).join(",") ===
				"Agent1,Agent2,Sprocket",
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
		assert(names.indexOf("Agent1") < names.indexOf("Widget"), "pre-seeded bots stay ahead of a new one");

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
		assert(asked.body.bot.started_at !== "2026-10-18T09:00:00.000Z", "needs_input should start a new clock");
		assert(Date.now() - Date.parse(asked.body.bot.started_at) < 60000, "needs_input clock should be now");
		const askedAgain = await postStatus({ bot: "AskBot", status: "needs_input", task: "still waiting" });
		assert(askedAgain.body.bot.started_at === asked.body.bot.started_at, "a repeat needs_input keeps its clock");
		const afterNeeds = await request(`${base}/status`);
		assert(afterNeeds.body.today.length === jobsBeforeNeeds, "needs_input must not record a job");
		assert(
			afterNeeds.body.bots.some((bot) => bot.bot === "AskBot" && bot.status === "needs_input"),
			"GET should list needs_input",
		);
		const unknownStatus = await postStatus({ bot: "AskBot", status: "waiting", task: "" });
		assert(unknownStatus.status === 400, `unknown status should be 400, was ${unknownStatus.status}`);
		assert(String(unknownStatus.body.error).includes("needs_input"), "the error should list needs_input");
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

		console.log("feed tests passed");
	} finally {
		await worker.stop();
		if (previousDevVars === null) fs.rmSync(devVarsPath, { force: true });
		else fs.writeFileSync(devVarsPath, previousDevVars);
	}
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
