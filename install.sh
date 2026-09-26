#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for installer in "$root"/*/install.sh; do
    "$installer"
done
