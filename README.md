<img width="485" height="255" alt="image" src="https://github.com/user-attachments/assets/33b71358-71b8-42bf-8400-a6b2630dbd02" />

# Axol

A cheerful little axolotl that lives in the corner of your screen. Drag her around, right-click for a menu, and let her tell you to hydrate.

She also listens for alerts on localhost and surfaces them as speech bubbles — clickable alerts can focus a terminal, open a URL, or reveal a file in Finder. Any tool that can POST JSON can talk to her; a plugin framework translates source-specific payloads (Claude Code hooks, GitHub webhooks, CI events, etc.) into a common envelope.

Pure Cocoa + Core Animation: a single ~300 KB binary with no webview or helper processes. Resident memory is ~40 MB and idle CPU is ~0%.

## Running

Requires the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh
./axol
```

`build.sh` compiles `Axol.swift` into a single `axol` binary in the project directory. The binary loads adapters from `./adapters/` (bundled with this repo) and `~/Library/Application Support/Axol/adapters/` (your own).

Window position is persisted to `~/Library/Application Support/Axol/state.json`.

## Sending alerts

The native build listens on `127.0.0.1:47329` (loopback only — remote connections are rejected). Two payload shapes are accepted: the native **envelope** or any shape that matches a registered **adapter**.

### Envelope format

```json
{
  "title":    "auth-service",
  "body":     "please approve this edit",
  "priority": "high",
  "source":   "my-script",
  "icon":     "🔔",
  "actions":  [
    { "type": "focus-pid",    "label": "Open terminal", "pid": 12345 }
  ],
  "context":  { "session_id": "abc", "cwd": "/x/y" }
}
```

Only `title` is required. Everything else has sensible defaults.

| Field | Notes |
|---|---|
| `title` | Bold lead of the bubble. |
| `body` | Wraps below the title. |
| `priority` | `low` (bubble only, not archived) \| `normal` \| `high` (worry bubbles rise from her head) \| `urgent` (worry bubbles + attention animation + **bubble pins open** until you handle it). Default `normal`. While an urgent is pinned, another urgent replaces it (older one drops into history); anything non-urgent slips silently into history without interrupting the pinned bubble. |
| `source` | Free-form sender id, shown in the history panel. |
| `icon` | Named glyph rendered before the title. Known names (below) map to SF Symbols; any other string is shown as a literal prefix (emoji or 1–2 chars). |
| `attention` | Optional one-shot attention animation: `wiggle` \| `hop` \| `none`. Defaults to `wiggle` on `urgent`, `none` otherwise. |
| `actions[]` | First action runs on bubble click. |
| `context{}` | Round-trips untouched; useful for your own bookkeeping. |

### Default icon names

Set `icon` on the envelope to one of these names and Axol renders the matching SF Symbol, tinted per-kind, before the title:

| Name | Glyph | Typical use |
|---|---|---|
| `success` | ✓ check-circle | completed step, passing check |
| `error` | ✕ x-circle | failed step, exception |
| `warn` | ⚠ triangle | attention needed |
| `info` | ⓘ info-circle | neutral notice |
| `ship` | paperplane | deploy / release |
| `review` | eye | code review / inspect |
| `sparkle` | sparkles | cheer / celebrate |
| `bell` | bell | generic alert |
| `bug` | ant | bug report |
| `metric` | trend line | analytics / measurement |
| `pending` | clock | queued / waiting |
| `security` | shield-check | security / audit |
| `message` | speech bubble | inbound chat |
| `approved` | thumbs-up | approval granted |
| `git` | branch | git event |

Unknown strings fall through as a literal prefix, so `"icon": "🚢"` still works for quick one-offs.

### Action vocabulary (closed set)

| Type | Effect | Fields |
|---|---|---|
| `focus-pid` | Activate the terminal window owning this PID | `pid` |
| `open-url` | Open in default browser. `http://` or `https://` only | `url` |
| `reveal-file` | Reveal a file in Finder. Path must exist and be inside `$HOME` | `path` |
| `noop` | Dismiss only | — |

Unknown action types (and anything resembling shell execution) are silently dropped by the envelope validator. Don't rely on arbitrary actions — use one of the four above, or run your code before POSTing.

### Adapters

An adapter is a JSON file that describes how to translate a non-envelope payload into an envelope. Axol ships with one bundled adapter for Claude Code; drop your own into `~/Library/Application Support/Axol/adapters/` to add more.

