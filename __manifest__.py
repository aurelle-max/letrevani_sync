{
    "name": "Letrevani Sync — Tables restaurant synchronisees",
    "version": "19.0.1.0.0",
    "category": "Sales/Point of Sale",
    "summary": "Synchro temps reel + ownership des tables restaurant",
    "description": """
Letrevani Sync — Synchronisation temps reel des tables restaurant

Fonctionnalites :
- Verrouillage automatique des tables (1ere session = proprietaire)
- Ecriture prioritaire du proprietaire en cas de conflit (< 200ms)
- Liberation automatique a la fermeture de session
- NOTIFY PostgreSQL temps reel (pas de polling)
- Compatible Odoo 19 + modules Maysoft maj_pos_restaurant_ai

Architecture :
- Table: letrevani_table_ownership
- 5 fonctions PL/pgSQL
- 7 triggers PostgreSQL
- 3 canaux NOTIFY (letrevani_table, letrevani_session, letrevani_conflict)
- Listener Python optionnel (systemd)

Installation :
1. Installer le module Odoo (active les triggers)
2. Optionnel: bash setup_listener.sh <database>
    """,
    "author": "Letrevani / Majsoft",
    "website": "https://letrevani.com",
    "depends": ["maj_pos_restaurant_ai"],
    "data": [
        "data/ir_config_parameter.xml",
    ],
    "installable": True,
    "application": False,
    "auto_install": False,
    "license": "LGPL-3",
}
