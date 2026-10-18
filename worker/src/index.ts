const INDEX_KEY = "bots:index";
const FALLBACK_BOTS = ["Agent1", "Agent2"];
const STATUSES = ["idle", "working", "failed", "done"] as const;
const BOT_NAME = /^[\p{L}\p{N}][\p{L}\p{N} ._'’-]{0,39}$/u;

type Status = (typeof STATUSES)[number];

type BotRecord = {
	bot: string;
	status: Status;
	task: string;
	started_at: string;
};

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		try {
			return await handle(request, env);
		} catch (error) {
			console.error(
				JSON.stringify({
					event: "status_crash",
					message: error instanceof Error ? error.message : "unknown",
				}),
			);
			return json({ error: "something went wrong" }, 500);
		}
	},
} satisfies ExportedHandler<Env>;

async function handle(request: Request, env: Env): Promise<Response> {
	const path = normalizePath(new URL(request.url).pathname);

	if (request.method === "GET" && path === "/") {
		return new Response(
			"Chief Status is running.\nBots are listed at /status\n",
			{
				headers: {
					"Content-Type": "text/plain; charset=utf-8",
					"Cache-Control": "no-store",
				},
			},
		);
	}

	if (path !== "/status") {
		return json({ error: "not found" }, 404);
	}

	if (request.method === "GET") {
		const bots = await listBots(env.STATUS, configuredBots(env));
		return json({ bots });
	}

	if (request.method === "POST") {
		return postStatus(request, env);
	}

	return json({ error: "method not allowed" }, 405, { Allow: "GET, POST" });
}

async function postStatus(request: Request, env: Env): Promise<Response> {
	if (!env.STATUS_TOKEN) {
		console.error(JSON.stringify({ event: "missing_secret" }));
		return json({ error: "server is missing STATUS_TOKEN" }, 500);
	}

	if (!(await authorized(request, env.STATUS_TOKEN))) {
		return json({ error: "unauthorized" }, 401);
	}

	const body = await readJson(request);
	if (!body.ok) {
		return json({ error: body.error }, body.status);
	}

	const parsed = parsePost(body.value);
	if (!parsed.ok) {
		return json({ error: parsed.error }, 400);
	}

	const record = parsed.record;
	const starters = configuredBots(env);
	await ensureSeed(env.STATUS, starters);
	await env.STATUS.put(botKey(record.bot), JSON.stringify(record));
	await rememberBot(env.STATUS, record.bot, starters);

	console.log(
		JSON.stringify({
			event: "status_upsert",
			bot: record.bot,
			status: record.status,
		}),
	);

	return json({ ok: true, bot: record });
}

function configuredBots(env: Env): string[] {
	const raw = typeof env.BOTS === "string" ? env.BOTS : "";
	const seen = new Set<string>();
	const names: string[] = [];
	for (const part of raw.split(",")) {
		const bot = parseBot(part);
		if (!bot || seen.has(bot)) continue;
		seen.add(bot);
		names.push(bot);
	}
	return names.length > 0 ? names : [...FALLBACK_BOTS];
}

async function listBots(kv: KVNamespace, starters: readonly string[]): Promise<BotRecord[]> {
	const names = await ensureSeed(kv, starters);
	const records = await Promise.all(
		names.map(async (name) => {
			const raw = await kv.get(botKey(name));
			if (raw === null) return seedRecord(name, new Date().toISOString());
			return parseStored(raw, name);
		}),
	);
	return records;
}

async function ensureSeed(kv: KVNamespace, starters: readonly string[]): Promise<string[]> {
	const existing = await readIndex(kv);
	if (existing) return existing;

	const started = new Date().toISOString();
	await Promise.all(
		starters.map(async (bot) => {
			const key = botKey(bot);
			if ((await kv.get(key)) === null) {
				await kv.put(key, JSON.stringify(seedRecord(bot, started)));
			}
		}),
	);
	const names = [...starters];
	await kv.put(INDEX_KEY, JSON.stringify(names));
	console.log(JSON.stringify({ event: "seeded", count: names.length }));
	return names;
}

async function rememberBot(
	kv: KVNamespace,
	bot: string,
	starters: readonly string[],
): Promise<void> {
	const names = (await readIndex(kv)) ?? [...starters];
	if (names.includes(bot)) return;
	names.push(bot);
	await kv.put(INDEX_KEY, JSON.stringify(names));
}

async function readIndex(kv: KVNamespace): Promise<string[] | null> {
	const raw = await kv.get(INDEX_KEY);
	if (raw === null) return null;
	try {
		const parsed: unknown = JSON.parse(raw);
		if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "string")) {
			return null;
		}
		const seen = new Set<string>();
		const names: string[] = [];
		for (const name of parsed) {
			if (seen.has(name)) continue;
			seen.add(name);
			names.push(name);
		}
		return names.length > 0 ? names : null;
	} catch {
		return null;
	}
}

