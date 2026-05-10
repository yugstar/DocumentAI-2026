#!/usr/bin/env bash
# Build Cloud Function source ZIPs expected by terraform/main.tf (run from repo root: ./scripts/package-functions.sh)
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
