"""Model-free SMTP connector tests. All SMTP clients are mocked; no mail is sent."""
import importlib.util
import json
import os
from pathlib import Path
import smtplib
import ssl
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1] / "Sources/TurboFieldfareApp/Core/Resources/SMTPMCP/server.py"
spec = importlib.util.spec_from_file_location("smtp_connector", SOURCE)
smtp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smtp)


class SMTPTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "SMTP_HOST": "smtp.example.invalid", "SMTP_PORT": "587", "SMTP_SECURITY": "STARTTLS",
            "SMTP_USERNAME": "user", "SMTP_PASSWORD": "secret", "SMTP_FROM": "sender@example.invalid",
        }, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.client = MagicMock()
        self.client.noop.return_value = (250, b"OK")
        self.client.send_message.return_value = {}
        self.factory = patch.object(smtp.smtplib, "SMTP", return_value=self.client)
        self.factory.start()
        self.addCleanup(self.factory.stop)

    def test_check_authenticates_only_after_starttls_and_does_not_send(self):
        self.assertTrue(smtp.check_connection()["authenticated"])
        names = [call[0] for call in self.client.mock_calls]
        self.assertEqual(names, ["ehlo", "starttls", "ehlo", "login", "noop", "close"])
        context = self.client.starttls.call_args.kwargs["context"]
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.client.send_message.assert_not_called()

    def test_missing_starttls_never_falls_back_to_plaintext(self):
        self.client.starttls.side_effect = smtplib.SMTPNotSupportedError("no STARTTLS")
        with self.assertRaises(smtplib.SMTPNotSupportedError):
            smtp.check_connection()
        self.client.login.assert_not_called()
        self.client.close.assert_called_once()

    def test_implicit_tls_and_custom_ca(self):
        os.environ.update(SMTP_SECURITY="TLS", SMTP_PORT="465", SMTP_CA_BUNDLE="/test/corporate.pem")
        context = MagicMock()
        with patch.object(smtp.ssl, "create_default_context", return_value=context), \
             patch.object(smtp.smtplib, "SMTP_SSL", return_value=self.client) as factory:
            smtp.check_connection()
        context.load_verify_locations.assert_called_once_with(cafile="/test/corporate.pem")
        factory.assert_called_once_with("smtp.example.invalid", 465, timeout=10, context=context)
        self.client.starttls.assert_not_called()

    def test_invalid_ca_stops_before_authentication(self):
        os.environ["SMTP_CA_BUNDLE"] = "/nonexistent/turbofieldfare-smtp-test.pem"
        with self.assertRaises(FileNotFoundError):
            smtp.check_connection()
        self.client.login.assert_not_called()

    def test_unicode_body_and_partial_acceptance_are_preserved(self):
        self.client.send_message.return_value = {"bad@example.invalid": (550, b"rejected")}
        result = smtp.send_email(["ok@example.invalid", "bad@example.invalid"], "Проверка", "Привет!\nВторая строка.")
        self.assertEqual(result["accepted"], ["ok@example.invalid"])
        self.assertEqual(result["rejected"], {"bad@example.invalid": 550})
        message = self.client.send_message.call_args.args[0]
        self.assertEqual(str(message["Subject"]), "Проверка")
        self.assertIn("Привет!", message.get_content())
        self.assertEqual(self.client.send_message.call_args.kwargs["from_addr"], "sender@example.invalid")

    def test_header_injection_and_bad_recipients_rejected_before_network(self):
        for to, subject in [(["victim@example.invalid\r\nBcc: other@example.invalid"], "Hi"),
                            (["ok@example.invalid"], "Hi\nBcc: other@example.invalid"),
                            (["Name <ok@example.invalid>"], "Hi"), ([], "Hi")]:
            with self.assertRaises(ValueError):
                smtp.send_email(to, subject, "body")
        self.client.login.assert_not_called()

    def test_interrupted_submission_is_unknown_and_not_retried(self):
        self.client.send_message.side_effect = smtplib.SMTPServerDisconnected("lost")
        with self.assertRaisesRegex(ValueError, "outcome is unknown"):
            smtp.send_email(["ok@example.invalid"], "Subject", "Body")
        self.client.send_message.assert_called_once()

    def test_authentication_error_does_not_echo_server_secrets(self):
        error = smtplib.SMTPAuthenticationError(535, b"secret")
        self.assertNotIn("secret", smtp.error_text(error))
        self.assertIn("535", smtp.error_text(error))

    def test_stdio_handshake_and_tools_do_not_offer_sending(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        ]
        result = subprocess.run([sys.executable, "-I", str(SOURCE)],
                                input="\n".join(json.dumps(x) for x in requests) + "\n",
                                text=True, capture_output=True, timeout=5, check=True)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-11-25")
        self.assertEqual([tool["name"] for tool in replies[1]["result"]["tools"]], ["check_connection"])


if __name__ == "__main__":
    unittest.main()
