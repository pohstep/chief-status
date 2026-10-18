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

function startWorker() {
	const persist = fs.mkdtempSync(path.join(os.tmpdir(), "chief-status-"));
	const bin = path.join(workerDir, "node_modules", ".bin", "wrangler");
	const child = spawn(
		bin,
		[
			"dev",
			"--ip",
			"127.0.0.1",
			"--port",
			String(port),
			"--inspector-port",
			"8892",
			"--local",
			"--persist-to",
			persist,
			"--show-interactive-dev-session=false",
			"--log-level",
			"warn",
		],
		{
			cwd: workerDir,
			env: { ...process.env, CI: "1" },
			stdio: ["ignore", "pipe", "pipe"],
		},
	);

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
				const response = await fetch(`http://127.0.0.1:${port}/`);
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
