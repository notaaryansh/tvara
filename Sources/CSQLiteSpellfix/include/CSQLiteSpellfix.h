#ifndef CSQLITE_SPELLFIX_H
#define CSQLITE_SPELLFIX_H

/// Statically link the SQLite spellfix1 extension into the open database.
/// `db` must be the handle returned by `sqlite3_open_v2` (pass the
/// Swift `OpaquePointer` value here). Returns `SQLITE_OK` (0) on success;
/// any other value is a SQLite error code.
///
/// After this call the `CREATE VIRTUAL TABLE … USING spellfix1` syntax
/// becomes available on this connection. Call once per open db.
int csqlite_spellfix_install(void *db);

#endif
