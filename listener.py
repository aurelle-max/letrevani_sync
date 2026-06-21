#!/usr/bin/env python3
"""
Letrevani Sync Listener — PostgreSQL NOTIFY en temps reel.
Copie par setup_listener.sh ou manuellement.
"""
import json, logging, os, sys, time
from datetime import datetime
from signal import SIGTERM, signal
import psycopg2

# --- Configuration (editer si necessaire) ---
DB_NAME = 'letrevani-validation-final'
DB_USER = 'odoo'
LOG_DIR = '/var/log/letrevani-sync'
ALERT_LOG = os.path.join(LOG_DIR, 'alerts.jsonl')
EVENT_LOG = os.path.join(LOG_DIR, 'events.jsonl')
HEALTH_FILE = os.path.join(LOG_DIR, 'health.json')

# --- Etat interne ---
events, alerts = 0, 0
table_states = {}
table_owners = {}
active_sessions = {}

def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s',
        handlers=[
            logging.FileHandler(os.path.join(LOG_DIR, 'listener.log')),
            logging.StreamHandler()
        ]
    )

def load_ownership():
    global table_owners
    try:
        conn = psycopg2.connect(dbname=DB_NAME, user=DB_USER, host='/var/run/postgresql')
        cur = conn.cursor()
        cur.execute("""
            SELECT o.table_id, o.owner_pos_session_id, o.acquired_at
            FROM letrevani_table_ownership o
            JOIN restaurant_ai_session s ON s.id = o.owner_session_id
            WHERE s.state IN ('draft', 'open')
        """)
        for row in cur.fetchall():
            table_owners[row[0]] = {
                'owner_pos_session_id': row[1],
                'acquired_at': str(row[2]) if row[2] else '?',
            }
        cur.close()
        conn.close()
        logging.info(f"Ownerships chargees: {len(table_owners)} tables")
    except Exception as e:
        logging.warning(f"Impossible de charger les ownerships: {e}")

def write_health():
    health = {
        'status': 'running',
        'events': events,
        'alerts': alerts,
        'last_heartbeat': datetime.now().isoformat(),
        'sessions': len(active_sessions),
        'tables': len(table_states),
        'ownerships': len(table_owners),
    }
    with open(HEALTH_FILE, 'w') as f:
        json.dump(health, f)

def handle_notification(channel, payload):
    global events, alerts
    try:
        data = json.loads(payload)
        
        if channel == 'letrevani_table':
            table_states[data.get('table_id')] = data.get('new_state')
        
        elif channel == 'letrevani_session':
            event = data.get('event')
            tid = data.get('table_id')
            psid = data.get('pos_session_id')
            
            if event == 'table_taken' and tid and tid not in table_owners:
                table_owners[tid] = {
                    'owner_pos_session_id': psid,
                    'acquired_at': data.get('ts', 'now'),
                }
                logging.info(f"Owner table #{data.get('table_number')} -> session {psid}")
            elif event == 'ownership_released':
                table_owners.pop(tid, None)
                active_sessions.pop(psid, None)
            elif event == 'table_freed':
                table_owners.pop(tid, None)
                active_sessions.pop(psid, None)
            
            active_sessions[psid] = tid
        
        elif channel == 'letrevani_conflict':
            alerts += 1
            logging.warning(f"CONFLIT table {data.get('table_number')}: "
                          f"{json.dumps(data, ensure_ascii=False)[:100]}")
        
        events += 1
        if events % 10 == 0:
            write_health()
    except json.JSONDecodeError:
        logging.error(f"Payload JSON invalide: {payload[:100]}")
    except Exception as e:
        logging.error(f"Erreur handler: {e}")

def main_loop():
    setup_logging()
    write_health()
    
    while True:
        try:
            conn = psycopg2.connect(
                dbname=DB_NAME, user=DB_USER, host='/var/run/postgresql'
            )
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
            cur = conn.cursor()
            
            load_ownership()
            for ch in ['letrevani_table', 'letrevani_session', 'letrevani_conflict']:
                cur.execute(f"LISTEN {ch};")
                logging.info(f"Ecoute canal: {ch}")
            
            logging.info("Listener demarre")
            write_health()
            
            while True:
                conn.poll()
                while conn.notifies:
                    n = conn.notifies.pop(0)
                    handle_notification(n.channel, n.payload)
                time.sleep(0.1)
        except Exception as e:
            logging.error(f"Erreur connexion: {e}")
            time.sleep(5)

if __name__ == '__main__':
    signal(SIGTERM, lambda *a: sys.exit(0))
    signal(2, lambda *a: sys.exit(0))
    main_loop()
