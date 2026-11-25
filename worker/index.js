// keynav.app: the static site (build/site), plus a small visit log and the /admin page that reads it.
//
// The log keeps no cookies and no IP addresses. Each visitor is a hash of the day, their IP and their browser, so
// one person counts once a day and can't be followed from one day to the next.
//
// /admin asks for the password set with `npx wrangler@4 secret put ADMIN_PASSWORD`, then remembers this browser
// for 30 days with a signed cookie.
//
// The app posts to /api/report when someone says the labels or panes look wrong. A report is the shapes KeyNav saw,
// never a screenshot, and /admin/reports draws them back as a wireframe.

const BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|curl|wget|python|go-http|headless|lighthouse/i;
const KINDS = new Set(["view", "play", "buy"]);
const DAY = 86400000;
const REPORT_BYTES = 400 * 1024;
// A report arrives compressed; this is how big its JSON may be once opened (D1 holds up to 2 MB a row).
const REPORT_TEXT = 1800 * 1024;
const REPORTS_PER_DAY = 30;

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
    if (path === "/api/report" && request.method === "POST") return report(request, env);
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
  const visitor = await visitorOf(request, env, day);
  await env.STATS.prepare(
    "INSERT INTO events (ts, day, kind, path, ref, source, country, device, visitor, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(now, day, event.kind, event.path ?? null, event.ref ?? null, event.source ?? null,
    request.cf?.country || null, device(ua), visitor, event.version ?? null).run();
}

