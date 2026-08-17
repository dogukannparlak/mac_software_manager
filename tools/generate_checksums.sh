#!/bin/zsh
#
# Regenerates SHA256SUMS for the files clients download at runtime.
#
# Self-update refuses to install any script whose hash is not listed here, so
# this MUST be re-run (and the result committed) whenever one of those scripts
# changes - otherwise every installation stops updating itself.
#
# Usage: ./tools/generate_checksums.sh [--check]
#   --check  verify the committed SHA256SUMS is in sync, without rewriting it

set -e
set -o pipefail

REPO_ROOT="${0:a:h:h}"
cd "$REPO_ROOT"

# Files fetched by setup_mac.sh and by the plugin's self-update
typeset -a DISTRIBUTED_FILES
DISTRIBUTED_FILES=(
    setup_mac.sh
    uninstall.sh
    update_system.1h.sh
)

for file in "${DISTRIBUTED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "❌ Missing distributed file: $file"
        exit 1
    fi
done

if [[ "$1" == "--check" ]]; then
    if [[ ! -f SHA256SUMS ]]; then
        echo "❌ SHA256SUMS is missing. Run ./tools/generate_checksums.sh"
        exit 1
    fi

    if diff -u SHA256SUMS <(shasum -a 256 "${DISTRIBUTED_FILES[@]}") > /dev/null; then
        echo "✅ SHA256SUMS is up to date."
        exit 0
    fi

    echo "❌ SHA256SUMS is out of date. Run ./tools/generate_checksums.sh and commit the result."
    diff -u SHA256SUMS <(shasum -a 256 "${DISTRIBUTED_FILES[@]}") || true
    exit 1
fi

shasum -a 256 "${DISTRIBUTED_FILES[@]}" > SHA256SUMS
echo "✅ SHA256SUMS written:"
cat SHA256SUMS
