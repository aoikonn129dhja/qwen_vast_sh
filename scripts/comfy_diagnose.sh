#!/usr/bin/env bash
# ComfyUI connectivity diagnostics for Vast.ai and SaladCloud.
# Read-only. No file uploads, downloads, model loading, generation, or restarts.
# All HTTP requests go ONLY to loopback addresses and never include credentials.

set -u
export LC_ALL=C

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_LOG="${COMFY_LOG:-$WORKSPACE/comfyui.log}"
PID_FILE="${COMFY_PID_FILE:-$WORKSPACE/comfyui.pid}"
READY_FILE="${SALAD_READY_FILE:-$WORKSPACE/.salad-setup-ready}"
COMFY_PORT="${COMFY_PORT:-8188}"
AUTH_PORT="${AUTH_PORT:-8190}"
GATEWAY_PORT="${GATEWAY_PORT:-8189}"

case "${1:-}" in
  -h|--help)
    cat <<'HELP'
使い方: bash comfy_diagnose.sh
環境変数: WORKSPACE, COMFY_DIR, PYTHON, COMFY_LOG,
          COMFY_PID_FILE, SALAD_READY_FILE, COMFY_PORT, AUTH_PORT, GATEWAY_PORT
このスクリプトは読み取り専用です。ログ本文・環境変数の値・画像・プロンプトは表示しません。
HTTPアクセス先は127.0.0.1と::1のみです。外部との通信は行いません。
HELP
    exit 0 ;;
  '') ;;
  *) printf '不明な引数です。--help を参照してください。\n' >&2; exit 2 ;;
esac

for v in COMFY_PORT AUTH_PORT GATEWAY_PORT; do
  port="${!v}"
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    printf '無効なポート設定: %s\n' "$v" >&2
    exit 2
  fi
  printf -v "$v" '%d' "$((10#$port))"
done

section() { printf '\n==== %s ====\n' "$1"; }
item() { printf '  %-27s %s\n' "$1" "$2"; }
exists() { [[ -e "$1" ]]; }

http_status() {
  if ! command -v curl >/dev/null 2>&1; then printf 'SKIP'; return; fi
  local code
  code="$(curl --noproxy '*' --silent --output /dev/null \
    --write-out '%{http_code}' --connect-timeout 2 --max-time 5 "$1" 2>/dev/null)" || {
    printf '000'; return
  }
  printf '%s' "${code:-000}"
}

# No process command lines, environments, headers, or cookies are printed.
process_exists() {
  # Compare the executable type before checking arguments, avoiding pgrep -f
  # false positives from interactive shell command lines containing these words.
  local type="$1" path comm needle
  case "$type" in
    comfy) needle='main.py' ;;
    proxy) needle='/opt/salad/auth_proxy.py' ;;
    socat) needle='TCP6-LISTEN:' ;;
    *) return 1 ;;
  esac
  for path in /proc/[0-9]*; do
    [[ -r "$path/comm" && -r "$path/cmdline" ]] || continue
    IFS= read -r comm < "$path/comm" || continue
    case "$type:$comm" in
      comfy:python*|proxy:python*|socat:socat) ;;
      *) continue ;;
    esac
    if tr '\0' '\n' < "$path/cmdline" 2>/dev/null | grep -Fq -- "$needle"; then
      return 0
    fi
  done
  return 1
}

# /proc fallback is important because the Salad image does not install ss.
listener_summary() {
  local p="$1" addresses="" raw proto addr hex
  if command -v ss >/dev/null 2>&1; then
    addresses="$(ss -ltnH 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" { print $4 }' || true)"
    if [[ -n "$addresses" ]]; then
      while IFS= read -r addr; do
        case "$addr" in
          127.0.0.1:*) printf 'IPv4-loopback ' ;;
          0.0.0.0:*)   printf 'IPv4-all ' ;;
          \[::1\]:*)    printf 'IPv6-loopback ' ;;
          \[::\]:*)     printf 'IPv6-all ' ;;
          *)          printf 'other-bind ' ;;
        esac
      done <<< "$addresses"
      return
    fi
  fi
  hex="$(printf '%04X' "$p")"
  for proto in tcp tcp6; do
    [[ -r "/proc/net/$proto" ]] || continue
    while IFS= read -r raw; do
      case "$proto:$raw" in
        tcp:0100007F) printf 'IPv4-loopback ' ;;
        tcp:00000000) printf 'IPv4-all ' ;;
        tcp6:00000000000000000000000001000000) printf 'IPv6-loopback ' ;;
        tcp6:00000000000000000000000000000000) printf 'IPv6-all ' ;;
        *) printf 'other-bind ' ;;
      esac
    done < <(awk -v h="$hex" 'NR>1 && $4=="0A" { split($2,a,":"); if (toupper(a[2])==h) print a[1] }' "/proc/net/$proto")
  done
}

