"""Pub/Sub-triggered function: warms/verifies REST API after employee doc is processed."""
import base64
import json
import os
import urllib.error
import urllib.request

import functions_framework


@functions_framework.cloud_event
def hello_pubsub(cloud_event):
    """Handle messages published by document-processor (JSON: {\"message_id\": \"...\"})."""
    event_data = cloud_event.data or {}
    message = event_data.get("message") or {}
    encoded_payload = message.get("data")
    if not encoded_payload:
        print("No Pub/Sub message data in CloudEvent")
        return
    payload = base64.b64decode(encoded_payload).decode("utf-8")
    body = json.loads(payload)
    employee_id = body.get("message_id")
    service_url = os.environ.get("SERVICE_URL", "").rstrip("/")
    if not employee_id:
        print("Missing message_id")
        return
    if not service_url:
        print("SERVICE_URL not set")
        return
    url = f"{service_url}/id/{employee_id}"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
        print(f"Fetched {url} status OK")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} for {url}: {e.reason}")
    except urllib.error.URLError as e:
        print(f"URL error for {url}: {e.reason}")
