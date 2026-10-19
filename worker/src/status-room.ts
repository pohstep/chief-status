import { DurableObject } from "cloudflare:workers";
import {
	checkedTimeZone,
	dayKey,
	idleAfterMinutes,
	isFinished,
	isStatus,
	nameKey,
	startersFrom,
	staleMinutes,
	type IncomingPost,
	type Starter,
	type Status,
} from "./parse";

const JOB_CAP = 200;
const INDEX_KEY = "bots:index";

export type BotRow = {
	bot: string;
	status: Status;
	task: string;
	started_at: string;
	url: string;
	color: string;
	/** True only while status is needs_input and the bot asked for an approval. */
	approval: boolean;
	/** When this row was last posted, set by the worker. Empty on a row that has not posted since the column was added. */
	last_posted_at: string;
};

export type JobRow = {
	bot: string;
	task: string;
	started_at: string;
	ended_at: string;
	duration_ms: number;
	result: "done" | "failed";
};

export type Snapshot = {
	bots: BotRow[];
	today: JobRow[];
	stale_after_minutes: number;
	timezone: string;
	/** Minutes before a quiet working row turns idle on its own. 0 means off. */
	idle_after_minutes: number;
};

export type UpsertResult =
	| { ok: true; bot: BotRow; snapshot: Snapshot }
	| { ok: false; status: number; error: string };

type SqlRow = Record<string, string | number | null | ArrayBuffer>;

