#!/usr/bin/env bash
# =====================================================================
#  BusterNodes v5 - one-file installer (bot + panel are bundled)
#  Maintainer: Kaleem
#  usage:  sudo bash install.sh        (asks only: bot token + owner id)
#  Safe to run again: updates the bot, keeps config + database.
# =====================================================================
set +H
export PATH=$PATH:/snap/bin
[ "$(id -u)" = "0" ] || { echo "Run as root:  sudo bash install.sh"; exit 1; }
D=/opt/busternodes
OLDBOT=/opt/busternodes-bot
OKC(){ echo "  [OK]  $*"; }; BAD(){ echo "  [XX]  $*"; }
step(){ echo; echo "[$1/8] $2"; }
cat <<'B'
[1;35m
  ██████╗ ██╗   ██╗███████╗████████╗███████╗██████╗ ███╗   ██╗ ██████╗ ██████╗ ███████╗
  ██╔══██╗██║   ██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗████╗  ██║██╔═══██╗██╔══██╗██╔════╝
  ██████╔╝██║   ██║███████╗   ██║   █████╗  ██████╔╝██╔██╗ ██║██║   ██║██║  ██║█████╗
  ██╔══██╗██║   ██║╚════██║   ██║   ██╔══╝  ██╔══██╗██║╚██╗██║██║   ██║██║  ██║██╔══╝
  ██████╔╝╚██████╔╝███████║   ██║   ███████╗██║  ██║██║ ╚████║╚██████╔╝██████╔╝███████╗
  ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝
[0m
             [1;37mBUSTERNODES BUSTERNODES v5[0m
                  [1;35mPowered by Kaleem[0m

B
OLDCFG=""; for c in $D/config.json $OLDBOT/config.json; do [ -f "$c" ] && { OLDCFG="$c"; break; }; done
oldval(){ [ -n "$OLDCFG" ] && python3 -c "import json,sys;v=json.load(open('$OLDCFG')).get('$1','');print(v[0] if isinstance(v,list) and v else v)" 2>/dev/null; }
echo "Only two answers needed:"
DEF_TOKEN="$(oldval token)"; DEF_OWNER="$(oldval owner_ids)"
if [ -z "${TOKEN:-}" ]; then
  if [ -n "$DEF_TOKEN" ]; then read -rp "  1) Discord bot token [Enter = reuse the saved one]: " TOKEN; TOKEN="${TOKEN:-$DEF_TOKEN}"
  else read -rp "  1) Discord bot token: " TOKEN; fi
fi
if [ -z "${OWNER:-}" ]; then
  if [ -n "$DEF_OWNER" ]; then read -rp "  2) Your Discord user ID (main admin) [Enter = $DEF_OWNER]: " OWNER; OWNER="${OWNER:-$DEF_OWNER}"
  else read -rp "  2) Your Discord user ID (main admin): " OWNER; fi
fi
case "$OWNER" in ''|*[!0-9]*) echo "Owner ID must be numbers only."; exit 1;; esac
[ -n "$TOKEN" ] || { echo "Token is required."; exit 1; }

step 1 "system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-venv python3-pip curl snapd ufw openssh-client >/dev/null 2>&1 && OKC "packages ready" || BAD "apt had problems (continuing)"

step 2 "system limits (fixes 'Too many open files')"
cat > /etc/sysctl.d/99-busternodes.conf <<'E'
fs.inotify.max_user_instances=1024
fs.inotify.max_user_watches=524288
fs.file-max=2097152
E
sysctl --system >/dev/null 2>&1 || true
OKC "limits written"

step 3 "LXD (daemon, storage pool, network, image servers)"
command -v lxc >/dev/null 2>&1 || snap install lxd >/dev/null 2>&1
lxd waitready --timeout 90 2>/dev/null
[ -n "$(lxc storage list --format csv 2>/dev/null)" ] || lxd init --auto
POOL=$(lxc storage list --format csv 2>/dev/null | head -1 | cut -d, -f1)
lxc profile show default 2>/dev/null | grep -q 'root:' || lxc profile device add default root disk path=/ pool="$POOL" >/dev/null 2>&1
if lxc network list --format csv 2>/dev/null | grep -q lxdbr0; then
  lxc profile show default 2>/dev/null | grep -q 'eth0:' || lxc profile device add default eth0 nic network=lxdbr0 name=eth0 >/dev/null 2>&1
fi
lxc remote add ubuntu https://cloud-images.ubuntu.com/releases --protocol=simplestreams --public >/dev/null 2>&1
lxc remote add canon https://images.lxd.canonical.com --protocol=simplestreams --public >/dev/null 2>&1
lxc remote set-url images https://images.lxd.canonical.com >/dev/null 2>&1
for id in $(lxc operation list --format csv 2>/dev/null | cut -d, -f1); do lxc operation delete "$id" >/dev/null 2>&1; done
for n in $(lxc list -c n --format csv 2>/dev/null | grep -E '^bn-'); do lxc delete "$n" --force >/dev/null 2>&1; done
if lxc info >/dev/null 2>&1; then OKC "LXD ok, pool=$POOL"; else BAD "LXD not reachable: $(lxc info 2>&1 | head -1)"; fi

step 4 "stop every older bot so nothing old keeps running"
PAT='^(/[^ ]*/)?python[0-9.]*( +-[^ ]+)* +(\./)?(/[^ ]*/)?(bot|cloud)\.py( |$)'
for svc in busternodes-bot busternodes-cloud busternodes; do systemctl stop $svc 2>/dev/null; done
systemctl disable busternodes-bot busternodes-cloud >/dev/null 2>&1
for pid in $(pgrep -f "$PAT"); do
  case "$(readlink /proc/$pid/cwd)" in *busternodes*) kill -9 "$pid" 2>/dev/null; OKC "stopped old process $pid";; esac
done
sleep 2; OKC "old bots stopped (their VPS data is imported automatically)"

step 5 "installing BusterNodes into $D"
mkdir -p $D/static $D/templates
LINE=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0")
tail -n +"$LINE" "$0" | base64 -d | tar xz -C $D 2>/dev/null && OKC "bot files extracted" || { BAD "could not unpack the bundle (is install.sh complete?)"; exit 1; }
cd $D
[ -x venv/bin/python ] || python3 -m venv venv
./venv/bin/pip install -q --upgrade pip >/dev/null 2>&1
./venv/bin/pip install -q -r requirements.txt && OKC "python packages installed" || BAD "pip failed - check internet"
cd static
for f in "xterm.js xterm@5.3.0/lib/xterm.js" "xterm.css xterm@5.3.0/css/xterm.css" "xterm-addon-fit.js xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"; do
  set -- $f
  [ "$(stat -c%s $1 2>/dev/null || echo 0)" -gt 1000 ] || curl -sL -m 60 -o "$1" "https://cdn.jsdelivr.net/npm/$2"
  [ "$(stat -c%s $1 2>/dev/null || echo 0)" -gt 1000 ] || rm -f "$1"
done
OKC "terminal assets: $(ls | tr '\n' ' ')"
cd $D

step 6 "configuration"
IP=$(curl -s -m 8 ifconfig.me || hostname -I | awk '{print $1}')
TOKEN="$TOKEN" OWNER="$OWNER" IP="$IP" OLDCFG="$OLDCFG" python3 - <<'PY'
import json, os
D = "/opt/busternodes"
cfg = {"prefix": "!", "port": 5000, "brand": "BusterNodes", "maker": "Kaleem", "start_id": 110, "console_login": True,
       "link_hours": 12, "max_snapshots": 3, "max_ports": 5, "port_base": 21000, "enforce_host_limits": False, "smtp": None,
       "legacy_db": "/opt/busternodes-bot/busternodes.db"}
old = {}
for p in (D + "/config.json", os.environ.get("OLDCFG", "")):
    if p and os.path.exists(p):
        try: old = json.load(open(p)); break
        except Exception: pass
for k in ("prefix", "public_url", "smtp", "start_id", "console_login", "link_hours", "max_snapshots", "max_ports", "enforce_host_limits"):
    if old.get(k) is not None: cfg[k] = old[k]
ip = os.environ["IP"]
cfg.update(token=os.environ["TOKEN"], owner_ids=[int(os.environ["OWNER"])], host_ip=ip)
if not cfg.get("public_url") or "YOUR_" in cfg["public_url"]: cfg["public_url"] = f"http://{ip}:{cfg['port']}"
json.dump(cfg, open(D + "/config.json", "w"), indent=2); os.chmod(D + "/config.json", 0o600)
print("  [OK]  config.json written  (panel URL: %s)" % cfg["public_url"])
PY

step 7 "service (auto-start, auto-restart, big file limit)"
cat > /etc/systemd/system/busternodes.service <<U
[Unit]
Description=BusterNodes v5
After=network-online.target snap.lxd.daemon.service
[Service]
WorkingDirectory=$D
ExecStart=$D/venv/bin/python bot.py
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload 2>/dev/null; systemctl enable busternodes >/dev/null 2>&1; systemctl restart busternodes 2>/dev/null
ufw allow 5000/tcp >/dev/null 2>&1; ufw allow 21000:29999/tcp >/dev/null 2>&1
sleep 5
if systemctl is-active --quiet busternodes; then OKC "running via systemd"; else
  (ulimit -n 65535 2>/dev/null; cd $D && nohup ./venv/bin/python bot.py >> bot.log 2>&1 &); sleep 5; OKC "running via nohup (log: $D/bot.log)"
fi

step 8 "health check + doctor"
UP=0; for i in $(seq 1 20); do curl -s -m 3 "http://127.0.0.1:5000/health" | grep -q '"ok"' && { UP=1; break; }; sleep 2; done
[ "$UP" = "1" ] && OKC "panel answers on port 5000" || BAD "panel not answering - see: journalctl -u busternodes -n 30 --no-pager"
./venv/bin/python bot.py --doctor 2>&1 | grep -v '^$' | cut -c1-150

echo
echo "====================== BUSTERNODES READY ======================"
echo " Maintainer: Kaleem"
echo " Bot logs : journalctl -u busternodes -f"
echo " In Discord:"
echo "   create 8 2 20           -> VPS (8GB RAM, 2 CPU, 20GB disk) for yourself, OS menu opens"
echo "   create 8 2 20 @user     -> for another user"
echo "   manage                  -> buttons: power, console, SSH, reinstall, snapshots, ports"
echo "   pinggy token YOUR_TOKEN -> use your Pinggy token for SSH + web console from anywhere"
echo "   help                    -> everything else   (type them with your prefix, default is the exclamation mark)"

step 9 "installing BusterNodes command shortcuts"
cat > /usr/local/bin/bn <<'BNCLI'
#!/usr/bin/env bash
set -e
D=/opt/busternodes
SERVICE=busternodes
CFG="$D/config.json"
case "${1:-help}" in
  env|config|cfg)
    [ -f "$CFG" ] || { echo "Config not found: $CFG"; exit 1; }
    exec nano "$CFG"
    ;;
  restart|re) systemctl restart "$SERVICE" && echo "BusterNodes restarted." ;;
  start) systemctl start "$SERVICE" && echo "BusterNodes started." ;;
  stop) systemctl stop "$SERVICE" && echo "BusterNodes stopped." ;;
  status|st) systemctl status "$SERVICE" --no-pager -l ;;
  logs|log|l) journalctl -u "$SERVICE" -f ;;
  errors|err) journalctl -u "$SERVICE" -n 100 --no-pager ;;
  doctor|check) cd "$D" && ./venv/bin/python bot.py --doctor ;;
  panel|url)
    python3 - "$CFG" <<'PYCFG'
