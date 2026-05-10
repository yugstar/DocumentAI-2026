variable "project_name" {
  description = "The project ID where all resources will be launched."
  type        = string

  validation {
    condition = (
      var.project_name != "your-gcp-project-id"
      && var.project_name != "REPLACE-WITH-YOUR-PROJECT-ID"
      && can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_name))
    )
    error_message = "Set project_name in terraform.tfvars to your real GCP project id (lowercase). Use the same value as gcloud config get-value project — not the example placeholder."
  }
}

variable "region" {
  description = "GCP region for Cloud Run, Cloud Functions, and related resources (e.g. us-central1)."
  type        = string
}

variable "zone" {
  description = "GCP zone within the region (e.g. us-central1-a)."
  type        = string
}

variable "frontend_container_image" {
  description = "Full image URI for the upload UI Cloud Run service. Leave empty to use gcr.io/<project_name>/frontend-app:latest"
  type        = string
  default     = ""
}

variable "restapi_container_image" {
  description = "Full image URI for the REST API Cloud Run service. Leave empty to use gcr.io/<project_name>/restapi:latest"
  type        = string
  default     = ""
}

variable "documentai_location" {
  description = "Document AI processor location, usually us or eu."
  type        = string
  default     = "us"
}

variable "documentai_processor_id" {
  description = "Document AI processor ID used by the document-processor function."
  type        = string
  default     = "d13ac6ef4eb4f480"
}

variable "manage_cloud_run_invoker_iam" {
  description = "If true, Terraform grants allUsers Cloud Run Invoker on frontend and restapi. Requires run.services.setIamPolicy (e.g. roles/run.admin). Set false and use gcloud run services add-iam-policy-binding as a project owner if you see 403 on setIamPolicy."
  type        = bool
  default     = true
}

variable "function_runtime" {
  description = "Python runtime ID for Cloud Run functions."
  type        = string
  default     = "python313"
}

variable "function_min_instances" {
  description = "Minimum instances for each Cloud Run function."
  type        = number
  default     = 0
}

variable "function_max_instances" {
  description = "Maximum instances for each Cloud Run function."
  type        = number
  default     = 5
}

variable "function_memory" {
  description = "Memory allocated to each Cloud Run function."
  type        = string
  default     = "512M"
}

variable "document_processor_timeout_seconds" {
  description = "Timeout for the Document AI processor function."
  type        = number
  default     = 540
}

variable "id_cards_timeout_seconds" {
  description = "Timeout for the id-cards Pub/Sub subscriber function."
  type        = number
  default     = 60
}

locals {
  frontend_image = var.frontend_container_image != "" ? var.frontend_container_image : "gcr.io/${var.project_name}/frontend-app:latest"
  restapi_image  = var.restapi_container_image != "" ? var.restapi_container_image : "gcr.io/${var.project_name}/restapi:latest"
}