async function visitorOf(request, env, day) {
  const ua = request.headers.get("user-agent") || "";
  const ip = request.headers.get("cf-connecting-ip") || "";
  return (await sha256(`${day}|${ip}|${ua}|${env.STATS_SALT || "keynav"}`)).slice(0, 16);
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

// MARK: - Reports

async function report(request, env) {
  const answer = (status, error) => Response.json({ ok: false, error }, { status });
  if (Number(request.headers.get("content-length")) > REPORT_BYTES) return answer(413, "too large");
  let bytes = await request.arrayBuffer();
  if (bytes.byteLength > REPORT_BYTES) return answer(413, "too large");
  // The app compresses its reports (raw DEFLATE), since the window's tree makes them large.
  if (request.headers.get("x-keynav-encoding") === "deflate-raw") {
    try {
      bytes = await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).arrayBuffer();
    } catch {
      return answer(400, "couldn't open it");
    }
  }
  if (bytes.byteLength > REPORT_TEXT) return answer(413, "too large");
  const text = new TextDecoder().decode(bytes);
  let body;
  try { body = JSON.parse(text); } catch { return answer(400, "not JSON"); }
  if (body?.v !== 1 || !["click", "scroll"].includes(body.mode)) return answer(400, "needs v 1 and a mode of click or scroll");

  const now = Date.now();
  const day = new Date(now).toISOString().slice(0, 10);
  const visitor = await visitorOf(request, env, day);
  const sent = await env.STATS.prepare("SELECT COUNT(*) AS n FROM reports WHERE day = ? AND visitor = ?").bind(day, visitor).first("n");
  if (sent >= REPORTS_PER_DAY) return answer(429, "too many reports today");

  const short = (value, n = 100) => (typeof value === "string" || typeof value === "number" ? String(value).slice(0, n) : null);
  const result = await env.STATS.prepare(
    "INSERT INTO reports (ts, day, mode, level, app, app_version, keynav, build, os, problem, marked, note, visitor, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(now, day, body.mode, ["layout", "names"].includes(body.level) ? body.level : null,
    short(body.app?.bundle, 200), short(body.app?.version), short(body.keynav?.version),
    Number.isInteger(body.keynav?.build) ? body.keynav.build : null, short(body.os), short(body.problem, 20),
    short(body.marked, 20), short(body.note, 5000), visitor, text).run();
  return Response.json({ ok: true, id: result.meta.last_row_id }, { status: 201 });
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
  if (url.pathname === "/admin/reports") return reports(env, url);
  const one = url.pathname.match(/^\/admin\/reports\/(\d+)(\.json)?$/);
  if (one) return reportPage(env, Number(one[1]), Boolean(one[2]), url.searchParams.has("buyer"));
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
  const [daily, totals, refs, downloadRefs, countries, devices, versions, installs, recent] = (await env.STATS.batch([
    q(`SELECT day, COUNT(DISTINCT CASE WHEN kind = 'view' THEN visitor END) AS visitors,
              SUM(kind = 'download' AND device = 'Mac') AS downloads FROM events WHERE day >= ? GROUP BY day`, since),
    q(`SELECT SUM(kind = 'view') AS views, SUM(kind = 'download' AND device = 'Mac') AS downloads, SUM(kind = 'buy') AS buys,
              SUM(kind = 'play') AS plays FROM events WHERE day >= ?`, since),
    q(`SELECT COALESCE(source, ref) AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' AND COALESCE(source, ref) IS NOT NULL GROUP BY name ORDER BY n DESC LIMIT 12`, since),
    // A download comes from keynav.app itself, so it takes the source of that visitor's visit the same day.
    q(`SELECT COALESCE((SELECT COALESCE(v.source, v.ref) FROM events v
         WHERE v.kind = 'view' AND v.day = d.day AND v.visitor = d.visitor AND COALESCE(v.source, v.ref) IS NOT NULL
         ORDER BY v.ts LIMIT 1), 'Direct') AS name, COUNT(*) AS n
       FROM events d WHERE d.day >= ? AND d.kind = 'download' AND d.device = 'Mac' GROUP BY name ORDER BY n DESC LIMIT 12`, since),
    q(`SELECT country AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' AND country IS NOT NULL GROUP BY name ORDER BY n DESC LIMIT 12`, since),
    q(`SELECT device AS name, COUNT(DISTINCT day || visitor) AS n FROM events
       WHERE day >= ? AND kind = 'view' GROUP BY name ORDER BY n DESC`, since),
    q(`SELECT version AS name, COUNT(DISTINCT visitor) AS n FROM events
       WHERE ts >= ? AND kind = 'update' GROUP BY name ORDER BY n DESC`, Date.now() - DAY),
    q(`SELECT COUNT(DISTINCT visitor) AS n FROM events WHERE ts >= ? AND kind = 'update'`, Date.now() - DAY),
    q(`SELECT ts, kind, ref, source, country, device FROM events WHERE kind != 'update' AND (kind != 'download' OR device = 'Mac') ORDER BY ts DESC LIMIT 25`),
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
      <a class="quiet" href="/admin/reports">Reports</a>
      <form method="post" action="/admin/logout"><button class="quiet">Sign out</button></form>
    </header>
    <section class="tiles">
      ${tile("Visitors", visitors)}
      ${tile("Mac downloads", t.downloads || 0, `${rate} of visitors`)}
      ${tile("Buy clicks", t.buys || 0, "Sales are in Polar")}
      ${tile("Active installs", installs[0]?.n || 0, "Checked for updates today")}
    </section>
    <section class="charts">
      ${bars("Visitors per day", series, "visitors")}
      ${bars("Mac downloads per day", series, "downloads")}
    </section>
    <section class="lists">
      ${list("Where visitors come from", refs, (n) => n, "No referrers yet")}
      ${list("Where Mac downloads come from", downloadRefs, (n) => n, "No Mac downloads yet")}
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
      ${LOCAL_TIMES}
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

// Times are written in UTC and shown in the browser's own time zone.
const LOCAL_TIMES = `for (const t of document.querySelectorAll("time")) {
        const d = new Date(t.dateTime);
        t.textContent = d.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
      }`;

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

// MARK: - Reports pages

const MODES = { click: "Clicking", scroll: "Scrolling" };
const PROBLEMS = { none: "No panes", wrong: "Wrong pane", missing: "Missing pane" };

async function reports(env, url) {
  const app = url.searchParams.get("app");
  const columns = "id, ts, mode, level, app, app_version, keynav, build, problem, marked, note";
  const q = (sql, ...args) => env.STATS.prepare(sql).bind(...args);
  const [rows, apps] = (await env.STATS.batch([
    app ? q(`SELECT ${columns} FROM reports WHERE app = ? ORDER BY ts DESC LIMIT 200`, app)
      : q(`SELECT ${columns} FROM reports ORDER BY ts DESC LIMIT 200`),
    q(`SELECT app AS name, COUNT(*) AS n FROM reports WHERE app IS NOT NULL GROUP BY app ORDER BY n DESC LIMIT 30`),
  ])).map((r) => r.results);

  const body = `
    <header>
      <h1>Reports</h1>
      <a class="quiet" href="/admin">Dashboard</a>
    </header>
    ${apps.length ? `<nav class="filters">
      <a href="/admin/reports"${app ? "" : ' aria-current="true"'}>All</a>
      ${apps.map((a) => `<a href="?app=${encodeURIComponent(a.name)}"${a.name === app ? ' aria-current="true"' : ""}>${esc(a.name)} <span class="n">${a.n}</span></a>`).join("")}
    </nav>` : ""}
    <section class="card">
      ${rows.length ? `<table class="reports">
        <thead><tr><th>Time</th><th>Mode</th><th>App</th><th>Marked</th><th>Note</th><th>Level</th><th>KeyNav</th></tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td><a href="/admin/reports/${r.id}"><time datetime="${new Date(r.ts).toISOString()}"></time></a></td>
          <td>${esc(MODES[r.mode] || r.mode)}</td>
          <td>${esc(r.app || "–")} <span class="muted">${esc(r.app_version || "")}</span></td>
          <td>${esc(marking(r))}</td>
          <td class="note">${esc(r.note && r.note.length > 140 ? `${r.note.slice(0, 140)}…` : r.note || "")}</td>
          <td class="muted">${esc(r.level || "–")}</td>
          <td class="muted">${esc(r.keynav || "–")}</td>
        </tr>`).join("")}</tbody></table>` : `<p class="muted">No reports${app ? " for this app" : ""} yet.</p>`}
    </section>
    <script>${LOCAL_TIMES}</script>`;
  return page("Reports", body);
}

// What the person pointed at: a label in Clicking, or a problem and a pane's number in Scrolling.
function marking(r) {
  const marked = r.marked == null || r.marked === "" ? null : r.marked;
  if (r.mode === "scroll") return [PROBLEMS[r.problem] || r.problem, marked && `Pane ${marked}`].filter(Boolean).join(" · ") || "–";
  return marked || "–";
}

// The buyer behind a report from a licensed copy. The app sends a hash of its license key, never the key; Polar
// lists the keys (with the token set by `npx wrangler@4 secret put POLAR_TOKEN`, scope license_keys:read), and the
// one whose hash matches names the customer.
const POLAR_ORGANIZATION = "8be57bc9-de0f-45dd-a63d-2498ea780371";

async function buyerOf(env, license) {
  if (!license?.keyHash) return { error: "This copy had no license (a trial, or built from source)." };
  if (!env.POLAR_TOKEN) return { error: "Set a Polar token first: npx wrangler@4 secret put POLAR_TOKEN" };
  for (let pageNumber = 1; pageNumber <= 50; pageNumber++) {
    const reply = await fetch(`https://api.polar.sh/v1/license-keys/?organization_id=${POLAR_ORGANIZATION}&limit=100&page=${pageNumber}`, {
      headers: { authorization: `Bearer ${env.POLAR_TOKEN}`, accept: "application/json" },
    });
    if (!reply.ok) return { error: `Polar answered ${reply.status}.` };
    const { items = [], pagination = {} } = await reply.json();
    for (const item of items) {
      if (item.key && (await sha256(item.key)) === license.keyHash) {
        return { email: item.customer?.email, name: item.customer?.name, key: item.display_key };
      }
    }
    if (!pagination.max_page || pageNumber >= pagination.max_page) break;
  }
  return { error: "No license on Polar matches this report." };
}

