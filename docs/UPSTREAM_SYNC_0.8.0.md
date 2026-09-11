# Upstream 0.8.0 integration

Date: 2026-09-11.

Upstream `4c6db1e698ea861609109d4bc517410ff302af46` (PR #174, version
0.8.0) is merged into `8aece79`, the fork's completed 0.7.2 integration.
The integration branch is `codex/sync-upstream-0.8.0`; local `main` receives
the resulting merge by fast-forward. The remote is not pushed.

## Result

The Mac app uses upstream's durable conversation records, token lineage,
replay, image ownership, asynchronous deletion, and termination persistence.
The fork keeps its sidebar, old chat archive, branches, edited messages,
documents, summaries, pins, tasks, exports, and MCP/Exchange preparation.
An optional conversation identifier connects the two stores without making
existing archive JSON incompatible. Native-only records appear in the fork's
sidebar; deleting a native conversation also removes its fork projection.

Older chats and edited branches rebuild their first request from message
history. Explicit image assignments keep historical images on their original
user messages, including image-only turns. Subsequent turns reuse native KV
lineage. Hidden summarization invalidates that lineage before rebuilding it
from compacted history. Documents and external context remain part of the
request while the transcript retains the user's original text.

The merged send pipeline preserves a newer composer draft and returns failed
turns to their original chat after navigation. Clearing history can be undone
without resurrecting a deleted native token record. Image errors remain
visible and fail closed. The app waits for pending persistence on termination
and rechecks the store and vision pack when becoming active.

Conflict resolution covers application state, inference and decode messages,
image types, lifecycle, settings, composer, transcript, inspector, and HUD.
Upstream tests are retained, with fork tests adapted to wait for the complete
asynchronous send and durable deletion. Additional integration cases cover
legacy JSON, image-to-message assignments, branch image history, context
handoff, cross-chat draft restoration, deletion across relaunch, and undo.

## Validation environment

MacBook Pro Mac16,8; Apple M4 Pro, 12 CPU cores (8 performance, 4 efficiency),
24 GB RAM; macOS 26.6.2 (25G83); Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).

Before package tests, the required process check found no existing model or
test process. `memory_pressure -Q` reported 56% free and the volume had
102 GiB available. The installed text model receipt, manifest SHA, location
binding, pinned source revision, and sizes of all 37 files were checked.
The companion vision pack was present. Tests ran serially through
`Scripts/test.sh`; no second model process, model download or duplication,
worktree, cache purge, or experimental control was used.

## Verification

Commands run from the repository root on the final merged source tree:

```sh
Scripts/test.sh --filter 'UpstreamHistoryIntegrationTests|AppChatImageHistoryTests|AppModelHistoryTests|AppChatTests|AppModelSendPipelineTests|ImageReleaseSitesTests' > /tmp/turbo-080-last-regression.log 2>&1
Scripts/test.sh > /tmp/turbo-080-verified-tests.log 2>&1
swift build -c release > /tmp/turbo-080-release.log 2>&1
git diff --cached --check
ruby Scripts/check_tracked_symlinks.rb
ruby Scripts/check_markdown_links.rb
```

Targeted and complete package tests exited 0. Complete timing footers:

```text
✔ Test run with 140 tests in 6 suites passed after 40.580 seconds.
✔ Test run with 1920 tests in 265 suites passed after 302.995 seconds.
```

The Git whitespace check and both repository checks exited 0:
`no tracked symlinks`; `checked 26 Markdown files; all local links and anchors resolve`.

Release build exited 0, including the Mac app and sibling decode service,
CLI, server, and repacker. Complete footer:

```text
Build complete! (62.09s)
```

Existing server warnings remain: NIO `IdleStateHandler` Sendable conformance
and redundant nil coalescing in `ServerInference.swift`.

Other checks:

- `ruby Scripts/check_app_version.rb`: exit 0;
  `app version 0.8.0 matches the latest release`.
- Exchange checks used a temporary `/tmp/turbo-080-exchange-venv` environment
  populated from `Sources/TurboFieldfareApp/Core/Resources/ExchangeMCP/requirements.lock`.
  `/tmp/turbo-080-exchange-venv/bin/python Scripts/test-exchange-readonly.py`:
  exit 0, 5 tests in 0.029s, OK.
  `/tmp/turbo-080-exchange-venv/bin/python Scripts/test-exchange-tls.py`:
  exit 0, 4 tests in 0.032s, OK (skipped=1). The skipped case requires an
  app-exported PEM. These checks used synthetic fixtures; no Exchange account
  or live mailbox was accessed.

## Deviations and limits

The sandbox initially prevented writing the Swift module cache; subsequent
Swift commands ran with host permissions. One compiler crash in an inspector
Binding setter was eliminated by spelling the setter as an explicit closure.
Early regression runs exposed integration errors which were fixed before the
final runs. The first full run exited 1 after 1917 tests in 265 suites
(297.844s, 11 issues); the second exited 1 after 1919 tests in 265 suites
(303.755s, 2 issues). The latter two issues concerned an asynchronous image
deletion assertion and preserving a draft during native history deletion.
System Python lacked Exchange dependencies, so its initial checks failed on
missing `lxml` and `cryptography`; the pinned temporary environment resolved
this without modifying the user's Python environment.

No interactive GUI session, real-mailbox integration, production text
generation benchmark, or Swift 6.2 compatibility run was performed. Package
tests exercise installed-pack vision cases as well as model-free behavior.
Test and build durations are validation measurements, not performance ceilings.
