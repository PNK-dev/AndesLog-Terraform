#requires -Version 5.1

function Add-AndeslogProbe([hashtable]$Metrics, [bool]$Ok, [double]$Milliseconds) {
    $Metrics.Samples.Add($Milliseconds)
    if (-not $Ok) { $Metrics.Failures = [int]$Metrics.Failures + 1 }
}

function Test-AndeslogWebRecovery([object[]]$Fleet, [string[]]$HealthyTargetIds, [string]$Victim, [string[]]$OriginalIds) {
    $ready = @($Fleet | Where-Object {
        $_.LifecycleState -eq 'InService' -and $_.HealthStatus -eq 'Healthy' -and
        $_.InstanceId -in $HealthyTargetIds
    })
    $zones = @($ready | Select-Object -ExpandProperty AvailabilityZone -Unique)
    $replacement = @($ready | Where-Object { $_.InstanceId -notin $OriginalIds })
    $victimStillPresent = @($Fleet | Where-Object { $_.InstanceId -eq $Victim }).Count -gt 0
    return $ready.Count -ge 2 -and $zones.Count -ge 2 -and $replacement.Count -ge 1 -and -not $victimStillPresent
}

function Test-AndeslogDatabaseRecovery([object]$Database, [string]$OriginalZone) {
    return $Database.Status -eq 'available' -and [bool]$Database.MultiAZ -and
        [bool]$OriginalZone -and [bool]$Database.AZ -and $Database.AZ -ne $OriginalZone
}
