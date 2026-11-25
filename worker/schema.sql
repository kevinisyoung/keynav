-- keynav.app's own visit log. Run once: npx wrangler@4 d1 execute keynav-stats --remote --file worker/schema.sql
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,          -- milliseconds since 1970
  day TEXT NOT NULL,            -- YYYY-MM-DD, UTC
  kind TEXT NOT NULL,           -- view, download, update, play, buy
  path TEXT,
  ref TEXT,                     -- referring site, host only
  source TEXT,                  -- utm_source or ?ref=
  country TEXT,
  device TEXT,                  -- mac, iphone, ipad, android, windows, linux, other
  visitor TEXT,                 -- hash of the day, IP and browser; changes daily, so it can't follow anyone
  version TEXT                  -- the app's build, for update checks
);
CREATE INDEX IF NOT EXISTS events_day ON events (day, kind);

-- Reports the app sends when someone says KeyNav's labels or panes look wrong: no screenshots, only the shapes it saw.
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,          -- milliseconds since 1970
  day TEXT NOT NULL,            -- YYYY-MM-DD, UTC
  mode TEXT NOT NULL,           -- click, scroll
  level TEXT,                   -- layout, or names when it includes what the buttons are called
  app TEXT,                     -- the app's bundle id
  app_version TEXT,
  keynav TEXT,                  -- KeyNav's version
  build INTEGER,
  os TEXT,
  problem TEXT,                 -- scroll only: none, wrong, missing
  marked TEXT,                  -- the label, or the pane's number, the person pointed at
  note TEXT,
  visitor TEXT,                 -- the same daily hash as events
  data TEXT NOT NULL            -- the whole report, as sent
);
CREATE INDEX IF NOT EXISTS reports_day ON reports (day);
CREATE INDEX IF NOT EXISTS reports_app ON reports (app);
