#!/usr/bin/env bash
set -euo pipefail

ROLE="PIXELBOOK-EDGE"
VERSION="1.3.0"
HOME_DIR="${HOME:?HOME is required}"
BIN_DIR="$HOME_DIR/.local/bin"
SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
STATE_DIR="$HOME_DIR/.local/share/flowjuggle/pixelbook-edge"
KEY="$HOME_DIR/.ssh/pixelbook_edge_ed25519"
AGENT="$BIN_DIR/pixelbook-edge-agent"
PUBLIC_JOB_URL="https://raw.githubusercontent.com/flowjuggle/24flow-public/main/pixelbook-edge/job.json"
PUBLIC_RECEIPT_URL="https://jugglingballs.info/__flow/pixelbook-edge/heartbeat"
LAN_JOB_URL="http://192.168.1.179:8101/pixelbook-edge/job"
LAN_RECEIPT_URL="http://192.168.1.179:8101/pixelbook-edge/heartbeat"
EXPECTED_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJijTDgOeR6f9l65egy+VJ49R36XQkttnXVUJUIjWoNS pixelbook-edge@flowjuggle"

mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$HOME_DIR/.ssh" "$HOME_DIR/.cache" "$STATE_DIR/outbox"
chmod 700 "$HOME_DIR/.ssh" "$STATE_DIR" "$STATE_DIR/outbox"

if [ ! -f "$KEY" ]; then
  echo "PIXELBOOK_EDGE_KEY_MISSING: expected existing enrollment key at $KEY" >&2
  exit 12
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"
if [ "$(cat "$KEY.pub")" != "$EXPECTED_PUB" ]; then
  echo "PIXELBOOK_EDGE_KEY_MISMATCH: refusing unknown key" >&2
  exit 13
fi

cat > "$AGENT" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
VERSION="1.3.0"
KEY="$HOME/.ssh/pixelbook_edge_ed25519"
STATE="$HOME/.local/share/flowjuggle/pixelbook-edge"
OUTBOX="$STATE/outbox"
PUBLIC_JOB_URL="https://raw.githubusercontent.com/flowjuggle/24flow-public/main/pixelbook-edge/job.json"
PUBLIC_RECEIPT_URL="https://jugglingballs.info/__flow/pixelbook-edge/heartbeat"
LAN_JOB_URL="http://192.168.1.179:8101/pixelbook-edge/job"
LAN_RECEIPT_URL="http://192.168.1.179:8101/pixelbook-edge/heartbeat"
NS="flowjuggle-pixelbook-edge"
mkdir -p "$OUTBOX"
chmod 700 "$STATE" "$OUTBOX"

command -v python3 >/dev/null 2>&1 || exit 20
command -v curl >/dev/null 2>&1 || exit 21
command -v ssh-keygen >/dev/null 2>&1 || exit 22
[ -f "$KEY" ] || exit 23

