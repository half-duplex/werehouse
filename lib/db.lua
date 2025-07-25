local DB_DIR = "db"
local ACCOUNTS_DB_FILE = "db/werehouse-accounts.sqlite3"
local TG_FORWARD_CACHE_DB_FILE = "db/werehouse-tg-forward-cache.sqlite3"
local USER_DB_FILE_TEMPLATE = "db/werehouse-%s.sqlite3"
local QUERY_STATS_FILE = "db/werehouse-qstats.sqlite3"

local IdPrefixes = {
    user = "u_",
    session = "s_",
    csrf = "csrf_",
    invite = "i_",
    telegram_link_request = "tglr_",
    share = "sh_",
}

local accounts_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "users" (
        "user_id" TEXT NOT NULL UNIQUE,
        "username" TEXT NOT NULL UNIQUE,
        "password" TEXT NOT NULL,
        "invites_available" INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY("user_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "telegram_accounts" (
        "user_id" TEXT NOT NULL,
        "tg_userid" INTEGER NOT NULL UNIQUE,
        "tg_username" TEXT,
        PRIMARY KEY("tg_userid", "user_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "sessions" (
        "session_id" TEXT NOT NULL UNIQUE,
        "created" TEXT NOT NULL,
        "user_id" TEXT NOT NULL,
        "last_seen" INTEGER NOT NULL,
        "user_agent" TEXT NOT NULL,
        "ip" TEXT NOT NULL,
        "csrf_token" TEXT NOT NULL,
        PRIMARY KEY("session_id"),
        FOREIGN KEY ("user_id") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "invites" (
        "invite_id" TEXT NOT NULL UNIQUE,
        "inviter" TEXT,
        "invitee" TEXT,
        "created_at" TEXT NOT NULL,
        PRIMARY KEY("invite_id"),
        FOREIGN KEY ("inviter") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("invitee") REFERENCES "users"("user_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "telegram_link_requests" (
        "request_id" TEXT NOT NULL UNIQUE,
        "display_name" TEXT,
        "username" TEXT,
        "tg_userid" INTEGER NOT NULL,
        "created_at" INTEGER NOT NULL,
        PRIMARY KEY("request_id")
    ) STRICT;

    CREATE TRIGGER IF NOT EXISTS invitee_write_once
        BEFORE UPDATE OF "invitee" ON "invites"
        FOR EACH ROW WHEN old.invitee NOT NULL
        BEGIN SELECT RAISE(ROLLBACK, 'Invite already used'); END;
]]

local user_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "images" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "file" TEXT NOT NULL UNIQUE,
        "mime_type" TEXT NOT NULL,
        "category" INTEGER,
        "saved_at" TEXT NOT NULL,
        "rating" INTEGER,
        "kind" INTEGER,
        "height" INTEGER NOT NULL,
        "width" INTEGER NOT NULL,
        "file_size" INTEGER NOT NULL,
        PRIMARY KEY("image_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "image_gradienthashes" (
        "image_id" INTEGER NOT NULL UNIQUE,
        "h1" INTEGER NOT NULL,
        "h2" INTEGER NOT NULL,
        "h3" INTEGER NOT NULL,
        "h4" INTEGER NOT NULL,
        PRIMARY KEY ("image_id", "h1", "h2", "h3", "h4"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "tags" (
        "tag_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT NOT NULL UNIQUE,
        "description" TEXT NOT NULL,
        PRIMARY KEY("tag_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "incoming_tags" (
        "itid" INTEGER NOT NULL UNIQUE,
        "image_id" INTEGER NOT NULL,
        "name" TEXT NOT NULL,
        "domain" TEXT NOT NULL,
        "image_tag_id" INTEGER,
        PRIMARY KEY("itid"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("image_tag_id") REFERENCES "image_tags"("image_tag_id")
        ON UPDATE CASCADE ON DELETE SET NULL
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "image_tags" (
        "image_tag_id" INTEGER NOT NULL,
        "image_id" INTEGER NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY ("image_tag_id"),
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE UNIQUE INDEX IF NOT EXISTS "no_duplicate_tags_on_images" ON "image_tags"
        ("image_id", "tag_id");

    CREATE VIEW IF NOT EXISTS "tag_counts" (tag_id, count) AS
    SELECT image_tags.tag_id, COUNT(*) AS count
        FROM image_tags
        GROUP BY image_tags.tag_id;

    CREATE TABLE IF NOT EXISTS "tag_rules" (
        "tag_rule_id" INTEGER NOT NULL UNIQUE,
        "incoming_name" TEXT NOT NULL,
        "incoming_domain" TEXT NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("tag_rule_id"),
        FOREIGN KEY("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE VIEW IF NOT EXISTS "incoming_tags_now_matched_by_tag_rules" (
        itid,
        image_id,
        tag_rule_id,
        tag_id,
        tag_name,
        applied
    ) AS SELECT
        incoming_tags.itid,
        incoming_tags.image_id,
        tag_rules.tag_rule_id,
        tag_rules.tag_id,
        tags.name,
        incoming_tags.image_tag_id IS NOT NULL
    FROM tag_rules
    INNER NATURAL JOIN tags
    INNER JOIN incoming_tags ON
        tag_rules.incoming_domain = incoming_tags.domain
        AND tag_rules.incoming_name = incoming_tags.name;

    CREATE TABLE IF NOT EXISTS "sources" (
        "source_id" INTEGER NOT NULL UNIQUE,
        "image_id" INTEGER NOT NULL,
        "link" TEXT NOT NULL,
        PRIMARY KEY("source_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE UNIQUE INDEX IF NOT EXISTS "unique_sources_per_image" ON "sources"
        ("image_id", "link");

    CREATE TABLE IF NOT EXISTS "artists" (
        "artist_id" INTEGER NOT NULL UNIQUE,
        "manually_confirmed" INTEGER NOT NULL DEFAULT 0,
        "name" TEXT NOT NULL UNIQUE COLLATE NOCASE,
        PRIMARY KEY("artist_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "artist_handles" (
        "handle_id" INTEGER NOT NULL,
        "artist_id" INTEGER NOT NULL,
        "handle" TEXT NOT NULL,
        "domain" TEXT NOT NULL,
        "profile_url" TEXT NOT NULL,
        PRIMARY KEY("handle_id"),
        FOREIGN KEY ("artist_id") REFERENCES "artists"("artist_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "image_artists" (
        "image_id" INTEGER NOT NULL,
        "artist_id" INTEGER NOT NULL,
        PRIMARY KEY("image_id", "artist_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("artist_id") REFERENCES "artists"("artist_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE VIEW IF NOT EXISTS "images_for_gallery" (
        image_id,
        file,
        file_size,
        kind,
        mime_type,
        width,
        height,
        saved_at,
        artists,
        first_thumbnail_id,
        first_thumbnail_width,
        first_thumbnail_height
    ) AS SELECT
        images.image_id,
        images.file,
        images.file_size,
        images.kind,
        images.mime_type,
        images.width,
        images.height,
        images.saved_at,
        group_concat(artists.name, ", ") AS artists,
        selected_thumbnails.thumbnail_id AS first_thumbnail_id,
        selected_thumbnails.width AS first_thumbnail_width,
        selected_thumbnails.height AS first_thumbnail_height
    FROM images
        LEFT NATURAL JOIN image_artists
        LEFT NATURAL JOIN artists
        LEFT JOIN selected_thumbnails ON selected_thumbnails.image_id = images.image_id
        GROUP BY images.image_id;

    CREATE TABLE IF NOT EXISTS "share_ping_list" (
        "spl_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT NOT NULL,
        -- JSON blob that contains settings necessary for sharing to whatever service.
        "share_data" TEXT NOT NULL,
        "send_with_attribution" INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY("spl_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "share_ping_list_entry" (
        "spl_entry_id" INTEGER NOT NULL UNIQUE,
        "handle" TEXT NOT NULL,
        "nickname" TEXT,
        "enabled" INTEGER NOT NULL DEFAULT 1,
        "spl_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id"),
        FOREIGN KEY ("spl_id") REFERENCES "share_ping_list"("spl_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "pl_entry_positive_tags" (
        "spl_entry_id" INTEGER NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id", "tag_id"),
        FOREIGN KEY ("spl_entry_id") REFERENCES "share_ping_list_entry"("spl_entry_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "pl_entry_negative_tags" (
        "spl_entry_id" INTEGER NOT NULL,
        "tag_id" INTEGER NOT NULL,
        PRIMARY KEY("spl_entry_id", "tag_id"),
        FOREIGN KEY ("spl_entry_id") REFERENCES "share_ping_list_entry"("spl_entry_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("tag_id") REFERENCES "tags"("tag_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "image_group" (
        "ig_id" INTEGER NOT NULL UNIQUE,
        "name" TEXT,
        PRIMARY KEY("ig_id")
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "images_in_group" (
        "image_id" INTEGER NOT NULL,
        "ig_id" INTEGER NOT NULL,
        "order" INTEGER,
        PRIMARY KEY("image_id", "ig_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("ig_id") REFERENCES "image_group"("ig_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "thumbnails" (
        "thumbnail_id" INTEGER NOT NULL UNIQUE,
        "image_id" INTEGER NOT NULL,
        "thumbnail" BLOB NOT NULL,
        "thumbnail_hash" TEXT,
        "width" INTEGER NOT NULL,
        "height" INTEGER NOT NULL,
        "scale" INTEGER NOT NULL,
        "mime_type" TEXT NOT NULL DEFAULT 'image/jpeg',
        PRIMARY KEY("thumbnail_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS thumbnails_by_image_and_id_desc ON thumbnails(
        image_id,
        thumbnail_id DESC
    );

    CREATE TABLE IF NOT EXISTS "selected_thumbnails" (
        image_id INTEGER NOT NULL UNIQUE,
        thumbnail_id INTEGER NOT NULL UNIQUE,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        PRIMARY KEY ("image_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("thumbnail_id") REFERENCES "thumbnails"("thumbnail_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TRIGGER IF NOT EXISTS update_selected_thumbnail
        AFTER INSERT ON "thumbnails"
        FOR EACH ROW
        BEGIN INSERT OR REPLACE INTO "selected_thumbnails" (
            image_id,
            thumbnail_id,
            width,
            height
        ) SELECT
            image_id,
            thumbnail_id,
            width,
            height
        FROM "thumbnails"
        WHERE new.image_id = thumbnails.image_id
        GROUP BY image_id
        HAVING MAX(thumbnail_id); END;

    CREATE TABLE IF NOT EXISTS "queue" (
        "qid" INTEGER NOT NULL UNIQUE,
        "link" TEXT UNIQUE,
        "image" BLOB,
        "image_mime_type" TEXT,
        "image_width" INTEGER,
        "image_height" INTEGER,
        "tombstone" INTEGER NOT NULL,
        "added_on" TEXT NOT NULL,
        "status" TEXT NOT NULL,
        "retry_count" INTEGER NOT NULL DEFAULT 0,
        "disambiguation_request" TEXT,
        "disambiguation_data" TEXT,
        "tg_chat_id" INTEGER,
        "tg_message_id" INTEGER,
        PRIMARY KEY("qid")
    );

    CREATE INDEX IF NOT EXISTS queue_added_on ON queue (added_on);

    CREATE TABLE IF NOT EXISTS "queue2" (
        "qid" INTEGER NOT NULL UNIQUE,
        "link" TEXT UNIQUE,
        "added_on" TEXT NOT NULL,
        "status" INTEGER NOT NULL,
        "description" TEXT NOT NULL,
        "retry_count" INTEGER NOT NULL DEFAULT 0,
        "help_ask" TEXT,
        "help_answer" TEXT,
        "tg_chat_id" INTEGER,
        "tg_message_id" INTEGER,
        "tg_source_link" TEXT,
        PRIMARY KEY ("qid")
    ) STRICT;

    CREATE INDEX IF NOT EXISTS queue2_added_on ON queue2 (added_on);
    CREATE INDEX IF NOT EXISTS queue2_status_added_on ON queue2(status, added_on);

    -- Stored as a separate table to ensure that if one value is present, they all are.
    CREATE TABLE IF NOT EXISTS "queue_images" (
        "qid" INTEGER NOT NULL UNIQUE,
        "image" TEXT NOT NULL UNIQUE,
        "image_mime_type" TEXT NOT NULL,
        "image_width" INTEGER NOT NULL,
        "image_height" INTEGER NOT NULL,
        FOREIGN KEY ("qid") REFERENCES "queue2"("qid")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "queue_gradienthashes" (
        "qid" INTEGER NOT NULL UNIQUE,
        "h1" INTEGER NOT NULL,
        "h2" INTEGER NOT NULL,
        "h3" INTEGER NOT NULL,
        "h4" INTEGER NOT NULL,
        PRIMARY KEY ("qid", "h1", "h2", "h3", "h4"),
        FOREIGN KEY ("qid") REFERENCES "queue2"("qid")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE IF NOT EXISTS "share_records" (
        "share_id" TEXT NOT NULL UNIQUE,
        "image_id" INTEGER,
        "ig_id" INTEGER,
        "shared_to" TEXT NOT NULL,
        "shared_at" TEXT,
        PRIMARY KEY("share_id"),
        FOREIGN KEY ("image_id") REFERENCES "images"("image_id")
        ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY ("ig_id") REFERENCES "image_group"("ig_id")
        ON UPDATE CASCADE ON DELETE CASCADE
    ) STRICT;

    CREATE TRIGGER IF NOT EXISTS share_record_use_once
        BEFORE UPDATE OF "shared_at" ON "share_records"
        FOR EACH ROW WHEN old.shared_at NOT NULL
        BEGIN SELECT RAISE(ROLLBACK, 'Share token already used'); END;
]]

local tg_forward_cache_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "cache" (
        "cache_id" INTEGER NOT NULL UNIQUE,
        "type" TEXT NOT NULL,
        "username" TEXT,
        "title" TEXT,
        "id" INTEGER,
        "message_id" INTEGER NOT NULL,
        "media_kind" TEXT NOT NULL,
        "media" TEXT NOT NULL,
        "cached_at" INTEGER,
        PRIMARY KEY ("cache_id")
    ) STRICT;

    CREATE UNIQUE INDEX IF NOT EXISTS cache_by_username_message_id
        ON cache (username, message_id);
]]

local query_stats_setup = [[
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS "query_stats" (
        "query" TEXT NOT NULL,
        "duration" REAL NOT NULL,
        "timestamp" INTEGER NOT NULL
    ) STRICT;

    CREATE INDEX IF NOT EXISTS query_stats_by_query ON query_stats (query);
]]

local queries = {
    accounts = {
        count_users = [[SELECT COUNT(*) AS count FROM "users";]],
        count_invites = [[SELECT COUNT(*) FROM "invites";]],
        bootstrap_invite = [[INSERT INTO "invites" ("invite_id", "created_at")
            VALUES (?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));]],
        find_invite = [[SELECT "inviter", "invitee", "created_at"
            FROM "invites"
            WHERE "invite_id" = ?;]],
        insert_user = [[INSERT INTO "users" ("user_id", "username", "password")
            VALUES (?, ?, ?);]],
        assign_invite = [[UPDATE "invites" SET "invitee" = ?
            WHERE invite_id = ? AND "invitee" IS NULL;]],
        find_user_by_name = [[SELECT "user_id", "username", "password"
            FROM "users"
            WHERE "username" = ?;]],
        insert_session = [[INSERT INTO "sessions" ("session_id", "user_id", "created", "last_seen", "user_agent", "ip", "csrf_token")
            VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?, ?, ?, ?);]],
        get_session_by_id = [[SELECT "created", "user_id" from "sessions"
            WHERE "session_id" = ?;]],
        get_all_sessions_for_user = [[SELECT session_id, created, last_seen, user_agent, ip
            FROM sessions WHERE user_id = ?;]],
        get_all_invite_links_created_by_user = [[SELECT
                invite_id, (invitee IS NOT NULL) AS used
            FROM invites WHERE inviter = ?;]],
        get_sessions_older_than_stamp = [[SELECT session_id FROM sessions WHERE last_seen < ?;]],
        get_user_by_session = [[SELECT u.user_id, u.username, u.invites_available, u.password FROM "users" AS u
            INNER JOIN "sessions" on u.user_id = sessions.user_id
            WHERE sessions.session_id = ?;]],
        get_user_by_tg_id = [[SELECT users.user_id, users.username
            FROM users
            JOIN telegram_accounts ON users.user_id = telegram_accounts.user_id
            WHERE telegram_accounts.tg_userid = ?;]],
        get_all_user_ids = [[SELECT user_id FROM "users";]],
        get_telegram_link_request_by_id = [[SELECT request_id, display_name, username, tg_userid, created_at
            FROM telegram_link_requests
            WHERE request_id = ?;]],
        get_telegram_accounts_by_user_id = [[SELECT tg_userid, tg_username
            FROM telegram_accounts WHERE user_id = ?;]],
        get_telegram_account_by_user_id_and_tg_userid = [[SELECT tg_username
            FROM telegram_accounts WHERE user_id = ? AND tg_userid = ?;]],
        insert_telegram_link_request = [[INSERT INTO "telegram_link_requests"
            ("request_id", "display_name", "username", "tg_userid", "created_at")
            VALUES (?, ?, ?, ?, ?);]],
        insert_telegram_account_id = [[INSERT INTO "telegram_accounts"
            ("user_id", "tg_userid", "tg_username")
            VALUES (?, ?, ?);]],
        insert_invite_for_user = [[INSERT INTO "invites" ("invite_id", "inviter", "created_at")
            VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));]],
        update_session_last_seen = [[UPDATE "sessions"
            SET last_seen = ?, ip = ?
            WHERE session_id = ?;]],
        update_csrf_token_for_session = [[UPDATE "sessions" SET csrf_token = ? WHERE session_id = ?;]],
        update_password_for_user = [[UPDATE "users" SET "password" = ? WHERE "user_id" = ?;]],
        delete_telegram_link_request = [[DELETE FROM telegram_link_requests WHERE request_id = ?;]],
        delete_sessions_older_than_stamp = [[DELETE FROM "sessions" WHERE last_seen < ?;]],
        delete_sessions_for_user = [[DELETE FROM "sessions" WHERE user_id = ?;]],
    },
    model = {
        get_recent_queue_entries = [[SELECT
                queue2.qid,
                queue2.link,
                queue_images.image,
                queue_images.image_width,
                queue_images.image_height,
                queue2.status,
                queue2.added_on,
                queue2.description,
                queue2.help_ask,
                queue2.help_answer
            FROM queue2
            LEFT NATURAL JOIN queue_images
            ORDER BY added_on DESC
            LIMIT 21;]],
        get_all_queue_entries = [[SELECT
                queue2.qid,
                queue2.link,
                queue_images.image,
                queue_images.image_mime_type,
                queue2.status,
                queue2.added_on,
                queue2.description,
                queue2.help_ask,
                queue2.help_answer
            FROM queue2
            LEFT NATURAL JOIN queue_images
            ORDER BY added_on ASC
            LIMIT 10;]],
        get_first_n_active_queue_entries = [[SELECT
                queue2.qid,
                queue2.link,
                queue_images.image,
                queue_images.image_mime_type,
                queue2.status,
                queue2.added_on,
                queue2.description,
                queue2.help_ask,
                queue2.help_answer,
                queue2.tg_chat_id,
                queue2.tg_message_id,
                queue2.tg_source_link,
                queue2.retry_count
            FROM queue2
            LEFT NATURAL JOIN queue_images
            WHERE status = 0
            AND ( (help_ask IS NULL) = (help_answer IS NULL) )
            ORDER BY queue2.added_on ASC
            LIMIT ?;]],
        get_queue_entry_count = [[SELECT COUNT(*) AS count FROM "queue2";]],
        get_queue_entries_paginated = [[SELECT
                queue2.qid,
                queue2.link,
                queue_images.image,
                queue_images.image_width,
                queue_images.image_height,
                queue2.status,
                queue2.added_on,
                queue2.description,
                queue2.help_ask,
                queue2.help_answer,
                queue2.tg_source_link
            FROM queue2
            LEFT NATURAL JOIN queue_images
            ORDER BY queue2.added_on DESC
            LIMIT ?
            OFFSET ?;]],
        get_queue_entry_by_id = [[SELECT
                queue2.qid,
                queue2.link,
                queue_images.image,
                queue_images.image_mime_type,
                queue2.status,
                queue2.added_on,
                queue2.description,
                queue2.help_ask,
                queue2.help_answer,
                queue2.tg_chat_id,
                queue2.tg_message_id,
                queue2.tg_source_link,
                queue2.retry_count
            FROM queue2
            LEFT NATURAL JOIN queue_images
            WHERE queue2.qid = ?;]],
        get_queue_image_by_id = [[SELECT image, image_mime_type FROM queue_images
            WHERE qid = ?;]],
        get_queue_image_by_filename = [[SELECT image, image_mime_type FROM
            queue_images WHERE image = ?;]],
        get_image_entry_count = [[SELECT COUNT(*) as count FROM images;]],
        get_recent_image_entries = [[SELECT image_id, file, kind, mime_type, artists, first_thumbnail_id, first_thumbnail_width, first_thumbnail_height
            FROM images_for_gallery
            ORDER BY saved_at DESC
            LIMIT 20;]],
        get_image_entries_newest_first_paginated = [[SELECT
                image_id,
                file,
                width,
                height,
                kind,
                mime_type,
                artists,
                first_thumbnail_id,
                first_thumbnail_width,
                first_thumbnail_height
            FROM images_for_gallery
            ORDER BY saved_at DESC
            LIMIT ?
            OFFSET ?;]],
        get_image_by_id = [[SELECT
                image_id, file, saved_at, category, rating, height, width,
                kind, file_size, mime_type
            FROM images
            WHERE image_id = ?;]],
        get_first_thumbnail_by_image_id = [[SELECT
            first_thumbnail_id
            FROM images_for_gallery
            WHERE image_id = ?;]],
        get_artists_for_image = [[SELECT artists.artist_id, artists.name, artists.manually_confirmed
            FROM artists INNER JOIN image_artists
            ON image_artists.artist_id = artists.artist_id
            WHERE image_artists.image_id = ?;]],
        get_tag_id_by_name = [[SELECT tag_id FROM tags WHERE name LIKE ?;]],
        get_tags_for_image = [[SELECT tags.tag_id, tags.name, tag_counts.count
            FROM tags INNER JOIN image_tags
            ON image_tags.tag_id = tags.tag_id
            JOIN tag_counts ON tag_counts.tag_id = image_tags.tag_id
            WHERE image_tags.image_id = ?
            ORDER BY tags.name COLLATE NOCASE;]],
        get_incoming_tags_for_image_by_id = [[SELECT name, itid
            FROM incoming_tags WHERE image_id = ? AND image_tag_id IS NULL;]],
        get_incoming_tag_by_id = [[SELECT itid, name, domain, image_tag_id
            FROM incoming_tags
            WHERE itid = ?;]],
        get_images_and_tags_for_new_tag_rules = [[SELECT
                tag_name, image_id, itid
            FROM incoming_tags_now_matched_by_tag_rules
            WHERE applied = 0;]],
        get_images_and_tags_for_new_tag_rules_by_tag_rule_id = [[SELECT
                tag_name, image_id, itid
            FROM incoming_tags_now_matched_by_tag_rules
            WHERE applied = 0 AND tag_rule_id = ?;]],
        get_all_tags = [[SELECT tag_id, name FROM tags;]],
        get_sources_for_image = [[SELECT source_id, link
            FROM sources
            WHERE image_id = ?;]],
        get_source_by_link = [[SELECT DISTINCT image_id FROM sources
            WHERE link = ?;]],
        get_artist_id_by_domain_and_handle = [[SELECT artist_id FROM artist_handles
            WHERE domain = ? AND handle = ?;]],
        get_last_order_for_image_group = [[SELECT MAX("order") AS max_order
            FROM images_in_group
            WHERE ig_id = ?;]],
        get_all_artists = [[SELECT artist_id, name FROM artists;]],
        get_artist_entry_count = [[SELECT COUNT(*) AS count FROM artists;]],
        get_artist_entry_count_search = [[SELECT COUNT(*) AS count FROM artists
            WHERE artists.name LIKE '%'||?||'%';]],
        get_artist_entries_paginated = [[SELECT
                artists.artist_id,
                artists.name,
                artists.manually_confirmed,
                COUNT(artist_handles.domain) AS handle_count,
                ifnull(image_count, 0) AS image_count
            FROM artists
            LEFT JOIN artist_handles ON artists.artist_id = artist_handles.artist_id
            LEFT JOIN (
                SELECT artist_id AS artist_id_for_count, COUNT(*) as image_count
                FROM image_artists
                GROUP BY artist_id
            ) ON artists.artist_id = artist_id_for_count
            GROUP BY artists.artist_id
            ORDER BY artists.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_artist_entries_paginated_search = [[SELECT
                artists.artist_id,
                artists.name,
                artists.manually_confirmed,
                COUNT(artist_handles.domain) AS handle_count,
                ifnull(image_count, 0) AS image_count
            FROM artists
            LEFT JOIN artist_handles ON artists.artist_id = artist_handles.artist_id
            LEFT JOIN (
                SELECT artist_id AS artist_id_for_count, COUNT(*) as image_count
                FROM image_artists
                GROUP BY artist_id
            ) ON artists.artist_id = artist_id_for_count
            WHERE artists.name LIKE '%'||?||'%'
            GROUP BY artists.artist_id
            ORDER BY artists.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_tag_entries_paginated = [[SELECT
                tags.tag_id,
                tags.name,
                tags.description,
                COUNT(image_tags.image_id) AS image_count
            FROM tags
            LEFT JOIN image_tags ON image_tags.tag_id = tags.tag_id
            GROUP BY tags.tag_id
            ORDER BY tags.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_tag_entries_paginated_search = [[SELECT
                tags.tag_id,
                tags.name,
                tags.description,
                COUNT(image_tags.image_id) AS image_count
            FROM tags
            LEFT JOIN image_tags ON image_tags.tag_id = tags.tag_id
            WHERE tags.name LIKE '%'||?||'%'
            GROUP BY tags.tag_id
            ORDER BY tags.name COLLATE NOCASE
            LIMIT ?
            OFFSET ?;]],
        get_artist_by_id = [[SELECT artist_id, name, manually_confirmed
            FROM artists
            WHERE artist_id = ?;]],
        get_tag_by_id = [[SELECT tag_id, name, description
            FROM tags WHERE tag_id = ?;]],
        get_artist_id_by_name = [[SELECT artist_id FROM artists
            WHERE lower(name) = lower(?) COLLATE NOCASE;]],
        get_handles_for_artist = [[SELECT handle_id, handle, domain, profile_url
            FROM artist_handles
            WHERE artist_id = ?;]],
        get_recent_images_for_artist = [[SELECT
                images_for_gallery.image_id,
                images_for_gallery.file,
                images_for_gallery.kind,
                images_for_gallery.mime_type,
                images_for_gallery.artists,
                images_for_gallery.first_thumbnail_id,
                images_for_gallery.first_thumbnail_width,
                images_for_gallery.first_thumbnail_height
            FROM images_for_gallery
            LEFT NATURAL JOIN image_artists
            WHERE image_artists.artist_id = ?
            ORDER BY images_for_gallery.saved_at DESC
            LIMIT ?;]],
        get_recent_images_for_tag = [[SELECT
                images_for_gallery.image_id,
                images_for_gallery.file,
                images_for_gallery.kind,
                images_for_gallery.mime_type,
                images_for_gallery.artists,
                images_for_gallery.first_thumbnail_id,
                images_for_gallery.first_thumbnail_width,
                images_for_gallery.first_thumbnail_height
            FROM images_for_gallery
            LEFT NATURAL JOIN image_tags
            WHERE image_tags.tag_id = ?
            ORDER BY images_for_gallery.saved_at DESC
            LIMIT ?;]],
        get_all_images_for_size_check = [[SELECT image_id, file, file_size FROM images;]],
        get_image_group_count = [[SELECT COUNT(*) AS count FROM image_group;]],
        get_image_group_count_search = [[SELECT COUNT(*) AS count FROM image_group
            WHERE image_group.name LIKE '%'||?||'%';]],
        get_image_groups_paginated = [[SELECT
                image_group.ig_id,
                image_group.name,
                COUNT(images_in_group.image_id) AS image_count
            FROM image_group
            LEFT NATURAL JOIN images_in_group
            GROUP BY image_group.ig_id
            ORDER BY image_group.ig_id
            LIMIT ?
            OFFSET ?;]],
        get_image_groups_paginated_search = [[SELECT
                image_group.ig_id,
                image_group.name,
            COUNT(images_in_group.image_id) AS image_count
            FROM image_group
            LEFT NATURAL JOIN images_in_group
            WHERE image_group.name LIKE '%'||?||'%'
            GROUP BY image_group.ig_id
            ORDER BY image_group.name
            LIMIT ?
            OFFSET ?;]],
        get_tag_rules_paginated = [[SELECT
                tag_rules.tag_rule_id,
                tag_rules.incoming_name,
                tag_rules.incoming_domain,
                tag_rules.tag_id,
                tags.name AS tag_name
            FROM tag_rules
            INNER JOIN tags ON tag_rules.tag_id = tags.tag_id
            ORDER BY tag_rules.incoming_domain, tag_rules.incoming_name
            LIMIT ?
            OFFSET ?;]],
        get_tag_rule_by_id = [[SELECT
                tag_rules.tag_rule_id,
                tag_rules.incoming_name,
                tag_rules.incoming_domain,
                tag_rules.tag_id,
                tags.name AS tag_name
            FROM tag_rules
            INNER JOIN tags ON tag_rules.tag_id = tags.tag_id
            WHERE tag_rules.tag_rule_id = ?;]],
        insert_or_ignore_tag_by_name = [[INSERT OR IGNORE INTO
            "tags"("name", "description")
            VALUES (?, '');]],
        get_image_group_by_id = [[SELECT ig_id, name
            FROM image_group
            WHERE ig_id = ?;]],
        get_images_for_group = [[SELECT
                images_in_group.image_id,
                images_in_group."order",
                images_for_gallery.file,
                images_for_gallery.file_size,
                images_for_gallery.width,
                images_for_gallery.height,
                images_for_gallery.kind,
                images_for_gallery.mime_type,
                images_for_gallery.artists,
                images_for_gallery.first_thumbnail_id,
                images_for_gallery.first_thumbnail_width,
                images_for_gallery.first_thumbnail_height
            FROM images_in_group
            LEFT NATURAL JOIN images_for_gallery
            WHERE ig_id = ?
            ORDER BY images_in_group."order";]],
        get_image_groups_by_image_id = [[SELECT DISTINCT
                image_group.ig_id,
                image_group.name,
                COUNT(images_in_group.image_id) OVER (PARTITION BY image_group.ig_id) as group_count
            FROM image_group
            JOIN images_in_group ON images_in_group.ig_id = image_group.ig_id
            WHERE images_in_group.ig_id IN (
                SELECT ig_id
                FROM images_in_group
                WHERE image_id = ?
            );]],
        get_prev_next_images_in_group = [[SELECT
                images_in_group."order" AS my_order,
                siblings.image_id,
                siblings."order" AS sibling_order
            FROM images_in_group
            JOIN images_in_group AS siblings ON images_in_group.ig_id = siblings.ig_id
            WHERE
                images_in_group.ig_id = ?
                AND images_in_group.image_id = ?
                AND (siblings."order" = (images_in_group."order" + 1)
                    OR siblings."order" = (images_in_group."order" - 1));]],
        get_tag_entry_count = [[SELECT COUNT(*) AS count FROM tags;]],
        get_tag_entry_count_search = [[SELECT COUNT(*) AS count FROM tags
            WHERE tags.name LIKE '%'||?||'%';]],
        get_tag_rule_count = [[SELECT COUNT(*) AS count FROM tag_rules;]],
        get_image_stats = [[SELECT kind, COUNT(kind) AS record_count FROM images
            GROUP BY kind
            ORDER BY kind;]],
        get_tag_id_by_incoming_name_domain = [[SELECT tag_id
            FROM tag_rules
            WHERE incoming_domain = ? AND incoming_name = ?;]],
        get_disk_space_usage = [[SELECT SUM(file_size) AS size_sum FROM images;]],
        get_pings_for_image = [[select
                "share_ping_list_entry".handle,
                group_concat(tags.name, ", ") AS tag_names,
                count(tags.name) AS tag_count
            from image_tags
                inner join pl_entry_positive_tags on image_tags.tag_id = pl_entry_positive_tags.tag_id
                left join tags on tags.tag_id = pl_entry_positive_tags.tag_id
                left join share_ping_list_entry on "share_ping_list_entry".spl_entry_id = "pl_entry_positive_tags".spl_entry_id
            where
                image_tags.image_id = ?
                and share_ping_list_entry.spl_id = ?
                and share_ping_list_entry.enabled = 1
                and pl_entry_positive_tags.spl_entry_id not in (
                    select pl_entry_negative_tags.spl_entry_id
                    from image_tags
                    inner natural join pl_entry_negative_tags
                    inner natural join share_ping_list_entry
                    where image_tags.image_id = ? and share_ping_list_entry.spl_id = ?
                )
            group by "share_ping_list_entry".handle
            order by tag_count desc, "share_ping_list_entry".handle;]],
        get_pings_for_image_group = [[select
                "share_ping_list_entry".handle,
                group_concat(tags.name, ", ") AS tag_names,
                count(tags.name) AS tag_count
            from images_in_group
                inner natural join image_tags
                inner join pl_entry_positive_tags on image_tags.tag_id = pl_entry_positive_tags.tag_id
                left join tags on tags.tag_id = pl_entry_positive_tags.tag_id
                left join share_ping_list_entry on "share_ping_list_entry".spl_entry_id = "pl_entry_positive_tags".spl_entry_id
            where
                images_in_group.ig_id = ?
                and share_ping_list_entry.spl_id = ?
                and share_ping_list_entry.enabled = 1
                and pl_entry_positive_tags.spl_entry_id not in (
                    select pl_entry_negative_tags.spl_entry_id
                    from images_in_group
                    inner natural join image_tags
                    inner natural join pl_entry_negative_tags
                    inner natural join share_ping_list_entry
                    where images_in_group.ig_id = ? and share_ping_list_entry.spl_id = ?
                )
            group by "share_ping_list_entry".handle
            order by tag_count desc, "share_ping_list_entry".handle;]],
        get_all_share_ping_lists = [[SELECT spl_id, name, share_data FROM share_ping_list;]],
        get_share_ping_list_by_id = [[SELECT
                spl_id,
                name,
                share_data,
                send_with_attribution
            FROM share_ping_list WHERE spl_id = ?;]],
        get_entries_for_ping_list_by_id = [[SELECT spl_entry_id, handle, nickname, enabled, spl_id
            FROM share_ping_list_entry WHERE spl_id = ?;]],
        get_all_positive_tags_for_all_entries_in_ping_list_by_id = [[SELECT
                pl_entry_positive_tags.spl_entry_id,
                pl_entry_positive_tags.tag_id,
                tags.name
            FROM "pl_entry_positive_tags"
            INNER JOIN share_ping_list_entry ON share_ping_list_entry.spl_entry_id = pl_entry_positive_tags.spl_entry_id
            INNER JOIN tags ON pl_entry_positive_tags.tag_id = tags.tag_id
            WHERE share_ping_list_entry.spl_id = ?]],
        get_all_negative_tags_for_all_entries_in_ping_list_by_id = [[SELECT
                pl_entry_negative_tags.spl_entry_id,
                pl_entry_negative_tags.tag_id,
                tags.name
            FROM "pl_entry_negative_tags"
            INNER JOIN share_ping_list_entry ON share_ping_list_entry.spl_entry_id = pl_entry_negative_tags.spl_entry_id
            INNER JOIN tags ON pl_entry_negative_tags.tag_id = tags.tag_id
            WHERE share_ping_list_entry.spl_id = ?]],
        get_thumbnail_by_id = [[SELECT
                thumbnail_id, thumbnail, thumbnail_hash, width, height, scale, mime_type
            FROM thumbnails WHERE thumbnail_id = ?;]],
        get_approximately_equal_image_hashes = [[SELECT image_id, h1, h2, h3, h4
            FROM image_gradienthashes
            WHERE h1 = ? OR h2 = ? OR h3 = ? OR h4 = ?;]],
        get_approximately_equal_queue_hashes = [[SELECT qid, h1, h2, h3, h4
            FROM queue_gradienthashes
            WHERE h1 = ? OR h2 = ? OR h3 = ? OR h4 = ?;]],
        get_share_records_for_image = [[SELECT "share_id", "shared_to", "shared_at"
            FROM "share_records" WHERE "image_id" = ?;]],
        get_share_records_for_image_group = [[SELECT "share_id", "shared_to", "shared_at"
            FROM "share_records" WHERE "ig_id" = ?;]],
        get_attribution_for_image = [[SELECT artists.name
            FROM "artists" WHERE "artist_id" IN (
                SELECT "artist_id"
                FROM "image_artists"
                WHERE "image_id" = ?
            );]],
        insert_link_into_queue = [[INSERT INTO
            "queue2" ("link", "status", "added_on", "description")
            VALUES (?, 0, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), '')
            RETURNING qid;]],
        insert_image_into_queue = [[INSERT INTO
            "queue2" (
                "added_on",
                "status",
                "description"
            )
            VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 0, '')
            RETURNING qid;]],
        insert_image_file_into_queue = [[INSERT INTO "queue_images" (
                "qid",
                "image",
                "image_mime_type",
                "image_width",
                "image_height"
            ) VALUES (?, ?, ?, ?, ?);]],
        insert_row_into_queue = [[INSERT INTO
            "queue2" (
                "link",
                "added_on",
                "status",
                "description",
                "retry_count",
                "help_ask",
                "help_answer",
                "tg_chat_id",
                "tg_message_id",
                "tg_source_link"
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING "qid";]],
        insert_image_into_images = [[INSERT INTO
            "images" ("file", "mime_type", "width", "height", "kind", "rating", "file_size", "saved_at")
            VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            RETURNING image_id;]],
        insert_tag = [[INSERT OR IGNORE INTO "tags" ("name", "description")
            VALUES (?, ?)
            RETURNING tag_id;]],
        insert_image_tag = [[INSERT OR IGNORE INTO "image_tags" ("image_id", "tag_id")
            VALUES (?, ?) RETURNING image_tag_id;]],
        insert_source_for_image = [[INSERT OR IGNORE INTO "sources" ("image_id", "link")
            VALUES (?, ?);]],
        insert_artist = [[INSERT INTO "artists" ("name", "manually_confirmed")
            VALUES (?, ?)
            RETURNING artist_id;]],
        insert_image_artist = [[INSERT OR IGNORE INTO "image_artists" ("image_id", "artist_id")
            VALUES (?, ?);]],
        insert_artist_handle = [[INSERT OR IGNORE INTO "artist_handles" ("artist_id", "handle", "domain", "profile_url")
            VALUES (?, ?, ?, ?);]],
        insert_image_group = [[INSERT INTO "image_group" ("name")
            VALUES (?)
            RETURNING ig_id;]],
        insert_image_in_group = [[INSERT OR IGNORE INTO images_in_group (image_id, ig_id, "order")
            VALUES (?, ?, ?);]],
        insert_tag_rule = [[INSERT INTO "tag_rules" (
                "incoming_name",
                "incoming_domain",
                "tag_id"
            ) VALUES (?, ?, ?)
            RETURNING tag_rule_id;]],
        insert_image_tags_for_new_tag_rules = [[INSERT
            OR REPLACE INTO image_tags (image_id, tag_id)
            SELECT image_id, tag_id
            FROM "incoming_tags_now_matched_by_tag_rules"
            WHERE applied = 0
            RETURNING image_id, tag_id, image_tag_id;]],
        insert_image_tags_for_new_tag_rules_by_id = [[INSERT
            OR REPLACE INTO image_tags (image_id, tag_id)
            SELECT image_id, tag_id
            FROM "incoming_tags_now_matched_by_tag_rules"
            WHERE applied = 0 AND tag_rule_id = ?
            RETURNING image_id, tag_id, image_tag_id;]],
        update_image_tag_id_for_incoming_tags = [[UPDATE incoming_tags
            SET image_tag_id = ?
            WHERE itid IN (
                SELECT itid
                FROM incoming_tags_now_matched_by_tag_rules
                WHERE image_id = ? AND tag_id = ? AND applied = 0
            );]],
        insert_incoming_tag = [[INSERT INTO
                "incoming_tags" ("name", "domain", "image_id", "image_tag_id")
            VALUES (?, ?, ?, ?);]],
        insert_share_ping_list = [[INSERT INTO share_ping_list (
                name,
                share_data,
                send_with_attribution
            ) VALUES (?, ?, ?)
            RETURNING spl_id;]],
        insert_spl_entry = [[INSERT INTO share_ping_list_entry (
            handle,
            nickname,
            enabled,
            spl_id
        ) VALUES (?, ?, ?, ?)
        RETURNING spl_entry_id;]],
        insert_positive_tag = [[INSERT OR IGNORE INTO pl_entry_positive_tags
            (spl_entry_id, tag_id) VALUES (?, ?);]],
        insert_negative_tag = [[INSERT OR IGNORE INTO pl_entry_negative_tags
            (spl_entry_id, tag_id) VALUES (?, ?);]],
        insert_thumbnail = [[INSERT INTO "thumbnails"
            ( "image_id", "thumbnail", "thumbnail_hash", "width", "height", "scale", "mime_type" )
            VALUES (?, ?, ?, ?, ?, ?, ?);]],
        insert_image_hash = [[INSERT INTO "image_gradienthashes"
            ("image_id", "h1", "h2", "h3", "h4")
            VALUES (?, ?, ?, ?, ?);]],
        insert_queue_hash = [[INSERT INTO "queue_gradienthashes"
            ("qid", "h1", "h2", "h3", "h4")
            VALUES (?, ?, ?, ?, ?);]],
        insert_pending_share_record_for_image = [[INSERT INTO "share_records"
            ("share_id", "image_id", "shared_to") VALUES (?, ?, ?);]],
        insert_pending_share_record_for_image_group = [[INSERT INTO "share_records"
            ("share_id", "ig_id", "shared_to") VALUES (?, ?, ?);]],
        delete_item_from_queue = [[DELETE FROM "queue2" WHERE qid = ?;]],
        delete_image_from_group_by_id = [[DELETE FROM "images_in_group" WHERE
            ig_id = ? AND image_id = ?;]],
        delete_image_by_id = [[DELETE FROM "images" WHERE image_id = ?;]],
        delete_artist_by_id = [[DELETE FROM "artists" WHERE artist_id = ?;]],
        delete_tag_by_id = [[DELETE FROM "tags" WHERE tag_id = ?;]],
        delete_image_group_by_id = [[DELETE FROM "image_group" WHERE ig_id = ?;]],
        delete_image_artist_by_id = [[DELETE FROM image_artists
            WHERE image_id = ? AND artist_id = ?;]],
        delete_image_tags_by_id = [[DELETE FROM "image_tags"
            WHERE image_id = ? AND tag_id = ?;]],
        delete_source_by_id = [[DELETE FROM "sources" WHERE image_id = ? AND source_id = ?;]],
        delete_tag_rule_by_id = [[DELETE FROM "tag_rules" WHERE tag_rule_id = ?;]],
        delete_handle_for_artist_by_id = [[DELETE FROM "artist_handles"
            WHERE artist_id = ? AND handle_id = ?;]],
        delete_spl_by_id = [[DELETE FROM "share_ping_list" WHERE spl_id = ?;]],
        delete_spl_entry_by_id = [[DELETE FROM "share_ping_list_entry"
            WHERE spl_entry_id = ?;]],
        delete_pl_positive_tag = [[DELETE FROM "pl_entry_positive_tags"
            WHERE spl_entry_id = ? AND tag_id = ?;]],
        delete_pl_negative_tag = [[DELETE FROM "pl_entry_negative_tags"
            WHERE spl_entry_id = ? AND tag_id = ?;]],
        delete_handled_queue_entries = [[DELETE FROM "queue2" WHERE
            ( "status" = 2 OR "status" = 5 )
            AND "qid" != (SELECT MAX("qid") FROM "queue2");]],
        delete_share_record_by_id = [[DELETE FROM "share_records" WHERE
            "share_id" = ?;]],
        update_queue_item_status = [[UPDATE "queue2"
            SET "description" = ?, "status" = ?
            WHERE qid = ?;]],
        update_queue_item_status_only = [[UPDATE "queue2"
            SET "status" = ?
            WHERE qid = ?;]],
        update_queue_item_status_to_zero = [[UPDATE "queue2"
            SET "status" = 0, "retry_count" = 0, "help_ask" = NULL, "help_answer" = NULL
            WHERE qid = ?;]],
        update_queue_item_help_ask = [[UPDATE "queue2"
            SET
                "help_ask" = ?,
                "status" = 0,
                "help_answer" = NULL
            WHERE qid = ?;]],
        update_queue_item_help_answer = [[UPDATE "queue2"
            SET
                "help_answer" = ?,
                "status" = 0,
                "description" = ''
            WHERE qid = ?;]],
        update_queue_item_telegram_ids = [[UPDATE "queue2"
            SET "tg_chat_id" = ?, "tg_message_id" = ? WHERE qid = ?;]],
        update_queue_item_telegram_link = [[UPDATE "queue2"
            SET "tg_source_link" = ? WHERE "qid" = ?;]],
        update_handles_to_other_artist = [[UPDATE "artist_handles"
            SET "artist_id" = ?
            WHERE "artist_id" = ?]],
        update_image_artists_to_other_artist = [[UPDATE OR IGNORE "image_artists"
            SET "artist_id" = ?
            WHERE "artist_id" = ?;]],
        update_image_tags_to_other_tag = [[UPDATE OR IGNORE "image_tags"
            SET "tag_id" = ?
            WHERE "tag_id" = ?;]],
        update_tag_rules_to_other_tag = [[UPDATE OR IGNORE "tag_rules"
            SET "tag_id" = ?
            WHERE "tag_id" = ?;]],
        update_images_to_other_group_preserving_order = [[UPDATE images_in_group
            SET
                ig_id = ?,
                "order" = (
                    (SELECT MAX("order") FROM images_in_group WHERE ig_id = ?)
                    + "order"
                )
            WHERE ig_id = ?;]],
        update_name_for_image_group_by_id = [[UPDATE image_group
            SET name = ?
            WHERE ig_id = ?;]],
        update_order_for_image_in_image_group = [[UPDATE images_in_group
            SET "order" = ?
            WHERE ig_id = ? AND image_id = ?;]],
        update_category_rating_for_image_by_id = [[UPDATE images SET category = ?, rating = ?
            WHERE image_id = ?;]],
        update_image_size_by_id = [[UPDATE images SET file_size = ?
            WHERE image_id = ?;]],
        update_image_replace_image_by_id = [[UPDATE images SET
                file = ?,
                mime_type = ?,
                width = ?,
                height = ?,
                file_size = ?
            WHERE image_id = ?;]],
        update_tag_by_id = [[UPDATE tags
            SET name = ?, description = ?
            WHERE tag_id = ?;]],
        update_artist_by_id = [[UPDATE "artists"
            SET name = ?, manually_confirmed = ?
            WHERE artist_id = ?;]],
        update_tag_rule_by_id = [[UPDATE "tag_rules"
            SET incoming_name = ?, incoming_domain = ?, tag_id = ?
            WHERE tag_rule_id = ?;]],
        update_queue_item_retry_count_increment_by_one = [[UPDATE "queue2"
            SET retry_count = retry_count + 1
            WHERE qid = ?;]],
        update_pending_share_record_with_date_now = [[UPDATE "share_records"
            SET "shared_at" = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            WHERE "share_id" = ?;]],
        update_spl_entry_metadata = [[UPDATE "share_ping_list"
            SET "name" = ?, "share_data" = ?, "send_with_attribution" = ?
            WHERE "spl_id" = ?;]],
        update_spl_entry_by_id = [[UPDATE "share_ping_list_entry"
            SET "handle" = ?, "nickname" = ?, "enabled" = ?
            WHERE "spl_entry_id" = ?;]],
    },
}

local function mkdir()
    local ok, err = unix.mkdir("./" .. DB_DIR, 0700)
    if not ok and err and err:errno() == unix.EEXIST then
        return true
    elseif not ok then
        return nil, err
    else
        return true
    end
end
local function make_stats_db()
    local ok, db = pcall(Fm.makeStorage, QUERY_STATS_FILE, query_stats_setup)
    if not ok then
        Log(kLogInfo, "Error initializing stats db: " .. tostring(db))
        return nil
    end
    Log(kLogInfo, "Query statistics DB initialized.")
    return db
end

local STATS_DB = make_stats_db()

local function trace(dbm, query, params, dt)
    Log(kLogDebug, "query params: " .. tostring(EncodeJson(params)))
    if STATS_DB then
        local ok, err = STATS_DB:execute(
            [[INSERT INTO
                query_stats ("query", "duration", "timestamp")
            VALUES (?, ?, unixepoch('now'));]],
            query,
            dt
        )
        if not ok then
            Log(kLogDebug, "Error logging query performance: " .. tostring(err))
        end
    end
end

local function get_query_stats()
    if not STATS_DB then
        return {}
    end
    return STATS_DB:fetchAll([[SELECT
            query, COUNT(*) AS count, (AVG(duration) * 1000000) AS mean_us
        FROM query_stats
        WHERE timestamp > (unixepoch('now') - (24 * 60 * 60))
        GROUP BY query
        ORDER BY mean_us DESC;]])
end

local function fetchOneExactly(conn, query, ...)
    local result, err = conn:fetchOne(query, ...)
    if not result then
        return nil, err
    elseif result == conn.NONE then
        return nil, "No records returned"
    end
    return result
end

---@class Model
---@field conn table
---@field user_id string
local Model = {}

---@return Model
function Model:new(o, user_id)
    o = o or {}
    local filename = USER_DB_FILE_TEMPLATE % { user_id }
    o.conn = Fm.makeStorage(filename, user_setup, { trace = trace })
    o.user_id = user_id
    setmetatable(o, self)
    self.__index = self
    return o
end

function Model:migrate(opts)
    return self.conn:upgrade(opts)
end

function Model:getImageStats()
    return self.conn:fetchAll(queries.model.get_image_stats)
end

function Model:_get_count(query, search)
    local fetchArgs = nil
    if type(query) ~= "table" then
        query = { query }
    end
    if search then
        fetchArgs = { query[2], search }
    else
        fetchArgs = { query[1] }
    end
    local result, errmsg = self.conn:fetchOne(table.unpack(fetchArgs))
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:_get_paginated(query, page_num, per_page, search_term)
    local offset = (page_num - 1) * per_page
    local fetchArgs = { per_page, offset }
    if type(query) ~= "table" then
        query = { query }
    end
    if search_term then
        table.insert(fetchArgs, 1, search_term)
        table.insert(fetchArgs, 1, query[2])
    else
        table.insert(fetchArgs, 1, query[1])
    end
    return self.conn:fetchAll(table.unpack(fetchArgs))
end

local function rand_hex(n)
    assert(n <= 256)
    assert(n > 0)
    return string.format("%x" * n, string.unpack("B" * n, GetRandomBytes(n)))
end

function Model:_delete_by_id(query, ids)
    local SP = "delete_by_id_" .. rand_hex(8)
    self:create_savepoint(SP)
    for i = 1, #ids do
        local ok, errmsg = self.conn:execute(query, ids[i])
        if not ok then
            self:rollback(SP)
            return nil, errmsg
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:_delete_by_two_ids(query, container_id, item_ids)
    local SP = "delete_by_two_ids_" .. rand_hex(8)
    self:create_savepoint(SP)
    for i = 1, #item_ids do
        local ok, err = self.conn:execute(query, container_id, item_ids[i])
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:_delete_by_two_ids_arbitrary(query, pairs)
    local SP = "delete_by_two_ids_arbitrary_" .. rand_hex(8)
    self:create_savepoint(SP)
    for i = 1, #pairs do
        local ok, err = self.conn:execute(query, pairs[i][1], pairs[i][2])
        if not ok then
            self:rollback(SP)
            return nil, err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:deleteImages(image_ids)
    return self:_delete_by_id(queries.model.delete_image_by_id, image_ids)
end

function Model:getPingsForImage(image_id, spl_id)
    return self.conn:fetchAll(
        queries.model.get_pings_for_image,
        image_id,
        spl_id,
        image_id,
        spl_id
    )
end

function Model:getPingsForImageGroup(ig_id, spl_id)
    return self.conn:fetchAll(
        queries.model.get_pings_for_image_group,
        ig_id,
        spl_id,
        ig_id,
        spl_id
    )
end

local function decode_queue_description_errors(items)
    for i = 1, #items do
        ---@type ActiveQueueEntry
        local item = items[i]
        if item.description then
            local decoded, json_err = DecodeJson(item.description)
            if not json_err and type(decoded) == "table" then
                ---@cast decoded string[]|table[]
                item.description = table.map(decoded, function(desc_err)
                    if type(desc_err) == "table" then
                        return desc_err.description
                    end
                    return desc_err
                end)
                if #item.description == 1 then
                    item.description = item.description[1]
                end
            end
        end
    end
    return items
end

---@alias RecentQueueEntry {qid: string, link: string, tombstone: integer, added_on: string, status: string}
---@return RecentQueueEntry[]
function Model:getRecentQueueEntries()
    local result, err =
        self.conn:fetchAll(queries.model.get_recent_queue_entries)
    if not result then
        return err
    end
    return decode_queue_description_errors(result)
end

---@alias ActiveQueueEntry {qid: integer, link: string, image: string, image_mime_type: string, status: integer, added_on: string, description: string, help_ask: string, help_answer: string, retry_count: integer, tg_message_id: integer, tg_chat_id: integer, tg_source_link: string}
---@return ActiveQueueEntry[]
function Model:getAllActiveQueueEntries()
    return self.conn:fetchAll(
        queries.model.get_first_n_active_queue_entries,
        10
    )
end

function Model:getQueueEntryCount()
    return self:_get_count(queries.model.get_queue_entry_count)
end

function Model:getPaginatedQueueEntries(page_num, per_page)
    local results, err = self:_get_paginated(
        queries.model.get_queue_entries_paginated,
        page_num,
        per_page
    )
    if not results then
        return err
    end
    return decode_queue_description_errors(results)
end

function Model:getImageEntryCount()
    return self:_get_count(queries.model.get_image_entry_count)
end

function Model:getRecentImageEntries()
    return self.conn:fetchAll(queries.model.get_recent_image_entries)
end

function Model:getPaginatedImageEntries(page_num, per_page)
    return self:_get_paginated(
        queries.model.get_image_entries_newest_first_paginated,
        page_num,
        per_page
    )
end

function Model:getQueueEntryById(qid)
    return fetchOneExactly(self.conn, queries.model.get_queue_entry_by_id, qid)
end

function Model:getQueueImageById(qid)
    return fetchOneExactly(self.conn, queries.model.get_queue_image_by_id, qid)
end

function Model:getQueueImageByFilename(filename)
    return fetchOneExactly(
        self.conn,
        queries.model.get_queue_image_by_filename,
        filename
    )
end

function Model:getImageById(image_id)
    return fetchOneExactly(self.conn, queries.model.get_image_by_id, image_id)
end

function Model:getFirstThumbnailByImageId(image_id)
    return fetchOneExactly(
        self.conn,
        queries.model.get_first_thumbnail_by_image_id,
        image_id
    )
end

function Model:getAllImagesForSizeCheck()
    return self.conn:fetchAll(queries.model.get_all_images_for_size_check)
end

function Model:updateImageSize(image_id, size)
    return self.conn:execute(
        queries.model.update_image_size_by_id,
        size,
        image_id
    )
end

function Model:getArtistsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_artists_for_image, image_id)
end

function Model:getTagsForImage(image_id)
    return self.conn:fetchAll(queries.model.get_tags_for_image, image_id)
end

function Model:deleteTagsForImageById(image_id, tag_ids)
    return self:_delete_by_two_ids(
        queries.model.delete_image_tags_by_id,
        image_id,
        tag_ids
    )
end

function Model:createTag(tag_name, description)
    local tag, errmsg =
        self.conn:fetchOne(queries.model.insert_tag, tag_name, description)
    if not tag or tag == self.conn.NONE then
        return nil, errmsg
    end
    return tag.tag_id
end

function Model:getAllTags()
    return self.conn:fetchAll(queries.model.get_all_tags)
end

function Model:getSourcesForImage(image_id)
    return self.conn:fetchAll(queries.model.get_sources_for_image, image_id)
end

function Model:getAttributionForImage(image_id)
    return self.conn:fetchAll(queries.model.get_attribution_for_image, image_id)
end

function Model:updateImageMetadata(image_id, category, rating)
    return self.conn:execute(
        queries.model.update_category_rating_for_image_by_id,
        category,
        rating,
        image_id
    )
end

function Model:enqueueLink(link)
    local ok, result, errmsg = pcall(
        self.conn.fetchOne,
        self.conn,
        queries.model.insert_link_into_queue,
        link
    )
    if not ok then
        return nil, "Link already in queue"
    end
    return result, errmsg
end

function Model:enqueueImage(mime_type, image_data)
    local width, height = nil, nil
    if img then
        local imageu8, i_err = img.loadbuffer(image_data)
        if imageu8 then
            width = imageu8:width()
            height = imageu8:height()
            Log(kLogDebug, "Image dimensions: %d x %d" % { width, height })
        else
            Log(kLogWarn, "error while parsing image for enqueue:" .. i_err)
        end
    end
    local filename, f_err =
        FsTools.save_queue(image_data, mime_type, self.user_id)
    if not filename then
        return nil, f_err
    end
    local SP = "enqueue_image"
    self:create_savepoint(SP)
    local q_record, qerr =
        self.conn:fetchOne(queries.model.insert_image_into_queue)
    Log(kLogDebug, "q_record: " .. EncodeJson(q_record))
    if not q_record then
        Log(kLogInfo, "error while adding queue record for image: " .. qerr)
        self:rollback(SP)
        return nil, qerr
    end
    local ok, imgok, imgerr = pcall(
        self.conn.execute,
        self.conn,
        queries.model.insert_image_file_into_queue,
        q_record.qid,
        filename,
        mime_type,
        width,
        height
    )
    Log(kLogDebug, "imgok: " .. EncodeJson(imgok))
    if not ok then
        self:rollback(SP)
        Log(kLogInfo, "constraint violation when enqueing image: " .. imgok)
        return nil, "An exact copy of this file is already in the queue."
    end
    if not imgok then
        self:rollback(SP)
        Log(
            kLogInfo,
            "error while adding queue_image record for image: " .. imgerr
        )
        return nil, imgerr
    end
    self:release_savepoint(SP)
    return q_record
end

function Model:enqueueExactRowForTesting(row)
    local ok, result, errmsg = pcall(
        self.conn.fetchOne,
        self.conn,
        queries.model.insert_row_into_queue,
        row.link,
        row.added_on,
        row.status,
        row.description,
        row.retry_count,
        row.help_ask,
        row.help_answer,
        row.tg_chat_id,
        row.tg_message_id,
        row.tg_source_link
    )
    if not ok then
        print(result)
        return nil, "Link already in queue"
    end
    return result, errmsg
end

function Model:updateQueueItemTelegramIds(qid, chat_id, message_id)
    return self.conn:execute(
        queries.model.update_queue_item_telegram_ids,
        chat_id,
        message_id,
        qid
    )
end

function Model:updateQueueItemTelegramLink(qid, telegram_link)
    return self.conn:execute(
        queries.model.update_queue_item_telegram_link,
        telegram_link,
        qid
    )
end

function Model:resetQueueItemStatus(queue_ids)
    local SP_QRESET = "reset_queue_status"
    self:create_savepoint(SP_QRESET)
    for _, qid in ipairs(queue_ids) do
        local ok, err = self.conn:execute(
            queries.model.update_queue_item_status_to_zero,
            qid
        )
        if not ok then
            self:rollback(SP_QRESET)
            return nil, err
        end
    end
    self:release_savepoint(SP_QRESET)
    return #queue_ids
end

function Model:setQueueItemStatusOnly(queue_id, status)
    return self.conn:execute(
        queries.model.update_queue_item_status_only,
        status,
        queue_id
    )
end

function Model:setQueueItemStatusAndDescription(
    queue_id,
    status,
    new_description
)
    return self:setQueueItemsStatusAndDescription(
        { queue_id },
        status,
        new_description
    )
end

function Model:setQueueItemsStatusAndDescription(
    queue_ids,
    status,
    new_description
)
    local SP_QSTATUS = "set_queue_status"
    self:create_savepoint(SP_QSTATUS)
    for _, qid in ipairs(queue_ids) do
        local ok, err = self.conn:execute(
            queries.model.update_queue_item_status,
            new_description,
            status,
            qid
        )
        if not ok then
            self:rollback(SP_QSTATUS)
            return nil, err
        end
    end
    self:release_savepoint(SP_QSTATUS)
    return #queue_ids
end

function Model:incrementQueueItemRetryCount(qid)
    return self.conn:execute(
        queries.model.update_queue_item_retry_count_increment_by_one,
        qid
    )
end

function Model:setQueueItemDisambiguationRequest(queue_id, disambiguation_data)
    return self.conn:execute(
        queries.model.update_queue_item_help_ask,
        disambiguation_data,
        queue_id
    )
end

function Model:setQueueItemHelpAnswer(queue_id, help_answer)
    if type(help_answer) ~= "string" then
        help_answer = EncodeJson(help_answer)
    end
    return self.conn:fetchOne(
        queries.model.update_queue_item_help_answer,
        help_answer,
        queue_id
    )
end

function Model:setQueueItemHelpAsk(queue_id, value)
    if type(value) ~= "string" then
        value = EncodeJson(value)
    end
    return self.conn:execute(
        queries.model.update_queue_item_help_ask,
        value,
        queue_id
    )
end

function Model:insertImage(image_data, mime_type, width, height, kind, rating)
    if not rating then
        rating = DbUtil.k.Rating.General
    end
    local kind_override = kind
    if mime_type == "image/gif" then
        local is_gif, is_animated = GifTools.is_gif(image_data)
        if is_gif and is_animated then
            kind_override = DbUtil.k.ImageKind.Animation
        end
    end
    local filename, f_err = FsTools.save_image(image_data, mime_type)
    if not filename then
        return nil, f_err
    end
    local ok, image, i_err = pcall(
        self.conn.fetchOne,
        self.conn,
        queries.model.insert_image_into_images,
        filename,
        mime_type,
        width,
        height,
        kind_override,
        rating,
        #image_data
    )
    if not ok then
        return nil, "An exact copy of this media file is already archived."
    end
    Log(
        kLogDebug,
        "image: %s; i_err: %s" % { tostring(image), tostring(i_err) }
    )
    if not image then
        return nil, i_err
    end
    return image
end

---Replace the image file for a record with a new file.
---@param image_id integer The ID of the record to update.
---@param image_data string The new media file data to associate with the record, instead of what's already there.
---@param mime_type string The MIME type of the new media file data.
---@param width integer The width in pixels of the new media file.
---@param height integer The height in pixels of the new media file.
function Model:replaceImage(image_id, image_data, mime_type, width, height)
    local existing, e_err = self:getImageById(image_id)
    if not existing then
        return nil, e_err
    end
    -- If the image isn't bigger/higher quality, do nothing.
    Log(
        kLogDebug,
        "Existing image: %d x %d (%s); Replacement image: %d x %d (%s)"
            % {
                existing.width,
                existing.height,
                existing.mime_type,
                width,
                height,
                mime_type,
            }
    )
    local isLarger = (width > existing.width and height > existing.height)
    local isSameSizePNG = (
        width == existing.width
        and height == existing.height
        and mime_type == "image/png"
    )
    local _, existing_filename =
        FsTools.make_image_path_from_filename(existing.file)
    local canReadExisting, r_err =
        unix.access(existing_filename, unix.R_OK | unix.W_OK)
    local fileMissing = canReadExisting == nil
    if not (isLarger or isSameSizePNG or fileMissing) then
        Log(
            kLogVerbose,
            "Not replacing image because the newer version is smaller or not an equally-sized PNG, or because the current file is gone."
        )
        return { image_id = image_id }
    end
    Log(
        kLogVerbose,
        "Replaced the image because the newer version is larger or an equally-sized PNG, or because the current file is gone."
    )
    local filename, f_err = FsTools.save_image(image_data, mime_type)
    if not filename then
        return nil, f_err
    end
    local ok, image, i_err = pcall(
        self.conn.execute,
        self.conn,
        queries.model.update_image_replace_image_by_id,
        filename,
        mime_type,
        width,
        height,
        #image_data,
        image_id
    )
    if not ok then
        return nil, "An exact copy of this media file is already archived."
    end
    if not image then
        return nil, i_err
    end
    return { image_id = image_id }
end

function Model:insertThumbnailForImage(
    image_id,
    thumbnail_data,
    width,
    height,
    scale,
    mime_type
)
    local hash = EncodeBase64(GetCryptoHash("SHA256", thumbnail_data))
    return self.conn:execute(
        queries.model.insert_thumbnail,
        image_id,
        thumbnail_data,
        hash,
        width,
        height,
        scale,
        mime_type
    )
end

function Model:getThumbnailImageById(thumbnail_id)
    return fetchOneExactly(
        self.conn,
        queries.model.get_thumbnail_by_id,
        thumbnail_id
    )
end

function Model:checkDuplicateSources(links)
    local dupes = {}
    for _, link in ipairs(links) do
        Log(kLogDebug, "checking for duplicates of: %s" % { EncodeJson(link) })
        local sources, errmsg =
            self.conn:fetchAll(queries.model.get_source_by_link, link)
        if not sources then
            return nil, errmsg
        end
        for _, image in ipairs(sources) do
            local dupe_list = nil
            if dupes[link] then
                dupe_list = dupes[link]
            else
                dupe_list = {}
                dupes[link] = dupe_list
            end
            dupe_list[#dupe_list + 1] = image.image_id
        end
    end
    return dupes
end

function Model:insertSourcesForImage(image_id, sources)
    local SP = "insert_sources"
    self:create_savepoint(SP)
    for _, source in ipairs(sources) do
        local result, errmsg = self.conn:execute(
            queries.model.insert_source_for_image,
            image_id,
            source
        )
        if not result then
            self:rollback(SP)
            return nil, errmsg
        end
    end
    self:release_savepoint(SP)
    return true
end

-- Just the source ID should be enough to identify it, but I'm adding in the image_id as a hedge against my own stupidity.
function Model:deleteSourcesForImageById(image_id, source_ids)
    return self:_delete_by_two_ids(
        queries.model.delete_source_by_id,
        image_id,
        source_ids
    )
end

function Model:getDiskSpaceUsage()
    local result, errmsg =
        self.conn:fetchOne(queries.model.get_disk_space_usage)
    if not result then
        return nil, errmsg
    end
    return result.size_sum
end

function Model:getTagCount()
    local result, errmsg = self.conn:fetchOne(queries.model.get_tag_entry_count)
    if not result then
        return nil, errmsg
    end
    return result.count
end

function Model:getTagCountForSearch(search_term)
    return self:_get_count({
        queries.model.get_tag_entry_count,
        queries.model.get_tag_entry_count_search,
    }, search_term)
end

function Model:getArtistCount()
    return self:_get_count(queries.model.get_artist_entry_count)
end

function Model:getArtistCountForSearch(search_term)
    return self:_get_count({
        queries.model.get_artist_entry_count,
        queries.model.get_artist_entry_count_search,
    }, search_term)
end

function Model:getAllArtists()
    return self.conn:fetchAll(queries.model.get_all_artists)
end

function Model:getPaginatedArtists(page_num, per_page)
    return self:_get_paginated(
        queries.model.get_artist_entries_paginated,
        page_num,
        per_page
    )
end

function Model:searchPaginatedArtists(page_num, per_page, search_term)
    return self:_get_paginated({
        queries.model.get_artist_entries_paginated,
        queries.model.get_artist_entries_paginated_search,
    }, page_num, per_page, search_term)
end

function Model:getPaginatedTags(page_num, per_page)
    return self:_get_paginated(
        queries.model.get_tag_entries_paginated,
        page_num,
        per_page
    )
end

function Model:searchPaginatedTags(page_num, per_page, search_term)
    return self:_get_paginated({
        queries.model.get_tag_entries_paginated,
        queries.model.get_tag_entries_paginated_search,
    }, page_num, per_page, search_term)
end

function Model:getArtistById(artist_id)
    return fetchOneExactly(self.conn, queries.model.get_artist_by_id, artist_id)
end

function Model:getTagById(tag_id)
    return fetchOneExactly(self.conn, queries.model.get_tag_by_id, tag_id)
end

function Model:updateTag(tag_id, name, desc)
    return self.conn:execute(queries.model.update_tag_by_id, name, desc, tag_id)
end

function Model:getHandlesForArtist(artist_id)
    return self.conn:fetchAll(queries.model.get_handles_for_artist, artist_id)
end

function Model:getRecentImagesForArtist(artist_id, limit)
    return self.conn:fetchAll(
        queries.model.get_recent_images_for_artist,
        artist_id,
        limit
    )
end

function Model:getRecentImagesForTag(tag_id, limit)
    return self.conn:fetchAll(
        queries.model.get_recent_images_for_tag,
        tag_id,
        limit
    )
end

function Model:createHandleForArtist(artist_id, handle, domain, profile_url)
    return self.conn:execute(
        queries.model.insert_artist_handle,
        artist_id,
        handle,
        domain,
        profile_url
    )
end

function Model:updateArtist(artist_id, name, manually_verified)
    local ok, result, err = pcall(
        self.conn.execute,
        self.conn,
        queries.model.update_artist_by_id,
        name,
        manually_verified,
        artist_id
    )
    if not ok then
        return nil, "An artist already exists with that name."
    end
    if not result then
        return nil, err
    end
    return result
end

function Model:findArtistIdByName(name)
    return self.conn:fetchOne(queries.model.get_artist_id_by_name, name)
end

function Model:getOrCreateArtist(name, manually_verified)
    local ok, artist, errmsg = pcall(
        self.conn.fetchOne,
        self,
        queries.model.insert_artist,
        name,
        manually_verified
    )
    if not ok then
        self.conn.prepcache = {}
        artist, errmsg = self:findArtistIdByName(name)
    end
    if not artist or artist == self.conn.NONE then
        return nil, errmsg
    end
    return artist.artist_id
end

function Model:createArtistWithHandles(name, manually_verified, handles)
    local SP = "create_artist_with_several_handles"
    self:create_savepoint(SP)
    local artist_id, errmsg = self:getOrCreateArtist(name, manually_verified)
    if not artist_id then
        self:rollback(SP)
        Log(kLogInfo, tostring(errmsg))
        return nil, errmsg
    end
    for i = 1, #handles do
        local handle = handles[i]
        local handle_ok, handle_err = self:createHandleForArtist(
            artist_id,
            handle.handle,
            handle.domain,
            handle.profile_url
        )
        if not handle_ok then
            self:rollback(SP)
            Log(kLogInfo, handle_err)
            return nil, handle_err
        end
    end
    self:release_savepoint(SP)
    return artist_id
end

function Model:associateTagWithImage(image_id, tag_id)
    return self.conn:fetchOne(queries.model.insert_image_tag, image_id, tag_id)
end

---@param author_info ScrapedAuthor
---@param domain string
function Model:createArtistAndFirstHandle(author_info, domain)
    local name = author_info.display_name
    local handles = {
        {
            handle = author_info.handle,
            domain = domain,
            profile_url = author_info.profile_url,
        },
    }
    return self:createArtistWithHandles(name, 0, handles)
end

---@param image_id integer
---@param artist_id integer
function Model:associateArtistWithImage(image_id, artist_id)
    return self.conn:execute(
        queries.model.insert_image_artist,
        image_id,
        artist_id
    )
end

---@param image_id integer
---@param domain string The domain name of the website that author_info is from.
---@param author_info ScrapedAuthor
function Model:createOrAssociateArtistWithImage(image_id, domain, author_info)
    local SP = "create_or_associate_artist"
    self:create_savepoint(SP)
    local artist, errmsg = self.conn:fetchOne(
        queries.model.get_artist_id_by_domain_and_handle,
        domain,
        author_info.handle
    )
    if not artist then
        Log(kLogInfo, "failed to look up artist by domain+handle: " .. errmsg)
        return nil, errmsg
    end
    local artist_id = artist.artist_id
    if not artist_id or artist == self.conn.NONE then
        local result3, errmsg3 =
            self:createArtistAndFirstHandle(author_info, domain)
        if not result3 then
            self:rollback(SP)
            Log(kLogInfo, "failed to create artist: " .. errmsg3)
            return nil, errmsg3
        end
        artist_id = result3
    end
    local result2, errmsg2 = self:associateArtistWithImage(image_id, artist_id)
    if not result2 then
        self:rollback(SP)
        Log(kLogInfo, "failed to link artist with image: " .. errmsg2)
        return nil, errmsg2
    end
    self:release_savepoint(SP)
    return true
end

function Model:addArtistsForImageByName(image_id, artist_names)
    local SP = "add_artists_for_image_by_name"
    self:create_savepoint(SP)
    for i = 1, #artist_names do
        local artist, errmsg = self.conn:fetchOne(
            queries.model.get_artist_id_by_name,
            artist_names[i]
        )
        if not artist then
            self:rollback(SP)
            return nil, errmsg
        end
        local artist_id = artist.artist_id
        if artist == self.conn.NONE then
            artist_id, errmsg = self:getOrCreateArtist(artist_names[i], 1)
            if not artist_id then
                self:rollback(SP)
                return nil, errmsg
            end
        end
        local link_ok, link_err =
            self:associateArtistWithImage(image_id, artist_id)
        if not link_ok then
            self:rollback(SP)
            return nil, link_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:findTagIdByName(tag_name)
    return self.conn:fetchOne(queries.model.get_tag_id_by_name, tag_name)
end

function Model:getOrCreateTagIdByName(tag_name)
    local tag, t_err =
        self.conn:fetchOne(queries.model.insert_tag, tag_name, "")
    if not tag or tag == self.conn.NONE then
        tag, t_err =
            self.conn:fetchOne(queries.model.get_tag_id_by_name, tag_name)
    end
    if not tag or tag == self.conn.NONE then
        return nil, t_err
    end
    return tag.tag_id
end

function Model:addTagsForImageByName(image_id, tag_names)
    local SP = "add_tags_for_image_by_name"
    self:create_savepoint(SP)
    for i = 1, #tag_names do
        local tag_name = tag_names[i]
        local tag_id, errmsg = self:getOrCreateTagIdByName(tag_name)
        if not tag_id then
            self:rollback(SP)
            Log(kLogDebug, tostring(errmsg))
            return nil, errmsg
        end
        local link_ok, link_err = self:associateTagWithImage(image_id, tag_id)
        if not link_ok then
            self:rollback(SP)
            Log(kLogDebug, link_err)
            return nil, link_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:deleteArtists(artist_ids)
    return self:_delete_by_id(queries.model.delete_artist_by_id, artist_ids)
end

function Model:deleteTags(tag_ids)
    return self:_delete_by_id(queries.model.delete_tag_by_id, tag_ids)
end

function Model:mergeArtists(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_artists"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local handle_ok, handle_err = self.conn:execute(
            queries.model.update_handles_to_other_artist,
            merge_into_id,
            merge_from_id
        )
        if not handle_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, handle_err)
            return nil, handle_err
        end
        local image_ok, image_err = self.conn:execute(
            queries.model.update_image_artists_to_other_artist,
            merge_into_id,
            merge_from_id
        )
        if not image_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, image_err)
            return nil, image_err
        end
    end
    local delete_ok, delete_err = self:deleteArtists(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, tostring(delete_err))
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:mergeTags(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_tags"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local image_ok, image_err = self.conn:execute(
            queries.model.update_image_tags_to_other_tag,
            merge_into_id,
            merge_from_id
        )
        if not image_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, image_err)
            return nil, image_err
        end
        local tr_ok, tr_err = self.conn:execute(
            queries.model.update_tag_rules_to_other_tag,
            merge_into_id,
            merge_from_id
        )
        if not tr_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, tr_err)
            return nil, tr_err
        end
    end
    local delete_ok, delete_err = self:deleteTags(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, tostring(delete_err))
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:deleteArtistsForImageById(image_id, artist_ids)
    return self:_delete_by_two_ids(
        queries.model.delete_image_artist_by_id,
        image_id,
        artist_ids
    )
end

function Model:deleteHandlesForArtistById(artist_id, handle_ids)
    return self:_delete_by_two_ids(
        queries.model.delete_handle_for_artist_by_id,
        artist_id,
        handle_ids
    )
end

function Model:getImageGroupCount()
    return self:_get_count(queries.model.get_image_group_count)
end

function Model:getImageGroupCountForSearch(search)
    return self:_get_count({
        queries.model.get_image_group_count,
        queries.model.get_image_group_count_search,
    }, search)
end

function Model:getPaginatedImageGroups(page_num, per_page, query)
    return self:_get_paginated(
        queries.model.get_image_groups_paginated,
        page_num,
        per_page,
        query
    )
end

function Model:searchPaginatedImageGroups(page_num, per_page, query)
    return self:_get_paginated({
        queries.model.get_image_groups_paginated,
        queries.model.get_image_groups_paginated_search,
    }, page_num, per_page, query)
end

function Model:renameImageGroup(ig_id, new_name)
    return self.conn:execute(
        queries.model.update_name_for_image_group_by_id,
        new_name,
        ig_id
    )
end

function Model:getGroupsForImage(image_id)
    return self.conn:fetchAll(
        queries.model.get_image_groups_by_image_id,
        image_id
    )
end

function Model:getPrevNextImagesInGroupForImage(ig_id, image_id)
    local siblings = {}
    local results, errmsg = self.conn:fetchAll(
        queries.model.get_prev_next_images_in_group,
        ig_id,
        image_id
    )
    if not results then
        return nil, errmsg
    end
    for _, result in ipairs(results) do
        if result.my_order > result.sibling_order then
            siblings.prev = result.image_id
            siblings.my_order = result.my_order
        elseif result.my_order < result.sibling_order then
            siblings.next = result.image_id
            siblings.my_order = result.my_order
        end
    end
    return siblings
end

function Model:createImageGroup(name)
    return self.conn:fetchOne(queries.model.insert_image_group, name)
end

function Model:addImageToGroupAtEnd(image_id, group_id)
    local last_order, errmsg = self.conn:fetchOne(
        queries.model.get_last_order_for_image_group,
        group_id
    )
    if not last_order then
        return nil, errmsg
    end
    return self.conn:execute(
        queries.model.insert_image_in_group,
        image_id,
        group_id,
        (last_order.max_order or 0) + 1
    )
end

function Model:removeImagesFromGroupById(ig_id, image_ids)
    return self:_delete_by_two_ids(
        queries.model.delete_image_from_group_by_id,
        ig_id,
        image_ids
    )
end

function Model:createImageGroupWithImages(name, image_ids)
    local SP = "create_image_group_with_images"
    self:create_savepoint(SP)
    local group, group_err = self:createImageGroup(name)
    if not group then
        self:rollback(SP)
        return nil, group_err
    end
    for i = 1, #image_ids do
        local add_ok, add_err = self.conn:execute(
            queries.model.insert_image_in_group,
            image_ids[i],
            group.ig_id,
            i
        )
        if not add_ok then
            self:rollback(SP)
            return nil, add_err
        end
    end
    self:release_savepoint(SP)
    return group.ig_id
end

function Model:getImageGroupById(ig_id)
    local group, err =
        self.conn:fetchOne(queries.model.get_image_group_by_id, ig_id)
    if not group then
        return nil, err
    elseif group == self.conn.NONE then
        return nil, "No such group"
    end
    return group
end

function Model:getImagesForGroup(ig_id)
    return self.conn:fetchAll(queries.model.get_images_for_group, ig_id)
end

function Model:setOrderForImageInGroup(ig_id, image_id, new_order)
    return self.conn:execute(
        queries.model.update_order_for_image_in_image_group,
        new_order,
        ig_id,
        image_id
    )
end

function Model:deleteImageGroups(ig_ids)
    return self:_delete_by_id(queries.model.delete_image_group_by_id, ig_ids)
end

function Model:moveAllImagesToOtherGroup(to_ig_id, from_ig_id)
    return self.conn:execute(
        queries.model.update_images_to_other_group_preserving_order,
        to_ig_id,
        to_ig_id,
        from_ig_id
    )
end

function Model:mergeImageGroups(merge_into_id, merge_from_ids)
    local SP_MERGE = "merge_image_groups"
    self:create_savepoint(SP_MERGE)
    for i = 1, #merge_from_ids do
        local merge_from_id = merge_from_ids[i]
        local group_ok, group_err = self.conn:execute(
            queries.model.update_images_to_other_group_preserving_order,
            merge_into_id,
            merge_into_id,
            merge_from_id
        )
        if not group_ok then
            self:rollback(SP_MERGE)
            Log(kLogInfo, group_err)
            return nil, group_err
        end
    end
    local delete_ok, delete_err = self:deleteImageGroups(merge_from_ids)
    if not delete_ok then
        self:rollback(SP_MERGE)
        Log(kLogInfo, tostring(delete_err))
        return nil, delete_err
    end
    self:release_savepoint(SP_MERGE)
    return delete_ok
end

function Model:deleteFromQueue(queue_ids)
    return self:_delete_by_id(queries.model.delete_item_from_queue, queue_ids)
end

function Model:getTagRuleCount()
    return self:_get_count(queries.model.get_tag_rule_count)
end

function Model:getPaginatedTagRules(cur_page, per_page)
    return self:_get_paginated(
        queries.model.get_tag_rules_paginated,
        cur_page,
        per_page
    )
end

function Model:deleteTagRules(tag_rule_ids)
    return self:_delete_by_id(queries.model.delete_tag_rule_by_id, tag_rule_ids)
end

function Model:getTagRuleById(tag_rule_id)
    return self.conn:fetchOne(queries.model.get_tag_rule_by_id, tag_rule_id)
end

function Model:updateTagRule(
    tag_rule_id,
    incoming_name,
    incoming_domain,
    tag_name
)
    local SP = "update_tag_rule"
    self:create_savepoint(SP)
    self.conn:execute(queries.model.insert_or_ignore_tag_by_name, tag_name)
    local tag, tag_err = self:findTagIdByName(tag_name)
    if not tag then
        self:rollback(SP)
        return nil, tag_err
    end
    -- Should never be none, because we inserted right before.
    local update_ok, update_err = self.conn:execute(
        queries.model.update_tag_rule_by_id,
        incoming_name,
        incoming_domain,
        tag.tag_id,
        tag_rule_id
    )
    if not update_ok then
        self:rollback(SP)
        return nil, update_err
    end
    self:release_savepoint(SP)
    return true
end

function Model:createTagRule(incoming_name, incoming_domain, tag_name)
    local SP = "create_tag_rule"
    self:create_savepoint(SP)
    self.conn:execute(queries.model.insert_or_ignore_tag_by_name, tag_name)
    local tag_id, tag_err = self:findTagIdByName(tag_name)
    if not tag_id then
        self:rollback(SP)
        return nil, tag_err
    end
    local insert_ok, insert_err = self.conn:fetchOne(
        queries.model.insert_tag_rule,
        incoming_name,
        incoming_domain,
        tag_id.tag_id
    )
    if not insert_ok then
        self:rollback(SP)
        return nil, insert_err
    end
    self:release_savepoint(SP)
    return insert_ok.tag_rule_id
end

function Model:addIncomingTagsForImage(
    image_id,
    incoming_domain,
    incoming_tag_names
)
    local SP = "add_incoming_tags"
    self:create_savepoint(SP)
    for i = 1, #incoming_tag_names do
        local name = incoming_tag_names[i]
        local tag_rule, tag_rule_err = self.conn:fetchOne(
            queries.model.get_tag_id_by_incoming_name_domain,
            incoming_domain,
            name
        )
        if not tag_rule then
            self:rollback(SP)
            return nil, tag_rule_err
        end
        local image_tag_id = nil
        if tag_rule ~= self.conn.NONE then
            local image_tag, tag_err =
                self:associateTagWithImage(image_id, tag_rule.tag_id)
            if not image_tag then
                self:rollback(SP)
                return nil, tag_err
            end
            image_tag_id = image_tag.image_tag_id
        end
        local itag_ok, itag_err = self.conn:execute(
            queries.model.insert_incoming_tag,
            name,
            incoming_domain,
            image_id,
            image_tag_id
        )
        if not itag_ok then
            self:rollback(SP)
            return nil, itag_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:getIncomingTagsForImage(image_id)
    return self.conn:fetchAll(
        queries.model.get_incoming_tags_for_image_by_id,
        image_id
    )
end

function Model:getIncomingTagsByIds(itids)
    local result = {}
    assert(#itids > 0)
    for i = 1, #itids do
        local it, err = fetchOneExactly(
            self.conn,
            queries.model.get_incoming_tag_by_id,
            itids[i]
        )
        if not it then
            return nil, err
        end
        result[#result + 1] = it
    end
    return result
end

function Model:applyIncomingTagsNowMatchedByTagRules()
    local SP = "apply_incoming_tags_now_matched_by_tag_rules"
    self:create_savepoint(SP)
    local changes, c_err =
        self.conn:fetchAll(queries.model.get_images_and_tags_for_new_tag_rules)
    if not changes then
        self:rollback(SP)
        Log(kLogDebug, "error in first query")
        return nil, c_err
    end
    if changes == self.conn.NONE then
        Log(kLogDebug, "no results from first query")
        self:release_savepoint(SP)
        return changes
    end
    local new_ids, apply_err =
        self.conn:fetchAll(queries.model.insert_image_tags_for_new_tag_rules)
    if not new_ids then
        Log(kLogDebug, "failed to apply tag rules")
        self:rollback(SP)
        return nil, apply_err
    end
    for i = 1, #new_ids do
        local new_id = new_ids[i]
        Log(
            kLogDebug,
            "Updating image_tag_id %d for image %d and tag %d"
                % { new_id.image_tag_id, new_id.image_id, new_id.tag_id }
        )
        local pcall_ok, upd_ok, upd_err = pcall(
            self.conn.execute,
            self.conn,
            queries.model.update_image_tag_id_for_incoming_tags,
            new_id.image_tag_id,
            new_id.image_id,
            new_id.tag_id
        )
        if not pcall_ok and upd_ok:startswith("FOREIGN") then
            Log(
                kLogDebug,
                "Unable to update image_tag_id %d because it doesn't exist. I will assume this is because it was replaced by a later tag rule and ignore the problem."
                    % { new_id.image_tag_id }
            )
            -- Clear the prepared statement cache so that the next call doesn't
            -- try to use the now-faulted statement.
            self.conn.prepcache = {}
        elseif not upd_ok then
            Log(
                kLogInfo,
                "failed to update image_tag_id = %d for incoming tags for image %d and tag %d"
                    % { new_id.image_tag_id, new_id.image_id, new_id.tag_id }
            )
            self:rollback(SP)
            return nil, upd_err
        elseif not pcall_ok then
            local msg = "Unexpected error: %s / %s"
                % { tostring(upd_ok), tostring(upd_err) }
            Log(kLogInfo, msg)
            self:rollback(SP)
            return nil, msg
        end
    end
    Log(kLogDebug, "made it to the end successfully")
    self:release_savepoint(SP)
    return changes
end

function Model:applyIncomingTagsNowMatchedBySpecificTagRules(tag_rule_ids)
    local SP = "apply_incoming_tags_now_matched_by_specific_tag_rules"
    self:create_savepoint(SP)
    local changes = {}
    for i = 1, #tag_rule_ids do
        local part_changes, pc_err = self.conn:fetchAll(
            queries.model.get_images_and_tags_for_new_tag_rules_by_tag_rule_id,
            tag_rule_ids[i]
        )
        if not part_changes then
            self:rollback(SP)
            return nil, pc_err
        end
        table.extend(changes, part_changes)
    end
    if #changes < 1 then
        Log(kLogDebug, "No changes to apply for specified tag rules.")
        self:release_savepoint(SP)
        return changes
    end
    local new_ids = {}
    for i = 1, #tag_rule_ids do
        local part_new_ids, pni_err = self.conn:fetchAll(
            queries.model.insert_image_tags_for_new_tag_rules_by_id,
            tag_rule_ids[i]
        )
        if not part_new_ids then
            Log(kLogInfo, "Failed to apply new tag rules: " .. pni_err)
            self:rollback(SP)
            return nil, pni_err
        end
        table.extend(new_ids, part_new_ids)
    end
    for i = 1, #new_ids do
        local new_id = new_ids[i]
        Log(
            kLogDebug,
            "Updating image_tag_id %d for image %d and tag %d"
                % { new_id.image_tag_id, new_id.image_id, new_id.tag_id }
        )
        local pcall_ok, upd_ok, upd_err = pcall(
            self.conn.execute,
            self.conn,
            queries.model.update_image_tag_id_for_incoming_tags,
            new_id.image_tag_id,
            new_id.image_id,
            new_id.tag_id
        )
        if not pcall_ok and upd_ok:startswith("FOREIGN") then
            Log(
                kLogDebug,
                "Unable to update image_tag_id %d because it doesn't exist. I will assume this is because it was replaced by a later tag rule and ignore the problem."
                    % { new_id.image_tag_id }
            )
            -- Clear the prepared statement cache so that the next call doesn't
            -- try to use the now-faulted statement.
            self.conn.prepcache = {}
        elseif not upd_ok then
            Log(
                kLogInfo,
                "failed to update image_tag_id = %d for incoming tags for image %d and tag %d"
                    % { new_id.image_tag_id, new_id.image_id, new_id.tag_id }
            )
            self:rollback(SP)
            return nil, upd_err
        elseif not pcall_ok then
            local msg = "Unexpected error: %s / %s"
                % { tostring(upd_ok), tostring(upd_err) }
            Log(kLogInfo, msg)
            self:rollback(SP)
            return nil, msg
        end
    end
    self:release_savepoint(SP)
    return changes
end

function Model:createSharePingList(name, share_data, send_with_attribution)
    if type(share_data) ~= "string" then
        share_data = EncodeJson(share_data)
    end
    local id, err = self.conn:fetchOne(
        queries.model.insert_share_ping_list,
        name,
        share_data,
        send_with_attribution
    )
    if not id then
        return nil, err
    end
    return id.spl_id
end

function Model:updateSharePingListMetadata(
    spl_id,
    name,
    share_data,
    send_with_attribution
)
    if type(share_data) ~= "string" then
        share_data = EncodeJson(share_data)
    end
    return self.conn:execute(
        queries.model.update_spl_entry_metadata,
        name,
        share_data,
        send_with_attribution,
        spl_id
    )
end

function Model:updateSharePingListEntry(spl_entry_id, handle, nickname, enabled)
    if enabled == true then
        enabled = 1
    else
        enabled = 0
    end
    return self.conn:execute(
        queries.model.update_spl_entry_by_id,
        handle,
        nickname,
        enabled,
        spl_entry_id
    )
end

function Model:getAllSharePingLists()
    local result, err =
        self.conn:fetchAll(queries.model.get_all_share_ping_lists)
    if not result then
        return nil, err
    end
    for i = 1, #result do
        local json, json_err = DecodeJson(result[i].share_data)
        if not json then
            return nil, json_err
        end
        result[i].share_data = json
    end
    return result
end

function Model:_linkTagsToSPLEntry(query, entry_id, tags)
    local SP = "link_tags_to_spl_entry"
    self:create_savepoint(SP)
    for i = 1, #tags do
        local tag_name = tags[i]
        Log(kLogDebug, "Trying to link %s to %d" % { tag_name, entry_id })
        local tag_id, t_err = self:getOrCreateTagIdByName(tag_name)
        if not tag_id then
            self:rollback(SP)
            return nil, t_err
        end
        Log(kLogDebug, "Using tag_id " .. tostring(tag_id))
        local link_ok, link_err = self.conn:execute(query, entry_id, tag_id)
        if not link_ok then
            self:rollback(SP)
            return nil, link_err
        end
    end
    self:release_savepoint(SP)
    return true
end

function Model:linkPositiveTagsToSPLEntryByName(entry_id, tag_names)
    return self:_linkTagsToSPLEntry(
        queries.model.insert_positive_tag,
        entry_id,
        tag_names
    )
end

function Model:linkNegativeTagsToSPLEntryByName(entry_id, tag_names)
    return self:_linkTagsToSPLEntry(
        queries.model.insert_negative_tag,
        entry_id,
        tag_names
    )
end

function Model:createSPLEntryWithTags(
    spl_id,
    handle,
    nickname,
    pos_tags,
    neg_tags
)
    local SP = "create_spl_entry_with_tags"
    self:create_savepoint(SP)
    local entry, entry_err = self.conn:fetchOne(
        queries.model.insert_spl_entry,
        handle,
        nickname,
        true,
        spl_id
    )
    if not entry then
        self:rollback(SP)
        return nil, entry_err
    end
    local ok, err =
        self:linkPositiveTagsToSPLEntryByName(entry.spl_entry_id, pos_tags)
    if not ok then
        self:rollback(SP)
        return nil, err
    end
    ok, err =
        self:linkNegativeTagsToSPLEntryByName(entry.spl_entry_id, neg_tags)
    if not ok then
        self:rollback(SP)
        return nil, err
    end
    self:release_savepoint(SP)
    return true
end

function Model:deleteSharePingList(spl_id)
    return self:_delete_by_id(queries.model.delete_spl_by_id, { spl_id })
end

function Model:getSharePingListById(spl_id, skip_decode)
    local result, err = fetchOneExactly(
        self.conn,
        queries.model.get_share_ping_list_by_id,
        spl_id
    )
    if not result then
        return nil, err
    end
    if not skip_decode then
        local json, json_err = DecodeJson(result.share_data)
        if not json then
            return nil, json_err
        end
        result.share_data = json
        result.send_with_attribution = result.send_with_attribution == 1
    end
    return result
end

function Model:getEntriesForSPLById(spl_id)
    local entries, e_err = self.conn:fetchAll(
        queries.model.get_entries_for_ping_list_by_id,
        spl_id
    )
    if not entries then
        return nil, e_err
    end
    local positive_tags, p_err = self.conn:fetchAll(
        queries.model.get_all_positive_tags_for_all_entries_in_ping_list_by_id,
        spl_id
    )
    if not positive_tags then
        return nil, p_err
    end
    local negative_tags, n_err = self.conn:fetchAll(
        queries.model.get_all_negative_tags_for_all_entries_in_ping_list_by_id,
        spl_id
    )
    if not negative_tags then
        return nil, n_err
    end
    local positive_tags_regrouped = {}
    local negative_tags_regrouped = {}
    for i = 1, #entries do
        local entry = entries[i]
        positive_tags_regrouped[entry.spl_entry_id] = {}
        negative_tags_regrouped[entry.spl_entry_id] = {}
        -- Also change enabled from int to bool
        entry.enabled = (entry.enabled == 1)
    end
    for i = 1, #positive_tags do
        local tag = positive_tags[i]
        local list = positive_tags_regrouped[tag.spl_entry_id]
        list[#list + 1] = tag
    end
    for i = 1, #negative_tags do
        local tag = negative_tags[i]
        local list = negative_tags_regrouped[tag.spl_entry_id]
        list[#list + 1] = tag
    end
    return entries, positive_tags_regrouped, negative_tags_regrouped
end

function Model:deleteSPLEntriesById(delete_entry_ids)
    return self:_delete_by_id(
        queries.model.delete_spl_entry_by_id,
        delete_entry_ids
    )
end

function Model:deletePLPositiveTagsByPair(pairs)
    return self:_delete_by_two_ids_arbitrary(
        queries.model.delete_pl_positive_tag,
        pairs
    )
end

function Model:deletePLNegativeTagsByPair(pairs)
    return self:_delete_by_two_ids_arbitrary(
        queries.model.delete_pl_negative_tag,
        pairs
    )
end

local function split_hash(hash)
    local mask = 0xFFFF
    local h4 = hash & mask
    local h3 = (hash >> 16) & mask
    local h2 = (hash >> 32) & mask
    local h1 = (hash >> 48) & mask
    return h1, h2, h3, h4
end

local function assemble_hash(h1, h2, h3, h4)
    return (h1 << 48) | (h2 << 32) | (h3 << 16) | h4
end

local popcnt = Popcnt

local function hamming_distance(a, b)
    -- ~ is Lua's bitwise XOR operator. Redbean provides Popcnt.
    return popcnt(a ~ b)
end

local function post_filter_ham(search_hash, max_distance, rows)
    assert(
        max_distance <= 3,
        "this function only produces correct results when max_distance is between 3 and 0 (inclusive)"
    )
    local results = {}
    for _, row in pairs(rows) do
        local row_hash = assemble_hash(row.h1, row.h2, row.h3, row.h4)
        local distance = hamming_distance(search_hash, row_hash)
        if distance <= max_distance then
            row.distance = distance
            results[#results + 1] = row
        end
    end
    return results
end

function Model:insertImageHash(image_id, hash)
    local h1, h2, h3, h4 = split_hash(hash)
    return self.conn:execute(
        queries.model.insert_image_hash,
        image_id,
        h1,
        h2,
        h3,
        h4
    )
end

function Model:insertQueueHash(qid, hash)
    local h1, h2, h3, h4 = split_hash(hash)
    return self.conn:execute(
        queries.model.insert_queue_hash,
        qid,
        h1,
        h2,
        h3,
        h4
    )
end

function Model:_findSimilarHashes(query, hash, max_distance)
    local h1, h2, h3, h4 = split_hash(hash)
    local rows, err = self.conn:fetchAll(query, h1, h2, h3, h4)
    if not rows then
        return nil, err
    end
    local results = post_filter_ham(hash, max_distance, rows)
    table.sort(results, function(a, b)
        return b.distance < a.distance
    end)
    return results
end

function Model:findSimilarImageHashes(hash, max_distance)
    return self:_findSimilarHashes(
        queries.model.get_approximately_equal_image_hashes,
        hash,
        max_distance
    )
end

function Model:findSimilarQueueHashes(hash, max_distance)
    return self:_findSimilarHashes(
        queries.model.get_approximately_equal_queue_hashes,
        hash,
        max_distance
    )
end

function Model:cleanUpQueue()
    return self.conn:execute(queries.model.delete_handled_queue_entries)
end

function Model:createPendingShareRecordForImage(image_id, to_where)
    local share_id = NanoID.simple_with_prefix(IdPrefixes.share)
    local ok, err = self.conn:fetchOne(
        queries.model.insert_pending_share_record_for_image,
        share_id,
        image_id,
        to_where
    )
    if not ok then
        return nil, err
    end
    return share_id
end

function Model:createPendingShareRecordForImageGroup(ig_id, to_where)
    local share_id = NanoID.simple_with_prefix(IdPrefixes.share)
    local ok, err = self.conn:fetchOne(
        queries.model.insert_pending_share_record_for_image_group,
        share_id,
        ig_id,
        to_where
    )
    if not ok then
        return nil, err
    end
    return share_id
end

function Model:getShareRecordsForImage(image_id)
    return self.conn:fetchAll(
        queries.model.get_share_records_for_image,
        image_id
    )
end

function Model:getShareRecordsForImageGroup(ig_id)
    return self.conn:fetchAll(
        queries.model.get_share_records_for_image_group,
        ig_id
    )
end

function Model:updatePendingShareRecordWithDateNow(share_id)
    local p_ok, p_err, err = pcall(
        self.conn.execute,
        self.conn,
        queries.model.update_pending_share_record_with_date_now,
        share_id
    )
    if not p_ok then
        return nil, p_err
    end
    if not p_err then
        return nil, err
    end
    return true
end

function Model:deleteShareRecords(share_ids)
    return self:_delete_by_id(
        queries.model.delete_share_record_by_id,
        share_ids
    )
end

function Model:create_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("SAVEPOINT " .. name .. ";")
end

function Model:release_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("RELEASE SAVEPOINT " .. name .. ";")
end

function Model:rollback(to_savepoint)
    if to_savepoint and type(to_savepoint) == "string" then
        return self.conn:execute(
            "ROLLBACK TO %s; RELEASE SAVEPOINT %s;"
                % { to_savepoint, to_savepoint }
        )
    else
        return self.conn:execute("ROLLBACK;")
    end
end

local Accounts = {}

function Accounts:new(o)
    o = o or {}
    o.conn = Fm.makeStorage(ACCOUNTS_DB_FILE, accounts_setup, { trace = trace })
    setmetatable(o, self)
    self.__index = self
    return o
end

function Accounts:migrate(opts)
    return self.conn:upgrade(opts)
end

function Accounts:bootstrapInvites()
    local users = self.conn:fetchOne(queries.accounts.count_users)
    if not users or users.count < 1 then
        -- TODO: see if there is an unused invite, and retrieve that instead of
        -- making a new one.
        local invite_id = NanoID.simple_with_prefix(IdPrefixes.invite)
        self.conn:execute(queries.accounts.bootstrap_invite, invite_id)
        Log(
            kLogWarn,
            "There are no accounts in the database. Register one using this link: https://127.0.0.1:8082/accept-invite/%s"
                % { invite_id }
        )
    end
end

function Accounts:findInvite(invite_id)
    local invite = self.conn:fetchOne(queries.accounts.find_invite, invite_id)
    return invite
end

function Accounts:getAllInvitesCreatedByUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_all_invite_links_created_by_user,
        user_id
    )
end

function Accounts:makeInviteForUser(user_id)
    local invite_id = NanoID.simple_with_prefix(IdPrefixes.invite)
    return self.conn:execute(
        queries.accounts.insert_invite_for_user,
        invite_id,
        user_id
    )
end

local function make_user_id()
    return NanoID.simple_with_prefix(IdPrefixes.user)
end

function Accounts:acceptInvite(invite_id, username, password_hash)
    local user_id = make_user_id()
    local SP = "accept_invite"
    self:create_savepoint(SP)
    local user_ok, user_err = self.conn:execute(
        queries.accounts.insert_user,
        user_id,
        username,
        password_hash
    )
    if not user_ok then
        self:rollback(SP)
        return nil, user_err
    end
    local invite_ok, invite_err =
        self.conn:execute(queries.accounts.assign_invite, user_id, invite_id)
    if not invite_ok then
        self:rollback(SP)
        return nil, invite_err
    end
    Model:new(nil, user_id)
    self:release_savepoint(SP)
    return invite_ok
end

function Accounts:findUser(username)
    return fetchOneExactly(
        self.conn,
        queries.accounts.find_user_by_name,
        username
    )
end

function Accounts:createSessionForUser(user_id, user_agent, ip)
    local session_id = NanoID.simple_with_prefix(IdPrefixes.session)
    local csrf_token = NanoID.simple_with_prefix(IdPrefixes.csrf)
    local now = unix.clock_gettime()
    local result, errmsg = self.conn:execute(
        queries.accounts.insert_session,
        session_id,
        user_id,
        now,
        user_agent,
        ip,
        csrf_token
    )
    if not result then
        return result, errmsg
    end
    return session_id
end

function Accounts:deleteAllSessionsForUser(user_id)
    return self.conn:execute(queries.accounts.delete_sessions_for_user, user_id)
end

function Accounts:findSessionById(session_id)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_session_by_id,
        session_id
    )
end

function Accounts:updateSessionLastSeenToNow(session_id, ip)
    local now = unix.clock_gettime()
    return self.conn:execute(
        queries.accounts.update_session_last_seen,
        now,
        ip,
        session_id
    )
end

function Accounts:getAllSessionsForUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_all_sessions_for_user,
        user_id
    )
end

function Accounts:sessionMaintenance()
    local now = unix.clock_gettime()
    -- Expire all sessions that have not been used in 30 days.
    local expiry_point = now - SESSION_MAX_DURATION_SECS
    local delete_count, err
    self.conn:execute(
        queries.accounts.delete_sessions_older_than_stamp,
        expiry_point
    )
    if not delete_count then
        Log(kLogWarn, "Error while deleting untouched sessions: %s" % { err })
    end
    Log(kLogInfo, "Deleted %d expired sessions." % { delete_count })
    -- Regenerate CSRF protection tokens for sessions that have not been used in
    -- 4 hours. (Avoid doing this too much or you'll break browser sessions.)
    local token_regen_point = now - (4 * 60 * 60)
    local sessions, s_err = self.conn:fetchAll(
        queries.accounts.get_sessions_older_than_stamp,
        token_regen_point
    )
    if not sessions then
        Log(
            kLogWarn,
            "Error while fetching sessions in need of CSRF token updates: %s"
                % { s_err }
        )
        return delete_count
    end
    local updated_count = 0
    for i = 1, #sessions do
        local new_token = NanoID.simple_with_prefix(IdPrefixes.csrf)
        -- TODO: this refreshes the token every hour once it's hit 4 hours old. Is that a problem?
        local t_ok, t_err = self.conn:execute(
            queries.accounts.update_csrf_token_for_session,
            new_token,
            sessions[i].session_id
        )
        if not t_ok then
            Log(
                kLogWarn,
                "Error while updating session %s: %s"
                    % { sessions[i].session_id, t_err }
            )
        else
            updated_count = updated_count + 1
        end
    end
    Log(
        kLogInfo,
        "Updated CSRF protection tokens for %d sessions." % { updated_count }
    )
    return delete_count + updated_count
end

function Accounts:findUserBySessionId(session_id)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_user_by_session,
        session_id
    )
end

function Accounts:updatePasswordForuser(user_id, new_password_hash)
    return self.conn:execute(
        queries.accounts.update_password_for_user,
        new_password_hash,
        user_id
    )
end

function Accounts:findUserByTelegramUserID(tg_userid)
    return self.conn:fetchOne(queries.accounts.get_user_by_tg_id, tg_userid)
end

function Accounts:getAllTelegramAccountsForUser(user_id)
    return self.conn:fetchAll(
        queries.accounts.get_telegram_accounts_by_user_id,
        user_id
    )
end

function Accounts:getTelegramAccountByUserIdAndTgUserId(user_id, tg_userid)
    return self.conn:fetchOne(
        queries.accounts.get_telegram_account_by_user_id_and_tg_userid,
        user_id,
        tg_userid
    )
end

function Accounts:getAllUserIds()
    return self.conn:fetchAll(queries.accounts.get_all_user_ids)
end

function Accounts:addTelegramLinkRequest(display_name, username, tg_userid)
    local request_id =
        NanoID.simple_with_prefix(IdPrefixes.telegram_link_request)
    local now, clock_err = unix.clock_gettime()
    if not now then
        return nil, clock_err
    end
    local ok, i_err = self.conn:execute(
        queries.accounts.insert_telegram_link_request,
        request_id,
        display_name,
        username,
        tg_userid,
        now
    )
    if not ok then
        return nil, i_err
    end
    return request_id
end

function Accounts:setTelegramUserIDForUserAndDeleteLinkRequest(
    user_id,
    tg_userid,
    tg_username,
    request_id
)
    local SP_TGLINK = "link_telegram_to_user"
    self:create_savepoint(SP_TGLINK)
    local insert_ok, insert_err = self.conn:execute(
        queries.accounts.insert_telegram_account_id,
        user_id,
        tg_userid,
        tg_username
    )
    if not insert_ok then
        self:rollback(SP_TGLINK)
        return nil, insert_err
    end
    local delete_ok, delete_err = self.conn:execute(
        queries.accounts.delete_telegram_link_request,
        request_id
    )
    if not delete_ok then
        self:rollback(SP_TGLINK)
        return nil, delete_err
    end
    self:release_savepoint(SP_TGLINK)
    return true
end

function Accounts:getTelegramLinkRequestById(request_id)
    return fetchOneExactly(
        self.conn,
        queries.accounts.get_telegram_link_request_by_id,
        request_id
    )
end

function Accounts:deleteTelegramLinkRequest(request_id)
    return self.conn:execute(
        queries.accounts.delete_telegram_link_request,
        request_id
    )
end

function Accounts:create_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("SAVEPOINT " .. name .. ";")
end

function Accounts:release_savepoint(name)
    if not name or #name < 1 then
        error("Must provide a savepoint name")
    end
    return self.conn:execute("RELEASE SAVEPOINT " .. name .. ";")
end

function Accounts:rollback(to_savepoint)
    if to_savepoint and type(to_savepoint) == "string" then
        return self.conn:execute(
            "ROLLBACK TO %s; RELEASE SAVEPOINT %s;"
                % { to_savepoint, to_savepoint }
        )
    else
        return self.conn:execute("ROLLBACK;")
    end
end

---@class TGForwardCache
---@field conn any
local TGForwardCache = {}

---@return TGForwardCache
function TGForwardCache:new(o)
    o = o or {}
    o.conn = Fm.makeStorage(
        TG_FORWARD_CACHE_DB_FILE,
        tg_forward_cache_setup,
        { trace = trace }
    )
    setmetatable(o, self)
    self.__index = self
    return o
end

function TGForwardCache:migrate(opts)
    return self.conn:upgrade(opts)
end

function TGForwardCache:insertChannelPost(
    chan_id,
    chan_title,
    chan_username,
    msg_id,
    media_kind,
    media
)
    if type(media) == "table" then
        media = EncodeJson(media)
    end
    local q = [[INSERT OR IGNORE INTO "cache" (
            "type",
            "username",
            "title",
            "id",
            "message_id",
            "media_kind",
            "media",
            "cached_at"
        ) VALUES (
            'channel',
            ?,
            ?,
            ?,
            ?,
            ?,
            ?,
            unixepoch('now')
        );]]
    return self.conn:execute(
        q,
        chan_username,
        chan_title,
        chan_id,
        msg_id,
        media_kind,
        media
    )
end

---@param username string
---@param msg_id integer
---@return {username: string, title: string, id: integer, message_id: integer, media_kind: string, media: table}
function TGForwardCache:lookUpChannelPost(username, msg_id)
    local q = [[SELECT
            "username",
            "title",
            "id",
            "message_id",
            "media_kind",
            "media"
        FROM "cache"
        WHERE username = ? AND message_id = ?;]]
    local record, err = self.conn:fetchOne(q, username, tonumber(msg_id))
    if not record then
        return nil, err
    end
    if record.media then
        record.media = DecodeJson(record.media)
    end
    return record
end

function TGForwardCache:clean(secs_in_past)
    local q =
        [[DELETE FROM "cache" WHERE "cached_at" < (unixepoch('now') - ?);]]
    return self.conn:excute(q, secs_in_past)
end

local function for_each_user(fn)
    local accounts = DbUtil.Accounts:new()
    local users, users_err = accounts:getAllUserIds()
    accounts.conn:close()
    if not users then
        error(users_err)
        return nil
    end
    for i = 1, #users do
        local user = users[i]
        Log(
            kLogInfo,
            "Checking records for user %s (%d of %d)…"
                % { user.user_id, i, #users }
        )
        local model = DbUtil.Model:new(nil, user.user_id)
        local rc = fn(i, user, model)
        model.conn:close()
        if rc ~= 0 then
            return rc
        end
    end
end

local function remove_deleted_files()
    local recordFileNamesFoundInUse = {}
    local record_files_q = [[SELECT "file" FROM "images";]]
    local queue_img_q = [[SELECT "image" FROM "queue_images";]]
    local queue_help_q =
        [[SELECT "help_ask" FROM "queue2" WHERE help_ask IS NOT NULL;]]
    local SP = "remove_deleted_files"
    for_each_user(function(_, user, model)
        local queueImagesFoundInUse = {}
        model:create_savepoint(SP)
        local record_files, rf_err = model.conn:fetchAll(record_files_q)
        if not record_files then
            model:rollback(SP)
            Log(kLogInfo, "Unable to query for all files: " .. rf_err)
            return 1
        end
        for i = 1, #record_files do
            recordFileNamesFoundInUse[record_files[i].file] = true
        end
        local qimg, qimg_err = model.conn:fetchAll(queue_img_q)
        if not qimg then
            model:rollback(SP)
            Log(kLogInfo, "Unable to query for all queue images: " .. qimg_err)
            return 1
        end
        for i = 1, #qimg do
            queueImagesFoundInUse[qimg[i].image] = true
        end
        local qhelp, qh_err = model.conn:fetchAll(queue_help_q)
        if not qhelp then
            model:rollback(SP)
            Log(
                kLogInfo,
                "Unable to query for all queue entries with help requests: "
                    .. qh_err
            )
            return 1
        end
        for i = 1, #qhelp do
            local json = DecodeJson(qhelp[i].help_ask)
            local filenames = table.search(json, { "media_file", "image_file" })
            for j = 1, #filenames do
                queueImagesFoundInUse[filenames[j]] = true
            end
        end
        FsTools.for_each_queue_file(user.user_id, function(file, path)
            if not queueImagesFoundInUse[file] then
                unix.unlink(path)
                Log(
                    kLogInfo,
                    "Deleted no longer referenced queue file: " .. path
                )
            end
        end)
        model:release_savepoint(SP)
        return 0
    end)
    FsTools.for_each_image_file(function(file, path)
        if not recordFileNamesFoundInUse[file] then
            unix.unlink(path)
            Log(kLogInfo, "Deleted no longer referenced record file: " .. path)
        end
    end)
end

local ImageKind = {
    Image = 1,
    Video = 2,
    Audio = 3,
    Flash = 4,
    Animation = 5,
}
local Rating = {
    General = 1,
    Adult = 2,
    Explicit = 3,
    HardKink = 4,
}
local Category = {
    Stash = 1,
    Reference = 2,
    Moodboard = 4,
    Sharing = 8,
    OwnArt = 16,
}
local ImageKindLoopable = {}
local RatingLoopable = {}
local CategoryLoopable = {}

for k, v in pairs(ImageKind) do
    ImageKindLoopable[v] = k
end
for k, v in pairs(Rating) do
    RatingLoopable[v] = k
end
for k, v in pairs(Category) do
    CategoryLoopable[#CategoryLoopable + 1] = { v, k }
end
table.sort(CategoryLoopable, function(a, b)
    return a[1] < b[1]
end)

return {
    mkdir = mkdir,
    make_user_id = make_user_id,
    get_query_stats = get_query_stats,
    Accounts = Accounts,
    Model = Model,
    TGForwardCache = TGForwardCache,
    remove_deleted_files = remove_deleted_files,
    for_each_user = for_each_user,
    -- k is for konstant! I passed spelling :)
    k = {
        ImageKind = ImageKind,
        Rating = Rating,
        Category = Category,
        ImageKindLoopable = ImageKindLoopable,
        RatingLoopable = RatingLoopable,
        CategoryLoopable = CategoryLoopable,
    },
}
