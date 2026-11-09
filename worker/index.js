// keynav.app: the static site (build/site), plus a small visit log and the /admin page that reads it.
//
// The log keeps no cookies and no IP addresses. Each visitor is a hash of the day, their IP and their browser, so
// one person counts once a day and can't be followed from one day to the next.
//
// /admin asks for the password set with `npx wrangler@4 secret put ADMIN_PASSWORD`, then remembers this browser
// for 30 days with a signed cookie.

const BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|curl|wget|python|go-http|headless|lighthouse/i;
const KINDS = new Set(["view", "play", "buy"]);
const DAY = 86400000;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.hostname.startsWith("www.")) {
      url.hostname = url.hostname.slice(4);
      return Response.redirect(url.toString(), 301);
    }
    const path = url.pathname;
    if (path === "/api/hit" && request.method === "POST") {
      // The body is read before answering; once the response is sent, it's gone.
      const body = await request.text();
      ctx.waitUntil(hit(request, env, body));
      return new Response(null, { status: 204 });
    }
    if (path === "/admin" || path.startsWith("/admin/")) return admin(request, env, url);

    const response = await env.ASSETS.fetch(request);
    const ua = request.headers.get("user-agent") || "";
    if (request.method === "GET" && response.ok) {
      if (path === "/download/KeyNav.dmg" && !BOT.test(ua) && !resumed(request)) {
        ctx.waitUntil(log(env, request, { kind: "download", path, ref: host(request.headers.get("referer")) }));
      } else if (path === "/appcast.xml" && ua.includes("Sparkle")) {
        ctx.waitUntil(log(env, request, { kind: "update", path, version: ua.match(/KeyNav\/(\S+)/)?.[1] || null }));
      }
    }
    return response;
  },
};

// A download that picks up where it left off isn't a new one.
function resumed(request) {
  const range = request.headers.get("range");
  return range && !/^bytes=0-/.test(range);
}

async function hit(request, env, text) {
  const ua = request.headers.get("user-agent") || "";
  if (BOT.test(ua)) return;
  let body;
  try { body = JSON.parse(text); } catch { return; }
  if (!KINDS.has(body.k)) return;
  const ref = host(body.r);
  await log(env, request, {
    kind: body.k,
    path: String(body.p || "/").slice(0, 200),
    ref: ref === "keynav.app" ? null : ref,
    source: String(body.s || "").slice(0, 60) || null,
  });
}

async function log(env, request, event) {
  const now = Date.now();
  const day = new Date(now).toISOString().slice(0, 10);
  const ua = request.headers.get("user-agent") || "";
  const ip = request.headers.get("cf-connecting-ip") || "";
  const visitor = (await sha256(`${day}|${ip}|${ua}|${env.STATS_SALT || "keynav"}`)).slice(0, 16);
  await env.STATS.prepare(
    "INSERT INTO events (ts, day, kind, path, ref, source, country, device, visitor, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(now, day, event.kind, event.path ?? null, event.ref ?? null, event.source ?? null,
    request.cf?.country || null, device(ua), visitor, event.version ?? null).run();
}

function host(value) {
  try { return new URL(value).hostname.replace(/^www\./, "") || null; } catch { return null; }
}

function device(ua) {
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Macintosh|Mac OS X|Darwin|Sparkle/.test(ua)) return "Mac";
  if (/Windows/.test(ua)) return "Windows";
  if (/Linux|CrOS/.test(ua)) return "Linux";
  return "Other";
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// MARK: - Sign-in

async function sign(secret, text) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function signedIn(request, secret) {
  const cookie = (request.headers.get("cookie") || "").match(/(?:^|;\s*)kn_admin=(\d+)\.([0-9a-f]{64})/);
  if (!cookie || Number(cookie[1]) < Date.now()) return false;
  return (await sign(secret, `admin:${cookie[1]}`)) === cookie[2];
}

