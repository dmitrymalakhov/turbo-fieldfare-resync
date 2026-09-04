"""Verify Exchange CA selection without credentials, sockets or network access.

Uses the pinned connector dependencies. All TLS handshakes run over MemoryBIO.
An optional positional PEM path also checks an actual app-exported CA bundle.
"""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import ssl
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from exchangelib.protocol import BaseProtocol
from urllib3.util.ssl_ import create_urllib3_context


EXPORTED_BUNDLE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None


class ExchangeTLSTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Synthetic Corporate CA")])
        self.now = datetime.now(timezone.utc)
        self.ca = self.certificate(ca=True)
        self.ca_file = self.root / "ca.pem"
        self.ca_file.write_bytes(self.ca.public_bytes(serialization.Encoding.PEM))

    def certificate(self, ca=False, expired=False):
        subject = self.name if ca else x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mail.example.invalid")])
        builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(self.name)
                   .public_key(self.key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(self.now - timedelta(days=2))
                   .not_valid_after(self.now + timedelta(days=-1 if expired else 365))
                   .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(self.key.public_key()), critical=False)
                   .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self.key.public_key()), critical=False)
                   .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                       key_encipherment=False, data_encipherment=False, key_agreement=False,
                       key_cert_sign=ca, crl_sign=ca, encipher_only=False, decipher_only=False), critical=True))
        if not ca:
            builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName("mail.example.invalid")]), critical=False)
        return builder.sign(self.key, hashes.SHA256())

    def client_context(self, bundle):
        # Exercise the actual exchangelib Requests session and adapter configuration.
        with patch.dict(os.environ, {"REQUESTS_CA_BUNDLE": str(bundle)}, clear=True):
            with BaseProtocol.raw_session("https://mail.example.invalid/EWS/Exchange.asmx") as session:
                settings = session.merge_environment_settings("https://mail.example.invalid", {}, None, None, None)
                self.assertEqual(settings["verify"], str(bundle))
                context = create_urllib3_context(cert_reqs=ssl.CERT_REQUIRED)
                context.load_verify_locations(cafile=settings["verify"])
                self.assertTrue(context.check_hostname)
                self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
                return context

    def handshake(self, client_context, hostname="mail.example.invalid", expired=False):
        server_cert = self.root / "server.pem"
        server_cert.write_bytes(self.certificate(expired=expired).public_bytes(serialization.Encoding.PEM))
        server_key = self.root / "server.key"
        server_key.write_bytes(self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                     serialization.NoEncryption()))
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(server_cert, server_key)
        incoming_client, outgoing_client, incoming_server, outgoing_server = [ssl.MemoryBIO() for _ in range(4)]
        client = client_context.wrap_bio(incoming_client, outgoing_client, server_hostname=hostname)
        server = server_context.wrap_bio(incoming_server, outgoing_server, server_side=True)
        done = set()
        for _ in range(20):
            for name, peer, output, incoming in [("client", client, outgoing_client, incoming_server),
                                                  ("server", server, outgoing_server, incoming_client)]:
                if name not in done:
                    try:
                        peer.do_handshake()
                        done.add(name)
                    except ssl.SSLWantReadError:
                        pass
                if output.pending:
                    incoming.write(output.read())
            if len(done) == 2:
                return
        self.fail("TLS handshake did not complete")

    def test_selected_ca_is_accepted_but_untrusted_ca_is_rejected(self):
        self.handshake(self.client_context(self.ca_file))
        with self.assertRaisesRegex(ssl.SSLCertVerificationError, "issuer certificate"):
            self.handshake(ssl.create_default_context())

    def test_selected_ca_does_not_disable_hostname_or_expiry_checks(self):
        with self.assertRaisesRegex(ssl.SSLCertVerificationError, "Hostname mismatch"):
            self.handshake(self.client_context(self.ca_file), hostname="wrong.example.invalid")
        with self.assertRaisesRegex(ssl.SSLCertVerificationError, "certificate has expired"):
            self.handshake(self.client_context(self.ca_file), expired=True)

    @unittest.skipUnless(EXPORTED_BUNDLE, "No app-exported PEM supplied")
    def test_app_export_is_readable_by_the_actual_python_tls_stack(self):
        context = self.client_context(EXPORTED_BUNDLE)
        self.assertGreater(len(context.get_ca_certs()), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
