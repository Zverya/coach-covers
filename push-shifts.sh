#!/usr/bin/env bash
# Push a schedule TSV into the Supabase board so coaches can see it.
#
# Config lives in ~/.coach-covers/config.env (chmod 600), not in this file:
#   SUPABASE_URL=https://xxxx.supabase.co
#   SUPABASE_ANON_KEY=eyJ...
#   ADMIN_TOKEN=<the admin_token schema.sql printed>
#
# Usage:  ./push-shifts.sh ~/arbox-shifts/my-shifts.tsv

set -uo pipefail
CFG="${COACH_COVERS_CONFIG:-$HOME/.coach-covers/config.env}"
[ -f "$CFG" ] || { echo "no config at $CFG — see README" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG"
: "${SUPABASE_URL:?missing in config}" "${SUPABASE_ANON_KEY:?missing}" "${ADMIN_TOKEN:?missing}"

TSV="${1:-$HOME/arbox-shifts/my-shifts.tsv}"
[ -f "$TSV" ] || { echo "no such file: $TSV" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

BODY="$(python3 - "$TSV" "$ADMIN_TOKEN" <<'PY'
import sys, io, json
rows=[]
with io.open(sys.argv[1], encoding='utf-8') as f:
    header = f.readline()
    for line in f:
        line=line.rstrip('\n')
        if not line.strip(): continue
        p=line.split('\t')
        if len(p) < 5: continue
        d,t,box,cls,coach = p[0],p[1][:5],p[2],p[3],p[4]
        rows.append({"key": "%s|%s|%s" % (d, t, box.strip().lower()),
                     "date": d, "time": t, "box": box, "klass": cls, "coach": coach})
print(json.dumps({"p_admin": sys.argv[2], "p_shifts": rows}))
PY
)" || exit 1

COUNT="$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["p_shifts"]))')"
echo "pushing $COUNT shifts…"

RESP="$(curl -sS -m 45 -X POST "$SUPABASE_URL/rest/v1/rpc/push_shifts" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY")" || { echo "request failed" >&2; exit 1; }

echo "$RESP"
printf '%s' "$RESP" | grep -q '"ok":true' && echo "done." || { echo "push rejected — check ADMIN_TOKEN" >&2; exit 1; }
