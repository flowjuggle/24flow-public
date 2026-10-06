#!/usr/bin/env bash
set -euo pipefail

KEY="$HOME/.ssh/pixelbook_edge_ed25519"
REMOTE="FlowK@192.168.1.186"
STATE="$HOME/.local/share/flowjuggle/pixelbook-edge"
BIN="$HOME/.local/bin"
SYSTEMD="$HOME/.config/systemd/user"

mkdir -p "$STATE" "$BIN" "$SYSTEMD" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$KEY" ]]; then
  echo "ERROR: expected existing Pixelbook key at $KEY" >&2
  exit 2
fi
chmod 600 "$KEY"

cat > "$BIN/pixelbook-edge-agent" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
KEY="$HOME/.ssh/pixelbook_edge_ed25519"
REMOTE="FlowK@192.168.1.186"
STATE="$HOME/.local/share/flowjuggle/pixelbook-edge"
mkdir -p "$STATE"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new "$REMOTE")
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if "${SSH[@]}" heartbeat > "$STATE/heartbeat-latest.json.tmp"; then
  mv "$STATE/heartbeat-latest.json.tmp" "$STATE/heartbeat-latest.json"
  printf '%s\n' "$now" > "$STATE/last-success.txt"
else
  rm -f "$STATE/heartbeat-latest.json.tmp"
  printf '%s\n' "$now" > "$STATE/last-failure.txt"
  exit 1
fi
if "${SSH[@]}" checkpoint > "$STATE/ringmaster-checkpoint.json.tmp"; then
  if [[ -s "$STATE/ringmaster-checkpoint.json.tmp" ]]; then
    mv "$STATE/ringmaster-checkpoint.json.tmp" "$STATE/ringmaster-checkpoint.json"
  else
    rm -f "$STATE/ringmaster-checkpoint.json.tmp"
  fi
else
  rm -f "$STATE/ringmaster-checkpoint.json.tmp"
fi
AGENT
chmod 700 "$BIN/pixelbook-edge-agent"

cat > "$SYSTEMD/pixelbook-edge.service" <<EOF
[Unit]
Description=FlowJuggle Pixelbook Edge observer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN/pixelbook-edge-agent
EOF

cat > "$SYSTEMD/pixelbook-edge.timer" <<'EOF'
[Unit]
Description=Run FlowJuggle Pixelbook Edge observer every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300
Persistent=true
RandomizedDelaySec=15

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now pixelbook-edge.timer
"$BIN/pixelbook-edge-agent"

echo "PIXELBOOK_EDGE_INSTALLED"
echo "ROLE=observer-verifier"
echo "REMOTE=$REMOTE"
systemctl --user --no-pager --full status pixelbook-edge.timer | sed -n '1,10p'
echo "HEARTBEAT:"
cat "$STATE/heartbeat-latest.json"
