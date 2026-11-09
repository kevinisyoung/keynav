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