async function reportPage(env, id, json, lookUpBuyer = false) {
  const row = await env.STATS.prepare("SELECT * FROM reports WHERE id = ?").bind(id).first();
  if (!row) return page("Report", `<p class="muted">There's no report ${id}. <a href="/admin/reports">All reports</a></p>`, 404);
  if (json) {
    return new Response(row.data, {
      headers: { "content-type": "application/json; charset=utf-8", "content-disposition": `attachment; filename="keynav-report-${id}.json"`, "cache-control": "no-store" },
    });
  }
  let data;
  try { data = JSON.parse(row.data); } catch { data = {}; }
  const pane = row.mode === "scroll" ? data.scroll : data.click;
  const search = pane && [
    pane.visited != null && `${pane.visited} elements`,
    pane.ms != null && `${pane.ms} ms`,
    (pane.truncated || pane.timedOut) && "stopped early",
    row.mode === "click" && Array.isArray(pane.targets) && `${pane.targets.length} labels`,
    row.mode === "scroll" && Array.isArray(pane.areas) && `${pane.areas.length} panes`,
  ].filter(Boolean).join(" · ");
  const facts = [
    ["Sent", `<time datetime="${new Date(row.ts).toISOString()}"></time>`],
    ["Mode", esc([MODES[row.mode] || row.mode, row.level].filter(Boolean).join(" · "))],
    ["App", esc([row.app, row.app_version].filter(Boolean).join(" ") || "–")],
    ["KeyNav", esc([row.keynav, row.build != null && `build ${row.build}`, data.keynav?.store === true ? "keynav.app copy" : data.keynav?.store === false ? "built from source" : null].filter(Boolean).join(" · ") || "–")],
    ["macOS", esc(row.os || "–")],
    ["Marked", esc(marking(row))],
    ["Scan", esc(search || "–")],
  ];
  // Who sent it, only when asked: a licensed copy can be traced to its buyer, so they can hear it's fixed.
  if (data.license?.keyHash) {
    if (lookUpBuyer) {
      const buyer = await buyerOf(env, data.license);
      const subject = `Fixed: the ${MODES[row.mode] || row.mode} problem you reported in ${row.app || "an app"}`;
      facts.push(["Buyer", buyer.email
        ? `${esc(buyer.name || "")} <a href="mailto:${esc(buyer.email)}?subject=${encodeURIComponent(subject)}">${esc(buyer.email)}</a>`
        : `<span class="muted">${esc(buyer.error)}</span>`]);
    } else {
      facts.push(["Buyer", `<a href="/admin/reports/${id}?buyer">Look up who sent it</a>`]);
    }
  } else {
    facts.push(["Buyer", `<span class="muted">No license (trial or built from source)</span>`]);
  }
  const scene = wireframe(data);
  const body = `
    <header>
      <h1>Report ${id}</h1>
      <a class="quiet" href="/admin/reports${row.app ? `?app=${encodeURIComponent(row.app)}` : ""}">Reports</a>
    </header>
    <section class="card">
      <dl class="facts">${facts.map(([k, v]) => `<div><dt class="muted">${k}</dt><dd>${v}</dd></div>`).join("")}</dl>
      ${row.note ? `<p class="said">${esc(row.note)}</p>` : ""}
    </section>
    <section class="card">
      ${scene ? `${scene}${legend(row.mode)}` : `<p class="muted">Nothing to draw.</p>`}
    </section>
    <section class="card">
      <details>
        <summary>JSON</summary>
        <pre>${esc(JSON.stringify(data, null, 2))}</pre>
      </details>
      <p class="small"><a href="/admin/reports/${id}.json">Download JSON</a></p>
    </section>
    <script>${LOCAL_TIMES}</script>`;
  return page("Report", body);
}