import json,sys
try:
 c=json.load(open(sys.argv[1])); print(c.get('public_url', 'Panel URL not configured'))
except Exception as e: print('Could not read config:',e)
PYCFG
    ;;
  backup|bk)
    mkdir -p /opt/busternodes-backups
    OUT="/opt/busternodes-backups/busternodes-$(date +%Y%m%d-%H%M%S).tar.gz"
    if [ -f /opt/busternodes-bot/busternodes.db ]; then
      tar -czf "$OUT" -C /opt busternodes/config.json busternodes-bot/busternodes.db
    else
      tar -czf "$OUT" -C /opt busternodes/config.json
    fi
    chmod 600 "$OUT"
    echo "Backup saved: $OUT"
    ;;
  help|--help|-h)
    cat <<'HELP'
BusterNodes quick commands:
  bn env       Edit config.json
  bn restart   Restart BusterNodes
  bn start     Start BusterNodes
  bn stop      Stop BusterNodes
  bn status    Show service status
  bn logs      Follow live logs
  bn errors    Show last 100 log lines
  bn doctor    Run built-in diagnostic
  bn panel     Show configured panel URL
  bn backup    Back up config and legacy database
  bn help      Show this help
HELP
    ;;
  *) echo "Unknown command: $1"; echo "Run: bn help"; exit 2 ;;
esac
BNCLI
chmod 755 /usr/local/bin/bn
OKC "CLI installed: run 'bn help'"
exit 0
__PAYLOAD_BELOW__
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
AQA=
