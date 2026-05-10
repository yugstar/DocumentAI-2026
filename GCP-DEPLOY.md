# Deploy DocumentAI-2026 on your GCP project

This repository deploys a Document AI processing pipeline with dynamic Cloud Run images, required GCS `location`, required APIs, Python 3.13 Cloud Run functions, and Terraform-generated function source archives.

## Architecture

Upload (Cloud Run + Flask) → **GCS** object finalize → **Cloud Run function** `document-processor` (Document AI + Firestore + Pub/Sub) → topic **`emp-notification`** → **Cloud Run function** `id-cards` (HTTP GET to REST API) → **Cloud Run** `restapi` reads **Firestore** collection `employee`.

## Prerequisites

- A GCP **project** with **billing** enabled.
- [gcloud](https://cloud.google.com/sdk/docs/install) and [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.3.
- Permissions to enable APIs, create buckets, Cloud Run functions, Cloud Run services, Pub/Sub, Eventarc, and **IAM policy updates** on the project and on Cloud Run. A service account with only **`roles/editor` cannot run this Terraform as-is** (Editor cannot change IAM). See **§5b** below.

## 1. Configure gcloud

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login   # optional; Terraform often uses this
```

## 2. Firestore (manual, once)

1. Console → **Firestore** → **Create database** → **Native** mode.
2. Pick a location compatible with your region (e.g. same multi-region/region as `us-central1` if possible).

Terraform does not create the Firestore database in this repo.

## 3. Document AI

- Ensure **Document AI API** is enabled (Terraform enables `documentai.googleapis.com`).
- Create or reuse a processor in `documentai_location`, then set `documentai_processor_id` in `terraform.tfvars`. The processor resource looks like `projects/<project>/locations/<location>/processors/<processor_id>`.

## 4. Build and push Cloud Run images (before first `terraform apply`)

Cloud Run services reference `gcr.io/<PROJECT_ID>/frontend-app:latest` and `gcr.io/<PROJECT_ID>/restapi:latest` by default. **Images must exist** (or override URIs in `terraform.tfvars`) or Cloud Run creation will fail.

From the **`app/` folder** (where `frontend-app/`, `service/`, and `terraform/` live). If your shell is in the parent folder `document-ai-gcp/`, run `cd app` first.

```bash
cd app   # skip if you are already in .../document-ai-gcp/app

export PROJECT_ID=$(gcloud config get-value project)

gcloud auth configure-docker gcr.io --quiet

gcloud builds submit ./frontend-app --tag "gcr.io/${PROJECT_ID}/frontend-app:latest" --project="${PROJECT_ID}"
gcloud builds submit ./service --tag "gcr.io/${PROJECT_ID}/restapi:latest" --project="${PROJECT_ID}"
```

If you stay in the workspace root (`document-ai-gcp/`) instead of `app/`, use:

```bash
gcloud builds submit ./app/frontend-app --tag "gcr.io/${PROJECT_ID}/frontend-app:latest" --project="${PROJECT_ID}"
gcloud builds submit ./app/service --tag "gcr.io/${PROJECT_ID}/restapi:latest" --project="${PROJECT_ID}"
```

Optional: use Cloud Build configs with a commit SHA tag, then set `frontend_container_image` and `restapi_container_image` in `terraform.tfvars`.

## 5. Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: project_name, region, zone
```

Authenticate Terraform (pick one):

- `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json` for a key, or
- Application Default Credentials from `gcloud auth application-default login`.

Terraform packages `Document-processing-function/` and `id-cards-function/` automatically using the `archive` provider. Generated ZIP files under `terraform/` are ignored by Git.

### 5b. Terraform service account — IAM permissions (common 403s)

This stack’s Terraform also creates **project-level IAM** for the function runtime account, Eventarc, the Cloud Functions service agent, and **Cloud Run invoker** bindings for `allUsers`. That requires extra roles beyond **`roles/editor`**.

**Option A — grant the Terraform SA enough rights (recommended)**
As a project **Owner**, run (use the `client_email` from your Terraform key JSON as `TF_SA`):

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export TF_SA="YOUR_TERRAFORM_SA@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${TF_SA}" \
  --role="roles/resourcemanager.projectIamAdmin"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${TF_SA}" \
  --role="roles/run.admin"
```

For a personal demo you can instead grant **`roles/owner`** on the project to that SA (avoid in production).

**Option B — keep Editor-only SA; skip only Cloud Run invoker in Terraform**
Project IAM for Cloud Run functions and Eventarc must still be applied by Terraform; that needs **`roles/resourcemanager.projectIamAdmin`** on the Terraform identity. If you truly cannot grant that, apply the project IAM bindings manually as Owner before functions deploy.

In `terraform.tfvars` set:

```hcl
manage_cloud_run_invoker_iam = false
```

Run `terraform apply`, then as an **Owner** user allow public invoke on Cloud Run:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"   # same as terraform.tfvars region

gcloud run services add-iam-policy-binding frontend-app --region="${REGION}" \
  --project="${PROJECT_ID}" --member="allUsers" --role="roles/run.invoker"
gcloud run services add-iam-policy-binding restapi --region="${REGION}" \
  --project="${PROJECT_ID}" --member="allUsers" --role="roles/run.invoker"
```

If Terraform never applied the **Artifact Registry reader** for `gcf-admin-robot`, add it once:

```bash
export PN="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PN}@gcf-admin-robot.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

## 6. Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Outputs include the **frontend** and **REST** Cloud Run URLs.

### Migrating from existing Gen1 functions

This branch replaces Gen1 `google_cloudfunctions_function` resources with Gen2 `google_cloudfunctions2_function` resources using the same function names. If Terraform plans to create the Gen2 functions before deleting the old Gen1 functions and Google reports a name conflict, delete the old Gen1 functions first or remove their old state entries only after confirming they are gone in GCP.

## 7. Smoke test

1. Open the **frontend** URL, upload a PDF that matches the form fields expected in `Document-processing-function/main.py` (e.g. `Employee #:`, `First Name:`, `Last Name:`).
2. Check **Firestore** → `employee` documents.
3. Call **`GET <restapi-url>/id/<employee_id>`**.

### Browser shows **Service Unavailable** on Cloud Run URLs (often HTTP **503**)

Google’s edge often returns a short body **“Service Unavailable”** (Chrome may not show the numeric code). That usually means **no healthy revision is receiving traffic**, not a Flask error page.

1. **Confirm the status code** (replace the URL from `terraform output`):

   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" "https://YOUR-FRONTEND-URL/"
   ```

   `403` → missing **Invoker** (`allUsers` or your user). If you set `manage_cloud_run_invoker_iam = false`, run the `gcloud run services add-iam-policy-binding` lines in **§5b Option B**.
   `503` → traffic/revision/container (continue below).

2. **Traffic to latest revision** — Terraform sets `traffic { percent = 100 latest_revision = true }`. Run `terraform apply` after pulling the latest `main.tf`.

3. **Public ingress** — Service metadata includes `run.googleapis.com/ingress = "all"`. If your org restricts ingress, the console may override this; check **Cloud Run → service → Networking**.

4. **Container never listens on `$PORT`** — Images use `CMD` via `sh -c` so Gunicorn binds to **`${PORT:-8080}`**. Rebuild and push **both** images after any Dockerfile change, then redeploy (new revision):

   ```bash
   cd app
   export PROJECT_ID="$(gcloud config get-value project)"
   gcloud builds submit ./frontend-app --tag "gcr.io/${PROJECT_ID}/frontend-app:latest" --project="${PROJECT_ID}"
   gcloud builds submit ./service --tag "gcr.io/${PROJECT_ID}/restapi:latest" --project="${PROJECT_ID}"
   cd terraform && terraform apply
   ```

5. **Logs** — `gcloud run services logs read frontend-app --region=REGION --project=PROJECT_ID` (and `restapi`). Look for bind errors, import errors, or crash loops.

6. **Firestore / GCS IAM** — Terraform adds **`roles/datastore.user`** (project) and **`roles/storage.objectAdmin`** (source bucket) for the default Cloud Run service account, and least-privilege IAM for the dedicated function runtime account. Re-apply if those bindings failed earlier.

## Security notes (production)

- Cloud Run is deployed with **`allUsers`** as **Invoker** (public). Restrict for private data.
- Prefer **least-privilege IAM** instead of **Editor** on service accounts.
- Rotate keys; prefer **Workload Identity** where possible.

## Local Docker (optional)

Images listen on **8080** (`PORT`). Example:

```bash
docker build -t restapi-local ./service
docker run --rm -p 8080:8080 -e PORT=8080 \
  -e GOOGLE_APPLICATION_CREDENTIALS=/key.json \
  -v "$HOME/key.json:/key.json:ro" \
  restapi-local
```

If you map host port differently, keep **container** port 8080: `-p 9090:8080`.

## Troubleshooting

### `gcloud builds submit` — `403` / `storage.objects.get` / `...-compute@developer.gserviceaccount.com`

Cloud Build stages your source under `gs://<PROJECT_ID>_cloudbuild/`. The build must read that object using project service accounts. If default roles were removed or the project is new, grant the usual roles (replace `PROJECT_ID` if unset):

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

# Cloud Build’s own service account (recommended first)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/storage.admin"

# If the error names the default Compute Engine service account, it also needs read access to staged sources:
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectViewer"
```

Wait 30–60 seconds for IAM to propagate, then retry `gcloud builds submit`. You need **Owner** or **Security Admin** (or equivalent) on the project to add bindings.

If your org uses deny policies or removes default SAs, ask an admin to allow Cloud Build’s GCS access for this project.

### `terraform apply` — `Unknown project id: your-gcp-project-id` / `CONSUMER_INVALID` / Service Usage `SERVICE_DISABLED`

**Cause:** `terraform.tfvars` still has the **example** `project_name` (`your-gcp-project-id` or similar). Terraform then targets a project that does not exist. Cloud Run and the API module fail; Service Usage errors often appear at the same time.

**Fix:**

1. Edit `app/terraform/terraform.tfvars` and set `project_name` to your **real** project id (must match where you ran `gcloud builds submit` and `gcloud config set project`).
2. One-time, enable the Service Usage API (as a human user with Owner / Editor on that project), then re-apply:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
gcloud services enable serviceusage.googleapis.com --project="${PROJECT_ID}"
```

3. From `app/terraform/` run `terraform plan` and `terraform apply` again.

If apply failed partway through, `terraform plan` will show any resources already created; usually a second apply after fixing `project_name` is enough.

### `Cloud Run Admin API ... SERVICE_DISABLED` during apply

APIs were still enabling while Cloud Run was created (race). This repo adds `depends_on = [module.project_services]` on Cloud Run (and related resources). Re-run `terraform apply`. You can also enable manually: `gcloud services enable run.googleapis.com --project=YOUR_PROJECT_ID`.

### Cloud Run functions — `gcf-artifacts` / `artifactregistry.repositories.get`

Cloud Run functions use Artifact Registry during builds. Terraform enables `artifactregistry.googleapis.com` and grants the **Cloud Functions service agent** `roles/artifactregistry.reader` (`service-<PROJECT_NUMBER>@gcf-admin-robot.iam.gserviceaccount.com`). Re-run `terraform apply`.

### `403 Policy update access denied` (project IAM) or `run.services.setIamPolicy` denied

Your Terraform identity (often a **service account key**) does not have permission to change **project IAM** or **Cloud Run service IAM**. **`roles/editor` alone is not enough.** See **§5b** in this file: add `roles/resourcemanager.projectIamAdmin` and `roles/run.admin` to that SA, or set `manage_cloud_run_invoker_iam` to `false` and run the manual `gcloud run services add-iam-policy-binding` commands there.

| Issue | What to check |
|--------|----------------|
| Terraform invalid / missing `location` on buckets | Use this repo’s updated `main.tf` (buckets set `location = var.region`). |
| Cloud Run fails to pull image | Build/push images to the same project and tag as in `terraform.tfvars` / defaults. |
| Cloud Run / Docker “port” or health check failures | Terraform sets `container_port = 8080`; containers use **Gunicorn** on `$PORT` (default 8080). Do not publish to the wrong container port. |
| Function deploy fails | Confirm `function_runtime` is supported in your region and dependencies in each function’s `requirements.txt` install on Python 3.13. |
| Document AI errors | API enabled, correct location/processor, PDF matches form hints. |
| `project_id` is None in logs | Terraform sets `PROJECT_ID` in the function environment. Re-apply if the service config did not update. |