async function admin(request, env, url) {
  const secret = env.ADMIN_PASSWORD;
  if (!secret) return page("Admin", `<p class="muted">Set a password first with <code>npx wrangler@4 secret put ADMIN_PASSWORD</code>.</p>`, 503);

  if (url.pathname === "/admin/logout" && request.method === "POST") {
    return new Response(null, { status: 303, headers: { location: "/admin", "set-cookie": "kn_admin=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict" } });
  }
  if (request.method === "POST") {
    const form = await request.formData();
    // Comparing signatures rather than the passwords themselves takes the same time however much of a guess is right.
    const given = await sign(secret, String(form.get("password") || ""));
    if (given !== (await sign(secret, secret))) {
      await new Promise((r) => setTimeout(r, 1000));
      return login("That password isn't right.");
    }
    const expires = Date.now() + 30 * DAY;
    const value = `${expires}.${await sign(secret, `admin:${expires}`)}`;
    return new Response(null, { status: 303, headers: { location: "/admin", "set-cookie": `kn_admin=${value}; Path=/admin; Max-Age=${30 * 86400}; HttpOnly; Secure; SameSite=Strict` } });
  }
  if (!(await signedIn(request, secret))) return login();
  return dashboard(env, url);
}

function login(error) {
  return page("Sign in", `
    <form method="post" class="login">
      <h1>KeyNav admin</h1>
      <input type="password" name="password" placeholder="Password" autocomplete="current-password" autofocus required>
      ${error ? `<p class="error">${error}</p>` : ""}
      <button>Sign in</button>
    </form>`, error ? 401 : 200);
}

// MARK: - Dashboard

async function dashboard(env, url) {
  const days = [7, 30, 90].includes(Number(url.searchParams.get("d"))) ? Number(url.searchParams.get("d")) : 30;
  const since = new Date(Date.now() - (days - 1) * DAY).toISOString().slice(0, 10);
  const q = (sql, ...args) => env.STATS.prepare(sql).bind(...args);
  const [daily, totals, refs, countries, devices, versions, installs, recent] = (await env.STATS.batch([
    q(`SELECT day, COUNT(DISTINCT CASE WHEN kind = 'view' THEN visitor END) AS visitors,
              SUM(kind = 'download') AS downloads FROM events WHERE day >= ? GROUP BY day`, since),
    q(`SELECT SUM(kind = 'view') AS views, SUM(kind = 'download') AS downloads, SUM(kind = 'buy') AS buys,
              SUM(kind = 'play') AS plays FROM events WHERE day >= ?`, since),
    q(`SELECT COALESCE(source, ref) AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' AND COALESCE(source, ref) IS NOT NULL GROUP BY name ORDER BY n DESC LIMIT 12`, since),
    q(`SELECT country AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' AND country IS NOT NULL GROUP BY name ORDER BY n DESC LIMIT 12`, since),
    q(`SELECT device AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' GROUP BY name ORDER BY n DESC`, since),
    q(`SELECT version AS name, COUNT(DISTINCT visitor) AS n FROM events
       WHERE ts >= ? AND kind = 'update' GROUP BY name ORDER BY n DESC`, Date.now() - DAY),
    q(`SELECT COUNT(DISTINCT visitor) AS n FROM events WHERE ts >= ? AND kind = 'update'`, Date.now() - DAY),
    q(`SELECT ts, kind, ref, source, country, device FROM events WHERE kind != 'update' ORDER BY ts DESC LIMIT 25`),
  ])).map((r) => r.results);

  const byDay = new Map(daily.map((d) => [d.day, d]));
  const series = Array.from({ length: days }, (_, i) => {
    const day = new Date(Date.now() - (days - 1 - i) * DAY).toISOString().slice(0, 10);
    return { day, visitors: byDay.get(day)?.visitors || 0, downloads: byDay.get(day)?.downloads || 0 };
  });
  const visitors = series.reduce((s, d) => s + d.visitors, 0);
  const t = totals[0] || {};
  const rate = visitors ? `${Math.round(((t.downloads || 0) / visitors) * 100)}%` : "–";
  const names = (() => { try { return new Intl.DisplayNames(["en"], { type: "region" }); } catch { return null; } })();
  const country = (c) => (c && names?.of(c)) || c || "–";

  const body = `
    <header>
      <h1>KeyNav admin</h1>
      <nav class="range">${[7, 30, 90].map((d) => `<a href="?d=${d}"${d === days ? ' aria-current="true"' : ""}>${d} days</a>`).join("")}</nav>
      <form method="post" action="/admin/logout"><button class="quiet">Sign out</button></form>
    </header>
    <section class="tiles">
      ${tile("Visitors", visitors)}
      ${tile("Downloads", t.downloads || 0, `${rate} of visitors`)}
      ${tile("Buy clicks", t.buys || 0, "Sales are in Polar")}
      ${tile("Active installs", installs[0]?.n || 0, "Checked for updates today")}
    </section>
    <section class="charts">
      ${bars("Visitors per day", series, "visitors")}
      ${bars("Downloads per day", series, "downloads")}
    </section>
    <section class="lists">
      ${list("Where visitors come from", refs, (n) => n, "No referrers yet")}
      ${list("Countries", countries, country)}
      ${list("Devices", devices, (n) => n)}
      ${list("App versions in use", versions, (n) => (n ? `Build ${n}` : "Unknown"), "No update checks today")}
    </section>
    <section>
      <h2>Latest</h2>
      ${recent.length ? `<table class="recent"><tbody>${recent.map((e) => `<tr>
        <td><time datetime="${new Date(e.ts).toISOString()}"></time></td>
        <td>${esc(label(e.kind))}</td>
        <td class="muted">${esc([country(e.country), e.device, e.source || e.ref].filter(Boolean).join(" · "))}</td>
      </tr>`).join("")}</tbody></table>` : `<p class="muted">Nothing yet.</p>`}
    </section>
    <p class="muted foot">Page views ${t.views || 0} · Soundtrack plays ${t.plays || 0}</p>
    <script>
      for (const t of document.querySelectorAll("time")) {
        const d = new Date(t.dateTime);
        t.textContent = d.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
      }
      const tip = document.querySelector(".tip");
      for (const bar of document.querySelectorAll(".bar")) {
        bar.addEventListener("pointerenter", () => {
          tip.textContent = bar.dataset.tip;
          const r = bar.getBoundingClientRect();
          tip.style.left = r.left + r.width / 2 + "px";
          tip.style.top = r.top + scrollY - 8 + "px";
          tip.hidden = false;
        });
        bar.addEventListener("pointerleave", () => (tip.hidden = true));
      }
    </script>`;
  return page("Admin", body);
}

