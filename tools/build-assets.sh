#!/bin/zsh

set -x

SCRIPT_DIR="${0:A:h}"

mkdir -p "$SCRIPT_DIR/../build/tools"
mkdir -p "$SCRIPT_DIR/../build/assets"

clang -o "$SCRIPT_DIR/../build/tools/png2c" "$SCRIPT_DIR/png2c.c" -lm

"$SCRIPT_DIR/../build/tools/png2c" \
    -n mindrot_ent \
    -o "$SCRIPT_DIR/../build/assets/mindrot_ent.c" \
    "$SCRIPT_DIR/../assets/mindrot_ent.png"
