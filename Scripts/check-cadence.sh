#!/bin/bash
# Shows how far apart the recorded samples actually are, so the Section 5.1 cadence
# can be checked against reality rather than against the setting that requested it.
DB="$HOME/Library/Application Support/PowerTask/history.sqlite"
[ -f "$DB" ] || { echo "No history database yet — run PowerTask first."; exit 1; }

echo "Last 20 samples (newest first):"
sqlite3 "$DB" "
SELECT datetime(timestamp,'unixepoch','localtime') AS at,
       COALESCE(timestamp - LAG(timestamp) OVER (ORDER BY timestamp), 0) || 's gap' AS gap,
       power_source
FROM (SELECT * FROM battery_sample ORDER BY timestamp DESC LIMIT 20)
ORDER BY timestamp DESC;"

echo
echo "How often each interval occurred:"
sqlite3 "$DB" "
SELECT gap || 's' AS interval, COUNT(*) AS times FROM (
  SELECT timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS gap FROM battery_sample
) WHERE gap IS NOT NULL GROUP BY gap ORDER BY gap;"
