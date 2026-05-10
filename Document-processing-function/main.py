import json
import logging
import mimetypes
import os
import re

from google.api_core.client_options import ClientOptions
from google.cloud import documentai_v1 as documentai
from google.cloud import firestore
from google.cloud import pubsub_v1


project_id = (
    os.environ.get("PROJECT_ID")
    or os.environ.get("GCP_PROJECT")
    or os.environ.get("GOOGLE_CLOUD_PROJECT")
    or os.environ.get("GCLOUD_PROJECT")
)
topic_id = os.environ.get("ALERT_TOPIC")
documentai_location = os.environ.get("DOCUMENTAI_LOCATION", "us")
documentai_processor_id = os.environ.get("DOCUMENTAI_PROCESSOR_ID")

TEXT_LIMIT = 150_000


def main(event, context):
    """Triggered by a finalized object in Cloud Storage."""
    bucket = event["bucket"]
    file_name = event["name"]
    uri = f"gs://{bucket}/{file_name}"
    mime_type = event.get("contentType") or mimetypes.guess_type(file_name)[0] or "application/pdf"

    processed = process_document(input_uri=uri, mime_type=mime_type)
    fields = processed["fields"]
    event_id = getattr(context, "event_id", "") or event.get("id", "")
    record_id = build_record_id(file_name, event_id, fields)

    first_name = lookup_field(fields, "First Name")
    last_name = lookup_field(fields, "Last Name")
    employee_id = lookup_field(fields, "Employee #") or lookup_field(fields, "Employee ID")

    record = {
        "record_id": record_id,
        "employee_id": employee_id,
        "first_name": first_name,
        "last_name": last_name,
        "fields": fields,
        "text": processed["text"][:TEXT_LIMIT],
        "text_truncated": len(processed["text"]) > TEXT_LIMIT,
        "source_bucket": bucket,
        "source_file": file_name,
        "gcs_uri": uri,
        "mime_type": mime_type,
        "document_ai_location": documentai_location,
        "document_ai_processor_id": documentai_processor_id,
        "created_at": firestore.SERVER_TIMESTAMP,
    }

    if first_name and last_name:
        record["email"] = f"{first_name.lower()}.{last_name.lower()}@example.com"

    add_into_firestore(record, record_id)
    publish_message(record_id)
    logging.info("Processed %s into Firestore employee/%s", uri, record_id)


def process_document(input_uri, mime_type):
    """Process a Cloud Storage document with the configured Document AI processor."""
    if not documentai_processor_id:
        raise RuntimeError("DOCUMENTAI_PROCESSOR_ID environment variable is not set")

    client_options = ClientOptions(api_endpoint=f"{documentai_location}-documentai.googleapis.com")
    client = documentai.DocumentProcessorServiceClient(client_options=client_options)
    processor_name = client.processor_path(project_id, documentai_location, documentai_processor_id)

    request = documentai.ProcessRequest(
        name=processor_name,
        gcs_document=documentai.GcsDocument(gcs_uri=input_uri, mime_type=mime_type),
    )
    result = client.process_document(request=request)
    document = result.document

    fields = {}
    for page in document.pages:
        for form_field in page.form_fields:
            name = layout_to_text(form_field.field_name, document.text).strip()
            value = layout_to_text(form_field.field_value, document.text).strip()
            if name:
                fields[name] = value

    logging.info("Extracted fields from %s: %s", input_uri, sorted(fields.keys()))
    return {"fields": fields, "text": document.text or ""}


def layout_to_text(layout, text):
    """Convert Document AI text anchor offsets into text."""
    response = []
    for segment in layout.text_anchor.text_segments:
        start_index = int(segment.start_index or 0)
        end_index = int(segment.end_index or 0)
        response.append(text[start_index:end_index])
    return "".join(response)


def lookup_field(fields, desired_name):
    desired = normalize_field_name(desired_name)
    for name, value in fields.items():
        if normalize_field_name(name) == desired:
            return value
    return ""


def normalize_field_name(name):
    return re.sub(r"[^a-z0-9#]+", "", name.lower().replace(":", ""))


def build_record_id(file_name, event_id, fields):
    employee_id = lookup_field(fields, "Employee #") or lookup_field(fields, "Employee ID")
    if employee_id:
        return clean_firestore_id(employee_id)
    base_name = os.path.splitext(os.path.basename(file_name))[0]
    suffix = event_id[-16:] if event_id else "processed"
    return clean_firestore_id(f"{base_name}-{suffix}")


def clean_firestore_id(value):
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-._")
    return (cleaned or "document")[:120]


def add_into_firestore(message, record_id):
    db = firestore.Client()
    doc_ref = db.collection("employee").document(record_id)
    doc_ref.set(message)


def publish_message(message_id):
    if not topic_id:
        logging.info("ALERT_TOPIC not set; skipping Pub/Sub publish")
        return
    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_id)
    data = json.dumps({"message_id": message_id}).encode("utf-8")
    future = publisher.publish(topic_path, data=data)
    logging.info("Published Pub/Sub message %s", future.result())
