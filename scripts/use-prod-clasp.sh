#!/usr/bin/env bash
set -euo pipefail
cp .clasp.prod.json.template .clasp.json
echo "Copied PROD clasp template to .clasp.json. Set scriptId before pushing."
