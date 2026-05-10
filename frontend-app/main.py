import logging
import os

from flask import Flask, redirect, render_template, request, url_for
from google.cloud import storage
from werkzeug.utils import secure_filename

app = Flask(__name__)

# Configure this environment variable via app.yaml
CLOUD_STORAGE_BUCKET = os.environ.get('CLOUD_STORAGE_BUCKET') or 'docai-demo1'
REST_API_URL = os.environ.get('REST_API_URL', '').rstrip('/')


@app.route('/')
def index():
    return render_template(
        'index.html',
        uploaded=request.args.get('uploaded'),
        error=request.args.get('error'),
        records_url=REST_API_URL,
    )


@app.route('/upload', methods=['POST'])
def upload():
    """Process the uploaded file and upload it to Google Cloud Storage."""
    uploaded_file = request.files.get('file')

    if not uploaded_file or not uploaded_file.filename:
        return redirect(url_for('index', error='Choose a PDF before uploading.'), code=303)

    filename = secure_filename(uploaded_file.filename)
    if not filename:
        return redirect(url_for('index', error='The selected file name is not valid.'), code=303)

    # Create a Cloud Storage client.
    gcs = storage.Client()

    # Get the bucket that the file will be uploaded to.
    bucket = gcs.get_bucket(CLOUD_STORAGE_BUCKET)

    # Create a new blob and upload the file's content.
    blob = bucket.blob(filename)

    blob.upload_from_file(
        uploaded_file.stream,
        content_type=uploaded_file.content_type
    )

    return redirect(url_for('index', uploaded=filename), code=303)


@app.errorhandler(500)
def server_error(e):
    logging.exception('An error occurred during a request.')
    return """
    An internal error occurred: <pre>{}</pre>
    See logs for full stacktrace.
    """.format(e), 500


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=int(os.environ.get('PORT', 8080)))
