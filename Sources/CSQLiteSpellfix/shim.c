// Thin Swift→C bridge for spellfix1. Keeps the umbrella header free of
// sqlite3.h so Swift callers don't have to worry about SDK header search
// paths — they pass an `OpaquePointer` (the sqlite3* from sqlite3_open_v2)
// as a `void*`, which we cast back inside the bridge.

#include "include/CSQLiteSpellfix.h"

// Forward declarations matching the symbols defined in spellfix1.c. We
// avoid `#include <sqlite3.h>` here because the module is consumed from
// Swift via SwiftPM's auto-generated modulemap; pulling in sqlite3.h's
// full ABI would require an explicit headerSearchPath into the SDK.
struct sqlite3;
struct sqlite3_api_routines;

int sqlite3_spellfix_init(
    struct sqlite3 *db,
    char **pzErrMsg,
    const struct sqlite3_api_routines *pApi
);

int csqlite_spellfix_install(void *db) {
    // SQLITE_CORE is defined at compile time, so SQLITE_EXTENSION_INIT2
    // inside spellfix1.c is a no-op and the pApi argument is ignored.
    // Passing NULL for both pzErrMsg and pApi is safe in that mode.
    return sqlite3_spellfix_init((struct sqlite3 *)db, 0, 0);
}
