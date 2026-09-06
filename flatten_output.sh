#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/qwen_batch/output"
DEST_NAME="$(date '+%Y_%m%d_%H%M')"
DEST="$ROOT/$DEST_NAME"
FLATTENED_DIR_PATTERN='[0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9]'

if [ ! -d "$ROOT" ]; then
    echo "ERROR: output directory not found: $ROOT" >&2
    exit 1
fi

# 同じ分に再実行して既存フォルダへ混ぜる事故を防止
if [ -e "$DEST" ]; then
    echo "ERROR: destination already exists: $DEST" >&2
    echo "1分待つか、既存フォルダを確認してください。" >&2
    exit 1
fi

mkdir "$DEST"

COUNT=0

while IFS= read -r -d '' file; do
    rel="${file#$ROOT/}"
    session="${rel%%/*}"
    basename="$(basename "$file")"

    target="$DEST/${session}__${basename}"

    # 万一 session + basename まで一致した場合も衝突回避
    if [ -e "$target" ]; then
        stem="${basename%.*}"
        ext="${basename##*.}"
        n=2

        while [ -e "$DEST/${session}__${stem}_${n}.${ext}" ]; do
            n=$((n + 1))
        done

        target="$DEST/${session}__${stem}_${n}.${ext}"
    fi

    mv -- "$file" "$target"
    COUNT=$((COUNT + 1))

done < <(
    while IFS= read -r -d '' source_dir; do
        find "$source_dir" \
            -type f \
            -iname '*.png' \
            -print0
    done < <(
        find "$ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            ! -name "$FLATTENED_DIR_PATTERN" \
            -print0
    )
)

# 空になった旧セッションフォルダだけ削除
find "$ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    ! -name "$FLATTENED_DIR_PATTERN" \
    -empty \
    -delete

echo "============================================================"
echo " FLATTEN COMPLETE"
echo "============================================================"
echo "Images : $COUNT"
echo "Output : $DEST"
echo "============================================================"
