# Product status

Snapshot of what this repo actually ships today. Keep this file honest when features land or slip.

## Shipped

### Home

- Hero **net cash flow** for the selected range, plus **In** / **Out**
- Range picker: Month · 30 Days · Year · Custom (date-picker sheet). **Year appears only when local history reaches back a full year** (banks often return less than the requested lookback)
- Cumulative net **line chart** (axes first; line reveals left→right on first load)
- Press-and-drag scrubbing with callout; Reduce Motion respected
- Pull-to-refresh sync; offline / error banners
- Empty, loading, and populated states (no cross-fade stack on first load)
- Quiet ranges (e.g. Month with no posts yet) stay on the cash-flow UI with $0 — not the “No activity yet” empty state — when the store already has history

Code: `ExpenseTracking/Features/Home/`

### Transactions

- Bank-style list grouped by month (headers scroll with content)
- **Keyset pagination** (page size 50); loads more near the end of the list
- Filters (sheet): account, category, tag, date (All / Month / 30d / Year / Custom)
- Search (store-wide via repository): title, category, tags, account, amount digits (e.g. `66` → `$66.43`)
- Edit sheet: category + description + multi-select tags (no delete in MVP)
- Pull-to-refresh sync with stage/window progress banner (not transaction totals)

Code: `ExpenseTracking/Features/Transactions/`

### Tags & Insights

- User-defined **tags** (many-to-many, local-only) orthogonal to system categories — e.g. “Japan Trip”, “Local Concert”
- Sync never invents or clears tags; wipe/relink clears tags with local accounts/transactions
- **Insights** tab: range picker (same options as Home), total spent, horizontal bar charts + lists for spending by category and by tag
- Combine filters by tapping a category and a tag (AND scope); **View transactions** opens the list with that scope + date range
- Manage Tags sheet (create / rename / delete); create tag from transaction editor
- Multi-tagged expenses count their full amount toward **each** tag in Insights

Code: `CashFlowKit` (Tag + breakdown use case), `CashFlowData` (TagEntity), `ExpenseTracking/Features/Insights/`

### Accounts & onboarding

- Connection status and last successful sync (durable via `ConnectionEntity`)
- Load Demo / Link SimpleFIN through `ConnectionLifecycleServing` (**mutually exclusive**; link always wipes local accounts first)
- Sync Now; disconnect (keep data or wipe); clear local data (keep link); **Erase everything**
- Orphan leftover-data recovery when Not linked but rows remain
- Account list with balance on the trailing edge; tap opens Transactions filtered to that account
- Local account rename (survives sync while the SimpleFIN account still matches); new accounts take the SimpleFIN name
- Re-link / keep-local can leave a **historical** copy next to the new **Sync OK** row. Historical rows say **Swipe to repair duplicate**; swipe **Repair** to merge, or **Keep locally** if it is not a duplicate (warning dismissed, later syncs leave it alone unless SimpleFIN returns it again)
- First-launch onboarding: Demo · Link · Skip
- Settings (gear from Accounts): About + local-data privacy note + app lock

**Semantics**
| Action | Credentials | Local accounts/txns |
|--------|-------------|---------------------|
| Link / Load Demo (`replaceAndLink`) | Switch to new provider | **Optional wipe** — UI asks Keep or Delete when local rows exist; `deleteLocalData: true` wipes first |
| Disconnect (keep data) | Cleared | Kept |
| Disconnect & delete | Cleared | Wiped |
| Clear local data (keep link) | Kept | Wiped (Sync Now re-pulls) |
| Erase everything | Cleared | Wiped |

Code: `ExpenseTracking/Features/Accounts/`, `Features/Settings/`

### App lock

- Optional **Require Face ID / Touch ID** toggle in Settings (off by default)
- Unlock with system biometrics and **device passcode fallback** (`deviceOwnerAuthentication`)
- Re-locks after a fixed **15s** grace when leaving the app; quick switches do not re-prompt
- Full-screen privacy cover while locked or backgrounded with lock enabled (app switcher)
- Enabling / disabling requires a successful authentication challenge
- Widget **unchanged by lock** — configured time-frame net still shows when lock is enabled

Code: `ExpenseTracking/Features/AppLock/`, `Features/Settings/`, `CashFlowData/SecureStorage/`

### Sync & data

