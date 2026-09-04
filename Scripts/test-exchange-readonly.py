"""Audit the bundled connector with real exchangelib and a synthetic EWS transport.

Run with a Python environment containing the connector's pinned dependencies.
No Exchange credentials or network access are used. All outbound requests fail.
"""

from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] /
                       "Sources/TurboFieldfareApp/Core/Resources/ExchangeMCP"))

from lxml import etree
from requests import Session
from exchangelib import Account, Configuration, Credentials, DELEGATE, NTLM
from exchangelib.folders import Calendar, Inbox, Root, SentItems
from exchangelib.services.common import EWSService
from exchangelib.version import Build, Version
from exchange_mcp import server


FORBIDDEN = ["send_email", "reply", "forward", "create_draft", "update_message",
             "delete_message", "move_message", "copy_message", "mark_as_read",
             "mark_as_unread", "set_categories", "create_event", "update_event",
             "delete_event", "accept_meeting", "decline_meeting", "execute",
             "SendItem", "UpdateItem", "DeleteItem"]
MESSAGES_NS = "http://schemas.microsoft.com/exchange/services/2006/messages"
TYPES_NS = "http://schemas.microsoft.com/exchange/services/2006/types"


class ReadOnlyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.network = patch.object(Session, "send", side_effect=AssertionError("Network access forbidden in audit"))
        self.network_mock = self.network.start()
        self.addCleanup(self.network.stop)
        self.operations = []
        self.payloads = []
        self.account = Account(
            primary_smtp_address="fixture@example.invalid", access_type=DELEGATE,
            config=Configuration(server="exchange.example.invalid", auth_type=NTLM,
                                 credentials=Credentials("fixture", "not-a-real-password"),
                                 version=Version(build=Build(15, 1, 2507, 6))),
            autodiscover=False,
        )
        # Pre-resolved folders avoid unrelated folder discovery in this mail-operation audit.
        root = Root(account=self.account, id="root", changekey="root-key")
        self.account.__dict__.update(
            root=root, inbox=Inbox(root=root, id="inbox", changekey="folder-key"),
            sent=SentItems(root=root, id="sent", changekey="folder-key"),
            calendar=Calendar(root=root, id="calendar", changekey="folder-key"),
        )
        account_patch = patch.object(server, "get_account", return_value=self.account)
        account_patch.start()
        self.addCleanup(account_patch.stop)
        audit = self

        def response(service, payload):
            return audit.respond(service, payload)

        transport = patch.object(EWSService, "_get_response_xml", response)
        transport.start()
        self.addCleanup(transport.stop)

    def tearDown(self):
        self.network_mock.assert_not_called()

    def respond(self, service, payload):
        operation = etree.QName(payload).localname
        self.operations.append(operation)
        self.payloads.append(etree.tostring(payload).decode())
        self.assertEqual(operation, service.SERVICE_NAME)
        self.assertIn(operation, {"FindItem", "GetItem"}, "Unexpected EWS operation")
        calendar = bool(payload.xpath("//*[local-name()='CalendarView']"))
        ids = payload.xpath("//*[local-name()='ItemId']/@Id")
        if calendar or "fixture-event" in ids:
            item = """<t:CalendarItem><t:ItemId Id="fixture-event" ChangeKey="unchanged"/>
                <t:ItemClass>IPM.Appointment</t:ItemClass><t:Subject>Fixture meeting</t:Subject>
                <t:Start>2026-09-04T08:00:00Z</t:Start><t:End>2026-09-04T09:00:00Z</t:End>
                <t:IsCancelled>false</t:IsCancelled><t:Location>Fixture room</t:Location>
                </t:CalendarItem>"""
        else:
            item = """<t:Message><t:ItemId Id="fixture-mail" ChangeKey="unchanged"/>
                <t:ItemClass>IPM.Note</t:ItemClass><t:Subject>Fixture mail</t:Subject>
                <t:Body BodyType="HTML">&lt;p&gt;Fixture body&lt;/p&gt;
                &lt;img src="https://example.invalid/tracking"/&gt;</t:Body>
                <t:DateTimeReceived>2026-09-04T08:00:00Z</t:DateTimeReceived>
                <t:DateTimeSent>2026-09-04T07:59:00Z</t:DateTimeSent>
                <t:HasAttachments>false</t:HasAttachments><t:IsRead>false</t:IsRead>
                <t:IsReadReceiptRequested>true</t:IsReadReceiptRequested></t:Message>"""
        content = f"<m:Items>{item}</m:Items>"
        if operation == "FindItem":
            content = f'<m:RootFolder IncludesLastItemInRange="true" TotalItemsInView="1"><t:Items>{item}</t:Items></m:RootFolder>'
        xml = f"""<m:{operation}ResponseMessage xmlns:m="{MESSAGES_NS}" xmlns:t="{TYPES_NS}" ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>{content}</m:{operation}ResponseMessage>"""
        return iter([etree.fromstring(xml.encode())])

    async def test_registered_tools_and_forbidden_calls(self):
        tools = await server.mcp.list_tools()
        self.assertEqual({tool.name for tool in tools},
                         {"check_connection", "list_messages", "get_message", "list_calendar_events"})
        for tool in tools:
            self.assertTrue(tool.annotations.readOnlyHint)
            self.assertFalse(tool.annotations.destructiveHint)
        from mcp.server.fastmcp.exceptions import ToolError
        for name in FORBIDDEN:
            with self.subTest(tool=name), self.assertRaisesRegex(ToolError, "Unknown tool"):
                await server.mcp.call_tool(name, {})
        self.assertEqual(self.operations, [])

    async def test_check_connection_only_finds_inbox_items(self):
        self.assertEqual(await server.check_connection(), {"authenticated": True})
        self.assertEqual(self.operations, ["FindItem"])

    async def test_period_mail_and_search_only_find_and_get_items(self):
        for period in ["today", "yesterday", "this_week"]:
            for folder in ["Inbox", "Sent"]:
                with self.subTest(period=period, folder=folder):
                    self.operations.clear()
                    result = await server.list_messages(period=period, folder=folder, include_body=True,
                                                        search="fixture", date_field="sent" if folder == "Sent" else "received")
                    self.assertEqual(result["returned"], 1)
                    self.assertEqual(result["messages"][0]["body"], "Fixture body")
                    self.assertEqual(self.operations, ["FindItem", "GetItem"])

    async def test_unread_message_and_receipt_request_do_not_trigger_writes(self):
        result = await server.get_message("fixture-mail", changekey="unchanged")
        self.assertEqual(result["body"], "Fixture body")
        self.assertEqual(result["changekey"], "unchanged")
        self.assertEqual(self.operations, ["GetItem"])
        # Inspect the actual library object too: fetching the unread message preserves its flag.
        message = next(self.account.fetch(ids=[("fixture-mail", "unchanged")], only_fields=["is_read"]))
        self.assertFalse(message.is_read)
        self.assertEqual(self.operations, ["GetItem", "GetItem"])

    async def test_calendar_only_finds_and_gets_items(self):
        result = await server.list_calendar_events("2026-09-04T00:00:00+03:00", "2026-09-05T00:00:00+03:00")
        self.assertEqual(result["events"][0]["subject"], "Fixture meeting")
        self.assertEqual(self.operations, ["FindItem", "GetItem"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