export class StatusRoom extends DurableObject<Env> {
	private preparing: Promise<void> | null = null;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		// Text "ping" is answered without waking the object, so a keepalive is free.
		this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
		ctx.blockConcurrencyWhile(async () => {
			this.ensureSchema();
		});
	}

	async snapshot(): Promise<Snapshot> {
		return this.current();
	}

	async upsert(incoming: IncomingPost): Promise<UpsertResult> {
		await this.ensureReady();
		this.rollover();
		this.expireStale();
		const name = this.resolveName(incoming.bot);
		if (!name) {
			await this.scheduleExpiry();
			return {
				ok: false,
				status: 403,
				error: `unknown bot "${incoming.bot}": only bots already on this feed or listed in BOTS can post`,
			};
		}
		const existing = this.botRow(name);
		let task = incoming.task;
		if (task === null) {
			// A heartbeat with no task refreshes the current working task, and nothing else.
			if (!existing || existing.status !== "working") {
				await this.scheduleExpiry();
				return {
					ok: false,
					status: 409,
					error: `${name} is not working, so there is no task to heartbeat. Post working with a task first`,
				};
			}
			task = existing.task;
		}
		const post: IncomingPost = { ...incoming, bot: name, task };
		const url = post.url === null ? (existing?.url ?? "") : post.url;
		const color = post.color === null ? (existing?.color ?? "") : post.color;
		const row: BotRow = {
			bot: name,
			status: post.status,
			task,
			started_at: this.resolveStarted(post, existing),
			url,
			color,
			approval: post.status === "needs_input" && post.approval,
			last_posted_at: new Date().toISOString(),
		};
		this.ctx.storage.sql.exec(
			`INSERT INTO bots (name, status, task, started_at, url, color, approval, last_posted_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET
			   status = excluded.status,
			   task = excluded.task,
			   started_at = excluded.started_at,
			   url = excluded.url,
			   color = excluded.color,
			   approval = excluded.approval,
			   last_posted_at = excluded.last_posted_at`,
			row.bot,
			row.status,
			row.task,
			row.started_at,
			row.url,
			row.color,
			row.approval ? 1 : 0,
			row.last_posted_at,
		);
		if (isFinished(row.status)) {
			this.recordJob(row);
		}
		await this.scheduleExpiry();
		const snapshot = this.readSnapshot();
		this.broadcast(snapshot);
		return { ok: true, bot: row, snapshot };
	}

	/** Removes one bot and its jobs, then tells every live client. The name is matched without case. */
	async remove(rawName: string): Promise<{ removed: boolean; jobs: number; name: string }> {
		await this.ensureReady();
		this.rollover();
		const name = this.existingName(rawName);
		if (!name) return { removed: false, jobs: 0, name: rawName };
		const jobs = this.ctx.storage.sql.exec("DELETE FROM jobs WHERE bot = ?", name).rowsWritten;
		this.ctx.storage.sql.exec("DELETE FROM bots WHERE name = ?", name);
		this.expireStale();
		await this.scheduleExpiry();
		this.broadcast(this.readSnapshot());
		return { removed: true, jobs, name };
	}

	/**
	 * Durable Object alarm, set for the next working row's idle deadline.
	 * It turns quiet working rows idle and pushes the change to live clients without a read.
	 */
	async alarm(): Promise<void> {
		await this.ensureReady();
		this.rollover();
		const changed = this.expireStale();
		await this.scheduleExpiry();
		if (changed > 0) this.broadcast(this.readSnapshot());
	}

	async fetch(request: Request): Promise<Response> {
		if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
			return new Response("Expected websocket", { status: 426 });
		}
		const pair = new WebSocketPair();
		const client = pair[0];
		const server = pair[1];
		this.ctx.acceptWebSocket(server);
		try {
			server.send(JSON.stringify({ type: "snapshot", ...(await this.current()) }));
		} catch {
			// The client can reconnect. The socket is still accepted.
		}
		return new Response(null, { status: 101, webSocket: client });
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
		const text = typeof message === "string" ? message : new TextDecoder().decode(message);
		if (text === "ping" || text === "pong") return;
		try {
			ws.send(JSON.stringify({ type: "snapshot", ...(await this.current()) }));
		} catch {
			// Already closed.
		}
	}

	async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
		try {
			ws.close(code, reason);
		} catch {
			// The runtime already finished the close handshake.
		}
	}

	async webSocketError(): Promise<void> {
		// Hibernation delivers the error here. The client reconnects on its own.
	}

	private ensureSchema(): void {
		this.ctx.storage.sql.exec(`
			CREATE TABLE IF NOT EXISTS bots (
				name TEXT PRIMARY KEY,
				status TEXT NOT NULL,
				task TEXT NOT NULL,
				started_at TEXT NOT NULL,
				url TEXT NOT NULL DEFAULT '',
				color TEXT NOT NULL DEFAULT '',
				approval INTEGER NOT NULL DEFAULT 0,
				last_posted_at TEXT NOT NULL DEFAULT ''
			);
			CREATE TABLE IF NOT EXISTS jobs (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				day TEXT NOT NULL,
				bot TEXT NOT NULL,
				task TEXT NOT NULL,
				started_at TEXT NOT NULL,
				ended_at TEXT NOT NULL,
				duration_ms INTEGER NOT NULL,
				result TEXT NOT NULL
			);
			CREATE INDEX IF NOT EXISTS jobs_day ON jobs(day, id);
			CREATE TABLE IF NOT EXISTS meta (
				key TEXT PRIMARY KEY,
				value TEXT NOT NULL
			);
		`);
		const columns = this.ctx.storage.sql.exec("PRAGMA table_info(bots)").toArray() as SqlRow[];
		const names = columns.map((column) => String(column.name ?? ""));
		if (!names.includes("color")) {
			this.ctx.storage.sql.exec("ALTER TABLE bots ADD COLUMN color TEXT NOT NULL DEFAULT ''");
		}
		if (!names.includes("approval")) {
			this.ctx.storage.sql.exec("ALTER TABLE bots ADD COLUMN approval INTEGER NOT NULL DEFAULT 0");
		}
		if (!names.includes("last_posted_at")) {
			this.ctx.storage.sql.exec("ALTER TABLE bots ADD COLUMN last_posted_at TEXT NOT NULL DEFAULT ''");
		}
	}

	/**
	 * The job clock. A heartbeat keeps the stored start of a working row (or starts now if the bot
	 * was not working) and ignores any started_at on that post. last_posted_at still updates on every upsert.
	 * A finish keeps the working row's start.
	 * A re-post of the same status and the same task (idle, working or needs_input) is a heartbeat too:
	 * it keeps the stored start even when the post carries a fresh started_at.
	 * A working post that omits started_at, for a bot that was not already working, starts now.
	 * A repeat of the same status keeps the stored start.
	 */
	private resolveStarted(post: IncomingPost, existing: BotRow | null): string {
		if (post.heartbeat) {
			if (existing?.status === "working" && existing.started_at) return existing.started_at;
			return new Date().toISOString();
		}
		if (isFinished(post.status) && existing?.status === "working" && existing.started_at) {
			return existing.started_at;
		}
		if (
			!isFinished(post.status) &&
			existing &&
			existing.status === post.status &&
			existing.task === post.task &&
			existing.started_at
		) {
			return existing.started_at;
		}
		if (post.started_at) return post.started_at;
		if (existing && existing.status === post.status && existing.started_at) {
			return existing.started_at;
		}
		return new Date().toISOString();
	}

	private ensureReady(): Promise<void> {
		if (!this.preparing) {
			this.preparing = this.prepare().catch((error: unknown) => {
				this.preparing = null;
				throw error;
			});
		}
		return this.preparing;
	}

	private async prepare(): Promise<void> {
		const seeded = this.meta("seeded");
		if (!seeded) {
			const imported = await this.readKvBots();
			for (const bot of imported) this.writeBot(bot);
			for (const starter of this.starters()) this.insertIfMissing(starter);
			this.setMeta("seeded", "1");
		} else {
			this.fillBlankLinks();
		}
		this.rollover();
	}

	private async current(): Promise<Snapshot> {
		await this.ensureReady();
		this.rollover();
		const changed = this.expireStale();
		await this.scheduleExpiry();
		const snapshot = this.readSnapshot();
		// Anyone else watching hears about an expiry this read found, not just the reader.
		if (changed > 0) this.broadcast(snapshot);
		return snapshot;
	}

	private idleAfterMs(): number {
		const raw = (this.env as { IDLE_AFTER_MINUTES?: string }).IDLE_AFTER_MINUTES;
		return Math.round(idleAfterMinutes(typeof raw === "string" ? raw : undefined) * 60_000);
	}

	/** When a working row last showed life: its last post, or its start on a row that never recorded one. */
	private lastSeenMs(row: SqlRow): number {
		const posted = typeof row.last_posted_at === "string" ? Date.parse(row.last_posted_at) : NaN;
		if (!Number.isNaN(posted)) return posted;
		return typeof row.started_at === "string" ? Date.parse(row.started_at) : NaN;
	}

	/**
	 * Turns every working row with no post for IDLE_AFTER_MINUTES idle: task cleared, approval off,
	 * started_at set to the moment it went quiet plus the window. last_posted_at is left alone,
	 * because the bot did not post. needs_input, done, failed and idle never expire. No job is recorded.
	 * Returns how many rows changed.
	 */
	private expireStale(now = Date.now()): number {
		const limit = this.idleAfterMs();
		if (limit <= 0) return 0;
		const rows = this.ctx.storage.sql
			.exec("SELECT name, started_at, last_posted_at FROM bots WHERE status = 'working'")
			.toArray() as SqlRow[];
		let changed = 0;
		for (const row of rows) {
			const seen = this.lastSeenMs(row);
			if (Number.isNaN(seen) || now - seen < limit) continue;
			const idleAt = new Date(Math.min(now, seen + limit)).toISOString();
			this.ctx.storage.sql.exec(
				"UPDATE bots SET status = 'idle', task = '', approval = 0, started_at = ? WHERE name = ? AND status = 'working'",
				idleAt,
				String(row.name ?? ""),
			);
			changed += 1;
			console.log(JSON.stringify({ event: "status_auto_idle", bot: String(row.name ?? "") }));
		}
		return changed;
	}

	/** Sets the alarm for the earliest working row's idle deadline, or clears it when none is working. */
	private async scheduleExpiry(): Promise<void> {
		const limit = this.idleAfterMs();
		let next = Infinity;
		if (limit > 0) {
			const rows = this.ctx.storage.sql
				.exec("SELECT started_at, last_posted_at FROM bots WHERE status = 'working'")
				.toArray() as SqlRow[];
			for (const row of rows) {
				const seen = this.lastSeenMs(row);
				if (!Number.isNaN(seen)) next = Math.min(next, seen + limit);
			}
		}
		try {
			const storage = this.ctx.storage;
			const current = await storage.getAlarm();
			if (next === Infinity) {
				if (current !== null) await storage.deleteAlarm();
				return;
			}
			const at = Math.max(next, Date.now() + 1000);
			if (current === null || Math.abs(current - at) > 500) await storage.setAlarm(at);
		} catch (error) {
			// Reads and posts still expire rows. The next one tries the alarm again.
			console.error(
				JSON.stringify({
					event: "alarm_schedule_failed",
					message: error instanceof Error ? error.message : "unknown",
				}),
			);
		}
	}

	/** The stored name that matches without case, or null. */
	private existingName(raw: string): string | null {
		const key = nameKey(raw);
		const rows = this.ctx.storage.sql.exec("SELECT name FROM bots ORDER BY rowid").toArray() as SqlRow[];
		for (const row of rows) {
			const name = String(row.name ?? "");
			if (nameKey(name) === key) return name;
		}
		return null;
	}

	/**
	 * The canonical name a post goes to. A row already on the feed wins (any case), then a BOTS entry.
	 * When BOTS is set, any other name is unknown (null). When BOTS is empty, a new name registers itself.
	 */
	private resolveName(raw: string): string | null {
		const existing = this.existingName(raw);
		if (existing) return existing;
		const starters = this.starters();
		if (starters.length === 0) return raw;
		const key = nameKey(raw);
		const listed = starters.find((starter) => nameKey(starter.name) === key);
		return listed ? listed.name : null;
	}

	private starters(): Starter[] {
		const bots = typeof this.env.BOTS === "string" ? this.env.BOTS : "";
		const urls = typeof this.env.BOT_URLS === "string" ? this.env.BOT_URLS : "";
		return startersFrom(bots, urls);
	}

	private zone(): string {
		const raw = typeof this.env.TZ === "string" ? this.env.TZ : "UTC";
		return checkedTimeZone(raw);
	}

	private minutes(): number {
		const raw = typeof this.env.STALE_MINUTES === "string" ? this.env.STALE_MINUTES : "60";
		return staleMinutes(raw);
	}

	/** v1.1 kept bots in a KV namespace. New feeds have no STATUS binding, so this is a no-op. */
	private async readKvBots(): Promise<BotRow[]> {
		const kv = (this.env as { STATUS?: KVNamespace }).STATUS;
		if (!kv) return [];
		try {
			const raw = await kv.get(INDEX_KEY);
			if (!raw) return [];
			const parsed: unknown = JSON.parse(raw);
			if (!Array.isArray(parsed)) return [];
			const bots: BotRow[] = [];
			for (const name of parsed) {
				if (typeof name !== "string" || !name) continue;
				const stored = await kv.get(`bot:${name}`);
				bots.push(stored ? this.parseStored(stored, name) : this.idle(name, ""));
			}
			return bots;
		} catch {
			console.log(JSON.stringify({ event: "kv_import_skipped" }));
			return [];
		}
	}

	private parseStored(raw: string, fallbackName: string): BotRow {
		try {
			const value: unknown = JSON.parse(raw);
			if (typeof value !== "object" || value === null) return this.idle(fallbackName, "");
			const record = value as Partial<BotRow>;
			if (typeof record.status !== "string" || !isStatus(record.status)) {
				return this.idle(fallbackName, "");
			}
			const started =
				typeof record.started_at === "string" ? record.started_at : new Date().toISOString();
			return {
				bot: typeof record.bot === "string" && record.bot ? record.bot : fallbackName,
				status: record.status,
				task: typeof record.task === "string" ? record.task : "",
				started_at: started,
				url: typeof record.url === "string" ? record.url : "",
				color: typeof record.color === "string" ? record.color : "",
				approval: record.status === "needs_input" && record.approval === true,
				last_posted_at: typeof record.last_posted_at === "string" ? record.last_posted_at : started,
			};
		} catch {
			return this.idle(fallbackName, "");
		}
	}

	private idle(name: string, url: string): BotRow {
		const now = new Date().toISOString();
		return {
			bot: name,
			status: "idle",
			task: "",
			started_at: now,
			url,
			color: "",
			approval: false,
			last_posted_at: now,
		};
	}

	private writeBot(row: BotRow): void {
		this.ctx.storage.sql.exec(
			`INSERT INTO bots (name, status, task, started_at, url, color, approval, last_posted_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET
			   status = excluded.status,
			   task = excluded.task,
			   started_at = excluded.started_at,
			   url = excluded.url,
			   color = excluded.color,
			   approval = excluded.approval,
			   last_posted_at = excluded.last_posted_at`,
			row.bot,
			row.status,
			row.task,
			row.started_at,
			row.url,
			row.color,
			row.approval ? 1 : 0,
			row.last_posted_at,
		);
	}

	private insertIfMissing(starter: Starter): void {
		const existing = this.botRow(starter.name);
		if (existing) {
			if (!existing.url && starter.url) {
				this.ctx.storage.sql.exec("UPDATE bots SET url = ? WHERE name = ?", starter.url, starter.name);
			}
			return;
		}
		this.writeBot(this.idle(starter.name, starter.url));
	}

	private fillBlankLinks(): void {
		for (const starter of this.starters()) {
			if (!starter.url) continue;
			this.ctx.storage.sql.exec(
				"UPDATE bots SET url = ? WHERE name = ? AND url = ''",
				starter.url,
				starter.name,
			);
		}
	}

	private recordJob(row: BotRow): void {
		const day = dayKey(new Date(), this.zone());
		const ended = new Date();
		const startedMs = Date.parse(row.started_at);
		const duration = Number.isNaN(startedMs) ? 0 : Math.max(0, ended.getTime() - startedMs);
		const previous = this.ctx.storage.sql
			.exec(
				"SELECT started_at, result FROM jobs WHERE bot = ? AND day = ? ORDER BY id DESC LIMIT 1",
				row.bot,
				day,
			)
			.toArray() as SqlRow[];
		const last = previous[0];
		if (last && last.started_at === row.started_at && last.result === row.status) return;

		const countRow = this.ctx.storage.sql
			.exec("SELECT COUNT(*) AS n FROM jobs WHERE day = ?", day)
			.toArray() as SqlRow[];
		let count = Number(countRow[0]?.n ?? 0);
		while (count >= JOB_CAP) {
			this.ctx.storage.sql.exec(
				"DELETE FROM jobs WHERE id = (SELECT id FROM jobs WHERE day = ? ORDER BY id ASC LIMIT 1)",
				day,
			);
			count -= 1;
		}
		this.ctx.storage.sql.exec(
			`INSERT INTO jobs (day, bot, task, started_at, ended_at, duration_ms, result)
			 VALUES (?, ?, ?, ?, ?, ?, ?)`,
			day,
			row.bot,
			row.task,
			row.started_at,
			ended.toISOString(),
			duration,
			row.status,
		);
	}

	private rollover(): void {
		const day = dayKey(new Date(), this.zone());
		if (this.meta("day") === day) return;
		this.ctx.storage.sql.exec("DELETE FROM jobs WHERE day != ?", day);
		this.setMeta("day", day);
	}

	private readSnapshot(): Snapshot {
		const bots = (this.ctx.storage.sql
			.exec(
				"SELECT name, status, task, started_at, url, color, approval, last_posted_at FROM bots ORDER BY rowid",
			)
			.toArray() as SqlRow[]).map((row) => this.asBot(row));
		const day = dayKey(new Date(), this.zone());
		const today = (this.ctx.storage.sql
			.exec(
				`SELECT bot, task, started_at, ended_at, duration_ms, result
				 FROM jobs WHERE day = ? ORDER BY id DESC`,
				day,
			)
			.toArray() as SqlRow[]).map((row) => this.asJob(row));
		return {
			bots,
			today,
			stale_after_minutes: this.minutes(),
			timezone: this.zone(),
			idle_after_minutes: this.idleAfterMs() / 60_000,
		};
	}

	private asBot(row: SqlRow): BotRow {
		const status = typeof row.status === "string" && isStatus(row.status) ? row.status : "idle";
		const approval = status === "needs_input" && Number(row.approval) === 1;
		return {
			bot: String(row.name ?? ""),
			status,
			task: typeof row.task === "string" ? row.task : "",
			started_at: typeof row.started_at === "string" ? row.started_at : "",
			url: typeof row.url === "string" ? row.url : "",
			color: typeof row.color === "string" ? row.color : "",
			approval,
			last_posted_at: typeof row.last_posted_at === "string" ? row.last_posted_at : "",
		};
	}

	private asJob(row: SqlRow): JobRow {
		const result = row.result === "failed" ? "failed" : "done";
		return {
			bot: String(row.bot ?? ""),
			task: typeof row.task === "string" ? row.task : "",
			started_at: typeof row.started_at === "string" ? row.started_at : "",
			ended_at: typeof row.ended_at === "string" ? row.ended_at : "",
			duration_ms: Number(row.duration_ms ?? 0),
			result,
		};
	}

	private botRow(name: string): BotRow | null {
		const rows = this.ctx.storage.sql
			.exec(
				"SELECT name, status, task, started_at, url, color, approval, last_posted_at FROM bots WHERE name = ?",
				name,
			)
			.toArray() as SqlRow[];
		const row = rows[0];
		return row ? this.asBot(row) : null;
	}

	private meta(key: string): string | null {
		const rows = this.ctx.storage.sql
			.exec("SELECT value FROM meta WHERE key = ?", key)
			.toArray() as SqlRow[];
		const value = rows[0]?.value;
		return typeof value === "string" ? value : null;
	}

	private setMeta(key: string, value: string): void {
		this.ctx.storage.sql.exec(
			`INSERT INTO meta (key, value) VALUES (?, ?)
			 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
			key,
			value,
		);
	}

	private broadcast(snapshot: Snapshot): void {
		const text = JSON.stringify({ type: "snapshot", ...snapshot });
		for (const ws of this.ctx.getWebSockets()) {
			try {
				if (ws.readyState === WebSocket.OPEN) ws.send(text);
			} catch {
				// A closed socket drops out of the list on its own.
			}
		}
	}
}
