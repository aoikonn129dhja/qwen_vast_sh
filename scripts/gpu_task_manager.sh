#!/usr/bin/env bash
set -u

bar() {
  awk -v value="$1" -v width=40 'BEGIN {
    if (value < 0) value = 0; if (value > 100) value = 100;
    n = int(value * width / 100 + 0.5);
    for (i = 0; i < width; i++) printf (i < n ? "#" : "-");
  }'
}

value() {
  case "$1" in ""|"[Not Supported]"|"[N/A]"|"N/A") printf 'N/A';; *) printf '%s' "$1";; esac
}

number() {
  awk -v v="$1" 'BEGIN { if (v ~ /^[0-9]+([.][0-9]+)?$/) print v; else print 0 }'
}

snapshot() {
  local row gpu used total temp power memutil clock memclock limit enc dec rx tx reason
  row=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n 1) || true
  if [[ -z $row ]]; then
    printf 'nvidia-smi could not read GPU data.\n'
    return 1
  fi
  IFS=',' read -r gpu used total temp power <<< "$row"
  row=$(nvidia-smi --query-gpu=utilization.memory,clocks.current.graphics,clocks.current.memory,power.limit --format=csv,noheader,nounits 2>/dev/null | head -n 1) || true
  IFS=',' read -r memutil clock memclock limit <<< "$row"
  row=$(nvidia-smi --query-gpu=utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null | head -n 1) || true
  IFS=',' read -r enc dec <<< "$row"
  row=$(nvidia-smi --query-gpu=pcie.rx_util,pcie.tx_util --format=csv,noheader,nounits 2>/dev/null | head -n 1) || true
  IFS=',' read -r rx tx <<< "$row"
  row=$(nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader,nounits 2>/dev/null | head -n 1) || true
  reason=$row
  gpu=$(value "${gpu// /}"); used=$(value "${used// /}"); total=$(value "${total// /}")
  temp=$(value "${temp// /}"); power=$(value "${power// /}")
  printf 'GPU   %5s%% [%s]\n' "$gpu" "$(bar "$(number "$gpu")")"
  local vram=0
  vram=$(awk -v u="$(number "$used")" -v t="$(number "$total")" 'BEGIN {if (t > 0) printf "%.1f", u/t*100; else print 0}')
  printf 'VRAM  %5s%% [%s] ' "$vram" "$(bar "$vram")"
  awk -v u="$(number "$used")" -v t="$(number "$total")" 'BEGIN {printf "%.1f / %.1f GiB\n", u/1024, t/1024}'
  printf 'TEMP  %5s C [%s]\n' "$temp" "$(bar "$(number "$temp")")"
  printf 'POWER %s W / %s W limit\n' "$(value "${power// /}")" "$(value "${limit// /}")"
  printf '\nGPU DETAIL\n'
  printf 'Memory activity: %s%%   Core clock: %s MHz   Memory clock: %s MHz\n' \
    "$(value "${memutil// /}")" "$(value "${clock// /}")" "$(value "${memclock// /}")"
  printf 'PCIe RX/TX: %s / %s KiB/s   Encoder/Decoder: %s%% / %s%%\n' \
    "$(value "${rx// /}")" "$(value "${tx// /}")" "$(value "${enc// /}")" "$(value "${dec// /}")"
  printf 'Clock limit reason: %s\n' "$(value "${reason# }")"
  local history_file="${TMPDIR:-/tmp}/gpu_task_manager_history_${UID}"
  local history=''
  if [[ -r $history_file ]]; then history=$(<"$history_file"); fi
  history="$history $(number "$gpu")"
  history=$(printf '%s\n' "$history" | awk '{start=NF-59; if(start<1) start=1; for(i=start;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}')
  printf '%s\n' "$history" > "$history_file"
  printf 'GPU history (~last 60 s): '
  awk -v samples="$history" 'BEGIN {n=split(samples,a," "); chars=" .:-=+*#%@"; for(i=1;i<=n;i++){k=int(a[i]/10)+1; if(k>10)k=10; printf "%s",substr(chars,k,1)} print ""}'
  printf '\nGPU PROCESSES (PID, name, VRAM MiB)\n'
  nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null | head -n 10 || true
  printf '\nSYSTEM\n'
  awk '/^cpu / {idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle}' /proc/stat | {
    read -r cpu_total cpu_idle
    local state_file="${TMPDIR:-/tmp}/gpu_task_manager_cpu_${UID}"
    if [[ -r $state_file ]]; then
      read -r prev_total prev_idle < "$state_file"
      awk -v dt="$((cpu_total-prev_total))" -v di="$((cpu_idle-prev_idle))" 'BEGIN {if(dt>0) printf "CPU: %.1f%%   ", (dt-di)/dt*100; else printf "CPU: N/A   "}'
    else
      printf 'CPU: N/A   '
    fi
    printf '%s %s\n' "$cpu_total" "$cpu_idle" > "$state_file"
  }
  free -h | awk '/^Mem:/ {printf "RAM: %s / %s\n", $3, $2}'
  df -h /workspace 2>/dev/null | awk 'NR==2 {printf "Disk /workspace: %s / %s (%s)\n", $3, $2, $5}'
}

if [[ ${1:-} == --once ]]; then
  snapshot
else
  watch -n 1 -t "bash '$0' --once"
fi