// MARK: - Wireframe

// Rects are [x, y, w, h] and points [x, y], in global screen points with the origin at the top left. Anything else
// a report sends in their place is left out of the drawing.
const isRect = (r) => Array.isArray(r) && r.length === 4 && r.every((n) => Number.isFinite(n)) && r[2] >= 0 && r[3] >= 0;
const isPoint = (p) => Array.isArray(p) && p.length === 2 && p.every((n) => Number.isFinite(n));
const arr = (value) => (Array.isArray(value) ? value : []);
const showRect = (r) => (isRect(r) ? `${r.map((n) => Math.round(n)).slice(0, 2).join(", ")}, ${Math.round(r[2])} × ${Math.round(r[3])}` : "none");
const contains = (r, p) => p[0] >= r[0] && p[0] <= r[0] + r[2] && p[1] >= r[1] && p[1] <= r[1] + r[3];
const bySize = (rect) => (a, b) => (rect(b)?.[2] * rect(b)?.[3] || 0) - (rect(a)?.[2] * rect(a)?.[3] || 0);

// Draws the scene around the window, widened to take in anything that fell outside it, but never past the
// displays, so a stray rect far off screen can't shrink everything else to a speck.
function wireframe(data) {
  const click = data.click || {};
  const scroll = data.scroll || {};
  const targets = arr(click.targets).filter((t) => t && typeof t === "object");
  const candidates = arr(scroll.candidates).filter((c) => c && isRect(c.rect));
  const rects = [data.window, ...targets.flatMap((t) => [t.frame, t.chip]), ...arr(click.unlabelled).map((u) => u?.frame),
    ...arr(scroll.areas), scroll.outlined, ...arr(scroll.scrollAreas), ...candidates.map((c) => c.rect)].filter(isRect);
  const points = [data.pointer, ...targets.map((t) => t.point)].filter(isPoint);
  for (const p of points) rects.push([p[0], p[1], 0, 0]);
  if (!rects.length) return null;

  let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
  for (const r of rects) [x0, y0, x1, y1] = [Math.min(x0, r[0]), Math.min(y0, r[1]), Math.max(x1, r[0] + r[2]), Math.max(y1, r[1] + r[3])];
  const displays = arr(data.displays).map((d) => d?.frame).filter(isRect);
  if (displays.length) {
    x0 = Math.max(x0, Math.min(...displays.map((d) => d[0])));
    y0 = Math.max(y0, Math.min(...displays.map((d) => d[1])));
    x1 = Math.min(x1, Math.max(...displays.map((d) => d[0] + d[2])));
    y1 = Math.min(y1, Math.max(...displays.map((d) => d[1] + d[3])));
  }
  const margin = 24;
  x0 -= margin; y0 -= margin; x1 += margin; y1 += margin;
  const scale = Math.min(1000 / Math.max(1, x1 - x0), 1400 / Math.max(1, y1 - y0));
  const width = Math.round((x1 - x0) * scale);
  const height = Math.round((y1 - y0) * scale);
  const n = (v) => Math.round(v * 10) / 10;
  const X = (x) => n((x - x0) * scale);
  const Y = (y) => n((y - y0) * scale);
  const box = (r, cls) => `<rect class="${cls}" x="${X(r[0])}" y="${Y(r[1])}" width="${n(r[2] * scale)}" height="${n(r[3] * scale)}"/>`;
  const title = (lines) => `<title>${esc(lines.filter(Boolean).join("\n"))}</title>`;

  const out = [...displays.map((d) => box(d, "display"))];
  if (isRect(data.window)) out.push(box(data.window, "window"));

  if (data.mode === "click") {
    for (const u of arr(click.unlabelled).filter((u) => isRect(u?.frame)).sort(bySize((u) => u.frame))) {
      out.push(`<g>${title([`Unlabelled ${u.role || ""}`, `frame ${showRect(u.frame)}`])}${box(u.frame, "unlabelled")}</g>`);
    }
    const tip = (t) => title([
      [t.label, t.role, t.name != null && `“${t.name}”`].filter(Boolean).join(" "),
      `frame ${showRect(t.frame)}`,
      t.hit ? `hit ${t.hit.ok === false ? "missed" : "ok"}: ${[t.hit.role, t.hit.relation].filter(Boolean).join(", ")} at ${showRect(t.hit.frame)}` : "hit not checked",
    ]);
    const miss = (t) => (t.hit?.ok === false ? " miss" : "");
    const sorted = [...targets].sort(bySize((t) => (isRect(t.frame) ? t.frame : null)));
    for (const t of sorted.filter((t) => isRect(t.frame))) {
      out.push(`<g>${tip(t)}${box(t.frame, `frame${miss(t)}`)}${miss(t) && isRect(t.hit?.frame) ? box(t.hit.frame, "hit") : ""}</g>`);
    }
    for (const t of targets.filter((t) => isPoint(t.point))) {
      const p = t.point;
      if (isRect(t.chip) && !contains(t.chip, p)) {
        out.push(`<line class="leader${miss(t)}" x1="${X(t.chip[0] + t.chip[2] / 2)}" y1="${Y(t.chip[1] + t.chip[3] / 2)}" x2="${X(p[0])}" y2="${Y(p[1])}"/>`);
      }
    }
    for (const t of targets.filter((t) => isRect(t.chip))) {
      const c = t.chip;
      const size = n(Math.min(12, Math.max(7, c[3] * scale * 0.62)));
      out.push(`<g>${tip(t)}${box(c, `chip${miss(t)}`)}<text class="chip-text" x="${X(c[0] + c[2] / 2)}" y="${Y(c[1] + c[3] / 2)}" font-size="${size}">${esc(t.label)}</text></g>`);
    }
    for (const t of targets.filter((t) => isPoint(t.point))) {
      out.push(`<circle class="dot${miss(t)}" cx="${X(t.point[0])}" cy="${Y(t.point[1])}" r="2"/>`);
    }
    const marked = data.marked != null && targets.find((t) => t.label === String(data.marked) && isRect(t.frame));
    if (marked) out.push(`<g>${tip(marked)}${box(marked.frame, "marked")}</g>`);
  } else {
    for (const r of arr(scroll.scrollAreas).filter(isRect)) out.push(box(r, "scrollarea"));
    const areas = arr(scroll.areas);
    const picked = Number.isInteger(data.marked) ? data.marked - 1 : -1;
    areas.forEach((r, i) => {
      if (!isRect(r)) return;
      const cls = i === picked ? "area picked" : "area";
      out.push(`<g>${title([`Pane ${i + 1}${i === picked ? ", marked" : ""}${i === scroll.areaIndex ? ", outlined" : ""}`, `rect ${showRect(r)}`])}${box(r, cls)}</g>`);
    });
    // Dropped candidates go over the panes, so hovering one shows why it was dropped.
    for (const c of candidates.filter((c) => !c.kept).sort(bySize((c) => c.rect))) {
      out.push(`<g>${title([`Dropped: ${c.reason || "no reason given"}`, `rect ${showRect(c.rect)}`, isRect(c.page) && `page ${showRect(c.page)}`,
        isRect(c.pane) && `pane ${showRect(c.pane)}`, c.scrolls != null && `scrolls ${c.scrolls ? "yes" : "no"}`])}${box(c.rect, "dropped")}</g>`);
    }
    if (isRect(scroll.outlined)) out.push(box(scroll.outlined, "outlined"));
    areas.forEach((r, i) => {
      if (!isRect(r)) return;
      out.push(`<rect class="badge" x="${X(r[0]) + 2}" y="${Y(r[1]) + 2}" width="${String(i + 1).length * 7 + 8}" height="15" rx="4"/><text class="badge-text" x="${X(r[0]) + 6}" y="${Y(r[1]) + 13}">${i + 1}</text>`);
    });
  }
  if (isPoint(data.pointer)) {
    out.push(`<g>${title([`Pointer ${data.pointer.map(Math.round).join(", ")}`])}<circle class="pointer" cx="${X(data.pointer[0])}" cy="${Y(data.pointer[1])}" r="5"/></g>`);
  }
  return `<svg class="wf scene" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="Wireframe of the report">${out.join("")}</svg>`;
}

