"""Bundled SMTP stdio connector; Python 3.9+, standard library only."""
import json
import os
import re
import smtplib
import ssl
import sys
from contextlib import contextmanager
from email.message import EmailMessage
from email.utils import formatdate, make_msgid


def address(value):
    # This UI accepts plain ASCII addr-specs, not display names or address lists.
    if not isinstance(value, str) or len(value) > 254 or not re.fullmatch(
        r"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*"
        r"@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", value
    ) or ".." in value:
        raise ValueError("Use a plain email address without display names or line breaks.")
    return value


@contextmanager
def connection():
    host = os.environ.get("SMTP_HOST", "")
    port = int(os.environ.get("SMTP_PORT", "587"))
    security = os.environ.get("SMTP_SECURITY", "STARTTLS")
    username = os.environ.get("SMTP_USERNAME", "")
    password = os.environ.get("SMTP_PASSWORD", "")
    if not host or any(c.isspace() or c in "/:\x00" for c in host) or not 1 <= port <= 65535:
        raise ValueError("Invalid SMTP hostname or port.")
    if security not in ("STARTTLS", "TLS") or not username or not password:
        raise ValueError("SMTP requires STARTTLS or TLS and a username and password.")
    context = ssl.create_default_context()
    if os.environ.get("SMTP_CA_BUNDLE"):
        context.load_verify_locations(cafile=os.environ["SMTP_CA_BUNDLE"])
    client = None
    try:
        if security == "TLS":
            client = smtplib.SMTP_SSL(host, port, timeout=10, context=context)
        else:
            client = smtplib.SMTP(host, port, timeout=10)
            client.ehlo()
            client.starttls(context=context)  # No plaintext fallback or AUTH before TLS.
        client.ehlo()
        client.login(username, password)
        yield client
    finally:
        if client is not None:
            # Closing must not turn a successful DATA response into a send failure.
            client.close()


def check_connection():
    address(os.environ.get("SMTP_FROM", ""))
    with connection() as client:
        code, _ = client.noop()
        if code != 250:
            raise ValueError("SMTP NOOP failed (code %s)." % code)
    return {"authenticated": True, "note": "TLS and login verified. No message was sent; sender permission is checked on sending."}


def send_email(to, subject, body):
    if not isinstance(to, list) or not 1 <= len(to) <= 50:
        raise ValueError("Enter between 1 and 50 recipients.")
    recipients = list(dict.fromkeys(address(item) for item in to))
    if not isinstance(subject, str) or not subject.strip() or len(subject) > 998 or any(c in subject for c in "\r\n\x00"):
        raise ValueError("Enter a subject without line breaks (at most 998 characters).")
    if not isinstance(body, str) or not body.strip() or len(body.encode("utf-8")) > 1_000_000 or "\x00" in body:
        raise ValueError("Enter a text body of at most 1 MB without NUL characters.")
    sender = address(os.environ.get("SMTP_FROM", ""))
    message = EmailMessage()
    message["From"], message["To"], message["Subject"] = sender, ", ".join(recipients), subject
    message["Date"], message["Message-ID"] = formatdate(localtime=False), make_msgid()
    message.set_content(body)
    with connection() as client:
        try:
            refused = client.send_message(message, from_addr=sender, to_addrs=recipients)
        except (OSError, smtplib.SMTPServerDisconnected) as error:
            raise ValueError("Submission outcome is unknown. Check with the mail server before retrying; the message may have been accepted.") from error
    return {"accepted": [item for item in recipients if item not in refused],
            "rejected": {item: details[0] for item, details in refused.items()},
            "message_id": str(message["Message-ID"]),
            "note": "Accepted by SMTP server; this does not confirm delivery. Do not resend to accepted recipients."}


def error_text(error):
    if isinstance(error, ssl.SSLCertVerificationError):
        return "SMTP certificate verification failed. Select the corporate CA certificate and check the hostname and certificate dates."
    if isinstance(error, smtplib.SMTPAuthenticationError):
        return "SMTP authentication failed (code %s). Check credentials and whether SMTP AUTH is enabled." % error.smtp_code
    if isinstance(error, smtplib.SMTPRecipientsRefused):
        return "SMTP rejected all recipients. No recipient accepted the message."
    if isinstance(error, smtplib.SMTPResponseException):
        return "SMTP rejected the request (code %s)." % error.smtp_code
    if isinstance(error, smtplib.SMTPNotSupportedError):
        return "The SMTP server does not support the required TLS or authentication method."
    if isinstance(error, ValueError):
        return str(error)
    return "SMTP connection failed (%s). Check the host, port, VPN, Python and certificate file." % type(error).__name__


def dispatch(method, params):
    if method == "initialize":
        return {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                "serverInfo": {"name": "turbofieldfare-smtp", "version": "1.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        # Sending is deliberately available only via the application's reviewed composer.
        return {"tools": [{"name": "check_connection", "description": "Check SMTP TLS and authentication without sending mail.",
                           "annotations": {"readOnlyHint": True},
                           "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}]}
    if method == "tools/call" and params.get("name") == "check_connection":
        result = check_connection()
    elif method == "smtp/send":
        result = send_email(**params)
    else:
        raise ValueError("Unsupported SMTP operation.")
    return {"structuredContent": result, "content": [{"type": "text", "text": json.dumps(result)}]}


def main():
    for line in sys.stdin:
        request = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or "id" not in request:
                continue
            try:
                result = dispatch(request.get("method"), request.get("params", {}))
            except Exception as error:
                result = {"isError": True, "content": [{"type": "text", "text": error_text(error)}]}
            response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        except (ValueError, TypeError):
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid JSON request"}}
        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
