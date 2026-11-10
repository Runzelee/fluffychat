#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

project=$(cd "$(dirname "$0")/.." && pwd)
engine="$project/.voice-engine"
cache=${VOICE_ENGINE_CACHE:-"$engine/downloads"}
mkdir -p "$cache" "$engine/assets/voice_asr"

fetch() {
    local name=$1 digest=$2 url=$3
    if [[ ! -f "$cache/$name" ]]; then
        curl --fail --location --retry 4 --retry-all-errors --connect-timeout 10 \
            --output "$cache/$name.part" "$url"
        mv "$cache/$name.part" "$cache/$name"
    fi
    (cd "$cache" && printf '%s  %s\n' "$digest" "$name" | sha256sum --check)
}

runtime=sherpa-onnx-1.12.20.aar
model=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09
fetch "$runtime" e3905b1258b577d8d374db798618602ceaaff5805cbf9b356ab25267cd98144d \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.20/$runtime"
fetch "$model.tar.bz2" 7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$model.tar.bz2"
fetch onnxruntime-ThirdPartyNotices.txt 4f9e2bb7b4b407d710a68168615bbc6f70e3d7cc8ba9410fb6c65d92fa71accf \
    "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.17.1/ThirdPartyNotices.txt"

cp "$cache/$runtime" "$engine/sherpa-onnx.aar"
tar -xjf "$cache/$model.tar.bz2" --strip-components=1 -C "$engine/assets/voice_asr" \
    "$model/model.int8.onnx" "$model/tokens.txt"
cp -r "$project/scripts/voice-transcription-licenses" "$engine/assets/"
cp "$cache/onnxruntime-ThirdPartyNotices.txt" \
    "$engine/assets/voice-transcription-licenses/ONNX-Runtime-ThirdPartyNotices.txt"
