# Project lessons

Maintain concise, durable lessons that are useful for future work in THIS repository.

Only add a lesson when it is verified and likely to recur. Prefer actionable rules over narrative history.

Good examples:
- required test commands or setup steps that are easy to miss;
- architectural invariants;
- recurring framework/build-system traps;
- repository-specific conventions that prevent regressions.

Do not add:
- one-off task details;
- temporary debugging state;
- secrets or credentials;
- personal information;
- SQLite Linkage: Targets link system `sqlite3` directly using `.linkedLibrary("sqlite3")` without third-party package dependencies.
- Test Isolation: Database unit tests should always initialize in-memory SQLite instances (`try Database(inMemory: true)`) to prevent filesystem pollution and test interference.
- Swift Concurrency: `Database` uses serial queue synchronization and `@unchecked Sendable` for thread-safe concurrent access across SwiftUI views.