- `SyncCoordinator` — single-flight; cancel waits for slot; failures keep last good local data
- Sync progress stream (`SyncProgress`): preparing → downloading (date windows) → saving → optional enriching; UI on Home / Transactions / Insights / Accounts
- `connectionStatus` assembles Keychain/Demo + `ConnectionEntity` (`needsReauth`, last sync)
- Initial / incomplete history: configurable lookback (default 2 years), at most 8 SimpleFIN windows per sync, stops after two consecutive empty windows; resumes via watermark until `historyComplete`; later syncs use last sync − 30 days
- Merge policy: **locked** category always kept; else matching **user rule** wins (even over manual edits); else **user-edited** category; else **LLM** (`.llm`); else **keyword** (`.keyword`); new rows start as **Undefined**. Account name: user-edited wins. Remote wins amount / date / description / balance / institution. Renames write `enrichedTitle` / `enrichedLocation` (bank description stays immutable). Bank description change resets non-user categories to Undefined for re-classification
- Category suggestion: ingest → **Undefined**; post-sync LLM is the initial real category; keyword (`SuggestTransactionCategoryUseCase`) only when AI unavailable/`nil`; unmatched keyword credits → Other (not Income)
- Demo provider for fixtures / portfolio; SimpleFIN for real institutions — **not coexisting in one store**
- Widget timelines reloaded after successful sync and on full wipe (`WidgetTimelineReloading`)
- Launch: single `VersionedSchema`; store load failures wipe App Group/local stores and retry, then in-memory — **no `fatalError` on SwiftData migration**
- **CSV export** (Settings → Data): filtered transaction CSV via `LocalDataExporting` using the shared `TransactionFilterSession` (same filters as the Transactions list) — no Keychain secrets
- **CSV import** (Settings → Data): file picker → column mapping (auto-detect + presets) → account (existing or new) → fingerprint conflict resolution (skip / replace / keep both, with bulk) → commit; rows get `IngestSource.csvImport`, run through merge rules + post-import enrichment; **Import History** lists batches and can delete a batch’s transactions (tombstone kept). Linking SimpleFIN/Demo with leftover local data prompts **Keep** or **Delete** (`replaceAndLink(deleteLocalData:)`)

Code: `Packages/CashFlowData/`

### Widget

- Small, medium, and accessory rectangular layouts
- Edit Widget time frame: **This Month** (default), **Previous Month**, **Last 30 Days**, **Previous 3 Months**, **Last 90 Days**, **Previous 6 Months**, **Last 180 Days**
- Live net / +in / −out from shared App Group SwiftData via `WidgetNetCashFlowLoader` + `CalculateNetCashFlowUseCase`
- Home reload and successful sync call `WidgetCenter.reloadTimelines` so each widget instance recomputes **its own** configured range (not Home’s selected range)
- UI: one-line scaled signed net; green `+$` income row and red `−$` expense row (no `In · Out` bullet line)
- Uses `AppIntentConfiguration` (`CashFlowWidgetConfigurationIntent`)
- **Live Activity** for on-device title cleanup: AirDrop-style circular progress on the Dynamic Island and Lock Screen while a user-started drain runs (Settings / first-sync prompt). Local updates only; overnight `BGProcessingTask` does not start a new activity

Code: `ExpenseTrackingWidget/`, `Shared/LiveActivities/`, `ExpenseTracking/App/TitleCleanupLiveActivityPresenter.swift`, `Packages/CashFlowData` (`WidgetNetCashFlowLoader`), `Packages/CashFlowKit` (`WidgetCashFlowTimeFrame`, `TitleCleanupLiveActivityMachine`)

### Quality gates

- Domain tests (`CashFlowKit`): net contribution, exclusions, ranges
- Data tests (`CashFlowData`): merge, demo net, sync-related coverage
- App tests (`ExpenseTrackingTests`): Home ViewModel, Insights ViewModel, App Lock ViewModel, amount search helpers
- `scripts/check_architecture.sh` + GitHub Actions CI

### Categorization

