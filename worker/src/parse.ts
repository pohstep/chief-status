/** needs_input: the bot is waiting on its person. It is not a finish, so it records no job. */
export const STATUSES = ["idle", "working", "failed", "done", "needs_input"] as const;
export const BOT_NAME = /^[\p{L}\p{N}][\p{L}\p{N} ._'’-]{0,39}$/u;
const JOB_RESULTS = ["done", "failed"] as const;

export type Status = (typeof STATUSES)[number];

export type Starter = {
	name: string;
	url: string;
};

export type IncomingPost = {
	bot: string;
	status: Status;
	task: string;
	/** null means "the worker should fill this in". */
	started_at: string | null;
	/** null means "leave the stored link alone". */
	url: string | null;
	/** null means "leave the stored colour alone". */
	color: string | null;
	/**
	 * True only when this post is needs_input and the bot is waiting on an approval.
	 * Any other status stores false. Omitted means false.
	 */
	approval: boolean;
};

export function isStatus(value: string): value is Status {
	return (STATUSES as readonly string[]).includes(value);
}

export function isFinished(value: string): boolean {
	return (JOB_RESULTS as readonly string[]).includes(value);
}

export function parseBot(value: unknown): string | null {
	if (typeof value !== "string") return null;
	const bot = value.trim();
	if (!BOT_NAME.test(bot)) return null;
	return bot;
}

/** A web URL or an app deep link. Empty is not a link. */
export function parseLink(value: string): string | null {
	const url = value.trim();
	if (!url || url.length > 2048 || /\s/.test(url)) return null;
	const match = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(url);
	if (!match) return null;
	const scheme = match[1].toLowerCase();
	if (scheme === "javascript" || scheme === "data" || scheme === "file" || scheme === "vbscript") {
		return null;
	}
	return url;
}

export function parsePost(
	value: unknown,
): { ok: true; post: IncomingPost } | { ok: false; error: string } {
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
		return { ok: false, error: "status must be idle, working, failed, done, or needs_input" };
	}

	if (typeof body.task !== "string") {
		return { ok: false, error: "task is required" };
	}
	const task = cleanTask(body.task);
	if (task === null) {
		return { ok: false, error: "task must be text, 200 characters or fewer" };
	}

	let started: string | null = null;
	if ("started_at" in body && body.started_at !== null && body.started_at !== "") {
		const parsed = parseStartedAt(body.started_at);
		if (!parsed) {
			return {
				ok: false,
				error: "started_at must be an ISO date, like 2026-10-18T10:00:00Z",
			};
		}
		started = parsed;
	}

	let url: string | null = null;
	if ("url" in body) {
		if (body.url === "" || body.url === null) {
			url = "";
		} else if (typeof body.url === "string") {
			const link = parseLink(body.url);
			if (!link) {
				return { ok: false, error: "url must be a web address or an app link" };
			}
			url = link;
		} else {
			return { ok: false, error: "url must be a web address or an app link" };
		}
	}

	let color: string | null = null;
	if ("color" in body) {
		if (body.color === "" || body.color === null) {
			color = "";
		} else if (typeof body.color === "string") {
			const parsed = parseColor(body.color);
			if (!parsed) {
				return { ok: false, error: "color must be a hex colour like #3B82F6" };
			}
			color = parsed;
		} else {
			return { ok: false, error: "color must be a hex colour like #3B82F6" };
		}
	}

	// approval is only meaningful with needs_input. Other statuses store false.
	// Omit it, or send null, and it is false. A non-boolean is rejected.
	let approval = false;
	if ("approval" in body && body.approval !== null && body.approval !== undefined) {
		if (typeof body.approval !== "boolean") {
			return { ok: false, error: "approval must be true or false" };
		}
		if (body.status === "needs_input") {
			approval = body.approval;
		}
	}

	return {
		ok: true,
		post: { bot, status: body.status, task, started_at: started, url, color, approval },
	};
}

/** #RRGGBB, stored lowercase. */
export function parseColor(value: string): string | null {
	const color = value.trim();
	if (!/^#[0-9A-Fa-f]{6}$/.test(color)) return null;
	return color.toLowerCase();
}

export function cleanTask(value: string): string | null {
	const task = value.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();
	if (task.length > 200) return null;
	if (/[\u0000-\u001F\u007F]/.test(task)) return null;
	return task;
}

export function parseStartedAt(value: unknown): string | null {
	if (typeof value !== "string" || value.trim() === "") return null;
	const ms = Date.parse(value);
	if (Number.isNaN(ms)) return null;
	return new Date(ms).toISOString();
}

export function startersFrom(botsRaw: string, urlsRaw: string): Starter[] {
	const urls = new Map<string, string>();
	for (const part of urlsRaw.split(",")) {
		const trimmed = part.trim();
		if (!trimmed) continue;
		const eq = trimmed.indexOf("=");
		if (eq <= 0) continue;
		const name = parseBot(trimmed.slice(0, eq));
		const link = parseLink(trimmed.slice(eq + 1));
		if (name && link) urls.set(name, link);
	}

	const starters: Starter[] = [];
	const seen = new Set<string>();
	for (const part of botsRaw.split(",")) {
		const piece = part.trim();
		if (!piece) continue;
		const pipe = piece.indexOf("|");
		const name = parseBot(pipe >= 0 ? piece.slice(0, pipe) : piece);
		if (!name || seen.has(name)) continue;
		seen.add(name);
		const piped = pipe >= 0 ? parseLink(piece.slice(pipe + 1)) : null;
		starters.push({ name, url: urls.get(name) || piped || "" });
	}
	return starters;
}

export function dayKey(date: Date, timeZone: string): string {
	try {
		const parts = new Intl.DateTimeFormat("en-US", {
			timeZone,
			year: "numeric",
			month: "2-digit",
			day: "2-digit",
		}).formatToParts(date);
		const read = (type: Intl.DateTimeFormatPartTypes) =>
			parts.find((part) => part.type === type)?.value ?? "";
		const year = read("year");
		const month = read("month");
		const day = read("day");
		if (year && month && day) return `${year}-${month}-${day}`;
	} catch {
		// Invalid IANA name. Fall through to UTC.
	}
	return date.toISOString().slice(0, 10);
}

export function checkedTimeZone(value: string): string {
	const trimmed = value.trim();
	if (!trimmed) return "UTC";
	try {
		new Intl.DateTimeFormat("en-US", { timeZone: trimmed }).format(0);
		return trimmed;
	} catch {
		return "UTC";
	}
}

export function staleMinutes(value: string): number {
	const parsed = Number(value);
	if (!Number.isFinite(parsed)) return 60;
	return Math.min(1440, Math.max(1, Math.round(parsed)));
}
