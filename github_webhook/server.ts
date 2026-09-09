// GitHub webhook server (Bun). Receives push events, verifies signatures, and
// hands each deployment to deploy.sh in the background. Run as the git account.
import { createHmac, timingSafeEqual } from "node:crypto";

const ROOT = process.env.GITHUB_WEBHOOK_ROOT ?? "/srv/git/.github_webhook";
const PORT = Number(process.env.PORT ?? 9090);
const HOST = process.env.HOST ?? "0.0.0.0";

// Owner/repository names follow the push_n_deploy conventions.
const NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;

function die(env: Record<string, unknown>, message: string, status: number): Response {
  console.error(message);
  return new Response(`${message}\n`, { status });
}

// Parse KEY=VALUE shell config written with printf %q.
function parseConfig(text: string): Record<string, string> {
  const config: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    let value = match[2];
    const single = value.match(/^'((?:[^'\\]|\\.|\\')*)'$/);
    const double = value.match(/^"((?:[^"\\]|\\.)*)"$/);
    if (single) value = single[1].replace(/\\(.)/g, "$1");
    else if (double) value = double[1].replace(/\\(.)/g, "$1");
    config[match[1]] = value;
  }
  return config;
}

function verifySignature(secret: string, body: string, header: string | null): boolean {
  if (!header?.startsWith("sha256=")) return false;
  const expected = createHmac("sha256", secret).update(body).digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(header.slice("sha256=".length));
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

// Recent delivery ids, bounded, to drop duplicate deliveries.
const recentDeliveries = new Set<string>();
function markDelivery(id: string): boolean {
  if (recentDeliveries.has(id)) return false;
  recentDeliveries.add(id);
  if (recentDeliveries.size > 5000) {
    const first = recentDeliveries.values().next().value;
    if (first !== undefined) recentDeliveries.delete(first);
  }
  return true;
}

function launchDeploy(owner: string, repo: string, revision: string): void {
  const dir = `${ROOT}/${owner}/${repo}`;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "");
  const log = `${dir}/logs/${stamp}-${revision.slice(0, 8)}.log`;
  const script = `${ROOT}/bin/deploy.sh`;
  // Redirect the whole child run into its log file; never inherit our env.
  const proc = Bun.spawn(
    ["/bin/bash", "-c", 'exec "$0" "$1" "$2" "$3" >"$4" 2>&1', script, owner, repo, revision, log],
    {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
      env: {
        PATH: "/usr/local/bin:/usr/bin:/bin",
        HOME: process.env.HOME ?? "/srv/git",
        GITHUB_WEBHOOK_ROOT: ROOT,
      },
    },
  );
  proc.unref();
  console.log(`${owner}/${repo}: queued ${revision.slice(0, 8)} (log: ${log})`);
}

const server = Bun.serve({
  port: PORT,
  hostname: HOST,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/healthz") {
      return new Response("ok\n");
    }
    if (req.method !== "POST") return new Response("method not allowed\n", { status: 405 });

    const [owner, repo] = url.pathname.replace(/^\//, "").split("/");
    if (!owner || !repo || !NAME_RE.test(owner) || !NAME_RE.test(repo) || owner === "bin") {
      return new Response("not found\n", { status: 404 });
    }
    const dir = `${ROOT}/${owner}/${repo}`;
    const secretFile = Bun.file(`${dir}/secret`);
    if (!(await secretFile.exists())) return new Response("not registered\n", { status: 404 });
    const secret = (await secretFile.text()).trim();
    if (!secret) return new Response("not registered\n", { status: 404 });

    const event = req.headers.get("x-github-event") ?? "";
    const delivery = req.headers.get("x-github-delivery") ?? crypto.randomUUID();
    const body = await req.text();
    if (!verifySignature(secret, body, req.headers.get("x-hub-signature-256"))) {
      console.error(`${owner}/${repo}: invalid signature for delivery ${delivery}`);
      return new Response("invalid signature\n", { status: 401 });
    }

    if (event === "ping") return new Response("pong\n");
    if (event !== "push") return new Response(`event ${event} ignored\n`);

    let payload: { ref?: string; after?: string; repository?: { full_name?: string } };
    try {
      payload = JSON.parse(body);
    } catch {
      return new Response("invalid payload\n", { status: 400 });
    }
    if (payload.repository?.full_name?.toLowerCase() !== `${owner}/${repo}`.toLowerCase()) {
      return new Response("repository mismatch\n", { status: 400 });
    }
    const config = parseConfig(await Bun.file(`${dir}/config`).text());
    const branch = config.branch ?? "main";
    if (payload.ref !== `refs/heads/${branch}`) {
      return new Response(`ref ${payload.ref} ignored (branch: ${branch})\n`);
    }
    const revision = payload.after ?? "";
    if (!/^[0-9a-f]{40}$/.test(revision) || /^0+$/.test(revision)) {
      return new Response("nothing to deploy\n");
    }
    if (!markDelivery(delivery)) {
      return new Response(`duplicate delivery ${delivery} ignored\n`);
    }
    launchDeploy(owner, repo, revision);
    return new Response(`deploy of ${revision.slice(0, 8)} queued\n`, { status: 202 });
  },
});

console.log(`GitHub webhook server listening on ${server.hostname}:${server.port}, root: ${ROOT}`);