log_check() {
  local file="$1" label="$2" n pattern count hits=0
  [[ -f "$file" && -r "$file" ]] || { item "$label" 'なし／読み取り不可'; return; }
  if command -v stat >/dev/null 2>&1; then
    item "$label" "存在（更新: $(stat -c '%y' -- "$file" 2>/dev/null | cut -d. -f1)）"
  else
    item "$label" '存在'
  fi
  # Print only fixed error categories and counts from the last 300 lines.
  # NEVER output the actual lines, which might contain prompts, URLs or tokens.
  while IFS='|' read -r label_pattern pattern; do
    count="$(tail -n 300 -- "$file" 2>/dev/null | grep -Eic -- "$pattern" || true)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      printf '    %-27s %s件（末尾300行）\n' "$label_pattern" "$count"
      hits=$((hits+1))
    fi
  done <<'PATTERNS'
CUDA OOM|CUDA out of memory|torch\.OutOfMemoryError|CUDNN_STATUS_ALLOC_FAILED
GPU / CUDAエラー|CUDA error|device-side assert|no kernel image is available
モジュール読込エラー|ModuleNotFoundError|ImportError|Failed to import
Python例外|Traceback \(most recent call last\)
ポート競合|Address already in use|Errno 98
ディスク容量不足|No space left on device|Errno 28
メモリ不足疑い|Out of memory: Killed process|MemoryError
権限エラー|Permission denied|Errno 13
接続エラー|Connection refused|Cannot connect to host
PATTERNS
  (( hits > 0 )) || printf '    定義済みのエラーパターンなし（末尾300行）\n'
}

printf '=========================================================\n'
printf ' ComfyUI 接続診断（Vast.ai / SaladCloud）\n'
printf '=========================================================\n'
printf '実行日時: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unknown')"
printf '安全性: 読み取り専用、HTTPはloopbackのみ、ログ本文／認証情報は非表示\n'

section '1. 環境'
if [[ -f /opt/salad/start.sh && -f /opt/salad/auth_proxy.py ]]; then
  PLATFORM='salad'
  item '構成判定' 'SaladCloud共通イメージ（/opt/saladあり）'
else
  PLATFORM='vast'
  item '構成判定' 'Vast.ai等（Salad専用起動ファイルなし）'
fi
item 'ComfyUI配置' "$([[ -f "$COMFY_DIR/main.py" ]] && printf 'OK' || printf 'main.pyなし')"
item 'Python実行ファイル' "$([[ -x "$PYTHON" ]] && printf 'OK' || printf 'なし／実行不可')"
if [[ -x "$PYTHON" ]]; then
  py_version="$("$PYTHON" --version 2>&1 || true)"
  [[ "$py_version" =~ ^Python[[:space:]]+[0-9] ]] && item 'Python版' "$py_version"
fi
if [[ -f "$COMFY_DIR/main.py" ]] && command -v git >/dev/null 2>&1; then
  revision="$(git -C "$COMFY_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  [[ "$revision" =~ ^[a-fA-F0-9]{7,40}$ ]] && item 'ComfyUI commit' "$revision"
fi

section '2. プロセス・PID'
if [[ -r "$PID_FILE" ]]; then
  IFS= read -r pid < "$PID_FILE" || true
  if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      state="$(sed -n 's/^.*) \([A-Za-z]\) .*/\1/p' "/proc/$pid/stat" 2>/dev/null || true)"
      if [[ "$state" == Z || "$state" == X ]]; then
        item 'comfyui.pid' "PID $pid はゾンビ／終了状態"
      else
        item 'comfyui.pid' "PID $pid は存在（ComfyUI本人かは未確定）"
      fi
    else
      item 'comfyui.pid' "古いPID（$pid は存在しない／アクセス不可）"
    fi
  else
    item 'comfyui.pid' '内容がPIDとして無効'
  fi
