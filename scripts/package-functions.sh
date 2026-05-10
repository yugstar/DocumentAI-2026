#!/usr/bin/env bash
# Optional: build local Cloud Run function source ZIPs for inspection.
# Terraform now generates these archives automatically via the archive provider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
mkdir -p "${TF_DIR}"
(
  cd "${ROOT}/Document-processing-function"
  zip -r "${TF_DIR}/document-processor.zip" . -x "*.pyc" -x "__pycache__/*" -x ".DS_Store"
)
(
  cd "${ROOT}/id-cards-function"
  zip -r "${TF_DIR}/id-cards.zip" . -x "*.pyc" -x "__pycache__/*" -x ".DS_Store"
)
echo "Wrote ${TF_DIR}/document-processor.zip and ${TF_DIR}/id-cards.zip"
