import { DurableObject } from "cloudflare:workers";
import {
	checkedTimeZone,
	dayKey,
	isFinished,
	isStatus,
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
};

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

	async upsert(post: IncomingPost): Promise<{ bot: BotRow; snapshot: Snapshot }> {
		await this.ensureReady();
		this.rollover();
		const existing = this.botRow(post.bot);
		const url = post.url === null ? (existing?.url ?? "") : post.url;
		const color = post.color === null ? (existing?.color ?? "") : post.color;
		const row: BotRow = {
			bot: post.bot,
			status: post.status,
			task: post.task,
			started_at: this.resolveStarted(post, existing),
			url,
			color,
			approval: post.status === "needs_input" && post.approval,
		};
		this.ctx.storage.sql.exec(
			`INSERT INTO bots (name, status, task, started_at, url, color, approval)
			 VALUES (?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET
			   status = excluded.status,
			   task = excluded.task,
			   started_at = excluded.started_at,
			   url = excluded.url,
			   color = excluded.color,
			   approval = excluded.approval`,
			row.bot,
			row.status,
			row.task,
			row.started_at,
			row.url,
			row.color,
			row.approval ? 1 : 0,
		);
		if (isFinished(row.status)) {
			this.recordJob(row);
		}
		const snapshot = this.readSnapshot();
		this.broadcast(snapshot);
		return { bot: row, snapshot };
	}

	/** Removes one bot and its jobs, then tells every live client. */
	async remove(name: string): Promise<{ removed: boolean; jobs: number }> {
		await this.ensureReady();
		this.rollover();
		if (!this.botRow(name)) return { removed: false, jobs: 0 };
		const jobs = this.ctx.storage.sql.exec("DELETE FROM jobs WHERE bot = ?", name).rowsWritten;
		this.ctx.storage.sql.exec("DELETE FROM bots WHERE name = ?", name);
		this.broadcast(this.readSnapshot());
		return { removed: true, jobs };
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
				approval INTEGER NOT NULL DEFAULT 0
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
	}

	/** A finish keeps the working row's clock. Anything else omitted becomes "now". */
	private resolveStarted(post: IncomingPost, existing: BotRow | null): string {
		if (isFinished(post.status) && existing?.status === "working" && existing.started_at) {
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
		return this.readSnapshot();
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
			return {
				bot: typeof record.bot === "string" && record.bot ? record.bot : fallbackName,
				status: record.status,
				task: typeof record.task === "string" ? record.task : "",
				started_at:
					typeof record.started_at === "string" ? record.started_at : new Date().toISOString(),
				url: typeof record.url === "string" ? record.url : "",
				color: typeof record.color === "string" ? record.color : "",
				approval: record.status === "needs_input" && record.approval === true,
			};
		} catch {
			return this.idle(fallbackName, "");
		}
	}

	private idle(name: string, url: string): BotRow {
		return {
			bot: name,
			status: "idle",
			task: "",
			started_at: new Date().toISOString(),
			url,
			color: "",
			approval: false,
		};
	}

	private writeBot(row: BotRow): void {
		this.ctx.storage.sql.exec(
			`INSERT INTO bots (name, status, task, started_at, url, color, approval)
			 VALUES (?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET
			   status = excluded.status,
			   task = excluded.task,
			   started_at = excluded.started_at,
			   url = excluded.url,
			   color = excluded.color,
			   approval = excluded.approval`,
			row.bot,
			row.status,
			row.task,
			row.started_at,
			row.url,
			row.color,
			row.approval ? 1 : 0,
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
			.exec("SELECT name, status, task, started_at, url, color, approval FROM bots ORDER BY rowid")
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
				"SELECT name, status, task, started_at, url, color, approval FROM bots WHERE name = ?",
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