else
  item 'comfyui.pid' 'なし／読み取り不可'
fi
if process_exists comfy; then
  item 'main.pyプロセス' '検出'
else
  item 'main.pyプロセス' '未検出（起動方法によっては検出不可）'
fi
if [[ "$PLATFORM" == salad ]]; then
  if process_exists proxy; then
    item 'Salad認証proxy' 'プロセス検出'
  else
    item 'Salad認証proxy' 'プロセス未検出'
  fi
  if process_exists socat; then
    item 'Salad socat' 'プロセス検出'
  else
    item 'Salad socat' 'プロセス未検出'
  fi
fi

section '3. ポート待受'
for row in "ComfyUI:$COMFY_PORT" "Auth proxy:$AUTH_PORT" "Gateway:$GATEWAY_PORT"; do
  [[ "$PLATFORM" == salad || "$row" == ComfyUI:* ]] || continue
  label="${row%%:*}"; port="${row##*:}"
  binds="$(listener_summary "$port")"
  item "$label ($port)" "${binds:-LISTENなし}"
done
if [[ "$PLATFORM" == salad ]]; then
  printf '  注記: 正常なSalad構成は8188/8190がIPv4-loopback、8189がIPv6-all。\n'
fi

section '4. ローカルHTTP確認（認証情報なし）'
COMFY_API="$(http_status "http://127.0.0.1:$COMFY_PORT/system_stats")"
COMFY_ROOT="$(http_status "http://127.0.0.1:$COMFY_PORT/")"
item "ComfyUI API ($COMFY_PORT)" "HTTP $COMFY_API"
item "ComfyUI画面 ($COMFY_PORT)" "HTTP $COMFY_ROOT"
if [[ "$PLATFORM" == salad ]]; then
  PROXY_HEALTH="$(http_status "http://127.0.0.1:$AUTH_PORT/healthz")"
  PROXY_AUTH="$(http_status "http://127.0.0.1:$AUTH_PORT/")"
  GW_HEALTH="$(http_status "http://[::1]:$GATEWAY_PORT/healthz")"
  item "Auth /healthz ($AUTH_PORT)" "HTTP $PROXY_HEALTH"
  item "Auth / ($AUTH_PORT)" "HTTP $PROXY_AUTH （正常なら401）"
  item "Gateway /healthz ($GATEWAY_PORT)" "HTTP $GW_HEALTH （IPv6 loopback）"
fi
printf '  HTTP 000 = 接続不可／タイムアウト、SKIP = curl未導入。\n'

