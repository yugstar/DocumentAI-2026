provider "google" {
  project = var.project_name
  region  = var.region
  zone    = var.zone
}

data "google_project" "current" {
  project_id = var.project_name
}

# Gen1 Cloud Functions read build metadata from Artifact Registry (gcf-artifacts).
resource "google_project_iam_member" "gcf_artifact_registry_reader" {
  project    = var.project_name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcf-admin-robot.iam.gserviceaccount.com"
  depends_on = [module.project_services]
}

moved {
  from = google_project_iam_member.gcf_artifact_registry_reader[0]
  to   = google_project_iam_member.gcf_artifact_registry_reader
}

#-------------------------------------------------------
# Enable APIs
#    - Cloud Function
#    - Pub/Sub
#    - Firestore
#    - Cloud run
#-------------------------------------------------------

module "project_services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "3.3.0"

  project_id = var.project_name
  activate_apis = [
    "cloudresourcemanager.googleapis.com",
    "cloudfunctions.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "run.googleapis.com",
    "documentai.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com"
  ]

  disable_services_on_destroy = false
  disable_dependent_services  = false
}

#-------------------------------------------------------
# Create Pub/Sub
#    - Topic
#    - Subscriber (Echo for test)
#-------------------------------------------------------

resource "google_pubsub_topic" "alert-topic" {
  name       = "emp-notification"
  depends_on = [module.project_services]
}

resource "google_pubsub_subscription" "echo" {
  name  = "echo"
  topic = google_pubsub_topic.alert-topic.name
}


#--------------------------------------------------------------------------------
# Event Collection Function
#  - Create source bucket
#  - Copy code from local into bucket
#  - Create function using source code and trigger based on pub/sub
#--------------------------------------------------------------------------------

resource "google_storage_bucket" "bucket" {
  name       = "${var.project_name}-source-bucket"
  location   = var.region
  depends_on = [module.project_services]
}

resource "google_storage_bucket" "archive" {
  name       = "${var.project_name}-archive-bucket"
  location   = var.region
  depends_on = [module.project_services]
}

# Default Cloud Run runtime identity (Compute Engine default SA) needs object access
# for the upload UI and Firestore for the REST API unless you set a custom service_account_name.
resource "google_storage_bucket_iam_member" "run_can_upload_to_source" {
  bucket = google_storage_bucket.bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "run_can_use_firestore" {
  project    = var.project_name
  role       = "roles/datastore.user"
  member     = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
  depends_on = [module.project_services]
}

resource "google_storage_bucket_object" "archive" {
  name   = "document-processor.zip"
  bucket = google_storage_bucket.archive.name
  source = "./document-processor.zip"
}

resource "google_cloudfunctions_function" "function" {
  name                  = "document-processor"
  runtime               = "python39"
  source_archive_bucket = google_storage_bucket.archive.name
  source_archive_object = google_storage_bucket_object.archive.name

  event_trigger {
    event_type = "google.storage.object.finalize"
    resource   = google_storage_bucket.bucket.name
  }
  entry_point = "main"
  labels = {
    app = "document-ai"
  }

  environment_variables = {
    ALERT_TOPIC             = google_pubsub_topic.alert-topic.name
    PROJECT_ID              = var.project_name
    DOCUMENTAI_LOCATION     = var.documentai_location
    DOCUMENTAI_PROCESSOR_ID = var.documentai_processor_id
  }
  # google_cloudfunctions_function requires a static depends_on list (no concat/conditionals).
  depends_on = [
    module.project_services,
    google_project_iam_member.gcf_artifact_registry_reader,
    google_pubsub_topic.alert-topic,
    google_storage_bucket_object.archive,
  ]
}

#----------------------------------------------------------------------------------------------
#  CLOUD RUN
#      - Enable API
#      - Create Service
#      - Expose the service to the public
#----------------------------------------------------------------------------------------------

resource "google_cloud_run_service" "front-end" {
  name     = "frontend-app"
  location = var.region
  depends_on = [
    module.project_services,
    google_storage_bucket_iam_member.run_can_upload_to_source,
    google_project_iam_member.run_can_use_firestore,
  ]

  # Ingress is a Service-level annotation (not valid on Revision template metadata).
  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
  }

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale"     = "1"
        "autoscaling.knative.dev/maxScale"     = "10"
        "run.googleapis.com/startup-cpu-boost" = "true"
      }
    }
    spec {
      containers {
        image = local.frontend_image
        ports {
          name           = "http1"
          container_port = 8080
        }
        env {
          name  = "CLOUD_STORAGE_BUCKET"
          value = google_storage_bucket.bucket.name
        }
        env {
          name  = "REST_API_URL"
          value = google_cloud_run_service.restapi.status[0].url
        }
      }
    }
  }

  # Without an explicit traffic block, revisions may receive 0% traffic → browser "Service Unavailable".
  traffic {
    percent         = 100
    latest_revision = true
  }
}

resource "google_cloud_run_service_iam_member" "allUsers" {
  count = var.manage_cloud_run_invoker_iam ? 1 : 0

  service  = google_cloud_run_service.front-end.name
  location = google_cloud_run_service.front-end.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}


#----------------------------------------------------------------------------------------------
#  CLOUD RUN
#      - Create Service for API endpoint
#----------------------------------------------------------------------------------------------

resource "google_cloud_run_service" "restapi" {
  name     = "restapi"
  location = var.region
  depends_on = [
    module.project_services,
    google_storage_bucket_iam_member.run_can_upload_to_source,
    google_project_iam_member.run_can_use_firestore,
  ]

  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
  }

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale"     = "1"
        "autoscaling.knative.dev/maxScale"     = "10"
        "run.googleapis.com/startup-cpu-boost" = "true"
      }
    }
    spec {
      containers {
        image = local.restapi_image
        ports {
          name           = "http1"
          container_port = 8080
        }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

resource "google_cloud_run_service_iam_member" "allUsers2" {
  count = var.manage_cloud_run_invoker_iam ? 1 : 0

  service  = google_cloud_run_service.restapi.name
  location = google_cloud_run_service.restapi.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}


#----------------------------------------------------------------------------------------------
#  Subscriber Cloud Function
#      - Copy code from local into existing source bucket
#      - Create function using source code and trigger based on Pub/Sub
#----------------------------------------------------------------------------------------------


resource "google_storage_bucket_object" "archive2" {
  bucket = google_storage_bucket.archive.name
  name   = "id-cards"
  source = "id-cards.zip"
}


resource "google_cloudfunctions_function" "id-cards" {
  name                  = "id-cards"
  runtime               = "python39"
  source_archive_bucket = google_storage_bucket.archive.name
  source_archive_object = google_storage_bucket_object.archive2.name

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.alert-topic.name
  }
  entry_point = "hello_pubsub"
  environment_variables = {
    SERVICE_URL = google_cloud_run_service.restapi.status[0].url
  }

  depends_on = [
    module.project_services,
    google_project_iam_member.gcf_artifact_registry_reader,
    google_cloud_run_service.restapi,
    google_storage_bucket_object.archive2,
    google_cloudfunctions_function.function,
  ]
}
