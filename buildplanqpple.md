Final architecture plan based on the code you pasted.

Assumptions:

* `AppSession` currently calls `AppStartupComposer.compose()` during launch and sets `sourceManager` or `startupError`.
* `CalendarWatcher` and `ContactsReader` permission behavior is as described in your pasted summary.
* The pasted `PreferencesView` details are incomplete, so Settings scope is inferred from your summary.

Architecture decision 1: keep the current scene model.

Your current app shape is already the right top-level macOS shape:

* `MenuBarExtra`
* main dashboard window
* preferences window

That aligns with Apple’s scene model for utility apps and menu bar extras. `MenuBarExtra` is specifically meant for commonly used functionality even when the app is not active. Apple’s current settings guidance also supports a dedicated settings/preferences surface for durable configuration. ([Apple Developer][1])

Do not replace this with a wizard-first shell.

Architecture decision 2: change startup from all-or-nothing to state-driven non-blocking boot.

Current problem:

* `AppStartupComposer.compose()` constructs every dependency eagerly.
* UI only has 3 states: loading, success, generic failure.
* Menu bar and dashboard both depend on `session.sourceManager` existing.

That is the wrong control point.

Replace it with a boot coordinator that always lets the app render, then progressively resolves capabilities.

New root model:

```swift
enum AppBootState {
    case launching
    case ready(AppRuntime)
    case degraded(AppRuntime, [StartupIssue])
    case setupRequired(SetupModel)
    case fatal(FatalStartupIssue)
}
```

`AppRuntime` contains only safe-to-create dependencies:

* logger
* local store
* config store
* preferences/config snapshot
* source registry
* sync preference state
* health/status store

It must not require source permission success to exist.

Architecture decision 3: split boot into three layers.

Layer A: unconditional boot
This must never trigger user-facing permissions.

* resolve app home
* create logger/local store/config store
* load preferences/config
* load persisted onboarding/setup state
* build source registry metadata
* create status/health store
* show dashboard/menu bar

Layer B: source discovery
This determines relevance before prompting.

* detect Mail availability
* detect Calendar capability
* detect Contacts capability
* determine current authorization status only
* do not request access yet

Layer C: point-of-use activation
This is triggered only by explicit user action.

* enable Calendar sync
* enable Contacts enrichment
* enable Mail ingestion
* repair denied source

This matches Apple’s privacy and onboarding guidance: request access in context, explain the benefit, and avoid forcing people through every prompt at launch. Apple’s onboarding guidance favors interactive discovery, and the privacy guidance emphasizes transparency and clarity around resource access. ([Apple Developer][2])

Architecture decision 4: make “no sources connected” a valid first-run state.

The app must be usable with zero active sources.

New first-run states:

1. Launching
2. Empty setup state
3. Partial setup state
4. Ready state
5. Degraded state
6. Fatal local infrastructure failure

Exact user meaning:

* Launching: local app infrastructure is loading
* Empty setup: app launched, no sources active yet
* Partial setup: one or more sources available, none or some enabled
* Ready: at least one source active
* Degraded: runtime exists, some sources failed or were denied
* Fatal: cannot initialize app-local filesystem/config/runtime

Only true local bootstrap failures should be fatal. Permission denial is not fatal. Missing Mail is not fatal. Empty data is not fatal.

Architecture decision 5: dashboard-first onboarding, not a blocking wizard.

Use the dashboard as the onboarding host.

Do not open a dedicated blocking first-run wizard. Apple’s onboarding guidance supports interactive onboarding where the user can safely discover and try actions. Your app is a utility app with existing windows and a menu bar entry, so a dashboard-hosted setup flow fits better than a modal takeover. ([Apple Developer][2])

Dashboard information architecture on first run:

* primary card: “Connect a source”
* source checklist card
* what-the-app-does card
* current local system status card
* recent activity area replaced by placeholder until first sync
* repair/actions area only when needed

Do not show a blank metrics dashboard with zeros as the main first-run experience.

Architecture decision 6: add a source capability model.

Your current startup is tightly coupled to concrete watcher classes. Replace that with a source registry.

Core model:

```swift
enum SourceKind {
    case mail
    case calendar
    case contacts
}

enum SourceAvailability {
    case available
    case unavailable(reason: String)
}

enum SourceAuthorizationStatus {
    case notRequired
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum SourceActivationStatus {
    case inactive
    case activating
    case active
    case degraded(reason: String)
}

struct SourceCapability {
    let kind: SourceKind
    let displayName: String
    let availability: SourceAvailability
    let authorization: SourceAuthorizationStatus
    let activation: SourceActivationStatus
    let isRequiredForCoreValue: Bool
    let canDefer: Bool
}
```

Each source gets:

* discovery
* authorization status check
* activation flow
* repair actions
* optional watcher construction

This lets you add Reminders, Notes, files, APIs later without rewriting app boot.

Architecture decision 7: do not instantiate all watchers during compose.

Current issue:

* `MailWatcher`
* `CalendarWatcher`
* `SourceManager`
* `SyncCoordinator`

are all created eagerly.

New rule:

* discovery objects can be created at boot
* permissioned or fragile runtime objects are created only when the source is activated

Recommended split:

```swift
protocol SourceProvider {
    var kind: SourceKind { get }
    func discover() -> SourceCapability
    func activate(context: RuntimeContext) async throws -> ActiveSource
    func repairActions() -> [RepairAction]
}
```

`SourceManager` then manages active sources, not all possible sources.

Architecture decision 8: redefine source ordering by user value and risk.

Based on your described product:

* Mail is highest user value
* Calendar is secondary
* Contacts is enrichment, not first-run gate

Your pasted summary said contacts is “required because `EntityExtractor` depends on it.” That dependency is architectural, not product truth. Fix the architecture. Contacts should not block Mail as a source. If contacts improve enrichment, treat them as optional enrichment with degraded extraction when denied.

Correct order:

1. Mail
2. Calendar
3. Contacts enrichment

That is the right product-first order.

Architecture decision 9: permission policy must be contextual and source-specific.

Current behavior, as summarized, requests permissions at startup. Remove that.

New policy:

* At launch, only inspect current authorization status.
* Before requesting access, show a lightweight inline explanation inside the dashboard/settings card.
* Then invoke the standard system prompt.
* If denied, keep the app usable and expose a repair action.

Apple’s privacy guidance supports benefit-led permission requests and transparency about why data is needed. ([Apple Developer][3])

Per-source policy:

Calendar

* launch behavior: check auth status only
* request trigger: user clicks “Enable Calendar”
* denial behavior: calendar card stays in degraded state with “Open System Settings”
* no startup throw

Contacts

* launch behavior: check auth status only
* request trigger: user enables contact enrichment or a workflow needing contact resolution
* denial behavior: fallback to raw email/entity extraction without contacts

Mail

* launch behavior: detect availability and current connectivity assumptions only
* request trigger: user clicks “Enable Mail”
* denial/failure behavior: show repair card, not startup failure

Architecture decision 10: menu bar extra becomes status-first and always available.

Current menu bar root is blocked on `sourceManager`. Change that.

Menu bar states:

* launching
* no sources active
* partial setup
* synced / healthy
* degraded

Actions:

* Open Dashboard
* Open Preferences
* Pause/Resume Sync only when at least one active source exists
* repair shortcut when degraded

This matches the role of menu bar extras as app-specific functionality exposed while the app runs, without making them the sole onboarding host. ([Apple Developer][1])

Architecture decision 11: use Preferences for durable configuration, not first-run education.

Preferences scope:

* API and account configuration
* source management
* per-source toggles
* repair/reconnect controls
* update settings
* diagnostics/log export

Dashboard scope:

* first-run guidance
* current health
* activity
* setup progress
* value-centric actions

Do not bury source setup only inside Preferences.

Architecture decision 12: formalize error taxonomy.

Right now everything collapses into “Startup failed.”

Replace with:

```swift
enum StartupIssue: Identifiable {
    case sourceUnavailable(SourceKind, reason: String)
    case authorizationDenied(SourceKind)
    case activationFailed(SourceKind, reason: String)
    case partialDependencyFailure(component: String, reason: String)
}

enum FatalStartupIssue: Identifiable {
    case storageInitializationFailed(String)
    case configurationLoadFailed(String)
    case loggerInitializationFailed(String)
}
```

Rules:

* source and permission issues are recoverable
* local storage/config corruption is fatal
* watcher construction errors are degraded unless the app cannot maintain any runtime at all

Architecture decision 13: introduce a resumable setup model.

Persist lightweight state:

* source cards dismissed
* source last-known availability
* permission denial observed
* user skipped source intentionally
* completed first-run milestone

Do not persist transient spinner states.
Do persist whether the user finished first-run.

Architecture decision 14: target native-first appearance with minimal custom glass.

Do not chase “Liquid 2026” as a custom visual language. Apple’s current term is Liquid Glass, and current guidance is to adopt it through system frameworks, materials, and standard navigation/control surfaces incrementally. Use native SwiftUI/AppKit surfaces and materials where appropriate. Do not build decorative glass-heavy onboarding chrome. ([Apple Developer][4])

Visual guidance:

* keep existing native windows
* standard toolbar/titlebar behavior
* standard grouped cards/lists/forms
* modest material use in sidebars/popovers only if it improves hierarchy
* avoid translucent setup cards over dense content

Architecture decision 15: revise the scene declarations slightly.

Use `Settings` scene instead of a plain `Window` for preferences if your deployment target allows it and you want native expectations around app settings. Apple has dedicated settings guidance and platform conventions for settings surfaces. ([Apple Developer][5])

Recommended direction:

```swift
MenuBarExtra(...)
WindowGroup(id: "main-dashboard") { DashboardRootView(...) }
Settings { PreferencesView(...) }
```

Keep the dashboard as a normal window group or single window depending on how many instances you want.

Architecture decision 16: new runtime composition structure.

Replace current `AppStartupComposer` with:

```swift
struct BootstrapContext {
    let logger: Logger
    let localStore: LocalStore
    let configStore: ConfigStore
    let preferences: Preferences
    let config: Config
    let setupStore: SetupStore
    let sourceRegistry: SourceRegistry
    let syncPreference: Bool
}
```

Then:

```swift
final class AppBootstrapper {
    func bootstrap() throws -> BootstrapContext
}
```

Separate:

```swift
final class SourceRegistry {
    func discoverAll() async -> [SourceCapability]
    func activate(_ kind: SourceKind) async throws -> ActiveSource
}
```

Then:

```swift
final class AppSession: ObservableObject {
    @Published var bootState: AppBootState
    @Published var sourceStatuses: [SourceCapability]
    @Published var menuState: MenuState
}
```

This is the core architecture change.

Architecture decision 17: rewrite root views around `bootState`, not `sourceManager`.

New menu bar root:

* `.launching` → small progress/status
* `.setupRequired` → setup summary + open dashboard
* `.ready` / `.degraded` → current popover
* `.fatal` → diagnostic message + open preferences/logs

New dashboard root:

* `.launching` → branded progress only
* `.setupRequired` → onboarding dashboard
* `.ready` → full dashboard
* `.degraded` → full dashboard with issue banner/cards
* `.fatal` → local recovery screen

Architecture decision 18: first-run dashboard content.

First-run dashboard sections:

1. Primary headline
   “Connect your first source”
2. Source cards

* Mail
* Calendar
* Contacts
  Each card shows:
* status
* short benefit statement
* primary action
* secondary repair/skip action

3. What happens next
   One short explainer of what the app will do after connection
4. Current device/app status

* app version
* sync preference
* source count active

5. Diagnostics link
   Open Preferences or logs

This is the entire onboarding surface.

Architecture decision 19: partial success is a first-class state.

If Mail works and Calendar fails:

* dashboard opens
* Mail card marked active
* Calendar card marked denied/degraded
* menu bar works
* sync actions target active sources only

Do not block on cross-source perfection.

Architecture decision 20: instrumentation.

Add these events locally first even if you do not yet ship analytics:

* app_boot_started
* app_boot_completed
* app_boot_fatal
* source_discovered
* source_activation_started
* source_activation_succeeded
* source_activation_failed
* permission_prompt_requested
* permission_denied_observed
* first_source_connected
* first_sync_completed
* onboarding_completed

Without this, you cannot validate the redesign.

Implementation order.

Phase 1 ✅ APPROVED

* ✅ Introduce `AppBootState`
* ✅ Remove startup hard dependency on `sourceManager`
* ✅ Make dashboard and menu bar render in setup/degraded states
* ✅ Convert generic startup failure into fatal vs recoverable
* ✅ Cleanup: Fix Identifiable conformance
* ✅ Cleanup: Use stable SourceCapability.id
* ✅ Cleanup: Remove unused workQueue

Phase 2

* Add `SourceRegistry` and `SourceCapability`
* Move source discovery out of eager watcher construction
* Make source activation explicit and async

Phase 3

* Move permission requests out of startup
* Add per-source cards and repair flows
* Make contacts optional enrichment rather than boot dependency

Phase 4

* Move durable config/repair into Settings
* Keep dashboard as the onboarding and health surface
* Add instrumentation

Direct code-level changes.

1. `BlawbyAgentApp`
   Keep scene structure, preferably migrate preferences to `Settings`.

2. `AppSession`
   Stop exposing only `sourceManager?` and `startupError?`.
   Expose `bootState`, `sourceStatuses`, and `menuState`.

3. `AppStartupComposer`
   Rename/split into `AppBootstrapper` plus `SourceRegistry`.

4. `DashboardRootView`
   Render from `bootState`, not `sourceManager` existence.

5. `MenuBarRootView`
   Render from `bootState`, not `sourceManager` existence.

6. `SourceManager`
   Manage active sources only.

7. `ContactsReader`
   Remove any startup-time hard dependency from mail processing path.

8. `CalendarWatcher` / `MailWatcher`
   Do not throw into app boot for normal absence/denial conditions.

Final product behavior.

First launch:

* app opens immediately
* dashboard shows source setup cards
* no permission prompt appears until the user enables a source
* menu bar extra is available with setup status
* preferences hold durable configuration

Second launch with one active source:

* dashboard opens in ready or degraded state
* only broken sources ask for repair
* app remains useful

That is the correct architecture for your current codebase and Apple’s current macOS guidance.

[1]: https://developer.apple.com/documentation/SwiftUI/MenuBarExtra?utm_source=chatgpt.com "MenuBarExtra | Apple Developer Documentation"
[2]: https://developer.apple.com/design/human-interface-guidelines/onboarding?utm_source=chatgpt.com "Onboarding | Apple Developer Documentation"
[3]: https://developer.apple.com/design/human-interface-guidelines/privacy?utm_source=chatgpt.com "Privacy | Apple Developer Documentation"
[4]: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass?utm_source=chatgpt.com "Adopting Liquid Glass | Apple Developer Documentation"
[5]: https://developer.apple.com/design/human-interface-guidelines/settings?utm_source=chatgpt.com "Settings | Apple Developer Documentation"