if [[ "$PLATFORM" == salad ]]; then
  section '5. Saladセットアップ状態'
  item 'readyファイル' "$([[ -s "$READY_FILE" ]] && printf '存在' || printf 'なし／空')"
  item 'setup-lock' "$([[ -d "$WORKSPACE/.salad-setup-lock" ]] && printf '存在（実行中か残骸かは未確定）' || printf 'なし')"
  if [[ -n "${COMFY_GATEWAY_USER:-}" ]]; then
    item 'Gatewayユーザー' '環境変数あり（値は非表示）'
  else
    item 'Gatewayユーザー' 'このシェルでは未設定'
  fi
  password_value="${COMFY_GATEWAY_PASSWORD:-}"
  if (( ${#password_value} >= 20 )); then
    item 'Gatewayパスワード' '長さ20文字以上（値は非表示）'
  else
    item 'Gatewayパスワード' 'このシェルでは未設定／20文字未満'
  fi
  printf '  注記: 現在のシェルの環境変数は既存プロセスの設定と異なる場合があります。\n'
fi

section '6. GPU・メモリ・ディスク'
if command -v nvidia-smi >/dev/null 2>&1; then
  if gpu_line="$(nvidia-smi --query-gpu=index,name,temperature.gpu,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)"; then
    printf '  GPU (index, name, temp C, VRAM used/total MiB, util %%):\n'
    printf '%s\n' "$gpu_line" | sed 's/^/    /'
  else
    item 'GPU' 'nvidia-smi がGPU情報を取得できない'
  fi
else
  item 'GPU' 'nvidia-smi なし'
fi
if command -v free >/dev/null 2>&1; then
  free -h 2>/dev/null | sed -n '1,3p' | sed 's/^/  /'
fi
if command -v df >/dev/null 2>&1; then
  disk_path="$WORKSPACE"
  [[ -d "$disk_path" ]] || disk_path=/
  printf '  ディスク使用状況:\n'
  df -h -- "$disk_path" 2>/dev/null | sed 's/^/    /'
  printf '  inode使用状況:\n'
  df -i -- "$disk_path" 2>/dev/null | sed 's/^/    /'
fi
if [[ -r /sys/fs/cgroup/memory.events ]]; then
  oom_kill="$(awk '$1=="oom_kill" {print $2}' /sys/fs/cgroup/memory.events)"
  [[ "$oom_kill" =~ ^[0-9]+$ ]] && item 'cgroup OOM kill累計' "$oom_kill （ComfyUI由来かは未確定）"
fi

section '7. ログ分類（内容は表示しない）'
log_check "$COMFY_LOG" 'ComfyUIログ'
if [[ "$PLATFORM" == salad ]]; then
  log_check "$WORKSPACE/salad-setup.log" 'Salad setupログ'
fi

section '8. 初期診断'
if [[ "$COMFY_API" == SKIP ]]; then
  printf '  [不明] curlがないためHTTP疎通の判定はできません。\n'
elif [[ "$COMFY_API" != 200 ]]; then
  printf '  [問題] ComfyUIの内部APIが正常に応答していません（HTTP %s）。\n' "$COMFY_API"
  if [[ -f "$COMFY_DIR/main.py" ]]; then
    printf '  → PID、ポート待受、起動ログのエラー分類、GPUとディスクを確認。\n'
  else
    printf '  → ComfyUIのセットアップが未完了か、配置先が異なります。\n'
  fi
  if [[ "$PLATFORM" == salad ]]; then
    printf '  → 先に8188の応答を回復させる必要があります。\n'
  fi
elif [[ "$COMFY_ROOT" != 200 ]]; then
  printf '  [問題] APIは応答しますが、画面URLはHTTP %sです。\n' "$COMFY_ROOT"
  printf '  → ComfyUIのフロントエンド配置・HTTPルーティングを確認。\n'
elif [[ "$PLATFORM" == salad ]]; then
  if [[ "$PROXY_HEALTH" != 200 ]]; then
    printf '  [問題] ComfyUIは動作していますがSalad認証proxyの/healthzがHTTP %sです。\n' "$PROXY_HEALTH"
    printf '  → auth_proxy.py、start.shのプロセスとGateway認証設定を確認。\n'
  elif [[ "$PROXY_AUTH" != 401 ]]; then
    printf '  [注意] proxyの未認証アクセスがHTTP %sです（期待値401）。\n' "$PROXY_AUTH"
    printf '  → 認証proxy設定・ポートの割当を確認。\n'
  elif [[ "$GW_HEALTH" != 200 ]]; then
    printf '  [問題] proxyは動作していますがGateway内部ポートはHTTP %sです。\n' "$GW_HEALTH"
    printf '  → socat、IPv6待受、8189ポートの設定を確認。\n'
  else
    printf '  [内部正常] ComfyUI→認証proxy→Gateway内部ポートのHTTP疎通は成功。\n'
    printf '  → 外部から開けない場合はSalad Container GatewayのHTTPS/8189設定、\n'
    printf '    レプリカ状態、公開URL、ブラウザ側の認証を確認。\n'
  fi
else
  printf '  [内部正常] ComfyUIのAPI・画面URLは127.0.0.1で応答。\n'
  printf '  → 外部から開けない場合はVast.aiのTunnels（8188）、\n'
  printf '    インスタンスの状態、公開URL、ブラウザ側を確認。\n'
fi
printf '  ※ この診断だけでは外部Gateway/Tunnelの到達性を検証できません。\n'

section '9. 補足'
printf '  生ログを手元で確認するコマンド（内容は共有前に検閲してください）:\n'
printf '    tail -n 100 %q\n' "$COMFY_LOG"
printf '  このスクリプトは機密情報を外部送信しません。\n'
