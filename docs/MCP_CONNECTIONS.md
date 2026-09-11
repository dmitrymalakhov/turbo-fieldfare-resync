# MCP connections in the Mac app

Open **MCP Connections** with **⌘,**, the puzzle-piece button in the top bar, or
**Settings → MCP Connections…**. Connections are shared across chats and model
locations. Starting a connector does not load another inference model.

The **Overview** is the common home for all MCP servers. It shows saved servers,
connection states and the number of configured enabled tools. Open **Manage** or
select a server in the sidebar to edit its settings, credentials and tools.
Use **Overview** in the sidebar to return to the full list.

**Add MCP Server** and the sidebar **+** open the same setup flow. Choose
**MCP Server** for a custom local connection, or a service preset. Exchange is one
preset in this list. Its mail/calendar controls appear only within that connection.

## SMTP setup and sending

1. Choose **Add MCP Server → SMTP Mail**.
2. Enter the SMTP hostname, port, **From address**, username and password.
   STARTTLS defaults to port 587; implicit TLS normally uses 465. Custom ports
   are supported. Authentication uses password-based SMTP AUTH;
   OAuth and NTLM are not implemented for SMTP.
3. Select a Python 3.9+ executable (the initial path is `/usr/bin/python3`).
   The bundled SMTP connector uses the standard library; no pip install is needed.
4. For a corporate CA, choose a certificate file or enter `/etc/ssl/cert.pem`
   in **Certificate file path** and click **Load File**. Certificates are copied
   into the profile. Keychain selection works, but the Exchange HTTPS
   **Find for Server** probe is unavailable for SMTP.
5. Save and click **Connect & Verify**. This checks TLS, SMTP AUTH and NOOP;
   it does not send a test message or prove permission to use the From address.
6. Choose **Compose Email…**, enter plain email addresses separated by commas,
   a subject and a text body. **Review Email** shows the exact message;
   **Send Email** submits it. The composer permits one submission per opening.

SMTP sends mail; reading mail and calendar still uses the Exchange preset.
The chat and generic tool tester cannot send SMTP messages. Passwords stay in
Keychain and enter only the connector process environment. Custom certificates
are scoped to the connection and add to Python's default trust through
`SSLContext.load_verify_locations`. TLS hostname and certificate validation
remain enabled; STARTTLS failure never falls back to plaintext.

The result distinguishes recipients accepted by the SMTP server from rejected
recipients. Acceptance is not proof of delivery. No automatic retry is made:
if submission is interrupted, check with the server before retrying to avoid
duplicates. SMTP does not automatically save a copy in Exchange Sent Items.
Attachments, HTML, Cc/Bcc and reading over IMAP/POP3 are not implemented.

