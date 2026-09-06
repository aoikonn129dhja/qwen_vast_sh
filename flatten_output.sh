#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/workspace/qwen_batch/output"
DEST_NAME="$(date '+%Y_%m%d_%H%M')"
DEST="$ROOT/$DEST_NAME"

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
    # DEST自身は対象外
    case "$file" in
        "$DEST"/*)
            continue
            ;;
    esac

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
    find "$ROOT" \
        -mindepth 2 \
        -type f \
        -iname '*.png' \
        -print0
)

# 空になった旧セッションフォルダだけ削除
find "$ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    ! -path "$DEST" \
    -empty \
    -delete

echo "============================================================"
echo " FLATTEN COMPLETE"
echo "============================================================"
echo "Images : $COUNT"
echo "Output : $DEST"
echo "============================================================"
