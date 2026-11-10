#requires -Version 5.1

function Start-AndeslogReadinessWorker([string]$Url, [int]$DurationSeconds, [int]$IntervalMs = 1000) {
    if ($DurationSeconds -lt 1 -or $DurationSeconds -gt 1860 -or $IntervalMs -lt 100) {
        throw 'Intervalo de sondeo inválido.'
    }
    return Start-Job -ArgumentList $Url, $DurationSeconds, $IntervalMs -ScriptBlock {
        param($TargetUrl, $LimitSeconds, $Interval)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName System.Net.Http
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(4)
        $overall = [Diagnostics.Stopwatch]::StartNew()
        try {
            while ($overall.Elapsed.TotalSeconds -lt $LimitSeconds) {
                $beginTick = [Diagnostics.Stopwatch]::GetTimestamp()
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $ok = $false
                $status = 0
                try {
                    $response = $client.GetAsync($TargetUrl).GetAwaiter().GetResult()
                    try {
                        $status = [int]$response.StatusCode
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if ($status -eq 200) {
                            $json = $body | ConvertFrom-Json
                            $ok = $json.status -eq 'ready' -and $json.database -eq 'ok'
                        }
                    } finally { $response.Dispose() }
                } catch { $ok = $false }
                $watch.Stop()
                [pscustomobject]@{
                    Ok = [bool]$ok; StatusCode = $status; Milliseconds = $watch.Elapsed.TotalMilliseconds
                    StartedTick = $beginTick; FinishedTick = [Diagnostics.Stopwatch]::GetTimestamp()
                }
                Start-Sleep -Milliseconds $Interval
            }
        } finally { $client.Dispose() }
    }
}

function Wait-AndeslogInitialReadiness([System.Management.Automation.Job]$Job, [int]$TimeoutSeconds = 20) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        foreach ($probe in @(Receive-Job -Job $Job -ErrorAction Stop)) {
            if (-not $probe.Ok) { throw 'El monitor independiente no observó readiness antes de la inyección.' }
            if ($Job.State -ne 'Running') { throw 'El monitor independiente terminó antes de la inyección.' }
            return
        }
        if ($Job.State -ne 'Running') { throw 'El monitor independiente no pudo iniciarse.' }
        Start-Sleep -Milliseconds 100
    }
    throw 'El monitor independiente no produjo una sonda inicial a tiempo.'
}

function Stop-AndeslogReadinessWorker([System.Management.Automation.Job]$Job) {
    if ($null -eq $Job) { return }
    if ($Job.State -eq 'Running') { Stop-Job -Job $Job }
    Remove-Job -Job $Job -Force
}
