#!/usr/bin/env bash
# Build the offline Webster's 1913 SQLite database shipped with omarchy-lookup.
#
# Source: Webster's Revised Unabridged Dictionary (1913), public domain, via
# Project Gutenberg / GCIDE. We consume the word->definition JSON compiled by
# matthewreagan/WebstersEnglishDictionary (data is public domain; that repo's
# parser is GPLv2 but we do not vendor any of its code, only the PD text).
#
# Output: data/webster1913.sqlite.xz  (compressed, committed to the repo)
# The runtime decompresses it to a cache dir on first use; see dict-lookup.
#
# Re-run this only to regenerate the shipped database. Requires: curl, sqlite3, xz.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="$here/data"
mkdir -p "$data_dir"

src_url="${WEBSTER_SRC_URL:-https://raw.githubusercontent.com/matthewreagan/WebstersEnglishDictionary/master/dictionary.json}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

json="$work/dictionary.json"
db="$work/webster1913.sqlite"

echo "==> Downloading Webster's 1913 source JSON"
curl -fsSL "$src_url" -o "$json"
bytes=$(wc -c <"$json")
echo "    got $bytes bytes"
[[ "$bytes" -gt 1000000 ]] || { echo "source download looks too small; aborting" >&2; exit 1; }

echo "==> Building SQLite database"
rm -f "$db"
sqlite3 "$db" <<SQL
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE entries (
  word       TEXT NOT NULL,   -- normalized (lowercased, trimmed) lookup key
  headword   TEXT NOT NULL,   -- original headword as written
  definition TEXT NOT NULL
);
INSERT INTO entries (word, headword, definition)
  SELECT lower(trim(key)), trim(key), value
  FROM json_each(readfile('$json'))
  WHERE typeof(value) = 'text' AND length(trim(key)) > 0;
CREATE INDEX idx_entries_word ON entries(word);
SQL

count=$(sqlite3 "$db" "SELECT count(*) FROM entries;")
echo "    indexed $count entries"
[[ "$count" -gt 50000 ]] || { echo "entry count too low; aborting" >&2; exit 1; }

echo "==> Sanity check ('dictionary')"
sqlite3 "$db" "SELECT substr(definition,1,80) FROM entries WHERE word='dictionary' LIMIT 1;"

echo "==> Compressing to data/webster1913.sqlite.xz"
xz -9 -e -T0 -c "$db" >"$data_dir/webster1913.sqlite.xz"
ls -la "$data_dir/webster1913.sqlite.xz"

echo "==> Done. Committed artifact: data/webster1913.sqlite.xz"
