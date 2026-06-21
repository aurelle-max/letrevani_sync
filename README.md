# Letrevani Sync

Module Odoo pour la synchronisation temps réel des tables restaurant.

**Fonctionnalités :**
- Verrouillage automatique des tables (1ère session = propriétaire)
- Écriture prioritaire du propriétaire en cas de conflit (< 200ms)
- Libération automatique à la fermeture de session
- NOTIFY PostgreSQL temps réel (pas de polling)
- Compatible Odoo 19 + modules Maysoft `maj_pos_restaurant_ai`

## Installation

```bash
# 1. Copier dans addons Odoo
cp -r letrevani_sync /maysoft/addons/

# 2. Installer le module Odoo
# Apps → Letrevani Sync → Installer

# 3. Optionnel : déployer le listener système
bash setup_listener.sh <nom_base>
```

## Architecture

- Table: `letrevani_table_ownership`
- 5 fonctions PL/pgSQL
- 7 triggers PostgreSQL
- 3 canaux NOTIFY (`letrevani_table`, `letrevani_session`, `letrevani_conflict`)
- Listener Python optionnel (systemd)

## Dépendances

- Odoo 19.0+
- `maj_pos_restaurant_ai` (Maysoft)
- PostgreSQL 14+
