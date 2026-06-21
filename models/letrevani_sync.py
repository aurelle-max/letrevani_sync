# -*- coding: utf-8 -*-
import logging
from odoo import api, fields, models

_logger = logging.getLogger(__name__)


class LetrevaniSync(models.AbstractModel):
    _name = "letrevani.sync"
    _description = "Letrevani Sync - Gestion des triggers PostgreSQL"

    @api.model
    def _install_sync_triggers(self):
        """Installe les triggers PostgreSQL pour la synchro temps reel."""
        self._cr.execute("""
            SELECT EXISTS (
                SELECT FROM pg_tables WHERE tablename = 'letrevani_table_ownership'
            )
        """)
        if self._cr.fetchone()[0]:
            _logger.info("Letrevani Sync: triggers deja installes, skip.")
            return

        _logger.info("Letrevani Sync: installation des triggers PostgreSQL...")

        # 1. Table ownership
        self._cr.execute("""
            CREATE TABLE IF NOT EXISTS letrevani_table_ownership (
                table_id INTEGER PRIMARY KEY REFERENCES restaurant_table(id) ON DELETE CASCADE,
                owner_session_id INTEGER NOT NULL,
                owner_pos_session_id INTEGER,
                acquired_at TIMESTAMP DEFAULT NOW(),
                last_write_at TIMESTAMP DEFAULT NOW()
            );
        """)

        # 2-6: Triggers via SQL script
        self._cr.execute(open('/maysoft/addons/letrevani_sync/data/install_triggers.sql').read())

        # 7. Peupler ownerships existantes
        self._cr.execute("""
            INSERT INTO letrevani_table_ownership (table_id, owner_session_id, owner_pos_session_id, acquired_at)
            SELECT DISTINCT ON (s.table_id)
                s.table_id, s.id, s.pos_session_id, s.opened_at
            FROM restaurant_ai_session s
            WHERE s.table_id IS NOT NULL
              AND s.state IN ('draft', 'open')
              AND NOT EXISTS (
                  SELECT 1 FROM letrevani_table_ownership o WHERE o.table_id = s.table_id
              )
            ORDER BY s.table_id, s.id ASC;
        """)

        _logger.info("Letrevani Sync: 7 triggers installes avec succes.")

    @api.model
    def _uninstall_triggers(self):
        """Desinstalle tous les triggers et la table."""
        self._cr.execute("""
            DROP TRIGGER IF EXISTS letrevani_acquire_owner ON restaurant_ai_session;
            DROP TRIGGER IF EXISTS letrevani_write_priority ON restaurant_ai_session;
            DROP TRIGGER IF EXISTS letrevani_release_owner ON restaurant_ai_session;
            DROP TRIGGER IF EXISTS session_table_notify ON restaurant_ai_session;
            DROP TRIGGER IF EXISTS table_state_notify ON restaurant_table;
            DROP FUNCTION IF EXISTS letrevani_acquire_ownership() CASCADE;
            DROP FUNCTION IF EXISTS letrevani_check_write_priority() CASCADE;
            DROP FUNCTION IF EXISTS letrevani_release_ownership() CASCADE;
            DROP FUNCTION IF EXISTS notify_session_change() CASCADE;
            DROP FUNCTION IF EXISTS notify_table_state() CASCADE;
            DROP TABLE IF EXISTS letrevani_table_ownership;
            DROP TABLE IF EXISTS letrevani_sync;
        """)
        _logger.info("Letrevani Sync: triggers desinstalles.")