```json
{
  "name":   "github-ci",
  "match":  { "field": "workflow_run", "exists": true },
  "switch": "workflow_run.conclusion",
  "cases": {
    "success": {
      "title":    "{{workflow_run.head_branch}}",
      "body":     "CI passed",
      "priority": "normal",
      "source":   "github-ci",
      "actions":  [{ "type": "open-url", "url": "{{workflow_run.html_url}}", "label": "View run" }]
    },
    "failure": {
      "title":    "{{workflow_run.head_branch}}",
      "body":     "CI failed",
      "priority": "urgent",
      "source":   "github-ci",
      "actions":  [{ "type": "open-url", "url": "{{workflow_run.html_url}}", "label": "View run" }]
    }
  }
}
```

**Adapter fields:**

- `match` — predicate deciding whether this adapter handles the payload. Supported: `{"field": "x", "exists": true}`, `{"field": "x", "equals": "y"}`.
- `switch` + `cases` — optional. If present, the value of `switch` picks the sub-template by key. Otherwise, use a flat `template` field instead.
- `skip_if` — optional per-case predicate. If it matches, the event is dropped silently.

**Template language** (kept deliberately tiny):

| Syntax | Does |
|---|---|
| `{{field}}` | Top-level field substitution. |
| `{{nested.field}}` | Dot-path into nested objects. |
| `{{field \| default 'x'}}` | Fallback when missing or empty. |
| `{{basename path}}` | Last path component. |
| `{{trim field}}` | Strip surrounding whitespace. |

When a value is a single `{{...}}` substitution, the native type is preserved — `{"pid": "{{claude_pid}}"}` yields `{"pid": 12345}`, not `"12345"`.

Adapters are loaded on startup in filename order. First match wins. Adapter output runs through the same validator as a direct envelope, so an adapter can't smuggle in disallowed actions.

## Claude Code integration

Claude Code support is provided by the bundled `adapters/claude-code.json`. It recognizes `SessionStart` (low priority), `Notification` (urgent — so permission prompts pin open until you handle them), and `Stop` (normal). The internal "waiting for your input" chatter is dropped via a `skip_if`.

Include an `X-Claude-PID` header with the Claude Code process ID (`$PPID` works) so clicking the speech bubble focuses the right terminal.

Example hook configuration (in your Claude Code `settings.json`):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST -H 'Content-Type: application/json' -H \"X-Claude-PID: $PPID\" --data @- http://127.0.0.1:47329/"
          }
        ]
      }
    ]
  }
}
```

## Interactions

- **Left-click** — replays the most recent actionable alert, or cycles through the recent ones. If there aren't any pending, she speaks a quip. Wakes her up from a nap.
- **⌘-click** — toggles Compact Mode (same as the right-click menu item).
- **Double-click** — opens the recent-alerts panel (scrollable, with sticky header). Closes automatically after 10s; click a row to run its action.
- **Right-click** — compact menu: **Idle Animations** (checkbox), **Compact Mode / Expand**, **About**, **Quit**.
- **Drag** — move the window; position is persisted across launches. Drags are clamped to the visible screen so she can't be lost off-edge.
- **Compact mode** — shrinks the window to a 62×62 static icon with a pink alert-count badge (top-left). Click the compact icon to expand back; any pending actionable alert replays in the bubble automatically once the resize settles.

Ambient behavior: she bobs, blinks, sways her gills, and occasionally fires a subtle idle animation (peek / stretch / tilt / wiggle). Worry bubbles rise from above her head while an alert is unresolved. She takes naps on a ~1.5–4 min initial schedule (5–15 min thereafter), waking on any incoming alert, click, or drag. The "Idle Animations" menu toggle disables both idles and naps.

### Bubble behavior

- Display duration scales with content length (2.5–6s for plain quips, 4–10s for alerts).
- Minimum 2.5s display window: non-urgent alerts arriving inside that window queue behind the current bubble (up to 4 pending) and pop once it dismisses. Urgent jumps the queue.
- Urgent bubbles stay pinned until handled; non-urgent alerts arriving during a pinned urgent slip silently into history without interrupting.
- Edge-aware: when the window is near a screen edge, the bubble and history panel bias a few pixels toward the open side.
- While history is open, new alerts append to the list live instead of popping a bubble over it.

### Mood

A single `woundUp ∈ [0, 1]` scalar reacts to alert volume (priority-scaled bumps + a stacking bonus when unseen alerts pile up), decays slowly (`×0.95` every 10s), and drops on handled actions and nap-wake. Three things change based on it:

- Nap scheduler refuses to nap above `0.55` (so she doesn't nod off right after an alert storm).
- Idle picker prefers calm animations (tilt, stretch) below `0.3` and agitated ones (peek, wiggle) above `0.6`.
- Quip pool swaps to a frazzled set above `0.6` ("That's a lot.", "One at a time.", "Gills are flaring.").

The user never sees a mood number — it shows up through behavior.

## License

[MIT](./LICENSE)
