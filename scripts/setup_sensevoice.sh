#!/bin/bash
# Installs the SenseVoice engine for Typ: a Python venv with sherpa-onnx, plus the model.
set -euo pipefail
DIR="$HOME/Library/Application Support/Typ/sensevoice"
MODEL_NAME=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
mkdir -p "$DIR"

if [ ! -x "$DIR/venv/bin/python" ]; then
    python3 -m venv "$DIR/venv"
fi
"$DIR/venv/bin/pip" install -q --disable-pip-version-check sherpa-onnx numpy

if [ ! -f "$DIR/model/model.onnx" ]; then
    TMP=$(mktemp -d)
    curl -L --fail -o "$TMP/m.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2"
    tar xjf "$TMP/m.tar.bz2" -C "$TMP"
    mkdir -p "$DIR/model"
    mv "$TMP/$MODEL_NAME/model.onnx" "$TMP/$MODEL_NAME/tokens.txt" "$DIR/model/"
    rm -rf "$TMP"
fi
echo "SenseVoice installed in $DIR"
