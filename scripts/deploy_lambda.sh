#!/bin/bash
# scripts/deploy_lambda.sh
# Packages and deploys Lambda functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
ENVIRONMENT=${1:-dev}
REGION=${AWS_DEFAULT_REGION:-us-east-1}
PROJECT_NAME="self-healing-infra"
# Use /tmp to avoid cross-filesystem issues in WSL
TMP_DIR="/tmp"
mkdir -p "$TMP_DIR"
if ! BUILD_DIR="$(mktemp -d "$TMP_DIR/lambda-build-XXXXXX" 2>/dev/null)"; then
  BUILD_DIR="$TMP_DIR/lambda-build-$$"
  mkdir -p "$BUILD_DIR"
fi
PACKAGE_FILE="$BUILD_DIR/lambda-package.zip"
RESPONSE_FILE="$BUILD_DIR/lambda-response.json"

echo "=== Deploying Lambda functions to $ENVIRONMENT ==="

# ─── Prerequisites ────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { echo "aws CLI not found"; exit 1; }
PYTHON_CMD=()
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PYTHON_CMD=("$candidate")
    break
  fi
done
if [ ${#PYTHON_CMD[@]} -eq 0 ] && command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON_CMD=(py -3)
fi
if [ ${#PYTHON_CMD[@]} -eq 0 ]; then
  echo "Python not found or the python3/python alias is invalid; install Python 3 and make it available as python3, python, or py"
  exit 1
fi

PIP_CMD=()
for candidate in pip3 pip; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PIP_CMD=("$candidate")
    break
  fi
done
if [ ${#PIP_CMD[@]} -eq 0 ]; then
  if "${PYTHON_CMD[@]}" -m pip --version >/dev/null 2>&1; then
    PIP_CMD=("${PYTHON_CMD[@]}" -m pip)
  else
    echo "pip not found; install pip for Python"
    exit 1
  fi
fi

PYTHON_IS_WINDOWS=false
if "${PYTHON_CMD[@]}" -c 'import os; print(os.name)' 2>/dev/null | grep -q '^nt$'; then
  PYTHON_IS_WINDOWS=true
fi

if [ "$PYTHON_IS_WINDOWS" = true ]; then
  echo "Error: Windows is not supported for building Linux-compatible Lambda packages with this script."
  echo "Run this script in WSL, Docker, or a Linux shell."
  exit 1
fi

if [ "$PYTHON_IS_WINDOWS" = true ] && command -v cygpath >/dev/null 2>&1; then
  BUILD_DIR_WIN="$(cygpath -w "$BUILD_DIR")"
  PACKAGE_FILE_WIN="$(cygpath -w "$PACKAGE_FILE")"
  RESPONSE_FILE_WIN="$(cygpath -w "$RESPONSE_FILE")"
  PIP_TARGET_DIR="$(cygpath -w "$BUILD_DIR")"
else
  BUILD_DIR_WIN="$BUILD_DIR"
  PACKAGE_FILE_WIN="$PACKAGE_FILE"
  RESPONSE_FILE_WIN="$RESPONSE_FILE"
  PIP_TARGET_DIR="$BUILD_DIR"
fi

ZIP_CMD=""
if command -v zip >/dev/null 2>&1; then
  ZIP_CMD="zip"
fi

# ─── Build Package ────────────────────────────────────────────────
echo "Building deployment package..."
mkdir -p "$BUILD_DIR"

# Install dependencies into package dir
echo "Installing Python dependencies into package directory..."
"${PIP_CMD[@]}" install \
  boto3 requests PyYAML \
  --target "$PIP_TARGET_DIR" \
  --platform manylinux2014_x86_64 \
  --only-binary=:all: \
  --python-version 3.11

# Copy source code
cp -r "$REPO_ROOT/src/." "$BUILD_DIR/"

# Create zip
cd "$BUILD_DIR"
if [ -n "$ZIP_CMD" ]; then
  zip -r "$PACKAGE_FILE" . -q
else
  "${PYTHON_CMD[@]}" - <<PY
import os
import zipfile
package = r"$PACKAGE_FILE_WIN"
with zipfile.ZipFile(package, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
    for root, _, files in os.walk('.'):
        for name in files:
            path = os.path.join(root, name)
            zf.write(path, os.path.relpath(path, '.'))
PY
fi
cd -

PACKAGE_SIZE=$(du -sh "$PACKAGE_FILE" | cut -f1)
echo "Package size: $PACKAGE_SIZE"

# ─── Deploy Functions ─────────────────────────────────────────────
FUNCTIONS=(
  "health-checker:src/health_checker/main.py:lambda_handler"
  "healer:src/healer/main.py:lambda_handler"
)

for func_spec in "${FUNCTIONS[@]}"; do
  IFS=':' read -r func_suffix _ handler <<< "$func_spec"
  FUNCTION_NAME="${PROJECT_NAME}-${func_suffix}-${ENVIRONMENT}"

  echo "Deploying $FUNCTION_NAME..."

  # Check if function exists
  if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
    # Update existing
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$PACKAGE_FILE_WIN" \
      --region "$REGION" \
      --output text \
      --query 'FunctionArn' \
      | xargs echo "  Updated:"
  else
    echo "  Function $FUNCTION_NAME not found. Deploy with Terraform first."
    echo "  cd terraform/environments/$ENVIRONMENT && terraform apply"
    exit 1
  fi

  # Wait for update to complete
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    2>/dev/null || true

  echo "  ✅ $FUNCTION_NAME deployed"
done

# ─── Smoke Test ──────────────────────────────────────────────────
echo ""
echo "Running smoke test on health-checker..."
RESULT=$(aws lambda invoke \
  --function-name "${PROJECT_NAME}-health-checker-${ENVIRONMENT}" \
  --payload '{"source": "smoke-test"}' \
  --region "$REGION" \
  "$RESPONSE_FILE_WIN" \
  --output json 2>&1)

if grep -q '"StatusCode": 200' <<< "$RESULT"; then
  echo "  ✅ Smoke test passed"
  cat "$RESPONSE_FILE"
else
  echo "  ❌ Smoke test failed: $RESULT"
  exit 1
fi

# ─── Cleanup ──────────────────────────────────────────────────────
rm -rf "$BUILD_DIR" "$PACKAGE_FILE" "$RESPONSE_FILE"

echo ""
echo "=== Deployment complete ✅ ==="
echo "CloudWatch Dashboard: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${PROJECT_NAME}-${ENVIRONMENT}"
