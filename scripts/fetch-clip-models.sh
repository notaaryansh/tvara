#!/usr/bin/env bash
# Downloads the MobileCLIP-S2 CoreML model files + CLIP BPE tokenizer assets
# that ImageIndexService needs at runtime. These are excluded from git via
# .gitignore because weight.bin exceeds GitHub's 100MB single-file limit.
#
# Run once after cloning, or whenever a model version bumps. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/Sources/spotlight++/Resources/Models"
mkdir -p "${DEST}"

REPO="https://huggingface.co/apple/coreml-mobileclip/resolve/main"

echo "==> Fetching MobileCLIP-S2 image + text encoders into ${DEST}"

for model in mobileclip_s2_image mobileclip_s2_text; do
    if [[ -f "${DEST}/${model}.mlmodelc/coremldata.bin" ]]; then
        echo "    [skip] ${model}.mlmodelc already present"
        continue
    fi
    echo "    [get]  ${model}.mlpackage → ${model}.mlmodelc"
    mkdir -p "${DEST}/${model}.mlpackage/Data/com.apple.CoreML/weights"
    curl -sSL -o "${DEST}/${model}.mlpackage/Manifest.json" \
        "${REPO}/${model}.mlpackage/Manifest.json"
    curl -sSL -o "${DEST}/${model}.mlpackage/Data/com.apple.CoreML/model.mlmodel" \
        "${REPO}/${model}.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    curl -sSL -o "${DEST}/${model}.mlpackage/Data/com.apple.CoreML/weights/weight.bin" \
        "${REPO}/${model}.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    xcrun coremlcompiler compile "${DEST}/${model}.mlpackage" "${DEST}" >/dev/null
    rm -rf "${DEST}/${model}.mlpackage"
done

echo "==> Fetching CLIP BPE tokenizer assets"
if [[ ! -s "${DEST}/clip-vocab.json" ]]; then
    curl -sSL -o "${DEST}/clip-vocab.json" \
        "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/vocab.json"
fi
if [[ ! -s "${DEST}/clip-merges.txt" ]]; then
    curl -sSL -o "${DEST}/clip-merges.txt" \
        "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt"
fi

echo "==> Done. ${DEST}:"
ls -lh "${DEST}"
