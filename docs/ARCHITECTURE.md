# Architecture

This document must stay aligned with [AGENTS.md](../AGENTS.md). For shipped vs deferred features, see [STATUS.md](STATUS.md).

## Style

Clean Architecture (layered) + **MVVM** at the UI edge. Swift 6 strict concurrency. SOLID applies to **all** code — domain, data, features, design system, and tests.

## Modules

| Module | Path | Responsibility |
|--------|------|----------------|
| **CashFlowKit** | `Packages/CashFlowKit` | Domain models, use cases, ports. **Foundation only.** |
| **CashFlowData** | `Packages/CashFlowData` | SwiftData, URLSession / SimpleFIN, Keychain, Demo provider, SyncCoordinator, WidgetNetCashFlowLoader. |
| **ExpenseTracking** | `ExpenseTracking/` | SwiftUI features, DesignSystem, composition root (`DependencyContainer`). |
| **ExpenseTrackingWidget** | `ExpenseTrackingWidget/` | WidgetKit extension; live App Group SwiftData via `WidgetNetCashFlowLoader`; title-cleanup Live Activity UI |

Dependency direction:

```
CashFlowKit  ←  CashFlowData  ←  ExpenseTracking
                              ←  ExpenseTrackingWidget
```

Features call **ports / use cases**. Only `ExpenseTracking/App/DependencyContainer.swift` constructs CashFlowData concretes (repos, Demo + SimpleFIN behind `CompositeBankLinkingService`, sync, resetter, connectivity).

### CashFlowKit (domain)

- Models: `Transaction`, `Account`, `Category` / `SystemCategory`, `CashFlowDateRange`, `WidgetCashFlowTimeFrame`, filters, errors, `TitleCleanupLiveActivityContent`
- Ports: `TransactionRepository`, `BankLinkingServing`, `SyncServing`, `WidgetTimelineReloading`, …
- Use cases: `CalculateNetCashFlowUseCase`, `CashFlowContribution`, `MergeSyncPolicy`, `CashFlowCurrencyFormatting`, `TitleCleanupLiveActivityMachine`

Money amounts are `Decimal` end-to-end in domain/data/UI models. Charts may convert to `Double` at the plot edge only.

### CashFlowData (I/O)

- Persistence: SwiftData schema v1, repositories, entity mappers, local reset
- Networking: `HTTPClient` → `SimpleFINClient` → `SimpleFINBankLinkingService`
- Demo: `DemoBankLinkingService` (+ composite router for Demo vs linked Access URL)
- Sync: single-flight `SyncCoordinator` + `SyncMergeEngine`
- Widget: `WidgetNetCashFlowLoader` reads shared App Group SwiftData; leftover `NetSnapshotStore` cleared on wipe
- Timeline reload: `WidgetTimelineReloading` after Home reload / successful sync / wipe

### ExpenseTracking (UI)

| Feature folder | Role |
|----------------|------|
| `Features/Home` | Net hero, ranges, dual-color chart |
| `Features/Transactions` | Paginated list, filters, store search, edit |
| `Features/Insights` | Spending pies + View transactions cross-tab focus |
| `Features/Accounts` | Link / Demo / sync / onboarding |
| `Features/Settings` | About + privacy + export + app lock + cleanup |
| `Features/AppLock` | Lock gate overlay, privacy cover, Face ID / passcode unlock |
| `DesignSystem` | Shared theme / formatting helpers |
| `App` | Entry, tabs, `AppRouter`, `DependencyContainer`, `TitleCleanupLiveActivityPresenter` |

## Navigation

`RootTabView`: **Home | Transactions | Accounts**. Each tab owns a `NavigationStack`. Sheets for custom range, transaction filters/editor, SimpleFIN link, and onboarding. Settings is pushed from Accounts (not its own tab).

## Net cash flow rules

Implemented only in `CalculateNetCashFlowUseCase` / `CashFlowContribution`:

- Income category → `+abs(amount)`
- Other non-excluded categories → `−abs(amount)`
- Hidden / Transfer / Credit Card Payment → `0`
- Pending → ignored
- Daily points are **cumulative** net over the selected range (chart ends at hero net)

## Sync

1. Provider fetch (Demo or SimpleFIN) via `BankLinkingServing`
2. Merge into SwiftData (`MergeSyncPolicy`: local category edits win; remote amount/date/description win)
3. On success, reload widget timelines (`WidgetTimelineReloading`) so each instance recomputes its configured range
4. On failure, keep last good local data and surface a banner

`SyncCoordinator` is single-flight (overlapping syncs coalesce / cancel appropriately).

## Title-cleanup Live Activity

User-initiated full drains emit `EnrichmentProgress` on `EnrichmentProgressHub`, including a terminal snapshot with `outcome` when the drain stops. `TitleCleanupLiveActivityPresenter` (app target; constructed in `DependencyContainer`) maps that through `TitleCleanupLiveActivityMachine` (Kit) into ActivityKit. A `.completed` outcome ends Done even if the last in-flight counts lagged; leftover activities on launch complete when the backlog is empty instead of freezing as Paused. Lock Screen / Dynamic Island views live in `ExpenseTrackingWidget`. `TitleCleanupActivityAttributes` is a shared file compiled into both the app and the widget.

## Transactions performance

- Keyset pagination (page size **50**)
- Filter predicates applied at the repository layer where possible
- Preformatted `TransactionRowModel` strings; tiny `List` rows
- Search uses `TransactionFilter.searchQuery` at the repository keyset layer (debounced in the list ViewModel)

## Concurrency

- ViewModels are `@MainActor` / `@Observable`
- Repositories and sync are actors (or actor-isolated) as appropriate
- Domain models are `Sendable`

## Enforcement

`scripts/check_architecture.sh` (also CI) fails on illegal imports — e.g. Kit using SwiftUI/SwiftData/ActivityKit, Features using `ModelContext` / SimpleFIN DTOs / ad-hoc `URLSession` / ActivityKit, CashFlowData using ActivityKit, or Features constructing `SimpleFINBankLinkingService`.
