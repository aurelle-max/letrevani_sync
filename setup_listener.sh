#!/bin/bash
# Letrevani Sync — Setup du Listener PostgreSQL NOTIFY
# Usage: bash setup_listener.sh <database_name> [db_user]
set -e

DB="${1:-letrevani-validation-final}"
DB_USER="${2:-odoo}"
INSTALL_DIR="/opt/letrevani-sync"
LOG_DIR="/var/log/letrevani-sync"

echo "╔══════════════════════════════════════════════╗"
echo "║  Letrevani Sync Listener Setup              ║"
echo "║  DB: $DB                                    "
echo "╚══════════════════════════════════════════════╝"

# Prérequis
echo ""
echo "[1/4] Verification des prerequis..."
if ! command -v psql &>/dev/null; then echo "❌ psql non trouve"; exit 1; fi
python3 -c "import psycopg2" 2>/dev/null || pip3 install psycopg2-binary --break-system-packages
echo "  ✅ OK"

# Créer les répertoires
echo ""
echo "[2/4] Creation des repertoires..."
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
chown "$DB_USER:$DB_USER" "$LOG_DIR" 2>/dev/null || true
echo "  ✅ $INSTALL_DIR"
echo "  ✅ $LOG_DIR"

# Copier le listener
echo ""
echo "[3/4] Installation du listener Python..."
cp "$(dirname "$0")/listener.py" "$INSTALL_DIR/listener.py" 2>/dev/null || cat > "$INSTALL_DIR/listener.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Letrevani Sync Listener — PostgreSQL NOTIFY en temps reel.
Genere automatiquement par setup_listener.sh
"""
import json, logging, os, sys, time
from datetime import datetime
from signal import SIGTERM, signal
import psycopg2

# Config (editable)
DB_NAME = 'letrevani-validation-final'
DB_USER = 'odoo'
LOG_DIR = '/var/log/letrevani-sync'
ALERT_LOG = os.path.join(LOG_DIR, 'alerts.jsonl')
EVENT_LOG = os.path.join(LOG_DIR, 'events.jsonl')
HEALTH_FILE = os.path.join(LOG_DIR, 'health.json')

# Etat
events, alerts = 0, 0
table_states = {}
table_owners = {}
active_sessions = {}

def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s',
        handlers=[logging.FileHandler(os.path.join(LOG_DIR, 'listener.log')), logging.StreamHandler()])

def load_ownership():
    global table_owners
    try:
        conn = psycopg2.connect(dbname=DB_NAME, user=DB_USER, host='/var/run/postgresql')
        cur = conn.cursor()
        cur.execute("""
            SELECT o.table_id, o.owner_pos_session_id, o.acquired_at
            FROM letrevani_table_ownership o
            JOIN restaurant_ai_session s ON s.id = o.owner_session_id
            WHERE s.state IN ('draft', 'open')""")
        for row in cur.fetchall():
            table_owners[row[0]] = {'owner_pos_session_id': row[1], 'acquired_at': str(row[2])}
        cur.close(); conn.close()
        logging.info(f"Ownerships: {len(table_owners)} tables")
    except Exception as e:
        logging.warning(f"Load ownership: {e}")

def write_health():
    h = {'status':'running', 'events':events, 'alerts':alerts,
         'last':datetime.now().isoformat(), 'sessions':len(active_sessions),
         'tables':len(table_states), 'ownerships':len(table_owners)}
    with open(HEALTH_FILE,'w') as f: json.dump(h,f)

def handle(ch, payload):
    global events, alerts
    try:
        d = json.loads(payload)
        if ch == 'letrevani_table':
            table_states[d.get('table_id')] = d.get('new_state')
        elif ch == 'letrevani_session':
            e, tid, psid = d.get('event'), d.get('table_id'), d.get('pos_session_id')
            if e == 'table_taken' and tid not in table_owners:
                table_owners[tid] = {'owner_pos_session_id': psid, 'acquired_at': d.get('ts')}
                logging.info(f"Owner table {d.get('table_number')} -> session {psid}")
            elif e == 'ownership_released':
                table_owners.pop(tid, None); active_sessions.pop(psid, None)
            elif e == 'table_freed':
                active_sessions.pop(psid, None)
            active_sessions[psid] = tid
        elif ch == 'letrevani_conflict':
            alerts += 1
            logging.warning(f"CONFLIT table {d.get('table_number')}: {d.get('message','?')}")
        events += 1
        if events % 10 == 0: write_health()
    except Exception as e:
        logging.error(f"Handler: {e}")

def main():
    setup_logging()
    load_ownership()
    write_health()
    while True:
        try:
            conn = psycopg2.connect(dbname=DB_NAME, user=DB_USER, host='/var/run/postgresql')
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
            cur = conn.cursor()
            for ch in ['letrevani_table','letrevani_session','letrevani_conflict']:
                cur.execute(f"LISTEN {ch};")
            logging.info("Listener demarre")
            while True:
                conn.poll()
                while conn.notifies:
                    n = conn.notifies.pop(0)
                    handle(n.channel, n.payload)
                time.sleep(0.1)
        except Exception as e:
            logging.error(f"Connection error: {e}")
            time.sleep(5)

if __name__ == '__main__':
    signal(SIGTERM, lambda *a: sys.exit(0))
    main()
PYEOF

chmod +x "$INSTALL_DIR/listener.py"
chown "$DB_USER:$DB_USER" "$INSTALL_DIR/listener.py"
echo "  ✅ $INSTALL_DIR/listener.py"

# Service systemd
echo ""
echo "[4/4] Creation du service systemd..."
cat > /etc/systemd/system/letrevani-listener.service << 'UNIT'
[Unit]
Description=Letrevani Sync Listener — PostgreSQL NOTIFY
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
ExecStart=/usr/bin/python3 /opt/letrevani-sync/listener.py
Restart=always
RestartSec=3
StandardOutput=append:/var/log/letrevani-sync/service.log
StandardError=append:/var/log/letrevani-sync/service.log

[Install]
WantedBy=multi-user.target
UNIT

# Injecter le nom de DB
sed -i "s/letrevani-validation-final/$DB/" "$INSTALL_DIR/listener.py"

systemctl daemon-reload
systemctl enable letrevani-listener
systemctl restart letrevani-listener

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ Letrevani Sync Listener installe         ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Service: letrevani-listener                  ║"
echo "║  Logs: $LOG_DIR                              "
echo "║  DB: $DB                                     "
echo "╚══════════════════════════════════════════════╝"
systemctl status letrevani-listener --no-pager -l 2>&1 | head -5
