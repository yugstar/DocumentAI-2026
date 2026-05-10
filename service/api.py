import os
from flask import Flask, jsonify, render_template
from google.cloud import firestore

app = Flask(__name__)


@app.route('/')
def index():
    return render_template('records.html', records=list_employee_records())


@app.route('/records')
def records():
    return render_template('records.html', records=list_employee_records())


@app.route('/api/records')
def records_api():
    records = list_employee_records()
    return jsonify({
        "records": records,
        "count": len(records),
    })


@app.route('/healthz')
def healthz():
    return jsonify({"status": "ok"})


@app.route('/id/<id>')
def get_message(id):
    client = firestore.Client()
    doc_ref = client.collection(u'employee').document(u'{}'.format(id))
    doc = doc_ref.get()
    data = doc.to_dict()
    if data:
        return jsonify(make_json_safe(data))
    else:
        return "Not Found", 404


def list_employee_records():
    client = firestore.Client()
    try:
        snapshots = (
            client.collection('employee')
            .order_by('created_at', direction=firestore.Query.DESCENDING)
            .limit(100)
            .stream()
        )
        records = [snapshot_to_record(snapshot) for snapshot in snapshots]
    except Exception:
        records = [snapshot_to_record(snapshot) for snapshot in client.collection('employee').limit(100).stream()]
        records.sort(key=lambda item: item.get('created_at') or '', reverse=True)
    return records


def snapshot_to_record(snapshot):
    data = make_json_safe(snapshot.to_dict() or {})
    data['id'] = snapshot.id
    data['display_name'] = build_display_name(data)
    data['field_count'] = len(data.get('fields') or {})
    data['text_preview'] = (data.get('text') or '').replace('\n', ' ')[:220]
    return data


def build_display_name(data):
    first = data.get('first_name') or ''
    last = data.get('last_name') or ''
    full_name = ' '.join(part for part in [first, last] if part).strip()
    return full_name or data.get('source_file') or data.get('record_id') or 'Untitled record'


def make_json_safe(value):
    if isinstance(value, dict):
        return {key: make_json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [make_json_safe(item) for item in value]
    if hasattr(value, 'isoformat'):
        return value.isoformat()
    return value


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=int(os.environ.get('PORT', 8080)))
