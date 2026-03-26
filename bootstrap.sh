#!/usr/bin/env bash
set -euo pipefail

# 1. สร้าง/activate venv
python -m venv .venv
# shellcheck disable=SC1091
. .venv/bin/activate

# 2. อัปเดต pip ภายใน venv และติดตั้ง Python deps ตามล็อก
pip install --upgrade pip setuptools wheel
pip install -r requirements.txt

# 3. ติดตั้ง npm deps ตาม package-lock.json (reproducible)
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi

echo "Bootstrap complete. Activate venv with: . .venv/bin/activate"