Implementation reference: [Python smtplib](https://docs.python.org/3/library/smtplib.html).
Model-free verification: `python3 Scripts/test-smtp.py` and
`Scripts/test.sh --filter 'AppMCPTests|MCPConnectionsPresentationTests|AppMCPCertificatesTests'`.
The SMTP test script uses fake transports and does not send real email.

## Exchange setup

1. Choose **Add MCP Server → Microsoft Exchange** under **Service Presets**.
2. Enter a name, Exchange host such as `mail.company.com`, mailbox address,
   sign-in username such as `DOMAIN\username`, and password.
3. Choose NTLM or Basic over TLS. NTLM is the default, matching the colleague
   connector this integration is based on. Set the mailbox time zone;
   `Europe/Moscow` is the default. Save the connection.
4. In **Python & Exchange connector**, click **Find Python** and select a version
   under **Installed Python**. The app finds and checks installed interpreters;
   a compatible installation is selected automatically for a new connection.
   Python 3.13 is preferred when available. No manual path entry is required.
   For a custom installation, expand **Choose a file or enter a path manually**,
   select its executable, then click **Check Python**. The app reports its version,
   resolved executable path, and availability of `venv` and `ensurepip`. This
   check does not download packages or access the mailbox. The chosen path is
   saved per connection; verification is repeated after restarting the app.
5. Choose **Install Connector**. A detected Python executable is prefilled;
   choose another Python 3.10+ executable if needed. Installation downloads
   pinned Python dependencies into a private environment under
   `~/Library/Application Support/TurboFieldfare/MCP/exchange-0.2.0/`.
6. Choose **Connect & Verify**. The app initializes MCP, discovers tools, and
   verifies actual Inbox read access. “Connected” means all three succeeded.

**Find Python** checks Homebrew, Python.org framework installations, pyenv,
Conda environments, asdf, uv and executable directories in PATH. It avoids
duplicate symlinks, relative PATH entries and version-manager shims; it does
not recursively scan projects or the whole disk. An old/incomplete interpreter
or a process that cannot start appears under **Unavailable installations** with
the reason. The search can be cancelled, checks at most 32 interpreters with
individual timeouts, and reports when the search budget is exhausted. Use the
manual file picker for installations outside these locations. Search results
remain in memory; the chosen path is saved when checking or installing.

**Connection diagnostics** shows the last attempt, each completed step, and the
step that failed. Installation failures include the command's exit code and
bounded Python/pip output. Server failures include the MCP error code/message
or process exit code and stderr. Common certificate, authentication, DNS,
network and missing-package errors include a suggested next step. Error details
open automatically and can be selected or copied with **Copy Diagnostics**.
Successful Python verification remains visible when later installation or
Exchange authentication fails; it does not mean the mailbox is connected.

Use **Install / Repair Connector** to retry installation even when an executable
was previously configured. A prior ready marker no longer bypasses verification:
installation checks imports and package compatibility before reporting success.
Repair recreates the private `.venv` with the selected base Python and disconnects
other connections using that shared environment. It does not change the base
Python's packages. Choose a Python outside the connector's own `.venv` to repair it.
The Python field takes the interpreter (`python3`); **Advanced → Existing MCP
executable** takes the connector (`exchange-mcp`). Selecting Python itself as
the MCP server cannot complete the MCP handshake. Disconnect a running connection
before checking or repairing its environment.

Setup diagnostics remain in memory for the current app session and are not
automatically written to disk, sent to a server or included in chat context.
Known credentials and common credential/header/URL patterns are masked before
display or copying. Protocol stdout, request parameters, successful tool responses
and JSON-RPC `error.data` are excluded from setup logs. A third-party server
controls its stderr and error messages, so its diagnostics may still contain
other data that server chose to log. Copying is an explicit local clipboard action.

The Exchange endpoint is EWS; enter its hostname without `https://` or
`/EWS/Exchange.asmx`. VPN may be required by the organization. For a corporate
certificate authority, open **Certificates → Choose Certificates… → Choose from
Keychain…**. Choose **Find for Server** to identify a matching certificate chain,
then **Select Suggested Chain → Use Selected Certificates → Save & Verify**.
Manual search by name, issuer or SHA-256 fingerprint is also available. A shortcut
also appears beside certificate-related connection errors. The certificate
section is also available when creating or editing an Exchange connection.

The picker reads public certificates from the Mac's keychain search list and
user, administrator and system certificate trust domains. It displays issuer,
expiry, fingerprint and certificate type, and removes duplicates. **All certificates**
is the default: self-signed roots and self-signed server certificates are visible.
Filters show **For this server**, **Self-signed / self-issued**, or **CA certificates**.
Expired/not-yet-valid certificates stay visible with a reason they cannot be selected.
Ordinary server/personal certificates require their issuing CA; self-signed server
certificates can be explicitly selected. Self-signatures are verified for RSA
PKCS#1 SHA-1/224/256/384/512 and ECDSA SHA-1/224/256/384/512. Certificates whose
issuer equals their subject but whose self-signature is not verified (including
unsupported signature algorithms) remain visible as **Self-issued**. Matching
issuer and subject names alone does not establish a self-signature.

Listing certificates is local and never reads private keys or modifies Keychain
trust. **Find for Server** explicitly opens a TLS-only connection to the configured
Exchange hostname on port 443, reads certificates, then rejects/closes the handshake.
It sends no HTTP request, login, password or mailbox data. DNS resolution and TLS
ClientHello/SNI are necessary to contact that host. The probe has a 10-second timeout,
supports cancellation and does not run automatically when opening the picker.

The returned chain is compared with available candidates using macOS Security,
checking the hostname, certificate dates and cryptographic path to each candidate.
Issuer and revocation network fetches are disabled; only local material/cache may
be used. Certificates with merely similar names are not marked as matching. A
successful match is sorted first and switches to **For this server**. The suggested
chain includes required intermediates (including ones supplied by the server) and
ends at a candidate from the local list. Server-supplied roots are not silently
trusted, and a self-signed server only receives a suggestion if it is already a
candidate. **Select Suggested Chain** prepares the selection for review; **Use
Selected Certificates** applies it to the editor. No matching chain, an expired
server, network failure and timeout have explicit explanations. Local matching
does not claim the Python connector or Exchange authentication has succeeded;
**Save & Verify** still performs that check. Selecting certificates explicitly adds
trust for this connection, rather than mirroring every macOS trust policy.

**Choose File…** accepts a PEM certificate bundle or a DER-encoded CER/CRT/DER
file. You can also enter an absolute path (for example `/etc/ssl/cert.pem`) or
a path starting with `~/` in **Certificate file path** and click **Load File**,
then **Save & Verify**. Both methods check the contents rather than relying on
the extension. Files must
contain only CA or supported self-signed server certificates (no private keys or P12/PFX identities), at most
512 certificates and 1 MB. Comments and textual descriptions outside PEM blocks
are accepted and discarded. Expired or not-yet-valid entries are skipped with
a visible count; a file with no currently valid certificates is rejected.
Private keys and incomplete or unsupported PEM blocks still cause an error.
Selected public certificates are copied into the
connection profile, so moving the original file does not break the connection.
After certificate renewal, select the replacement. Existing manually configured
PEM paths still work and are validated at connection time.

**Save & Verify** disconnects the previous session, saves the selection without
changing credentials and checks Exchange again. The app creates a private,
per-connection PEM under `MCP/Certificates/` beside the profiles file and passes
its path only to that Exchange process as `REQUESTS_CA_BUNDLE`. Existing bundled
connectors support this; reinstalling Python or the connector is unnecessary.
Diagnostics show a separate **Prepare Exchange TLS certificates** step. A
missing, invalid or expired certificate stops connection before MCP starts.
Preparing the file is not a claim that the server's chain is valid; only the
subsequent Exchange verification can establish that.

**Use Default Certificates** restores Python's default CA bundle, which may not
include a corporate CA installed in macOS. This does not disable TLS: certificate
chain, validity and hostname verification stay enabled in both modes. No TLS
bypass is offered. Package-installation trust for pip is separate. There is no
OAuth/Graph flow in this connector.

Credentials are stored in macOS Keychain (`TurboFieldfare.MCP`). They are passed
only to the connector process, not to Gemma, command-line arguments or profile
JSON. The **Authentication** card opens the editing form. **Remove Integration…**
is available in the connection header, the overview and the sidebar context
menu. After confirmation it immediately removes the server from chat routing,
stops its MCP process, deletes its profile, Keychain credentials and generated
per-connection certificate file. If macOS refuses a local cleanup step, the
integration remains removed and the app reports exactly what still needs manual
cleanup. The connection menu also provides **Forget Credentials**.

Profiles live in
`~/Library/Application Support/TurboFieldfare/mcp-connections.json`.
An unreadable or unsupported profile file is preserved and reported.
Connections start disconnected on launch. **Disconnect** and app termination
stop processes owned by this manager. Existing Outlook or model processes are
not affected.

## Request mail directly in chat

After saving and installing the Exchange connection, send an ordinary chat
message such as **«Разбери почту за сегодня»**, **«Что важного в письмах за
неделю?»**, **«Покажи письма за вчера»**, or **“Summarize my email this week”**.
The app resolves the requested period, connects and verifies the saved account if
needed, and loads headers without bodies. A **Какие письма анализировать?**
sheet shows senders and counts, saved groups, a subject filter and individual
message checkboxes. Only after confirmation does the app fetch bodies for the
selected IDs and add them to the model's reference context. Progress and
cancellation are available in the composer; cancelling the selection restores
the request without fetching bodies or starting inference.
If no Exchange integration is configured, the MCP mail router stays inactive:
messages containing words such as **«почта»**, **«письмо»** or **“email”** go
straight to the local model and cannot block an ordinary chat.
The sent message displays the account, period, folder and loaded-message count.
Before inference, the app checks whether the new reference text fits with the
current prompt. Mail references are not shortened to a prefix: when full loaded
bodies cannot fit, submission stops and asks for fewer messages or a larger
context. This prevents a successful-looking analysis containing only headers.
The summary includes the number of body characters loaded, excluding headers.
An empty body returned by the server is identified explicitly in the reference.

Follow-up questions such as **«Какие сроки указаны в письме?»** or
**«Проанализируй содержание этих писем»** use the mail already stored in that
conversation, without another server call or selection dialog. The complete
reference is saved as the user message's `contextContent`, including through
conversation serialization. A new chat does not inherit another chat's selection.
**«Загрузи письма за вчера»**, **«Обнови почту»**, or a new requested period opens
a fresh selection. Questions explicitly referring to loaded/selected messages
retain that selection. Normal history compression still applies in long chats;
original references remain saved in the transcript, but model context is finite.
Previously truncated references must be loaded again to recover missing bodies.

**Контакты и группы…** is available both in the selection sheet and the Exchange
connection. Sender names and addresses are remembered locally in that profile's
`mailContacts` field; subjects and bodies are not saved in this contact library.
Add or rename contacts by entering their email and preferred name. Select contacts
to create or update named groups. Mark mailing-list senders **Исключать** to leave
them unselected in suggestions and **Все, кроме исключённых**. They can still be
explicitly checked for a particular analysis. Groups can replace the sender
selection or be added to it. All library edits take effect when saved and remain
scoped to that mailbox.

Examples: **«Письма от Иванова за сегодня»**, **«Что важного от группы «Проект
Альфа» в почте за неделю?»**, **«Письма за сегодня, тема «релиз»»**. Local matching
prefills known email addresses, contact names, unique surnames (including common
Russian surname endings), exact group names and quoted subject filters. This is
a deterministic suggestion, not an LLM query planner: unsupported wording must be
adjusted in the sheet. All suggestions require review. No sender is selected by
default when the request has no recognized contact or group; use the all-senders
button or choose contacts. Period and folder routing follow the rules below.

Filtering applies to newly retrieved reference material. Earlier messages already
in the same conversation remain part of its history. The model is instructed to
limit conclusions to the current selection and to disclose incomplete coverage.

An explicit mail-reading request without a period defaults to today. **«А за
неделю?»** can follow a mail request in the same chat. With multiple accounts,
include the connection name or mailbox address in the request; a follow-up retains
the account from the preceding retrieval when identifiable. The default folder is
Inbox; “отправленные письма” selects Sent, and **из папки «Проект»** selects a
named folder. Straight quotes around the folder name also work.

Routing is intentionally limited to direct mail requests for today, yesterday
and the current week. Unsupported or conflicting periods request clarification
before mailbox access. Setup questions, quoted examples, explicit negation and
requests to analyze already attached mail do not trigger a new read. Only the
user's visible message and preceding user message inform routing; email bodies,
attachments and model output cannot authorize tool calls. This is a dedicated
mail request resolver, not a general model-driven MCP tool loop.

Missing configuration, failed sign-in and disabled mail tools stop submission
with an error and preserve the draft. No answer is generated as though mail had
been read. Cancelling retrieval also preserves the request. Mail remains read-only.

## Read mail manually and add it to a chat

Select **Today**, **Yesterday**, or **This Week**, select a folder, then choose
**Выбрать письма…**. Choose senders/groups, optionally filter subjects and uncheck
individual messages, then confirm. The default folder is Inbox, excluding subfolders. Today means
midnight to the first request; yesterday is the previous calendar day; this
week means Monday midnight to the first request, in the configured time zone.
Selecting Sent/Sent Items uses the sent timestamp.

The app follows header pages (100 headers per request, up to 10,000 per preview)
and reports when a preview is incomplete. Body requests use only confirmed IDs;
unselected messages are not passed to the model. It follows selected-message
body continuations. It displays
progress and supports cancellation. Dates are filtered on Exchange before
paging; the original last-100-messages search limitation is removed. A local
import budget of 300,000 characters or 1,000 messages stops an oversized selected
import with an error rather than returning bodies cut down to headers. The preview
can still be incomplete at its separate header limit. Live folder moves/deletions can shift EWS offsets;
the mailbox is not an immutable snapshot.

Review the loaded text, then choose **Add to Chat**. Mail is added as a reference
attachment to the selected chat, with a suggested analysis prompt if its draft
is empty. Generation starts only when the user sends the message. The existing
context budget rejects a mail attachment that cannot fit completely; use fewer
messages when necessary. Manually attached mail does not trigger a second mailbox
read when the message is sent. Email instructions are
treated as quoted reference content. Attachments inside emails are not fetched.

The Exchange connector exposes only `list_messages`, `get_message`,
`list_calendar_events` and an internal `check_connection`. It implements no
sending, editing, deleting, marking read or file-download operations. The app
also enforces a fixed Exchange tool allowlist, independently of advertised
`readOnlyHint` values. Tool switches are persisted and enforced on every call.
Account permissions themselves remain the normal Exchange permissions.

## Other local MCP servers

Choose **Add MCP Server → MCP Server**. Select an executable, put each argument on its
own line, optionally select a working directory, and add environment variables.
Environment values are stored in Keychain. Executables run directly without a
shell; paths must be absolute. Connect to discover tools and explicitly enable
the tools you want available for that connection.

This interface manages local stdio servers. Remote HTTP/OAuth connections and
general model-driven tool loops are not implemented. Exchange supports direct
mail requests from chat and manual mail-to-chat import; other servers currently
have configuration, connection checking, discovery, tool controls and manual
test requests.

## Test a connection and inspect data

Open a server and choose **Test Data…** beside its connection status. The test
window is available for every MCP connection and does not load an inference model.

1. If disconnected, choose **Connect & Verify** to authenticate and discover tools.
2. Select a tool. Disabled tools remain disabled; enable the intended tool in the
   server's **Tools** section first.
3. Review **Parameters · JSON**. Defaults and required fields are generated from
   the tool's schema; fill any required values. Expand **Parameter schema** for
   the full schema, including descriptions and allowed values.
4. Choose **Run Test**. The result shows the returned data, tool name, elapsed
   time, response size and receipt time. Expand **Parameters used for this
   response** to inspect the exact request, even after editing the next request.

For Exchange, **Today**, **Yesterday** and **This Week** prepare a sample of up
to three Inbox messages without bodies. Press **Run Test** to fetch it; selecting
a preset does not access the mailbox. The tester sends one request and does not
follow pagination. The JSON can be edited to change the folder or sample size.
All requests enforce the same Exchange read-only allowlist and tool switches
as chat/mail import, independently of server annotations.

Structured data and ordinary text responses are supported. **Show full MCP
envelope** reveals the original tool result. A tool-reported `isError` response
is displayed as **Tool error**, with its returned content. Connection failures
and invalid input are shown separately. An empty collection explicitly shows
zero items; a successful connection alone does not claim that mail was found.

The view displays server text as inert text, without loading images or links.
The preview is limited to 50,000 characters; **Copy JSON** explicitly copies the
complete tool response to the clipboard. Results are held only in memory and
cleared on closing the window. No diagnostics are automatically logged or added
to chat. **Cancel** stops waiting and suppresses late responses; the server may
already have processed a request. Generic MCP tools can have side effects and
are described according to their server's annotations, not guaranteed read-only.

## Implementation and validation

- AppCore `MCP/`: profiles, Keychain persistence, process ownership, MCP stdio
  lifecycle, tool policy, Exchange installation and mail import.
- MacPresentation `MCP/`: connection list, authentication form, tools and mail UI.
- `Resources/ExchangeMCP`: bundled adaptation of the supplied colleague archive
  `3fd1d62c85451c914d83183fccce46ab998731bc`, with exact Python dependency versions.
- `AppMCPTests`: persistence without secrets, Exchange authentication, tool
  policy, reconnect settings, full paging, corrupt-file preservation and real
  stdio framing/cancellation against a synthetic server; chat-to-mail-to-inference
  flow, follow-ups, cancellation, retry after failed sign-in, account selection
  and fitting large reference text before inference; diagnostic responses for
  plain text, errors, empty collections, invalid input, cancellation and paging.
- `AppMCPMailIntentTests`: Russian/English period requests, follow-ups, folder
  selection, rejected dates/write requests and non-mail messages that must not
  access a mailbox.
- `AppMCPCertificatesTests`: public certificate parsing, validity and CA checks,
  rejection of private keys/malformed or oversized files, per-connection PEM
  preparation, copied selections and compatibility with existing profiles.
- `AppMCPServerCertificatesTests`: issuer paths, lookalike CA rejection, hostname
  and expiry rejection, self-signed servers, offline trust policy, host validation
  and cancellation before probing. Fixtures use synthetic certificates only.
- `MCPConnectionsPresentationTests`: offscreen rendering of the common overview,
  empty state, server picker, local-server settings, Exchange detail and
  authentication form, plus diagnostic request/data/error states without loading a model.

```sh
Scripts/test.sh --filter 'AppMCPTests|AppMCPMailIntentTests|MCPConnectionsPresentationTests'
swift build -c release
```

These tests do not contact corporate Exchange or exercise the live Keychain.
Actual corporate authentication remains to be checked using the user's local
credentials. No mail is included in fixtures or screenshots.

`Scripts/test-exchange-tls.py` uses the installed, pinned Python dependencies to
check the actual Exchange Requests session's CA setting and TLS handshakes over
in-memory BIOs (no sockets). A selected CA succeeds; an unknown CA, wrong hostname
and expired server certificate fail. An optional PEM argument also verifies an
actual app-exported bundle can be loaded by the Python TLS stack:

```sh
scratch/exchange-mcp-readonly/.venv/bin/python Scripts/test-exchange-tls.py
```

### Read-only audit

`Scripts/test-exchange-readonly.py` exercises the bundled connector with the
actual pinned `exchangelib` library and synthetic EWS responses. It records the
generated EWS operations and rejects anything except `FindItem` and `GetItem`.
All HTTP requests are blocked by the test. It covers authentication checking,
today/yesterday/week mail queries, Sent, search, body reading and calendar access.
An unread fixture requesting a read receipt causes no update or receipt operation;
HTML tracking images are not loaded. Explicit calendar offsets are normalized to
UTC before passing them to the EWS library.

```sh
scratch/exchange-mcp-readonly/.venv/bin/python Scripts/test-exchange-readonly.py
Scripts/test.sh --filter AppMCPTests
```

Use another Python executable with the pinned dependencies if the scratch
environment is absent. The Python audit rejects 20 forbidden tool names at the
server boundary. The Swift test rejects the same 20 names before dispatch,
including with forged read-only annotations and a saved profile that enables them.

This assessment applies to the bundled Exchange connector and its Exchange
profile policy. A manually substituted executable or a generic local MCP is not
made read-only by a tool annotation. Normal Exchange account permissions remain
unchanged; no server-side read-only role is provisioned by this application.

### Local mail workspace

The **Почта** entry appears only while at least one mail MCP (Exchange or SMTP)
is connected successfully. Saving a profile alone does not enable it. Disconnecting
the last mail MCP hides the entry and closes the mail window; the local archive is retained.
Open **Почта** from the main window toolbar or **Settings → Почта — письма,
контакты и группы…**. Select an Exchange account to manage its contacts and
named groups. Contacts can be added or updated; the contact context menu offers
editing and deletion. Groups and exclusions remain scoped to the account.

**Загрузить письма…** connects to the selected account and previews the chosen
period and folder. Confirm senders and individual messages before body download.
Successful selected-message downloads now also populate a local archive at
`~/Library/Application Support/TurboFieldfare/mail-archive.json` (permissions
0600). Repeated downloads update the same account/message ID. Header previews
and failed partial downloads do not add body records. Earlier chat attachments
are not automatically migrated: reload their selection to populate the archive.

Search matches all entered words, case insensitively, across sender name/address,
subject and full text, with optional account/contact/group filters. It searches
only downloaded messages, without network requests or model calls. This is an
in-memory text search over the persisted archive, not a server-wide search.
Select a result to view/copy its full text; add one message or all matching results
to the current chat as a Mail attachment for analysis and follow-up questions.
The existing full-text/context budget checks still apply. Local archive deletion
leaves server messages and existing chat attachments intact.


Without a connected mail MCP, the composer **+** opens the file picker directly.
While a mail MCP is connected, **+** offers **Файлы…** and **Письма…**. The mail option opens the workspace as an attachment picker in a
sheet: filter downloaded messages, load another selection, check individual
messages, or attach all matching results. Confirmation stages their full text
as a Mail attachment with an envelope icon, closes the picker, and focuses the
prompt. It neither fills the prompt nor starts generation. Users can preview or
remove the attachment before sending. Attachment confirmation verifies that the
original chat is still selected and editable; disconnecting mail dismisses the
picker without attaching anything.
