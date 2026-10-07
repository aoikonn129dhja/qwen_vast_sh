#!/usr/bin/env bash
# Source this library; URLs and credentials are never printed.
sha256_matches() {
    [ -s "$1" ] && [ "$(sha256sum -- "$1" | awk '{print $1}')" = "$2" ]
}
_download_verified() {
    local url="$1" destination="$2" expected="$3" resume="$4"
    local partial="${destination}.part"
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { echo 'ERROR: Invalid SHA-256.' >&2; return 2; }
    if sha256_matches "$destination" "$expected"; then return 0; fi
    mkdir -p -- "$(dirname -- "$destination")" || return
    local args=(-q --https-only --tries=3 --timeout=60)
    if [ "$resume" = 1 ]; then args+=(-c); else rm -f -- "$partial" || return; fi
    wget "${args[@]}" -O "$partial" "$url" || { echo 'ERROR: Download failed.' >&2; return 1; }
    if ! sha256_matches "$partial" "$expected"; then
        rm -f -- "$partial"
        echo 'ERROR: SHA-256 mismatch.' >&2
        return 1
    fi
    mv -f -- "$partial" "$destination"
}
download_verified() { _download_verified "$1" "$2" "$3" 0; }
download_resume_verified() { _download_verified "$1" "$2" "$3" 1; }