const label = (kind) => ({ view: "Visit", download: "Download", buy: "Buy click", play: "Soundtrack" })[kind] || kind;

function tile(name, value, note = "") {
  return `<div class="tile"><p class="muted">${name}</p><p class="value">${value.toLocaleString("en-US")}</p>${note ? `<p class="muted small">${esc(note)}</p>` : ""}</div>`;
}

function bars(title, series, key) {
  const max = Math.max(1, ...series.map((d) => d[key]));
  const day = (d) => new Date(`${d}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  return `<figure class="chart">
    <figcaption>${title}</figcaption>
    <div class="plot">${series.map((d) => `<div class="bar" data-tip="${day(d.day)}: ${d[key]}"><i style="height:${(d[key] / max) * 100}%"></i></div>`).join("")}</div>
    <div class="axis"><span>${day(series[0].day)}</span><span>Today</span></div>
  </figure>`;
}

function list(title, rows, name, empty = "Nothing yet") {
  const max = Math.max(1, ...rows.map((r) => r.n));
  return `<div class="list"><h2>${title}</h2>${rows.length ? rows.map((r) => `
    <div class="row"><span class="fill" style="width:${(r.n / max) * 100}%"></span><span>${esc(name(r.name))}</span><span class="n">${r.n}</span></div>`).join("") : `<p class="muted">${empty}</p>`}</div>`;
}

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function page(title, body, status = 200) {
  return new Response(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${title} · KeyNav</title>
<link rel="icon" href="/icon.png?v=2">
<style>
  :root { --bg: #fafaf9; --text: #141416; --muted: #66666e; --line: rgba(0,0,0,.08); --card: #fff; --accent: #2f6bff; --soft: rgba(47,107,255,.12); }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #0e0e10; --text: #f3f3f5; --muted: #9a9aa4; --line: rgba(255,255,255,.09); --card: #18181b; --accent: #5b8cff; --soft: rgba(91,140,255,.16); }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; -webkit-font-smoothing: antialiased; }
  main { max-width: 1040px; margin: 0 auto; padding: 32px 16px 56px; }
  h1 { font-size: 22px; letter-spacing: -0.02em; margin: 0; }
  h2 { font-size: 15px; margin: 0 0 12px; }
  p { margin: 0; }
  .muted { color: var(--muted); }
  .small { font-size: 13px; margin-top: 4px; }
  button { font: inherit; border: 0; border-radius: 999px; padding: 10px 18px; background: var(--text); color: var(--bg); font-weight: 600; cursor: pointer; }
  button.quiet { background: none; color: var(--muted); padding: 6px 0; font-weight: 500; }
  header { display: flex; align-items: center; gap: 24px; margin-bottom: 28px; flex-wrap: wrap; }
  header form { margin-left: auto; }
  .range { display: flex; gap: 4px; background: var(--line); padding: 3px; border-radius: 999px; }
  .range a { padding: 5px 12px; border-radius: 999px; color: var(--muted); text-decoration: none; font-size: 14px; }
  .range a[aria-current] { background: var(--card); color: var(--text); box-shadow: 0 1px 2px rgba(0,0,0,.08); }
  section { margin-bottom: 16px; }
  .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
  .tile, .chart, .list, section:has(> .recent), section:has(> h2 + p) { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 20px; }
  .value { font-size: 32px; font-weight: 650; letter-spacing: -0.02em; margin-top: 4px; font-variant-numeric: tabular-nums; }
  .charts, .lists { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .chart { margin: 0; }
  figcaption { font-weight: 600; margin-bottom: 16px; }
  .plot { display: flex; align-items: flex-end; gap: 2px; height: 140px; border-bottom: 1px solid var(--line); }
  .bar { flex: 1; height: 100%; display: flex; align-items: flex-end; }
  .bar i { display: block; width: 100%; min-height: 0; background: var(--accent); border-radius: 4px 4px 0 0; }
  .bar:hover i { opacity: .75; }
  .axis { display: flex; justify-content: space-between; font-size: 12px; color: var(--muted); margin-top: 8px; }
  .tip { position: absolute; transform: translate(-50%, -100%); background: var(--text); color: var(--bg); font-size: 12px; padding: 4px 8px; border-radius: 6px; pointer-events: none; white-space: nowrap; }
  .row { position: relative; display: flex; justify-content: space-between; gap: 12px; padding: 6px 10px; margin: 0 -10px 2px; border-radius: 8px; overflow: hidden; }
  .row span { position: relative; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .row .fill { position: absolute; inset: 0 auto 0 0; background: var(--soft); border-radius: 8px; }
  .n { font-variant-numeric: tabular-nums; color: var(--muted); flex: none; }
  .recent { width: 100%; border-collapse: collapse; font-size: 14px; }
  .recent td { padding: 8px 12px 8px 0; border-top: 1px solid var(--line); vertical-align: top; }
  .recent tr:first-child td { border-top: 0; }
  .recent td:first-child { white-space: nowrap; color: var(--muted); width: 1%; }
  .recent td:nth-child(2) { white-space: nowrap; width: 1%; }
  .recent td:last-child { overflow-wrap: anywhere; padding-right: 0; }
  .foot { font-size: 13px; text-align: center; margin-top: 24px; }
  .login { max-width: 320px; margin: 18vh auto 0; display: grid; gap: 12px; }
  .login h1 { margin-bottom: 8px; }
  .login input { font: inherit; padding: 11px 14px; border: 1px solid var(--line); border-radius: 12px; background: var(--card); color: var(--text); }
  .error { color: #d33; font-size: 14px; }
  code { font: 13px ui-monospace, Menlo, monospace; }
  @media (max-width: 760px) {
    .tiles { grid-template-columns: 1fr 1fr; gap: 12px; }
    .charts, .lists { grid-template-columns: 1fr; }
    .value { font-size: 26px; }
  }
</style>
</head>
<body><main>${body}</main><div class="tip" hidden></div></body>
</html>`, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
      "content-security-policy": "frame-ancestors 'none'",
    },
  });
}
