import { parseBot, parsePost } from "./parse";
import { StatusRoom } from "./status-room";

export { StatusRoom };

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
			"Chief Status is running.\nBots are listed at /status\nLive updates are at /status/live\n",
			{
				headers: {
					"Content-Type": "text/plain; charset=utf-8",
					"Cache-Control": "no-store",
				},
			},
		);
	}

	if (request.method === "DELETE" && path.startsWith("/status/")) {
		return deleteBot(request, env, path.slice("/status/".length));
	}

	if (path === "/status/live") {
		return live(request, env);
	}

	if (path !== "/status") {
		return json({ error: "not found" }, 404);
	}

	if (request.method === "GET") {
		const denied = await denyUnlessReader(request, env);
		if (denied) return denied;
		const snapshot = await env.ROOM.getByName("feed").snapshot();
		return json(snapshot);
	}

	if (request.method === "POST") {
		return postStatus(request, env);
	}

	return json({ error: "method not allowed" }, 405, { Allow: "GET, POST" });
}

/** Admin: DELETE /status/<bot> removes the bot and its jobs. Same password as POST. */
async function deleteBot(request: Request, env: Env, rawName: string): Promise<Response> {
	if (!env.STATUS_TOKEN) {
		console.error(JSON.stringify({ event: "missing_secret" }));
		return json({ error: "server is missing STATUS_TOKEN" }, 500);
	}

	if (!(await authorized(request, env.STATUS_TOKEN))) {
		return json({ error: "unauthorized" }, 401);
	}

	let decoded: string;
	try {
		decoded = decodeURIComponent(rawName);
	} catch {
		return json({ error: "bad bot name" }, 400);
	}
	const name = parseBot(decoded);
	if (!name) {
		return json({ error: "bad bot name" }, 400);
	}

	const result = await env.ROOM.getByName("feed").remove(name);
	if (!result.removed) {
		return json({ error: "no such bot" }, 404);
	}

	console.log(JSON.stringify({ event: "status_delete", bot: name, jobs: result.jobs }));

	return json({ ok: true, deleted: name, jobs_removed: result.jobs });
}

async function live(request: Request, env: Env): Promise<Response> {
	const denied = await denyUnlessReader(request, env, true);
	if (denied) return denied;
	if (request.method !== "GET") {
		return json({ error: "method not allowed" }, 405, { Allow: "GET" });
	}
	const upgrade = request.headers.get("Upgrade");
	if (!upgrade || upgrade.toLowerCase() !== "websocket") {
		return json({ error: "expected a websocket upgrade" }, 426);
	}
	return env.ROOM.getByName("feed").fetch(request);
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

	const saved = await env.ROOM.getByName("feed").upsert(parsed.post);

	console.log(
		JSON.stringify({
			event: "status_upsert",
			bot: saved.bot.bot,
			status: saved.bot.status,
		}),
	);

	return json({ ok: true, bot: saved.bot });
}

function normalizePath(pathname: string): string {
	const trimmed = pathname.replace(/\/+$/, "");
	return trimmed === "" ? "/" : trimmed;
}

/**
 * When the READ_TOKEN secret is set, reading the feed requires Authorization: Bearer <token>.
 * The live feed (/status/live) also accepts ?token=<token>, for clients that cannot set headers.
 * A missing or wrong token is 401 with an empty body. When the secret is unset, reading stays open.
 * The value is never logged.
 */
function configuredReadToken(env: Env): string | null {
	const value = (env as { READ_TOKEN?: string }).READ_TOKEN;
	if (typeof value !== "string") return null;
	const trimmed = value.trim();
	if (trimmed.length === 0) return null;
	return trimmed;
}

async function denyUnlessReader(
	request: Request,
	env: Env,
	allowQuery = false,
): Promise<Response | null> {
	const expected = configuredReadToken(env);
	if (!expected) return null;
	if (await authorized(request, expected)) return null;
	if (allowQuery) {
		const provided = new URL(request.url).searchParams.get("token") ?? "";
		if (provided.length > 0 && provided.length <= 512 && (await tokenMatches(provided, expected))) {
			return null;
		}
	}
	return new Response(null, {
		status: 401,
		headers: { "Cache-Control": "no-store" },
	});
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
