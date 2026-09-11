# Upstream 0.7.2 integration

Date: 2026-09-11.

The integration merges upstream `6c044011c24dd55595af823cfef10f26b525cfca`
(PR #171, release 0.7.2) into fork commit
`226fa4a` on `codex/sync-upstream-0.7.2`.

## Changes

- Reject unknown and unsupported top-level OpenAI request fields explicitly.
- Decode and validate `response_format` as JSON; treat null request keys as
  absent and bound diagnostic echoes by UTF-8 byte count.
- Accept server `--prefill-chunk-tokens auto` as the 256-token cap.
- Avoid resolving CLI automatic chunk size when prefill is disabled.
- Share allowed-value rendering between CLI/server help and validation.
- Include upstream tests, documentation corrections, and About version 0.7.2.

The only textual conflict was CLI help. Both fork flags, `--progress` and
`--metrics-json`, remain, alongside upstream's generated expert-cache value
list. Existing CLI tests cover both flags and the complete help option list.
Runtime defaults are unchanged.

## Validation

Hardware: MacBook Pro Mac16,8, Apple M4 Pro, 12 CPU cores (8 performance,
4 efficiency), 24 GB RAM. macOS 26.6.2 (25G83). Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).

Commands run from the repository root on the merged source tree:

```sh
Scripts/test.sh --filter 'CLIArgumentsTests|PrefillChunkScratchTests|OpenAIRequestDecodingTests|OpenAIValidationTests|HTTPServerTests|ServerArgumentTests' > /tmp/turbo-upstream-072-tests.log 2>&1
swift build -c release > /tmp/turbo-upstream-072-build.log 2>&1
git diff --check
```

All three completed with exit code 0. Complete test summary and build footer:

```text
✔ Test run with 124 tests in 8 suites passed after 6.199 seconds.
Build complete! (52.38s)
```

The release build includes the Mac app and its sibling decode service, CLI,
server, and repacker. No inference run or performance benchmark was performed.
The selected tests exercise request validation, a fake-inference loopback
server, argument parsing, and Metal scratch allocation without loading the
installed model. The full package suite was not run.

Environment observations: `memory_pressure -Q` reported 61% free; the volume
had 103 GiB available. A process check with host permissions found none of the
model/test processes listed in AGENTS.md (`pgrep` exit 1 with empty output).

Sandbox deviations: the initial process check could not access the process
list and was repeated with host permissions. The initial test attempt exited
1 before compiling the package because the sandbox denied the Swift module
cache. Its terminal errors were:

```text
<unknown>:0: error: error opening '/Users/dmitrii.malakhov/.cache/clang/ModuleCache/Swift-1IEYM950OGIQC.swiftmodule' for output: /Users/dmitrii.malakhov/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
error: ExitCode(rawValue: 1)
```

Tests and the release build subsequently ran with host permissions for normal
Swift caches and test loopback sockets. No caches were purged, model files
changed, model processes started, or experimental controls enabled.
Compiler warnings remain in unchanged code, including NIO `Sendable`
conformance and redundant nil coalescing in server inference.

## Separate 0.8.0 integration

The follow-up is now documented in [Upstream 0.8.0 integration](UPSTREAM_SYNC_0.8.0.md).
The assessment below records the state of the earlier 0.7.2 merge.

Upstream `4c6db1e698ea861609109d4bc517410ff302af46` (PR #174) is not included.
Its history implementation changes storage, replay, decode transport, and UI
together. The preliminary full-upstream merge showed textual conflicts in
16 files, including the CLI conflict resolved here.

The fork's `AppChat` retains document drafts, context text distinct from
displayed text, summaries, branches, edited-message metadata, pins, and tasks.
Upstream's `ConversationDocument`/`ConversationStore` instead ties persisted
turn records and image spans to token lineage used for replay. A follow-up
integration must preserve the fork's fields and existing saved chats, adapt
the inference path that injects document/MCP context, and validate image
restoration and conversation continuation before replacing history/UI code.