- User rules: multi-condition AND filters (title/description contains|equals, account, amount min/max) stored in SwiftData
- Optional **rename title / location** actions on rules; applied via enrichment (`TitleSource.rule`) on sync/re-apply
- Apply on sync/ingest before LLM/keyword; create/edit/delete re-applies to all **unlocked** transactions (including prior manual edits)
- Per-transaction **Lock category** toggle blocks rule overwrites (category and rename)
- New transactions land as **Undefined** until processed; LLM suggests the initial category; keyword fallback when AI cannot; user edits (`.user`) stick vs LLM/keywords; matching categorize **rules** still overwrite unlocked user edits (same as before)
- `CategorySource`: keyword < llm < user < rule (mirrors TitleSource pattern; rules outrank user for category re-apply)
- Demo fixtures set `preferSuggestedCategory` so seeded categories stick as `.keyword` (screenshot-quality Insights without waiting on enrichment)
- UI: Settings → Categorization Rules; Create Rule… from transaction editor

Code: `CashFlowKit` (rules + resolve), `CashFlowData` (persist + reapply + merge), `ExpenseTracking/Features/CategorizationRules/`

## Known limitations (document accurately)

| Topic | Behavior today |
|-------|----------------|
| Bank history depth | SimpleFIN/Bridge only returns what the institution exposes; lookback requests older windows but empty older ranges are common |
| Transaction search | Repository-backed via `TransactionFilter.searchQuery` (title, location, bank description, category, tags, account, amount digits); debounced in the list ViewModel |
| Edited description | Manual / rule titles stick when category is sticky (`userEditedCategory` / `.user`) or locked; otherwise bank description change clears enrichment and resets category to Undefined for re-classification |
| Home date fetch | Posted txs for the range; date scoping may finish in memory when SwiftData predicates are fragile |
| App Group | Shared SwiftData + leftover snapshot cleanup use `group.com.expensetracking.shared`; widget shows empty state if the group container is unavailable |
| Settings | About + privacy + Assistant + Categorization Rules + app lock |
| Navigation helpers | `AppRouter` route enums exist but tabs use plain `NavigationStack`s |

## Deferred (not built)

- Cloud backup, multi-device sync
- JSON **import** / restore from export file
- Plaid (or other aggregators requiring a backend)
- Delete transaction API (forbidden for MVP; CSV **import batch** delete is the scoped exception)
- Budgets, multi-currency, marketing screenshot pack
- Auto-tagging *rules* (deterministic); tag date ranges or event budgets; splitting one amount across tags
- Private Cloud Compute / server models for the assistant

### On-device intelligence (Foundation Models)

- Apple **Foundation Models** (on-device) behind `SystemLanguageModel` availability; app targets **iOS 26+**
- Post-sync enrichment writes local-only `enrichedTitle` / `enrichedLocation` (bank `description` is immutable after ingest)
- Display prefers enrichment cache, else raw bank description (no heuristic cleanup)
- LLM suggests the **initial category** for every unlocked, non-rule-matched **Undefined** row; keyword fallback when AI unavailable/`nil`; user edits never overwritten
- Undefined is an expense category (visible in Insights until processed); amounts still count in Out/net
- **Assistant** (Transactions toolbar + Settings): interprets intent into rule conditions, shows a preview with affected count, applies on Run (optional lasting rule; Undo from Rules → Edit Rule)
- **Rule Undo**: Edit Rule sheet can undo the last apply for assistant and user rules; later manual edits win
- When Apple Intelligence is off / ineligible / not ready, titles stay raw until the user renames via rules or the editor; categories still get keyword fallback
- Configurable history lookback (90 days / 1 / 2 / 5 years) with quota-aware multi-day backfill; Settings shows progress and “Clean up transactions”
- User-started cleanup also presents an AirDrop-style Live Activity (circular ring, counts + phase; no merchant names or amounts)

Code: `CashFlowKit` ports + plan DTOs, `CashFlowData/Intelligence/`, `ExpenseTracking/Features/Assistant/`

### Categorization roadmap (remaining)

**Phase 1 — User rules** — shipped (see Categorization above).

**Phase 2 — On-device Foundation Models** — shipped (see On-device intelligence above). Custom Create ML rankers remain out of scope.

## Demo happy path (manual)

1. Launch app → onboarding → **Explore with Demo Data** (or Accounts → Load Demo Data)
2. Home shows positive/negative net for This Month and an animated chart
3. Transactions list scrolls; filters and search work on loaded rows
4. Edit a category → Sync Now → category should stick (unless an unlocked matching rule applies)
5. Settings → Categorization Rules → add a rule → matching unlocked txs update
6. Edit a transaction → add a tag → Insights shows spend by that tag for the selected range
7. Widget (Edit → pick a time frame) reflects live App Group totals after Home reload / sync