fetch_job() {
  local tmp="$STATE/job.fetch.tmp"
  if curl -fsSL --max-time 15 --retry 1 "$PUBLIC_JOB_URL" -o "$tmp"; then
    if python3 - "$tmp" <<'PY'
import json,sys
p=sys.argv[1]
o=json.load(open(p,encoding='utf-8'))
assert o.get('schema')==1
assert o.get('source')=='RINGMASTER'
assert o.get('public_payload') is True
assert o.get('type') in {'heartbeat','http_probe'}
assert isinstance(o.get('targets') or [],list) and len(o.get('targets') or [])<=8
PY
    then
      mv "$tmp" "$STATE/queued-job.json"
      printf '%s\n' public_github > "$STATE/last-job-transport.txt"
      return 0
    fi
  fi
  rm -f "$tmp"
  if curl -fsSL --max-time 8 "$LAN_JOB_URL" -o "$tmp"; then
    if python3 - "$tmp" <<'PY'
import json,sys
p=sys.argv[1]
o=json.load(open(p,encoding='utf-8'))
assert o.get('schema')==1
assert o.get('source')=='RINGMASTER'
assert o.get('type') in {'heartbeat','http_probe'}
assert isinstance(o.get('targets') or [],list) and len(o.get('targets') or [])<=8
PY
    then
      mv "$tmp" "$STATE/queued-job.json"
      printf '%s\n' lan > "$STATE/last-job-transport.txt"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

post_envelope() {
  local f="$1"
  if curl -fsS --max-time 15 --retry 1 -H 'Content-Type: application/json' --data-binary "@$f" "$PUBLIC_RECEIPT_URL" >/dev/null 2>&1; then
    printf '%s\n' public_https > "$STATE/last-receipt-transport.txt"
    return 0
  fi
  if curl -fsS --max-time 10 --retry 1 -H 'Content-Type: application/json' --data-binary "@$f" "$LAN_RECEIPT_URL" >/dev/null 2>&1; then
    printf '%s\n' lan > "$STATE/last-receipt-transport.txt"
    return 0
  fi
  return 1
}

flush_outbox() {
  local f
  shopt -s nullglob
  for f in "$OUTBOX"/*.json; do
    if post_envelope "$f"; then
      rm -f "$f"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/last-upload-success.txt"
    else
      date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/last-upload-failure.txt"
      return 1
    fi
  done
  return 0
}

flush_outbox || true
online=0
if fetch_job; then online=1; fi
if [ ! -s "$STATE/queued-job.json" ]; then
  printf '%s\n' '{"schema":1,"job_id":"heartbeat-fallback","type":"heartbeat","targets":[],"source":"RINGMASTER","public_payload":true}' > "$STATE/queued-job.json"
fi

job_id="$(python3 - "$STATE/queued-job.json" <<'PY'
import json,sys
try:o=json.load(open(sys.argv[1],encoding='utf-8'));print(str(o.get('job_id',''))[:80])
except Exception:print('')
PY
)"
last="$(cat "$STATE/last-completed-job-id.txt" 2>/dev/null || true)"
if [ -n "$job_id" ] && [ "$job_id" = "$last" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/last-idempotent-skip.txt"
  exit 0
fi

job_type="$(python3 - "$STATE/queued-job.json" <<'PY'
import json,sys
try:o=json.load(open(sys.argv[1],encoding='utf-8'));print(str(o.get('type','heartbeat')))
except Exception:print('heartbeat')
PY
)"
if [ "$job_type" = "http_probe" ] && [ "$online" -ne 1 ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/last-deferred-offline.txt"
  exit 0
fi

result_json="$(JOB_FILE="$STATE/queued-job.json" TRANSPORT="$(cat "$STATE/last-job-transport.txt" 2>/dev/null || printf cache)" python3 - <<'PY'
import json, os, platform, socket, subprocess, time, urllib.parse
job=json.load(open(os.environ['JOB_FILE'],encoding='utf-8'))
allowed={
 'flowjuggle.com','www.flowjuggle.com','walkman.live','ptiv.live','nybeats.shop',
 'ruxballs.shop','ruxballs.blog','ruxballs.art','nymix.live','cassettes.bond',
 'jugglingballs.info','jugglingballs.live','jugglingballs.art','jugglingballs.org','jugglingballs.blog',
 'flowersticks.blog','flowersticks.live','flowersticks.net','jugglingclubs.live','jugglingclubs.art',
 'jugglingclubs.net','jugglingclubs.com','jugglingclubs.blog','diabolo.blog','diabolo.info','juggling.blog',
 'malabares.net','malabares.blog','malabares.info'
}
out={
 'schema':1,'role':'PIXELBOOK-EDGE','authority':'observer-verifier','agent_version':'1.3.0',
 'host':socket.gethostname(),'os':platform.system(),'machine':platform.machine(),'kernel':platform.release(),
 'observed_at':int(time.time()),'job_id':str(job.get('job_id','heartbeat'))[:80],
 'job_type':str(job.get('type','heartbeat'))[:40],'job_transport':os.environ.get('TRANSPORT','cache'),
 'store_forward':True,'checks':[]
}
if out['job_type']=='http_probe':
    for u in (job.get('targets') or [])[:8]:
        try:
            p=urllib.parse.urlsplit(str(u))
            if p.scheme!='https' or p.hostname not in allowed:
                out['checks'].append({'url':str(u)[:180],'accepted':False,'reason':'not_allowlisted'}); continue
            cp=subprocess.run(['curl','-L','-sS','-o','/dev/null','--max-time','20','-w','%{http_code}|%{time_total}',str(u)],text=True,capture_output=True,timeout=25)
            status,_,elapsed=(cp.stdout.strip() or '000|').partition('|')
            try: seconds=float(elapsed or 999)
            except Exception: seconds=999
            reachable=cp.returncode==0 and status.startswith(('2','3'))
            out['checks'].append({'url':str(u),'status':status,'seconds':elapsed,'accepted':reachable and seconds<=10.0,'reachable':reachable})
        except Exception as e:
            out['checks'].append({'url':str(u)[:180],'status':'000','accepted':False,'reachable':False,'reason':type(e).__name__})
out['accepted']=out['host']=='penguin' and out['os']=='Linux' and all(c.get('accepted',False) for c in out['checks'])
print(json.dumps(out,separators=(',',':'),sort_keys=True))
PY
)"

payload="$(mktemp)"; sigtmp="$(mktemp)"; envtmp="$(mktemp)"
printf '%s' "$result_json" > "$payload"
ssh-keygen -Y sign -f "$KEY" -n "$NS" "$payload" >/dev/null 2>&1
mv "$payload.sig" "$sigtmp"
python3 - "$payload" "$sigtmp" > "$envtmp" <<'PY'
import base64,json,pathlib,sys
enc=lambda p:base64.urlsafe_b64encode(pathlib.Path(p).read_bytes()).decode().rstrip('=')
print(json.dumps({'payload':enc(sys.argv[1]),'signature':enc(sys.argv[2])},separators=(',',':')))
PY
rm -f "$payload" "$sigtmp"
name="$(date -u +%Y%m%dT%H%M%SZ)-${job_id:-heartbeat}.json"
mv "$envtmp" "$OUTBOX/$name"
printf '%s\n' "$job_id" > "$STATE/last-completed-job-id.txt"
printf '%s\n' "$result_json" > "$STATE/last-result.json"
flush_outbox || true
AGENT
chmod 700 "$AGENT"

cat > "$SYSTEMD_DIR/pixelbook-edge.service" <<EOF
[Unit]
Description=Flow Juggle Pixelbook Edge verifier v1.3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadOnlyPaths=$KEY $KEY.pub
ReadWritePaths=$HOME_DIR/.cache $STATE_DIR
EOF

cat > "$SYSTEMD_DIR/pixelbook-edge.timer" <<'EOF'
[Unit]
Description=Run Flow Juggle Pixelbook Edge verifier every 5 minutes

[Timer]
OnBootSec=60s
OnUnitActiveSec=5min
Persistent=true
RandomizedDelaySec=20s

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now pixelbook-edge.timer
systemctl --user restart pixelbook-edge.service || true

echo "PIXELBOOK_EDGE_INSTALLED role=$ROLE version=$VERSION scheduler=systemd-user transport=public-github+store-forward"
systemctl --user --no-pager --full status pixelbook-edge.timer | sed -n '1,12p' || true
