-- ==========================================================
-- Letrevani Sync — Installation des triggers PostgreSQL
-- Compatible Odoo 19+ / PostgreSQL 16+
-- Utilisation: psql -d <database> -f install_triggers.sql
-- ==========================================================

-- 2. Acquérir ownership à la création d'une session
CREATE OR REPLACE FUNCTION letrevani_acquire_ownership()
RETURNS trigger AS $FUNC1$
BEGIN
    INSERT INTO letrevani_table_ownership (table_id, owner_session_id, owner_pos_session_id, acquired_at)
    VALUES (NEW.table_id, NEW.id, NEW.pos_session_id, NOW())
    ON CONFLICT (table_id) DO NOTHING;
    RETURN NEW;
END;
$FUNC1$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS letrevani_acquire_owner ON restaurant_ai_session;
CREATE TRIGGER letrevani_acquire_owner
AFTER INSERT ON restaurant_ai_session
FOR EACH ROW EXECUTE FUNCTION letrevani_acquire_ownership();

-- 3. Priorité d'écriture : proprio gagne si conflit < 200ms
CREATE OR REPLACE FUNCTION letrevani_check_write_priority()
RETURNS trigger AS $FUNC2$
DECLARE
    owner_id INTEGER;
    table_num INTEGER;
    owner_last_write TIMESTAMP;
BEGIN
    IF NEW.table_id IS NULL THEN RETURN NEW; END IF;

    SELECT o.owner_pos_session_id, o.last_write_at INTO owner_id, owner_last_write
    FROM letrevani_table_ownership o WHERE o.table_id = NEW.table_id;

    SELECT table_number INTO table_num FROM restaurant_table WHERE id = NEW.table_id;

    IF owner_id IS NULL THEN
        INSERT INTO letrevani_table_ownership (table_id, owner_session_id, owner_pos_session_id)
        VALUES (NEW.table_id, NEW.id, NEW.pos_session_id)
        ON CONFLICT (table_id) DO NOTHING;
        RETURN NEW;
    END IF;

    IF NEW.pos_session_id != owner_id AND TG_OP IN ('INSERT', 'UPDATE') THEN
        IF EXISTS (
            SELECT 1 FROM letrevani_table_ownership
            WHERE table_id = NEW.table_id
              AND last_write_at > NOW() - INTERVAL '200 milliseconds'
              AND owner_pos_session_id != NEW.pos_session_id
        ) THEN
            PERFORM pg_notify('letrevani_conflict',
                json_build_object(
                    'event', 'write_conflict',
                    'table_id', NEW.table_id,
                    'table_number', table_num,
                    'owner_session', json_build_object('session_id', owner_id, 'last_write', owner_last_write),
                    'requesting_session', NEW.pos_session_id,
                    'resolution', 'owner_wins',
                    'ts', NOW()
                )::text);
            RAISE WARNING 'Letrevani Sync: Conflit table % - proprio % gagne, session % refuse',
                table_num, owner_id, NEW.pos_session_id;
            RETURN NULL;
        END IF;
    END IF;

    UPDATE letrevani_table_ownership
    SET last_write_at = NOW()
    WHERE table_id = NEW.table_id
      AND (owner_pos_session_id = NEW.pos_session_id OR owner_pos_session_id IS NULL);

    RETURN NEW;
END;
$FUNC2$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS letrevani_write_priority ON restaurant_ai_session;
CREATE TRIGGER letrevani_write_priority
BEFORE INSERT OR UPDATE ON restaurant_ai_session
FOR EACH ROW EXECUTE FUNCTION letrevani_check_write_priority();

-- 4. Libérer ownership quand session fermée
CREATE OR REPLACE FUNCTION letrevani_release_ownership()
RETURNS trigger AS $FUNC3$
BEGIN
    IF NEW.state = 'closed' THEN
        DELETE FROM letrevani_table_ownership
        WHERE owner_session_id = OLD.id OR owner_session_id = NEW.id;
        PERFORM pg_notify('letrevani_session',
            json_build_object(
                'event', 'ownership_released',
                'table_id', NEW.table_id,
                'session_id', NEW.id,
                'pos_session_id', NEW.pos_session_id,
                'ts', NOW()
            )::text);
    END IF;
    RETURN NEW;
END;
$FUNC3$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS letrevani_release_owner ON restaurant_ai_session;
CREATE TRIGGER letrevani_release_owner
AFTER UPDATE OF state ON restaurant_ai_session
FOR EACH ROW
WHEN (NEW.state = 'closed')
EXECUTE FUNCTION letrevani_release_ownership();

-- 5. NOTIFY changements d'état de table
CREATE OR REPLACE FUNCTION notify_table_state()
RETURNS trigger AS $FUNC4$
BEGIN
    IF OLD.ai_physical_state IS DISTINCT FROM NEW.ai_physical_state THEN
        PERFORM pg_notify('letrevani_table',
            json_build_object(
                'event', 'state_change',
                'table_id', NEW.id,
                'table_number', NEW.table_number,
                'old_state', OLD.ai_physical_state,
                'new_state', NEW.ai_physical_state,
                'ts', NOW()
            )::text);
    END IF;
    RETURN NEW;
END;
$FUNC4$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS table_state_notify ON restaurant_table;
CREATE TRIGGER table_state_notify
AFTER UPDATE OF ai_physical_state ON restaurant_table
FOR EACH ROW EXECUTE FUNCTION notify_table_state();

-- 6. NOTIFY sessions avec info ownership
CREATE OR REPLACE FUNCTION notify_session_change()
RETURNS trigger AS $FUNC5$
DECLARE
    table_num INTEGER;
    owner_info RECORD;
BEGIN
    IF NEW.table_id IS NULL THEN RETURN NEW; END IF;

    SELECT table_number INTO table_num FROM restaurant_table WHERE id = NEW.table_id;
    SELECT o.owner_session_id, o.owner_pos_session_id, o.acquired_at
    INTO owner_info
    FROM letrevani_table_ownership o WHERE o.table_id = NEW.table_id;

    PERFORM pg_notify('letrevani_session',
        json_build_object(
            'event', CASE
                WHEN TG_OP = 'INSERT' THEN 'table_taken'
                WHEN TG_OP = 'UPDATE' AND NEW.state = 'closed' THEN 'table_freed'
                ELSE 'session_update'
            END,
            'table_id', NEW.table_id,
            'table_number', table_num,
            'session_id', NEW.id,
            'pos_session_id', NEW.pos_session_id,
            'state', NEW.state,
            'is_owner', (NEW.pos_session_id = owner_info.owner_pos_session_id),
            'owner_pos_session_id', owner_info.owner_pos_session_id,
            'owner_acquired_at', owner_info.acquired_at,
            'ts', NOW()
        )::text);
    RETURN NEW;
END;
$FUNC5$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS session_table_notify ON restaurant_ai_session;
CREATE TRIGGER session_table_notify
AFTER INSERT OR UPDATE ON restaurant_ai_session
FOR EACH ROW EXECUTE FUNCTION notify_session_change();