function parsePost(
	value: unknown,
): { ok: true; record: BotRecord } | { ok: false; error: string } {
	if (typeof value !== "object" || value === null || Array.isArray(value)) {
		return { ok: false, error: "body must be a JSON object" };
	}
	const body = value as Record<string, unknown>;

	const bot = parseBot(body.bot);
	if (!bot) {
		return {
			ok: false,
			error:
				"bot must be 1–40 letters or numbers, and can include spaces, dots, hyphens, and apostrophes",
		};
	}

	if (typeof body.status !== "string" || !isStatus(body.status)) {
		return { ok: false, error: "status must be idle, working, failed, or done" };
	}

	if (typeof body.task !== "string") {
		return { ok: false, error: "task is required" };
	}
	const task = cleanTask(body.task);
	if (task === null) {
		return { ok: false, error: "task must be text, 200 characters or fewer" };
	}

	const started = parseStartedAt(body.started_at);
	if (!started) {
		return {
			ok: false,
			error: "started_at must be an ISO date, like 2026-10-18T10:00:00Z",
		};
	}

	return {
		ok: true,
		record: { bot, status: body.status, task, started_at: started },
	};
}

function parseBot(value: unknown): string | null {
	if (typeof value !== "string") return null;
	const bot = value.trim();
	if (!BOT_NAME.test(bot)) return null;
	return bot;
}

function isStatus(value: string): value is Status {
	return (STATUSES as readonly string[]).includes(value);
}

function cleanTask(value: string): string | null {
	const task = value.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();
	if (task.length > 200) return null;
	if (/[\u0000-\u001F\u007F]/.test(task)) return null;
	return task;
}

function parseStartedAt(value: unknown): string | null {
	if (typeof value !== "string" || value.trim() === "") return null;
	const ms = Date.parse(value);
	if (Number.isNaN(ms)) return null;
	return new Date(ms).toISOString();
}

function parseStored(raw: string, fallbackName: string): BotRecord {
	try {
		const value: unknown = JSON.parse(raw);
		if (typeof value !== "object" || value === null) {
			return seedRecord(fallbackName, new Date().toISOString());
		}
		const record = value as Partial<BotRecord>;
		if (typeof record.status !== "string" || !isStatus(record.status)) {
			return seedRecord(fallbackName, new Date().toISOString());
		}
		return {
			bot: typeof record.bot === "string" && record.bot ? record.bot : fallbackName,
			status: record.status,
			task: typeof record.task === "string" ? record.task : "",
			started_at:
				typeof record.started_at === "string"
					? record.started_at
					: new Date().toISOString(),
		};
	} catch {
		return seedRecord(fallbackName, new Date().toISOString());
	}
}

function seedRecord(bot: string, startedAt: string): BotRecord {
	return { bot, status: "idle", task: "", started_at: startedAt };
}

function botKey(name: string): string {
	return `bot:${name}`;
}

function normalizePath(pathname: string): string {
	const trimmed = pathname.replace(/\/+$/, "");
	return trimmed === "" ? "/" : trimmed;
}

async function authorized(request: Request, expected: string): Promise<boolean> {
	const header = request.headers.get("Authorization");
	if (!header) return false;
	const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
	if (!match) return false;
	const provided = match[1];
	if (provided.length === 0 || provided.length > 512) return false;
	return tokenMatches(provided, expected);
}

async function tokenMatches(provided: string, expected: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [providedHash, expectedHash] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(provided)),
		crypto.subtle.digest("SHA-256", encoder.encode(expected)),
	]);
	return crypto.subtle.timingSafeEqual(providedHash, expectedHash);
}

async function readJson(
	request: Request,
): Promise<{ ok: true; value: unknown } | { ok: false; error: string; status: number }> {
	const length = Number(request.headers.get("Content-Length") ?? "0");
	if (Number.isFinite(length) && length > 8192) {
		return { ok: false, error: "body too large", status: 413 };
	}
	let text: string;
	try {
		text = await request.text();
	} catch {
		return { ok: false, error: "could not read body", status: 400 };
	}
	if (text.length > 8192) {
		return { ok: false, error: "body too large", status: 413 };
	}
	try {
		return { ok: true, value: JSON.parse(text) as unknown };
	} catch {
		return { ok: false, error: "body must be JSON", status: 400 };
	}
}

function json(
	data: unknown,
	status = 200,
	extra: Record<string, string> = {},
): Response {
	return Response.json(data, {
		status,
		headers: {
			"Cache-Control": "no-store",
			...extra,
		},
	});
}