function legend(mode) {
  const key = (shape, name) => `<span><svg class="wf" width="22" height="14" viewBox="0 0 22 14">${shape}</svg>${name}</span>`;
  const rect = (cls) => `<rect class="${cls}" x="2" y="2" width="18" height="10"/>`;
  const keys = mode === "click" ? [
    key(rect("frame"), "Target"),
    key(`<rect class="chip" x="3" y="2" width="16" height="10"/>`, "Label"),
    key(`<circle class="dot" cx="11" cy="7" r="2"/>`, "Click point"),
    key(rect("frame miss"), "Misses its target"),
    key(rect("hit"), "What the click hit"),
    key(rect("marked"), "Marked"),
    key(rect("unlabelled"), "Unlabelled"),
  ] : [
    key(rect("area"), "Pane"),
    key(rect("outlined"), "Outlined"),
    key(rect("area picked"), "Marked"),
    key(rect("dropped"), "Dropped candidate"),
    key(rect("scrollarea"), "Scroll area"),
  ];
  keys.push(key(`<circle class="pointer" cx="11" cy="7" r="4"/>`, "Pointer"), key(rect("window"), "Window"));
  return `<p class="legend muted">${keys.join("")}</p>`;
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
  a { color: var(--accent); }
  a.quiet { color: var(--muted); text-decoration: none; font-weight: 500; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 20px; overflow-x: auto; }
  .filters { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; }
  .filters a { padding: 5px 12px; border-radius: 999px; background: var(--line); color: var(--muted); text-decoration: none; font-size: 14px; }
  .filters a[aria-current] { background: var(--text); color: var(--bg); }
  .filters a[aria-current] .n { color: inherit; opacity: .7; }
  .reports { width: 100%; border-collapse: collapse; font-size: 14px; }
  .reports th { text-align: left; font-weight: 500; color: var(--muted); padding: 0 12px 8px 0; }
  .reports td { padding: 8px 12px 8px 0; border-top: 1px solid var(--line); vertical-align: top; white-space: nowrap; }
  .reports td.note { white-space: normal; overflow-wrap: anywhere; min-width: 200px; }
  .facts { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px 24px; margin: 0; }
  .facts dd { margin: 2px 0 0; overflow-wrap: anywhere; }
  .facts dt { font-size: 13px; }
  .said { margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--line); white-space: pre-wrap; overflow-wrap: anywhere; }
  summary { cursor: pointer; font-weight: 600; }
  pre { font: 12px/1.5 ui-monospace, Menlo, monospace; overflow: auto; max-height: 600px; margin: 12px 0 0; }
  details + .small { margin-top: 12px; }
  .scene { display: block; max-width: 100%; height: auto; margin: 0 auto; }
  .legend { display: flex; flex-wrap: wrap; gap: 8px 18px; font-size: 13px; margin-top: 16px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .wf rect, .wf circle { vector-effect: non-scaling-stroke; }
  .wf .display { fill: none; stroke: var(--line); }
  .wf .window { fill: var(--bg); stroke: var(--muted); stroke-width: 1; pointer-events: none; }
  .wf .frame, .wf .area { fill: transparent; stroke: var(--muted); stroke-width: 1; pointer-events: all; }
  .wf .area { stroke: var(--text); stroke-width: 1.5; }
  .wf .miss { stroke: #e5484d; }
  .wf .hit { fill: none; stroke: #e5484d; stroke-dasharray: 2 2; stroke-width: 1; }
  .wf .marked, .wf .outlined { fill: none; stroke: var(--accent); stroke-width: 3; }
  .wf .outlined { pointer-events: none; }
  .wf .unlabelled { fill: transparent; stroke: #999; stroke-dasharray: 4 3; pointer-events: all; }
  .wf .chip { fill: #fff3a6; stroke: #c9a400; stroke-width: 1; }
  .wf .chip.miss { stroke: #e5484d; stroke-width: 1.5; }
  .wf .chip-text { fill: #141416; font-family: ui-monospace, Menlo, monospace; font-weight: 600; text-anchor: middle; dominant-baseline: central; pointer-events: none; }
  .wf .leader { stroke: var(--muted); stroke-width: .75; }
  .wf .leader.miss { stroke: #e5484d; }
  .wf .dot { fill: var(--text); }
  .wf .dot.miss { fill: #e5484d; }
  .wf .pointer { fill: none; stroke: var(--text); stroke-width: 2; }
  .wf .scrollarea { fill: var(--soft); }
  .wf .dropped { fill: transparent; stroke: var(--muted); stroke-dasharray: 6 4; stroke-width: 1; pointer-events: all; }
  .wf .picked { fill: rgba(255,159,10,.16); stroke: #ff9f0a; stroke-width: 2.5; }
  .wf .badge { fill: var(--text); }
  .wf .badge-text { fill: var(--bg); font: 600 11px -apple-system, sans-serif; pointer-events: none; }
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
