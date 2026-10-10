param(
    [string]$Group = 'qwen-edit-2511',
    [string]$GatewayUrl
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cli = Join-Path $root '.agents\skills\salad-cloud-cli\scripts\salad_cli.py'

function Probe-Http([string]$Label, [string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 8 -UseBasicParsing
        Write-Output ("{0}: HTTP {1}" -f $Label, [int]$r.StatusCode)
    } catch {
        if ($_.Exception.Response) {
            Write-Output ("{0}: HTTP {1}" -f $Label, [int]$_.Exception.Response.StatusCode)
        } else {
            Write-Output ("{0}: {1}" -f $Label, $_.Exception.Message)
        }
    }
}

Write-Output '== SaladCloud group =='
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Output 'Python is unavailable. Install/configure Python to use the repository CLI.'
} elseif (-not (Test-Path -LiteralPath $cli)) {
    Write-Output 'Repository SaladCloud CLI was not found.'
} else {
    $raw = & python $cli status $Group 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $state = ($raw | Out-String | ConvertFrom-Json)
            Write-Output ("Group: {0}; state: {1}; running instances: {2}" -f $state.name, $state.current_state.status, $state.current_state.instance_status_counts.running_count)
            Write-Output ("Pending change: {0}; autostart: {1}" -f $state.pending_change, $state.autostart_policy)
            if (-not $GatewayUrl -and $state.networking.dns) {
                $GatewayUrl = 'https://' + $state.networking.dns
            }
        } catch {
            Write-Output 'Could not parse the CLI status response.'
        }
    } else {
        Write-Output ('CLI status failed: ' + (($raw | Out-String).Trim()))
    }
}

if ($GatewayUrl) {
    try {
        $uri = [uri]$GatewayUrl
        if ($uri.Scheme -ne 'https' -or -not $uri.Host) { throw 'Use an HTTPS gateway URL.' }
        Write-Output '== Network =='
        try {
            $ips = [Net.Dns]::GetHostAddresses($uri.Host)
            Write-Output ('DNS addresses: ' + $ips.Count)
        } catch { Write-Output ('DNS failed: ' + $_.Exception.Message) }
        try {
            $tcp = New-Object Net.Sockets.TcpClient
            $pending = $tcp.BeginConnect($uri.Host, 443, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne(5000)) {
                $tcp.EndConnect($pending)
                Write-Output 'TCP 443: connected'
            } else { Write-Output 'TCP 443: timeout' }
        } catch { Write-Output ('TCP 443 failed: ' + $_.Exception.Message) }
        finally { if ($tcp) { $tcp.Close() } }
        Probe-Http 'Gateway /healthz' ($GatewayUrl.TrimEnd('/') + '/healthz')
        Probe-Http 'Gateway /' ($GatewayUrl.TrimEnd('/') + '/')
    } catch { Write-Output ('Gateway URL invalid: ' + $_.Exception.Message) }
} else {
    Write-Output 'Gateway URL unavailable. Pass -GatewayUrl https://your-host.salad.cloud'
}
Write-Output '== Interpretation =='
Write-Output 'HTTP 503: the gateway cannot serve ComfyUI; inspect container logs and local processes.'
Write-Output 'HTTP 401: Basic authentication may be enabled; verify credentials separately.'
Write-Output 'Running state alone does not prove that ComfyUI responds.'
Write-Output 'No stop, restart, download or generation was performed.'
