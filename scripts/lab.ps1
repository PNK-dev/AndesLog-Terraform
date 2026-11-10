#requires -Version 5.1
<#
.SYNOPSIS
  Orquesta el laboratorio AndesLog con los estados HCP de AWS y Azure.
.EXAMPLE
  .\scripts\lab.ps1 -Action Recreate -ConfirmDataLoss
#>
param(
    [ValidateSet('Deploy', 'PreviewDestroy', 'Destroy', 'Recreate', 'Status', 'CleanupNat')]
    [string]$Action = 'Status',
    [switch]$ConfirmDataLoss,
    [string]$ExpectedHcpOrganization = 'AndesLog',
    [string]$ExpectedAwsAccount = '406197219647',
    [string]$ExpectedAzureSubscription = '75b45f81-0930-4278-8fd9-896cec6eebe1',
    [string]$AdminPublicCidr = '',
    [string]$SshPrivateKey = "$env:USERPROFILE\.ssh\id_ed25519",
    [string]$AzureUser = 'azureuser',
    [string]$AzureFilesDrLocation = 'mexicocentral',
    [string]$ErpDirectory = '',
    [string]$ErpImage = 'ghcr.io/pnk-dev/andeslog-erp:v1.2.1',
    [string]$WebInstanceProfileName = '',
    [string]$RdsExternalMasterSecretArn = '',
    [string]$RdsExternalRotationLambdaArn = '',
    [switch]$EnableAwsRegionalDr,
    [switch]$EnableBackupAudit,
    [switch]$DisableErpIntegration,
    [switch]$EnableRemoteAccess,
    [switch]$EnableFilesDrGateway,
    [ValidateSet('', 'logging', 'count', 'enforce')]
    [string]$WafPhase = '',
    [ValidateRange(0, 2000000000)]
    [int]$WafRateLimit = 0,
    [switch]$WafLogsVerified,
    [switch]$WafRulesReviewed,
    [switch]$SkipIntercloudVpn,
    [switch]$DisableInstanceRefresh,
    [switch]$ResumeUninitializedBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'regional-dr-guard.ps1')
. (Join-Path $PSScriptRoot 'rds-ephemeral.ps1')
. (Join-Path $PSScriptRoot 'runtime-consistency-guard.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repo 'environments\lab\aws'
$azureRoot = Join-Path $repo 'environments\lab\azure'
$awsOverlay = Join-Path $awsRoot '99-runtime.auto.tfvars.json'
$azureOverlay = Join-Path $azureRoot '99-runtime.auto.tfvars.json'
$secretPath = Join-Path $awsRoot 'andeslog.runtime.secret'
if (-not $ErpDirectory) {
    $erpCandidates = @(
        (Join-Path $repo 'ERP-APP'),
        (Join-Path $repo '..\ERP-APP'),
        (Join-Path $repo '..\AndesLog-ERP')
    )
    foreach ($candidate in $erpCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'Dockerfile')) {
            $ErpDirectory = [IO.Path]::GetFullPath($candidate)
            break
        }
    }
}
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = $ExpectedHcpOrganization }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = Join-Path $tempRoot ('andeslog-lab-run-' + [guid]::NewGuid().ToString('N'))
$sshConfig = Join-Path $work 'ssh_config'
$script:archive = ''
$script:ecrTag = ''
$script:currentEcrTag = ''
$script:bootstrapEnabled = $true
$script:webInstanceProfileName = $WebInstanceProfileName
$script:awsTunnelConfigJson = ''

function Say([string]$message) { Write-Host "[AndesLog] $message" }
function Need([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Falta $name en PATH." }
}
function Native([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe falló con código $LASTEXITCODE." }
}
function Capture([string]$exe, [string[]]$arguments) {
    # Native tools can write informational messages to stderr even on success.
    # In Windows PowerShell 5, Stop otherwise turns those messages into errors.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = & $exe @arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $result = (@($lines | ForEach-Object { if ($null -ne $_) { $_.ToString() } }) -join "`n")
    if ($code -ne 0) { throw "$exe falló con código $code. $result" }
    return $result.Trim()
}
function Tf([string]$root, [string[]]$arguments) {
    Push-Location $root
    try {
        $needsPassword = $root -eq $awsRoot -and $arguments.Count -gt 0 -and $arguments[0] -in @('plan', 'apply', 'destroy')
        $secretArn = ''
        if ($needsPassword) { $secretArn = [string](ReadJson $awsOverlay)['rds_external_master_secret_arn'] }
        if ($needsPassword -and $secretArn) {
            Invoke-WithAndeslogRdsPassword $secretArn { Native 'terraform' $arguments }
        } else {
            Native 'terraform' $arguments
        }
    } finally { Pop-Location }
}
function TfOutput([string]$root, [string]$name) {
    Push-Location $root
    try {
        $result = & terraform output -raw $name 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return ($result | Out-String).Trim()
    } finally { Pop-Location }
}
function TfOutputJson([string]$root, [string]$name) {
    Push-Location $root
    try {
        $raw = Capture 'terraform' @('output', '-json', $name)
        $parsed = $raw | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains 'value') { $parsed = $parsed.value }
        return (ConvertTo-Json -InputObject $parsed -Depth 20 -Compress)
    } finally { Pop-Location }
}
function SaveJson([string]$path, [object]$value) {
    [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 5), $utf8)
}
function ReadJson([string]$path) {
    if (-not (Test-Path $path)) { return @{} }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hash = @{}
    foreach ($property in $obj.PSObject.Properties) { $hash[$property.Name] = $property.Value }
    return $hash
}
$savedAwsSettings = ReadJson $awsOverlay
$script:wafPhase = if ($WafPhase) { $WafPhase } elseif ($savedAwsSettings.ContainsKey('waf_phase')) { [string]$savedAwsSettings['waf_phase'] } else { 'off' }
$script:wafRateLimit = if ($WafRateLimit) { $WafRateLimit } elseif ($savedAwsSettings.ContainsKey('waf_rate_limit')) { [int]$savedAwsSettings['waf_rate_limit'] } else { 0 }
$script:wafLogsVerified = $WafLogsVerified -or ($savedAwsSettings.ContainsKey('waf_logs_verified') -and $savedAwsSettings['waf_logs_verified'] -eq $true)
$script:wafRulesReviewed = $WafRulesReviewed -or ($savedAwsSettings.ContainsKey('waf_rules_reviewed') -and $savedAwsSettings['waf_rules_reviewed'] -eq $true)
$script:rdsExternalSecretArn = if ($RdsExternalMasterSecretArn) { $RdsExternalMasterSecretArn } elseif ($savedAwsSettings.ContainsKey('rds_external_master_secret_arn')) { [string]$savedAwsSettings['rds_external_master_secret_arn'] } else { '' }
$script:rdsRotationLambdaArn = if ($RdsExternalRotationLambdaArn) { $RdsExternalRotationLambdaArn } elseif ($savedAwsSettings.ContainsKey('rds_external_rotation_lambda_arn')) { [string]$savedAwsSettings['rds_external_rotation_lambda_arn'] } else { '' }
$script:regionalDrRequested = $EnableAwsRegionalDr -or ($savedAwsSettings.ContainsKey('enable_aws_regional_dr') -and $savedAwsSettings['enable_aws_regional_dr'] -eq $true)
$script:backupAuditRequested = $EnableBackupAudit -or ([bool](ReadJson $azureOverlay)['enable_backup_audit'])
$script:erpIntegrationRequested = -not $DisableErpIntegration
$script:erpIngestUrl = ''
$script:erpIngestSecret = ''
$script:erpIntegrationPublished = $false
$script:filesDrGatewayRequested = $EnableFilesDrGateway -or ([bool](ReadJson $azureOverlay)['enable_files_dr_gateway'])
$script:remoteAccessRequested = $EnableRemoteAccess -or $script:filesDrGatewayRequested -or ([bool](ReadJson $azureOverlay)['enable_remote_access'])
$script:intercloudVpnEnabled = -not [bool]$SkipIntercloudVpn
$script:instanceRefreshEnabled = -not [bool]$DisableInstanceRefresh
$script:backupAuditPublished = $false
$script:asgMinSize = 0
$script:asgDesiredCapacity = 0
$script:asgMaxSize = 3
function RandomSecret {
    $bytes = New-Object byte[] 36
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function SetupSsh([string]$bootstrapPublicIp) {
    $key = ([IO.Path]::GetFullPath($SshPrivateKey)).Replace('\', '/')
    $known = (Join-Path $work 'known_hosts').Replace('\', '/')
    $config = @"
Host *
  BatchMode yes
  LogLevel ERROR
Host aws-bootstrap
  HostName $bootstrapPublicIp
  User ubuntu
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
  ServerAliveInterval 15
  ServerAliveCountMax 4
"@
    [IO.File]::WriteAllText($sshConfig, $config, $utf8)
}
function RedactRemoteDiagnostic([string]$text) {
    $text = $text -replace '(?i)(postgres(?:ql)?(?:\+\w+)?://)[^@\s]+@', '$1[REDACTED]@'
    $text = $text -replace '(?i)(password|secret|token)(\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s,;]+)', '$1$2[REDACTED]'
    return $text.Trim()
}
function Remote([string]$hostName, [string]$command) {
    try {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $rawOutput = & ssh @('-F', $sshConfig, $hostName, $command) 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $output = (@($rawOutput | ForEach-Object { if ($null -ne $_) { $_.ToString() } }) -join "`n").TrimEnd()
        if ($exitCode -ne 0) {
            $diagnostic = RedactRemoteDiagnostic $output
            if (-not $diagnostic) { $diagnostic = 'sin salida del proceso remoto' }
            throw "ssh falló con código $exitCode. $diagnostic"
        }
        if ($output) { Write-Host $output }
    } catch { throw "SSH en ${hostName}: $($_.Exception.Message)" }
}
function RemoteOutput([string]$hostName, [string]$command) {
    try { return Capture 'ssh' @('-F', $sshConfig, $hostName, $command) }
    catch { throw "SSH en ${hostName}: $($_.Exception.Message)" }
}
function Upload([string]$file, [string]$hostName, [string]$remotePath) {
    Native 'scp' @('-F', $sshConfig, $file, "${hostName}:$remotePath")
}
function CheckIdentity {
    Need 'terraform'; Need 'aws'; Need 'az'
    if ($ErpImage -notmatch '^[a-z0-9][a-z0-9./_-]+:[a-zA-Z0-9_.-]+$' -or $ErpImage.EndsWith(':latest')) {
        throw 'ErpImage debe ser un tag Docker versionado (sin latest).'
    }
    if ($env:TF_CLOUD_ORGANIZATION -ne $ExpectedHcpOrganization) {
        throw "Organización HCP inesperada: $env:TF_CLOUD_ORGANIZATION. Se esperaba $ExpectedHcpOrganization."
    }
    $account = Capture 'aws' @('sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
    if ($account -ne $ExpectedAwsAccount) { throw "Cuenta AWS $account, esperada $ExpectedAwsAccount." }
    if (-not $script:webInstanceProfileName) {
        foreach ($candidate in @('LabInstanceProfile', 'LabRole')) {
            $found = & aws iam get-instance-profile --instance-profile-name $candidate --query 'InstanceProfile.InstanceProfileName' --output text --no-cli-pager 2>$null
            if ($LASTEXITCODE -eq 0 -and $found -and $found -ne 'None') {
                $script:webInstanceProfileName = "$found"
                break
            }
        }
    }
    if ($script:webInstanceProfileName) {
        Say "Usando perfil de instancia existente '$script:webInstanceProfileName'; debe permitir ECR pull y lectura del secreto ERP."
    } else {
        Say 'No se detectó un perfil académico existente; Terraform intentará crear un rol mínimo para los nodos ERP.'
    }
    $subscription = Capture 'az' @('account', 'show', '--query', 'id', '-o', 'tsv')
    if ($subscription -ne $ExpectedAzureSubscription) { throw "Suscripción Azure $subscription, esperada $ExpectedAzureSubscription." }
    if ($script:remoteAccessRequested -and $Action -in @('Deploy', 'Recreate')) {
        $region = $AzureFilesDrLocation
        if (-not $region) { $region = [string](ReadJson $azureOverlay)['azure_files_dr_location'] }
        if (-not $region) { $region = $env:TF_VAR_azure_files_dr_location }
        if (-not $region) { $region = 'mexicocentral' }
        $policyRaw = (& az policy assignment list --scope "/subscriptions/$subscription" --disable-scope-strict-match --output json 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $assignments = @($policyRaw | ConvertFrom-Json)
            foreach ($assignment in $assignments) {
                $allowed = @()
                if ($assignment.PSObject.Properties['parameters'] -and $assignment.parameters -and $assignment.parameters.PSObject.Properties['listOfAllowedLocations']) {
                    $allowed = @($assignment.parameters.listOfAllowedLocations.value)
                }
                if ($allowed.Count -gt 0 -and $allowed -notcontains $region.ToLowerInvariant()) {
                    $available = ($allowed -join ', ')
                    throw "La política Azure no permite $region para esta suscripción. Regiones permitidas: $available. Elige una con -AzureFilesDrLocation antes de aplicar."
                }
            }
        }
    }
    if ($Action -in @('Deploy', 'Recreate')) {
        if (-not (Test-Path $SshPrivateKey) -or -not (Test-Path "$SshPrivateKey.pub")) {
            throw "Falta la pareja SSH $SshPrivateKey y $SshPrivateKey.pub."
        }
        $script:publicKey = (Get-Content -LiteralPath "$SshPrivateKey.pub" -Raw).Trim()
        if ($publicKey -notmatch '^ssh-(ed25519|rsa) ') { throw 'La clave SSH pública no tiene formato esperado.' }
        if (-not $AdminPublicCidr) {
            $ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 20).Trim()
            $script:AdminPublicCidr = "$ip/32"
        }
        if ($AdminPublicCidr -notmatch '^(?:\d{1,3}\.){3}\d{1,3}/32$') { throw 'AdminPublicCidr debe ser IPv4 /32.' }
        Say "AWS $account; Azure $subscription; IP administrativa $AdminPublicCidr."
    } else {
        Say "AWS $account; Azure $subscription. No se necesita la clave SSH para $Action."
    }
}
function InitRoots {
    foreach ($root in @($azureRoot, $awsRoot)) {
        $vars = Join-Path $root 'terraform.tfvars'
        if (-not (Test-Path $vars)) { Copy-Item (Join-Path $root 'terraform.tfvars.example') $vars }
        Tf $root @('init', '-input=false')
        Tf $root @('validate', '-no-color')
    }
}
function UpdateOverlays([string[]]$azureGatewayIps, [bool]$nat, [bool]$enableAzureConnections = $false) {
    $az = ReadJson $azureOverlay
    $az['subscription_id'] = $ExpectedAzureSubscription
    $az['enable_backup_audit'] = $script:backupAuditRequested
    $az['enable_erp_integration'] = $script:erpIntegrationRequested
    $az['enable_remote_access'] = $script:remoteAccessRequested
    $az['enable_files_dr_replica'] = $script:remoteAccessRequested
    $az['enable_files_dr_gateway'] = $script:filesDrGatewayRequested
    if ($AzureFilesDrLocation) { $az['azure_files_dr_location'] = $AzureFilesDrLocation.ToLowerInvariant() }
    $az['enable_intercloud_vpn'] = $script:intercloudVpnEnabled
    $az['enable_aws_vpn_connections'] = $enableAzureConnections
    # Event Grid validates that the function endpoint already exists. Keep its
    # subscription off until DeployBackupAudit has published the function code.
    $az['enable_backup_event_subscription'] = $script:backupAuditRequested -and $script:backupAuditPublished
    SaveJson $azureOverlay $az
    $aw = ReadJson $awsOverlay
    if ($script:rdsExternalSecretArn) { $aw['rds_external_master_secret_arn'] = $script:rdsExternalSecretArn }
    if ($script:rdsRotationLambdaArn) { $aw['rds_external_rotation_lambda_arn'] = $script:rdsRotationLambdaArn }
    if ($script:regionalDrRequested) { $aw['enable_aws_regional_dr'] = $true }
    if ($script:currentEcrTag) { $aw['erp_image_tag'] = $script:currentEcrTag }
    $aw['admin_public_cidr'] = $AdminPublicCidr
    $aw['ssh_public_key'] = $publicKey
    $aw['enable_intercloud_vpn'] = $script:intercloudVpnEnabled -and (@($azureGatewayIps).Count -eq 2)
    $aw['azure_gateway_public_ips'] = @($azureGatewayIps)
    $aw['web_min_size'] = $script:asgMinSize
    $aw['web_desired_capacity'] = $script:asgDesiredCapacity
    $aw['enable_instance_refresh'] = $script:instanceRefreshEnabled
    $aw['bootstrap_instance_enabled'] = $script:bootstrapEnabled
    $aw['web_instance_profile_name'] = $script:webInstanceProfileName
    $aw['enable_erp_integration'] = $script:erpIntegrationRequested
    $aw['enable_temporary_nat'] = $nat
    $aw['rds_deletion_protection'] = $true
    $aw['waf_phase'] = $script:wafPhase
    $aw['waf_rate_limit'] = $script:wafRateLimit
    $aw['waf_logs_verified'] = [bool]$script:wafLogsVerified
    $aw['waf_rules_reviewed'] = [bool]$script:wafRulesReviewed
    SaveJson $awsOverlay $aw
}
function EnsureBackupProviders {
    if (-not $script:backupAuditRequested -and -not $script:erpIntegrationRequested) { return }
    $namespaces = @('Microsoft.Web', 'Microsoft.ManagedIdentity')
    if ($script:erpIntegrationRequested) { $namespaces += 'Microsoft.App' }
    if ($script:backupAuditRequested) { $namespaces += 'Microsoft.EventGrid' }
    foreach ($namespace in $namespaces) {
        $registration = Capture 'az' @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState', '-o', 'tsv')
        if ($registration -ne 'Registered') {
            Say "Registrando proveedor Azure $namespace para Functions e integración ERP."
            Native 'az' @('provider', 'register', '--namespace', $namespace, '--wait')
        }
    }
}
function DeployErpIntegration {
    if (-not $script:erpIntegrationRequested) { return }
    $appName = TfOutput $azureRoot 'erp_event_function_name'
    $groupName = TfOutput $azureRoot 'resource_group_name'
    $script:erpIngestUrl = TfOutput $azureRoot 'erp_event_ingest_url'
    $script:erpIngestSecret = TfOutput $azureRoot 'erp_event_hmac_secret'
    if (-not $appName -or -not $groupName -or $script:erpIngestUrl -notmatch '^https://[^/]+/api/erp/events$' -or -not $script:erpIngestSecret) {
        throw 'Azure no devolvió los datos requeridos para la Function de integración ERP.'
    }
    $source = Join-Path $repo 'functions\erp-ingest'
    $package = Join-Path $work 'erp-ingest.zip'
    $staging = Join-Path $work 'erp-ingest-stage'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $staging -Recurse -Force
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $package -Force
    Say "Publicando ERP event ingest y la réplica de Azure Files por SDK oficial en $appName."
    Native 'az' @('functionapp', 'deployment', 'source', 'config-zip', '--resource-group', $groupName, '--name', $appName, '--src', $package, '--build-remote', 'true', '--timeout', '300', '--output', 'none')
    $published = $false
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $functionName = & az functionapp function show --resource-group $groupName --name $appName --function-name ErpEventIngest --query name -o tsv 2>$null
        $eventReady = ($LASTEXITCODE -eq 0 -and $functionName)
        $syncReady = $true
        if ($script:remoteAccessRequested) {
            $syncName = & az functionapp function show --resource-group $groupName --name $appName --function-name AzureFilesDisasterRecoverySync --query name -o tsv 2>$null
            $syncReady = ($LASTEXITCODE -eq 0 -and $syncName)
        }
        if ($eventReady -and $syncReady) { $published = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $published) { throw 'No aparecieron todos los triggers requeridos en Azure después de publicar el paquete.' }
    $script:erpIntegrationPublished = $true
    Say 'Azure ERP ingest está publicado; la clave HMAC se mantiene fuera de la salida.'
}
function DeployBackupAudit {
    if (-not $script:backupAuditRequested) { return }
    $appName = TfOutput $azureRoot 'backup_audit_function_name'
    $groupName = TfOutput $azureRoot 'resource_group_name'
    if (-not $appName -or -not $groupName) { throw 'Azure no devolvió la Function o el Resource Group de BackupAudit.' }
    $source = Join-Path $repo 'functions\backup-audit'
    $package = Join-Path $work 'backup-audit.zip'
    Compress-Archive -Path (Join-Path $source '*') -DestinationPath $package -Force
    Say "Publicando BackupAudit en $appName."
    Native 'az' @('functionapp', 'deployment', 'source', 'config-zip', '--resource-group', $groupName, '--name', $appName, '--src', $package, '--build-remote', 'true', '--output', 'none')
    $published = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $functionName = & az functionapp function show --resource-group $groupName --name $appName --function-name BackupAudit --query name -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $functionName) { $published = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $published) { throw 'BackupAudit no apareció en Azure después de publicar el paquete; no se activó Event Grid.' }
    $script:backupAuditPublished = $true
    $az = ReadJson $azureOverlay
    $az['enable_backup_event_subscription'] = $true
    SaveJson $azureOverlay $az
    Say 'Activando la suscripción Event Grid para los respaldos.'
    $applyArgs = @('apply', '-input=false', '-auto-approve', '-no-color')
    $vpnVarsFile = NewAzureVpnVarsFile $script:awsTunnelConfigJson
    if ($vpnVarsFile) { $applyArgs += "-var-file=$vpnVarsFile" }
    Tf $azureRoot $applyArgs
}
function PrepareSecrets([string]$dbHost) {
    $vars = @{}
    if (Test-Path $secretPath) {
        foreach ($line in (Get-Content -LiteralPath $secretPath)) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $vars[$matches[1]] = $matches[2] }
        }
    }
    $dbPassword = RandomSecret
    if ($vars.ContainsKey('DATABASE_URL') -and $vars['DATABASE_URL'] -match '^postgresql\+psycopg://andeslog_app:([^@]+)@') {
        $dbPassword = [uri]::UnescapeDataString($matches[1])
    }
    if (-not $vars.ContainsKey('SECRET_KEY')) { $vars['SECRET_KEY'] = RandomSecret }
    if (-not $vars.ContainsKey('BOOTSTRAP_ADMIN_PASSWORD')) { $vars['BOOTSTRAP_ADMIN_PASSWORD'] = RandomSecret }
    if (-not $vars.ContainsKey('BOOTSTRAP_ADMIN_USERNAME')) { $vars['BOOTSTRAP_ADMIN_USERNAME'] = 'admin' }
    $vars['APP_ENV'] = 'development'
    if ($script:erpIntegrationRequested) {
        if (-not $script:erpIntegrationPublished -or -not $script:erpIngestUrl -or -not $script:erpIngestSecret) {
            throw 'La Function ERP de Azure no está publicada; no se guarda un secreto incompleto.'
        }
        $vars['ERP_AZURE_INGEST_URL'] = $script:erpIngestUrl
        $vars['ERP_AZURE_INGEST_HMAC_SECRET'] = $script:erpIngestSecret
        $vars['OUTBOX_POLL_SECONDS'] = '5'
    } else {
        $vars.Remove('ERP_AZURE_INGEST_URL')
        $vars.Remove('ERP_AZURE_INGEST_HMAC_SECRET')
        $vars.Remove('OUTBOX_POLL_SECONDS')
    }
    $vars['DATABASE_URL'] = "postgresql+psycopg://andeslog_app:$([uri]::EscapeDataString($dbPassword))@${dbHost}:5432/andeslog?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fcerts%2Faws-rds-global-bundle.pem"
    $secretKeys = @('APP_ENV', 'SECRET_KEY', 'DATABASE_URL', 'BOOTSTRAP_ADMIN_USERNAME', 'BOOTSTRAP_ADMIN_PASSWORD')
    if ($script:erpIntegrationRequested) { $secretKeys += @('ERP_AZURE_INGEST_URL', 'ERP_AZURE_INGEST_HMAC_SECRET', 'OUTBOX_POLL_SECONDS') }
    $lines = $secretKeys | ForEach-Object { "$_=$($vars[$_])" }
    [IO.File]::WriteAllText($secretPath, (($lines -join "`n") + "`n"), $utf8)
    return $dbPassword
}
function BuildErp {
    Need 'docker'; Need 'ssh'; Need 'scp'
    if (-not $ErpDirectory -or -not (Test-Path -LiteralPath (Join-Path $ErpDirectory 'Dockerfile'))) {
        throw 'No se encontró ERP-APP/AndesLog-ERP con Dockerfile. Clona el ERP junto a Terraform o indica -ErpDirectory.'
    }
    Native 'docker' @('info', '--format', '{{.ServerVersion}}')
    Say 'Construyendo imagen ERP linux/amd64 antes de modificar la nube.'
    Native 'docker' @('build', '--platform', 'linux/amd64', '-t', $ErpImage, $ErpDirectory)
    # BuildKit can attach a fresh provenance attestation on every build. The
    # outer image-index digest may then change even when the runnable image is
    # identical. Identify the linux/amd64 manifest to avoid needless rollouts.
    try {
        $imageId = Capture 'docker' @('image', 'inspect', '--platform', 'linux/amd64', '--format', '{{.Id}}', $ErpImage)
    } catch {
        # Older Docker Engine APIs do not support platform-specific inspect.
        # Retain the previous behavior instead of blocking those clients.
        Say 'Docker no admite inspección por plataforma; se usará el identificador general de la imagen.'
        $imageId = Capture 'docker' @('image', 'inspect', '--format', '{{.Id}}', $ErpImage)
    }
    if ($imageId -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Docker no devolvió el identificador SHA-256 esperado para la imagen ERP.' }
    $script:ecrTag = 'img-' + $imageId.Substring(7, 24)
    $script:archive = Join-Path $work 'andeslog-erp.tar'
    Native 'docker' @('save', '-o', $archive, $ErpImage)
    $script:archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
}
function PublishErpImage([string]$repositoryUrl, [string]$region) {
    if (-not $repositoryUrl -or $repositoryUrl -notmatch '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/.+$') {
        throw 'ECR devolvió una URL de repositorio inesperada.'
    }
    $registry = $repositoryUrl.Split('/')[0]
    $image = "${repositoryUrl}:$script:ecrTag"
    $repositoryName = $repositoryUrl.Substring($repositoryUrl.IndexOf('/') + 1)
    # A missing tag is normal on a first deploy; describe-images writes an
    # error to stderr for it, which PowerShell 5 treats as a terminating error.
    $imageList = (Capture 'aws' @('ecr', 'list-images', '--region', $region, '--repository-name', $repositoryName,
        '--filter', 'tagStatus=TAGGED', '--query', 'imageIds', '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
    $exists = @($imageList | Where-Object { $null -ne $_ -and $_.PSObject.Properties['imageTag'] -and $_.imageTag -ceq $script:ecrTag }).Count -gt 0
    if (-not $exists) {
        Say "Publicando la imagen ERP inmutable $script:ecrTag en ECR."
        $password = Capture 'aws' @('ecr', 'get-login-password', '--region', $region, '--no-cli-pager')
        try {
            $password | & docker login --username AWS --password-stdin $registry | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'No se pudo autenticar Docker en ECR.' }
        } finally { $password = $null }
        Native 'docker' @('tag', $ErpImage, $image)
        Native 'docker' @('push', $image)
    } else {
        Say "La misma versión de imagen $script:ecrTag ya existe en ECR; se reutiliza."
    }
    return $image
}
function AssertUninitializedBootstrap([string]$secretArn, [string]$groupName, [string]$imageTag, $overlay) {
    $message = 'No se puede reanudar el bootstrap no inicializado: verifica que el secreto no tenga versiones, el ASG esté vacío y la VM bootstrap esté habilitada.'
    if (-not $secretArn -or -not $groupName -or $imageTag -cne 'img-bootstrap' -or
        -not $overlay.ContainsKey('bootstrap_instance_enabled') -or $overlay['bootstrap_instance_enabled'] -ne $true) { throw $message }
    try {
        $secret = (Capture 'aws' @('secretsmanager', 'describe-secret', '--secret-id', $secretArn, '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
        $versionsProperty = $secret.PSObject.Properties['VersionIdsToStages']
        if ($null -ne $versionsProperty -and $null -ne $versionsProperty.Value -and @($versionsProperty.Value.PSObject.Properties).Count -gt 0) { throw 'versions exist' }
        $result = (Capture 'aws' @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', $groupName, '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
        $groups = @($result.AutoScalingGroups)
        if ($groups.Count -ne 1 -or $groups[0].AutoScalingGroupName -cne $groupName -or [int]$groups[0].MinSize -ne 0 -or
            [int]$groups[0].DesiredCapacity -ne 0 -or @($groups[0].Instances).Count -ne 0) { throw 'ASG not empty' }
    } catch { throw $message }
}
function EnsureBootstrapReady([string]$hostName) {
    $status = RemoteOutput $hostName 'cloud-init status --wait; exit 0'
    $ready = RemoteOutput $hostName 'if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker && test -f /etc/ssl/certs/aws-rds-global-bundle.pem; then echo ready; else echo incomplete; fi'
    if ($ready -eq 'ready') { return }
    if ($status -notmatch 'status:\s*error') {
        throw "Bootstrap temporal incompleto en $hostName (cloud-init: $status)."
    }
    Say "cloud-init falló en $hostName; reintentando instalar el bootstrap con NAT disponible."
    Remote $hostName 'sudo test -f /var/lib/cloud/instance/scripts/part-001 && curl --fail --silent --show-error --head --max-time 10 http://us-east-1.ec2.archive.ubuntu.com/ubuntu/dists/noble/InRelease >/dev/null && sudo bash /var/lib/cloud/instance/scripts/part-001'
    Remote $hostName 'sudo test -x /usr/bin/docker && sudo test -f /etc/ssl/certs/aws-rds-global-bundle.pem && sudo systemctl is-active --quiet docker'
}
function BootstrapRds([string]$dbEndpoint, [string]$masterSecretArn, [string]$dbPassword) {
    if ($dbEndpoint -notmatch '^[a-zA-Z0-9.-]+$') { throw 'El endpoint RDS tiene un formato inesperado.' }
    if (-not $masterSecretArn -or $masterSecretArn -notmatch '^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$') {
        throw 'RDS no devolvió el ARN del secreto maestro administrado.'
    }

    Say 'Inicializando rol de aplicación y base en PostgreSQL Multi-AZ.'
    $masterSecretJson = Capture 'aws' @('secretsmanager', 'get-secret-value', '--secret-id', $masterSecretArn, '--query', 'SecretString', '--output', 'text', '--no-cli-pager')
    $master = $masterSecretJson | ConvertFrom-Json
    if (-not $master.username -or -not $master.password) { throw 'El secreto maestro RDS no contiene username/password.' }

    $masterFile = Join-Path $work 'rds-master.json'
    $appFile = Join-Path $work 'erp-db-user.json'
    $bootstrapFile = Join-Path $repo 'scripts\bootstrap-rds.py'
    [IO.File]::WriteAllText($masterFile, $masterSecretJson, $utf8)
    [IO.File]::WriteAllText($appFile, (@{ username = 'andeslog_app'; password = $dbPassword } | ConvertTo-Json -Compress), $utf8)
    $primaryError = $null
    try {
        Upload $masterFile 'aws-bootstrap' '/home/ubuntu/.rds-master.json'
        Upload $appFile 'aws-bootstrap' '/home/ubuntu/.erp-db-user.json'
        Upload $bootstrapFile 'aws-bootstrap' '/home/ubuntu/.bootstrap-rds.py'
        Remote 'aws-bootstrap' "chmod 600 /home/ubuntu/.rds-master.json /home/ubuntu/.erp-db-user.json && sudo docker run --rm --network host -e DB_HOST=$dbEndpoint -e DB_PORT=5432 -e RDS_MASTER_SECRET_FILE=/run/secrets/rds-master.json -e ERP_DB_SECRET_FILE=/run/secrets/erp-db-user.json -v /home/ubuntu/.rds-master.json:/run/secrets/rds-master.json:ro -v /home/ubuntu/.erp-db-user.json:/run/secrets/erp-db-user.json:ro -v /home/ubuntu/.bootstrap-rds.py:/run/bootstrap-rds.py:ro -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $ErpImage python /run/bootstrap-rds.py"
    } catch {
        $primaryError = $_
        throw
    } finally {
        try {
            $cleanupSucceeded = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Remote 'aws-bootstrap' 'rm -f /home/ubuntu/.rds-master.json /home/ubuntu/.erp-db-user.json /home/ubuntu/.bootstrap-rds.py'
                    $cleanupSucceeded = $true
                    break
                } catch {
                    if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                    elseif (-not $primaryError) { throw }
                }
            }
            if (-not $cleanupSucceeded -and $primaryError) {
                Say 'No se confirmó la limpieza remota de los archivos temporales; se conserva el error original para diagnóstico.'
            }
        } finally {
            Remove-Item -LiteralPath $masterFile, $appFile -Force -ErrorAction SilentlyContinue
        }
    }
}
function PublishRuntimeSecret([string]$secretArn) {
    $runtime = @{}
    foreach ($line in (Get-Content -LiteralPath $secretPath)) {
        if ($line -match '^([A-Z_][A-Z0-9_]*)=(.*)$') { $runtime[$matches[1]] = $matches[2] }
    }
    if (-not $runtime.ContainsKey('DATABASE_URL') -or -not $runtime.ContainsKey('SECRET_KEY')) {
        throw 'El secreto local del ERP no contiene DATABASE_URL y SECRET_KEY.'
    }
    $jsonPath = Join-Path $work 'erp-runtime.json'
    [IO.File]::WriteAllText($jsonPath, ($runtime | ConvertTo-Json -Compress), $utf8)
    try {
        Say 'Publicando el secreto del ERP en AWS Secrets Manager (el valor no se imprime).'
        Native 'aws' @('secretsmanager', 'put-secret-value', '--secret-id', $secretArn, '--secret-string', "file://$jsonPath", '--no-cli-pager')
    } finally { Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue }
}
function CaptureExistingWebCapacity {
    $groupName = TfOutput $awsRoot 'web_auto_scaling_group_name'
    if (-not $groupName) {
        Push-Location $awsRoot
        try { $stateList = Capture 'terraform' @('state', 'list') } finally { Pop-Location }
        if ($stateList -match '(?m)^aws_autoscaling_group\.web$') {
            throw 'Terraform contiene el ASG web, pero no expone web_auto_scaling_group_name. No se puede preservar su capacidad con seguridad.'
        }
        return
    }
    $document = (Capture 'aws' @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', $groupName, '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
    $group = @($document.AutoScalingGroups)[0]
    if (-not $group) { return }
    $script:asgMinSize = [int]$group.MinSize
    $script:asgDesiredCapacity = [int]$group.DesiredCapacity
    $script:asgMaxSize = [Math]::Max([int]$group.MaxSize, 3)
    $script:currentEcrTag = TfOutput $awsRoot 'web_erp_image_tag'
    if (-not $script:currentEcrTag) {
        Push-Location $awsRoot
        try {
            $stateText = Capture 'terraform' @('state', 'show', '-no-color', 'aws_launch_template.web')
            $userDataMatch = [regex]::Match($stateText, '(?m)^\s*user_data\s*=\s*"(?<value>[A-Za-z0-9+/=]+)"')
            if ($userDataMatch.Success) {
                $userData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($userDataMatch.Groups['value'].Value))
                $imageMatch = [regex]::Match($userData, '(?m)^ExecStart=.*?(?<image>\d{12}\.dkr\.ecr\.[^/\s]+\.amazonaws\.com/[^:\s]+:(?<tag>[A-Za-z0-9_.-]+))\s')
                if ($imageMatch.Success) { $script:currentEcrTag = $imageMatch.Groups['tag'].Value }
            }
        } catch {
            # A missing launch template is expected before the first deployment.
        } finally { Pop-Location }
    }
    if (-not $script:currentEcrTag) {
        $existingOverlay = ReadJson $awsOverlay
        if ($existingOverlay.ContainsKey('erp_image_tag')) { $script:currentEcrTag = [string]$existingOverlay['erp_image_tag'] }
    }
    if (@($group.Instances).Count -gt 0 -and -not $script:currentEcrTag) {
        throw 'El ASG ya tiene instancias, pero no pude determinar el tag ERP actualmente desplegado. Se cancela para evitar cambiar su imagen durante una actualización.'
    }
    if ($script:currentEcrTag) { Say 'Se conserva la etiqueta ECR actualmente desplegada hasta terminar las migraciones de base de datos.' }
    Say "Se conserva la capacidad existente del ERP durante las fases previas: min=$($script:asgMinSize), desired=$($script:asgDesiredCapacity), max=$($script:asgMaxSize)."
}
function GetWebAsgSnapshot([string]$groupName, [string]$targetGroupArn) {
    $groupDocument = (Capture 'aws' @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', $groupName, '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
    $group = @($groupDocument.AutoScalingGroups)[0]
    if (-not $group) { throw "AWS no devolvió el Auto Scaling Group $groupName." }
    $targetDocument = (Capture 'aws' @('elbv2', 'describe-target-health', '--target-group-arn', $targetGroupArn, '--output', 'json', '--no-cli-pager')) | ConvertFrom-Json
    $targetStates = @{}
    foreach ($entry in @($targetDocument.TargetHealthDescriptions)) {
        $targetStates[[string]$entry.Target.Id] = [string]$entry.TargetHealth.State
    }
    $healthyTargets = @($targetStates.Values | Where-Object { $_ -eq 'healthy' }).Count
    $healthyInstances = @($group.Instances | Where-Object {
        $_.LifecycleState -eq 'InService' -and
        $_.HealthStatus -eq 'Healthy' -and
        $targetStates.ContainsKey([string]$_.InstanceId) -and
        $targetStates[[string]$_.InstanceId] -eq 'healthy'
    })
    $version = [string]$group.LaunchTemplate.Version
    $latestHealthyInstances = @($healthyInstances | Where-Object { [string]$_.LaunchTemplate.Version -eq $version })
    $zones = @($healthyInstances | Select-Object -ExpandProperty AvailabilityZone -Unique)
    return [pscustomobject]@{
        Group                = $group
        TargetStates         = $targetStates
        HealthyTargets       = $healthyTargets
        HealthyInstances     = $healthyInstances
        LatestHealthy        = $latestHealthyInstances
        HealthyZones         = $zones
        LaunchTemplateVersion = $version
    }
}
function WaitForWebFleet([string]$groupName, [string]$targetGroupArn, [int]$desired) {
    for ($attempt = 1; $attempt -le 80; $attempt++) {
        $snapshot = GetWebAsgSnapshot $groupName $targetGroupArn
        if ($snapshot.LatestHealthy.Count -ge $desired -and $snapshot.HealthyTargets -ge $desired -and $snapshot.HealthyZones.Count -ge 2) {
            Say "$($snapshot.LatestHealthy.Count) nodos de la versión actual y $($snapshot.HealthyTargets) destinos del ALB saludables en $($snapshot.HealthyZones.Count) AZ."
            return
        }
        if (($attempt % 4) -eq 0) {
            Say "Flota: $($snapshot.LatestHealthy.Count)/$desired nodos actuales saludables; ALB: $($snapshot.HealthyTargets)/$desired destinos; AZ: $($snapshot.HealthyZones.Count)/2."
        }
        Start-Sleep -Seconds 15
    }
    throw "El ASG $groupName no alcanzó $desired instancias de la versión actual, targets saludables y dos AZ en 20 minutos."
}
function RotateWebFleetWithoutInstanceRefresh([string]$groupName, [string]$targetGroupArn, [int]$minimum, [int]$desired) {
    $snapshot = GetWebAsgSnapshot $groupName $targetGroupArn
    $old = @($snapshot.Group.Instances | Where-Object {
        $_.LifecycleState -eq 'InService' -and [string]$_.LaunchTemplate.Version -ne $snapshot.LaunchTemplateVersion
    })
    if ($old.Count -eq 0) { return }
    if ([int]$snapshot.Group.MaxSize -lt ($desired + 1)) {
        throw "La actualización sin Instance Refresh necesita MaxSize >= $($desired + 1) para mantener capacidad mientras rota los nodos."
    }

    $aw = ReadJson $awsOverlay
    $aw['web_min_size'] = $minimum
    $aw['web_desired_capacity'] = $desired + 1
    SaveJson $awsOverlay $aw
    Say "AWS Academy bloquea Instance Refresh; se hará rotación gradual con capacidad temporal $($desired + 1), terminando un nodo cada vez."
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')

    for ($attempt = 1; $attempt -le 80; $attempt++) {
        $snapshot = GetWebAsgSnapshot $groupName $targetGroupArn
        $old = @($snapshot.Group.Instances | Where-Object {
            $_.LifecycleState -eq 'InService' -and [string]$_.LaunchTemplate.Version -ne $snapshot.LaunchTemplateVersion
        })
        if ($old.Count -eq 0) { break }

        $candidate = @($old | Where-Object {
            $snapshot.TargetStates.ContainsKey([string]$_.InstanceId) -and
            $snapshot.TargetStates[[string]$_.InstanceId] -eq 'unhealthy'
        } | Select-Object -First 1)
        if ($candidate.Count -eq 0 -and $snapshot.HealthyTargets -ge ($desired + 1)) {
            $candidate = @($old | Where-Object {
                $snapshot.TargetStates.ContainsKey([string]$_.InstanceId) -and
                $snapshot.TargetStates[[string]$_.InstanceId] -eq 'healthy'
            } | Select-Object -First 1)
        }

        if ($candidate.Count -gt 0 -and $snapshot.LatestHealthy.Count -ge 1) {
            $instanceId = [string]$candidate[0].InstanceId
            Say "Reemplazando gradualmente $instanceId; quedan $($old.Count) nodos con el template anterior y $($snapshot.HealthyTargets) destinos saludables."
            $null = Capture 'aws' @('autoscaling', 'terminate-instance-in-auto-scaling-group', '--instance-id', $instanceId, '--no-should-decrement-desired-capacity', '--output', 'json', '--no-cli-pager')
        } elseif (($attempt % 4) -eq 0) {
            Say "Rotación en espera: $($old.Count) nodos antiguos; $($snapshot.LatestHealthy.Count) nuevos y $($snapshot.HealthyTargets) destinos saludables."
        }
        Start-Sleep -Seconds 15
    }

    $snapshot = GetWebAsgSnapshot $groupName $targetGroupArn
    $oldRemaining = @($snapshot.Group.Instances | Where-Object {
        $_.LifecycleState -eq 'InService' -and [string]$_.LaunchTemplate.Version -ne $snapshot.LaunchTemplateVersion
    })
    if ($oldRemaining.Count -gt 0) { throw "La rotación manual dejó $($oldRemaining.Count) nodos con el template anterior; se conserva capacidad para diagnóstico." }

    # Wait until the extra replacement is itself healthy before scaling back
    # to the steady-state desired capacity. This keeps both steady-state nodes
    # serving while the ASG terminates the temporary third node.
    Say 'Validando los tres nodos actuales y saludables antes de reducir la capacidad temporal.'
    WaitForWebFleet $groupName $targetGroupArn ($desired + 1)

    $aw = ReadJson $awsOverlay
    $aw['web_min_size'] = $minimum
    $aw['web_desired_capacity'] = $desired
    SaveJson $awsOverlay $aw
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
}
function ScaleWebAsg([string]$groupName, [string]$targetGroupArn, [int]$minimum, [int]$desired) {
    if (-not $groupName) { throw 'No se recibió el nombre del Auto Scaling Group.' }
    if (-not $targetGroupArn) { throw 'No se recibió el Target Group ARN para validar la salud del ERP.' }
    if ($minimum -lt 2 -or $desired -lt $minimum) { throw 'El servicio ERP requiere al menos dos nodos y desired_capacity no puede ser menor que min_size.' }
    $script:asgMinSize = $minimum
    $script:asgDesiredCapacity = $desired
    $aw = ReadJson $awsOverlay
    $aw['web_min_size'] = $minimum
    $aw['web_desired_capacity'] = $desired
    $script:asgMaxSize = [Math]::Max($script:asgMaxSize, $desired + 1)
    $aw['web_max_size'] = $script:asgMaxSize
    if ($script:ecrTag) { $aw['erp_image_tag'] = $script:ecrTag }
    SaveJson $awsOverlay $aw
    Say 'Terraform aplica la versión nueva y conserva la capacidad mínima multi-AZ del ERP.'
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    if ($desired -gt 0) {
        if (-not $script:instanceRefreshEnabled) { RotateWebFleetWithoutInstanceRefresh $groupName $targetGroupArn $minimum $desired }
        WaitForWebFleet $groupName $targetGroupArn $desired
        # Later Terraform overlay updates (for example removing the temporary
        # bootstrap host) must retain the image that was just validated.
        if ($script:ecrTag) { $script:currentEcrTag = $script:ecrTag }
    }
}
function StopWebAsg([string]$groupName) {
    if (-not $groupName) { return }
    $groups = & aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $groupName --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text --no-cli-pager 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo inspeccionar el ASG antes de la baja.' }
    if (-not $groups -or $groups -eq 'None') { return }
    $script:asgMinSize = 0
    $script:asgDesiredCapacity = 0
    $aw = ReadJson $awsOverlay
    $aw['web_min_size'] = 0
    $aw['web_desired_capacity'] = 0
    SaveJson $awsOverlay $aw
    # Directly scale down this specific group. A full Terraform apply here can
    # recreate unrelated resources when a different clone lacks its overlay.
    Native 'aws' @('autoscaling', 'update-auto-scaling-group', '--auto-scaling-group-name', $groupName,
                   '--min-size', '0', '--desired-capacity', '0', '--no-cli-pager')
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $count = & aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $groupName --query 'length(AutoScalingGroups[0].Instances)' --output text --no-cli-pager 2>$null
        if ($LASTEXITCODE -eq 0 -and "$count" -eq '0') { return }
        Start-Sleep -Seconds 15
    }
    throw "El ASG $groupName no terminó de vaciarse; se detiene antes de continuar."
}
function InstallErp([string]$dbPassword, [string]$dbEndpoint, [string]$masterSecretArn, [string]$runtimeSecretArn) {
    Say 'Inicializando PostgreSQL y el usuario administrador mediante la VM bootstrap temporal.'
    if ($dbPassword -match '[\r\n\x00]') { throw 'La contraseña PostgreSQL existente contiene un salto de línea o NUL.' }
    EnsureBootstrapReady 'aws-bootstrap'
    Upload $archive 'aws-bootstrap' '/home/ubuntu/andeslog-erp.tar'
    $actual = RemoteOutput 'aws-bootstrap' 'sha256sum /home/ubuntu/andeslog-erp.tar'
    if (-not $actual.StartsWith($archiveHash)) { throw 'El hash de la imagen ERP no coincide en la VM bootstrap.' }
    Remote 'aws-bootstrap' 'sudo docker load -i /home/ubuntu/andeslog-erp.tar && rm -f /home/ubuntu/andeslog-erp.tar'
    Upload $secretPath 'aws-bootstrap' '/home/ubuntu/.andeslog-erp.env'
    Remote 'aws-bootstrap' 'chmod 600 /home/ubuntu/.andeslog-erp.env && sudo install -d -o root -g root -m 0750 /etc/andeslog-app && sudo install -o root -g root -m 0600 /home/ubuntu/.andeslog-erp.env /etc/andeslog-app/erp.env && rm -f /home/ubuntu/.andeslog-erp.env'
    BootstrapRds $dbEndpoint $masterSecretArn $dbPassword
    Remote 'aws-bootstrap' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $ErpImage flask --app app:create_app db upgrade"
    Remote 'aws-bootstrap' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $ErpImage flask --app app:create_app seed-admin"
    PublishRuntimeSecret $runtimeSecretArn
}
function TestErpAzureFlow([string]$image) {
    if (-not $script:erpIntegrationRequested) { return }
    Say 'Generando un evento de prueba en RDS y verificando su almacenamiento idempotente en Azure Blob.'
    $eventId = RemoteOutput 'aws-bootstrap' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $image flask --app app:create_app outbox-smoke"
    if ($eventId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        throw 'El ERP no devolvió un identificador válido para el evento de prueba.'
    }
    $status = ''
    for ($attempt = 1; $attempt -le 36; $attempt++) {
        # Restrict each attempt to the synthetic event; temporary Azure RBAC
        # propagation can cause a retryable failure during fresh deployment.
        Remote 'aws-bootstrap' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $image python -m app.outbox_worker --once --event-id $eventId"
        $status = RemoteOutput 'aws-bootstrap' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env -v /etc/ssl/certs/aws-rds-global-bundle.pem:/etc/ssl/certs/aws-rds-global-bundle.pem:ro $image flask --app app:create_app outbox-status --event-id $eventId"
        if ($status -eq 'delivered') { break }
        if ($status -notin @('pending', 'processing')) { break }
        Start-Sleep -Seconds 5
    }
    if ($status -ne 'delivered') { throw "El evento de prueba $eventId no llegó a Azure; estado final: $status." }
    Say "Flujo ERP -> outbox PostgreSQL -> HTTPS/HMAC -> Azure Function -> Blob ZRS verificado ($eventId)."
}
function ReadVpnTunnelConfigJson {
    Push-Location $awsRoot
    try {
        $raw = & terraform output -json vpn_tunnel_configs 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        $parsed = ($raw | Out-String) | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains 'value') { $parsed = $parsed.value }
        $items = @($parsed)
        if ($items.Count -ne 4) { return '' }
        return (ConvertTo-Json -InputObject $items -Depth 10 -Compress)
    } catch { return '' } finally { Pop-Location }
}
function ReadAzureGatewayIps {
    Push-Location $azureRoot
    try {
        $raw = & terraform output -json vpn_gateway_public_ips 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $parsed = ($raw | Out-String) | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains 'value') { $parsed = $parsed.value }
        return @($parsed)
    } catch { return @() } finally { Pop-Location }
}
function NewAzureVpnVarsFile([string]$tunnelConfigJson) {
    if (-not $tunnelConfigJson) { return '' }
    $path = Join-Path $work 'azure-vpn-tunnels.auto.tfvars.json'
    $document = '{"enable_aws_vpn_connections":true,"aws_vpn_tunnel_configs":' + $tunnelConfigJson + '}'
    [IO.File]::WriteAllText($path, $document, $utf8)
    return $path
}
function DownloadVpnClientProfile([string]$GatewayOutput = 'vpn_gateway_name', [string]$FileName = 'andeslog-azure-vpn-client.zip') {
    if (-not $script:remoteAccessRequested) { return }
    $resourceGroup = TfOutput $azureRoot 'resource_group_name'
    $gatewayName = TfOutput $azureRoot $GatewayOutput
    if (-not $resourceGroup -or -not $gatewayName) { throw 'Azure no devolvió el gateway necesario para el perfil VPN P2S.' }
    $raw = & az network vnet-gateway vpn-client generate --resource-group $resourceGroup --name $gatewayName --processor-architecture Amd64 --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure no pudo generar el perfil de cliente P2S; revisa el estado del gateway y vuelve a ejecutar Deploy.' }
    try { $result = ($raw | Out-String) | ConvertFrom-Json } catch { throw 'Azure devolvió un perfil P2S en formato inesperado.' }
    # Azure CLI versions may serialize the SAS URL as a JSON string, while
    # others return an object with vpnProfileSASUrl. Support both shapes and
    # never print the SAS URL because it grants temporary profile access.
    if ($result -is [string]) {
        $url = $result
    } elseif ($result -is [System.Collections.IDictionary]) {
        $url = $result['vpnProfileSASUrl']
    } else {
        $urlProperty = $result.PSObject.Properties | Where-Object Name -EQ 'vpnProfileSASUrl' | Select-Object -First 1
        if ($urlProperty) { $url = $urlProperty.Value }
    }
    if (-not $url -or $url -notmatch '^https://') { throw 'Azure no devolvió el enlace de descarga del perfil P2S.' }
    $profileDirectory = Join-Path $repo '.lab-runtime\vpn'
    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    $zip = Join-Path $profileDirectory $FileName
    try { Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 90 -UseBasicParsing | Out-Null }
    catch { throw 'No se pudo descargar el perfil Azure VPN Client. Revisa conectividad y reintenta Deploy.' }
    Say "Perfil P2S guardado en $zip. Impórtalo en Azure VPN Client e inicia sesión con Microsoft Entra ID."
}
function Deploy {
    $existingCheckpoint = TfOutput $azureRoot 'files_dr_checkpoint_enabled'
    $existingEventArchiveDr = TfOutput $azureRoot 'erp_event_archive_replication_enabled'
    $existingIngressDr = TfOutput $azureRoot 'erp_failover_ingest_enabled'
    $existingFilesDrGateway = TfOutput $azureRoot 'files_dr_gateway_name'
    $azureGuardOverlay = ReadJson $azureOverlay
    if ($EnableFilesDrGateway) { $azureGuardOverlay['enable_files_dr_gateway'] = $true }
    if (-not $existingFilesDrGateway) {
        Push-Location $azureRoot
        try { $azureState = Capture 'terraform' @('state', 'list') } finally { Pop-Location }
        if (@($azureState -split "`r?`n") -contains 'azurerm_virtual_network_gateway.files_dr[0]') {
            throw 'El gateway regional consta en el estado Azure pero no se pudo leer su nombre; se detiene Deploy antes de modificar recursos.'
        }
    }
    Assert-AndeslogFilesDrGateway $existingFilesDrGateway $azureGuardOverlay
    Assert-AndeslogFilesCheckpoint $existingCheckpoint $azureGuardOverlay
    Assert-AndeslogEventArchiveReplication $existingEventArchiveDr $azureGuardOverlay
    Assert-AndeslogIngressDrNotAutomated $existingIngressDr $azureGuardOverlay
    # A fresh clone must never silently disable already managed regional DR.
    # Preserve it only when the local overlay explicitly retains both the DR
    # flag and the same external master-secret ARN recorded in the state.
    $existingDrEnabled = TfOutput $awsRoot 'aws_regional_dr_enabled'
    $existingDrRepository = TfOutput $awsRoot 'dr_erp_repository_url'
    $existingDrCompute = TfOutput $awsRoot 'dr_erp_compute_enabled'
    $existingDrAlbDns = TfOutput $awsRoot 'dr_erp_alb_dns_name'
    $existingDrCertificate = TfOutput $awsRoot 'dr_erp_certificate_arn'
    $existingDrSecretReplication = TfOutput $awsRoot 'dr_erp_runtime_secret_replication_enabled'
    $existingDrRuntimeSecret = TfOutput $awsRoot 'dr_erp_runtime_secret_arn'
    $existingBackupReplication = TfOutput $awsRoot 'rds_backup_replication_enabled'
    $existingReplicatedBackupArn = TfOutput $awsRoot 'rds_replicated_backup_arn'
    $existingDrProbeNetwork = TfOutput $awsRoot 'dr_probe_network_enabled'
    $existingDrProbeGroup = TfOutput $awsRoot 'dr_probe_security_group_id'
    $existingMasterSecret = TfOutput $awsRoot 'db_master_secret_arn'
    $existingRotationLambda = TfOutput $awsRoot 'rds_external_rotation_lambda_arn'
    $existingExternalSecret = TfOutput $awsRoot 'rds_external_master_secret_arn'
    $existingWafPhase = TfOutput $awsRoot 'web_waf_phase'
    $existingWafRate = TfOutput $awsRoot 'web_waf_rate_limit'
    $guardOverlay = ReadJson $awsOverlay
    if ($EnableAwsRegionalDr) { $guardOverlay['enable_aws_regional_dr'] = $true }
    if ($RdsExternalMasterSecretArn) { $guardOverlay['rds_external_master_secret_arn'] = $RdsExternalMasterSecretArn }
    if ($RdsExternalRotationLambdaArn) { $guardOverlay['rds_external_rotation_lambda_arn'] = $RdsExternalRotationLambdaArn }
    Assert-AndeslogRegionalState $existingDrEnabled $existingDrRepository $guardOverlay $existingMasterSecret $existingRotationLambda
    Assert-AndeslogRegionalRuntimeReplication $existingDrSecretReplication $existingDrRuntimeSecret $guardOverlay
    Assert-AndeslogRegionalProbeNetwork $existingDrProbeNetwork $existingDrProbeGroup $guardOverlay
    Assert-AndeslogRegionalCompute $existingDrCompute $existingDrAlbDns $existingDrCertificate $guardOverlay
    Assert-AndeslogRegionalExperimentNotAutomated $guardOverlay
    Assert-AndeslogBackupReplicationNotAutomated $existingBackupReplication $existingReplicatedBackupArn $guardOverlay
    Assert-AndeslogExternalCredentials $existingExternalSecret $existingRotationLambda $script:rdsExternalSecretArn $script:rdsRotationLambdaArn
    if ($script:rdsExternalSecretArn -and $existingMasterSecret -and $script:rdsExternalSecretArn -cne $existingMasterSecret) {
        throw 'No se permite cambiar el secreto maestro de una base existente con Deploy; prepara y verifica una migración específica.'
    }
    $existingDbEndpoint = TfOutput $awsRoot 'db_endpoint'
    Push-Location $awsRoot
    try { $existingAwsState = Capture 'terraform' @('state', 'list') } finally { Pop-Location }
    Assert-AndeslogWaf $existingWafPhase $existingWafRate $existingAwsState $script:wafPhase $script:wafRateLimit ([bool]$script:wafLogsVerified) ([bool]$script:wafRulesReviewed)
    Assert-AndeslogNoManagedRegionalBackup $existingAwsState 'Deploy'
    if (-not $existingDbEndpoint -and @($existingAwsState -split "`r?`n") -contains 'aws_db_instance.main') {
        throw 'La base consta en el estado Terraform, pero no se pudo leer su endpoint; se detiene Deploy antes de modificar recursos.'
    }
    if ($existingDbEndpoint) {
        $existingRuntimeArn = TfOutput $awsRoot 'web_runtime_secret_arn'
        if ($ResumeUninitializedBootstrap) {
            AssertUninitializedBootstrap $existingRuntimeArn (TfOutput $awsRoot 'web_auto_scaling_group_name') (TfOutput $awsRoot 'web_erp_image_tag') $guardOverlay
            Say 'Reanudando un bootstrap inicial sin versión de secreto y sin instancias web.'
        } else {
            $existingRuntime = $null
            try {
                $existingRuntime = Get-AndeslogRuntimeSecretString $existingRuntimeArn
                if (-not (Test-Path -LiteralPath $secretPath)) {
                    Restore-AndeslogRuntimeSecret $secretPath $existingRuntime
                    Say 'Se recuperó el secreto ERP existente en un archivo local privado; no se muestra su contenido.'
                }
                Assert-AndeslogRuntimeConsistency $secretPath $existingRuntime
            } finally { $existingRuntime = $null }
        }
    }
    if (-not $script:archive) { BuildErp }
    CaptureExistingWebCapacity
    EnsureBackupProviders
    $azureGatewayIps = @(ReadAzureGatewayIps)
    $vpnConfigJson = ReadVpnTunnelConfigJson
    $script:awsTunnelConfigJson = $vpnConfigJson
    $azureHasConnections = ($script:intercloudVpnEnabled -and @($azureGatewayIps).Count -eq 2 -and $vpnConfigJson)
    UpdateOverlays $azureGatewayIps $true ([bool]$azureHasConnections)
    $azureVpnVarsFile = NewAzureVpnVarsFile $vpnConfigJson
    Say 'Fase 1/7: gateway Azure activo-activo y servicios corporativos.'
    $azureApplyArgs = @('apply', '-input=false', '-auto-approve', '-no-color')
    if ($azureVpnVarsFile) { $azureApplyArgs += "-var-file=$azureVpnVarsFile" }
    Tf $azureRoot $azureApplyArgs
    DeployErpIntegration
    DeployBackupAudit
    $azureGatewayIps = @(ReadAzureGatewayIps)
    if ($script:intercloudVpnEnabled -and (@($azureGatewayIps).Count -ne 2 -or @($azureGatewayIps | Where-Object { $_ -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$' }).Count -gt 0)) {
        throw 'Azure no devolvió dos IP públicas válidas para el gateway activo-activo.'
    }

    Say 'Fase 2/8: AWS con RDS Multi-AZ, ASG, NAT por zona y enlace Site-to-Site si la política académica lo permite.'
    UpdateOverlays $azureGatewayIps $true $false
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    $dbEndpoint = TfOutput $awsRoot 'db_endpoint'
    $dbMasterSecretArn = TfOutput $awsRoot 'db_master_secret_arn'
    $bootstrapPublicIp = TfOutput $awsRoot 'bootstrap_public_ip'
    $bootstrapPrivateIp = TfOutput $awsRoot 'bootstrap_private_ip'
    $ecrRepositoryUrl = TfOutput $awsRoot 'web_ecr_repository_url'
    $runtimeSecretArn = TfOutput $awsRoot 'web_runtime_secret_arn'
    $awsRegion = TfOutput $awsRoot 'aws_region'
    $asgName = TfOutput $awsRoot 'web_auto_scaling_group_name'
    $targetGroup = TfOutput $awsRoot 'web_target_group_arn'
    if (-not $dbEndpoint -or -not $dbMasterSecretArn -or -not $bootstrapPublicIp -or -not $bootstrapPrivateIp -or -not $ecrRepositoryUrl -or -not $runtimeSecretArn -or -not $asgName -or -not $targetGroup) {
        throw 'AWS no devolvió todos los datos necesarios para RDS, ECR, secreto, bootstrap, ASG y Target Group.'
    }

    if ($script:intercloudVpnEnabled) {
        $vpnConfigJson = ReadVpnTunnelConfigJson
        if (-not $vpnConfigJson) { throw 'AWS no devolvió la configuración sensible de sus cuatro túneles VPN.' }
        $script:awsTunnelConfigJson = $vpnConfigJson
        UpdateOverlays $azureGatewayIps $true $true
        $azureVpnVarsFile = NewAzureVpnVarsFile $vpnConfigJson
        Say 'Fase 3/7: estableciendo las cuatro conexiones IPsec en Azure sin imprimir las claves compartidas.'
        $azureApplyArgs = @('apply', '-input=false', '-auto-approve', '-no-color', "-var-file=$azureVpnVarsFile")
        Tf $azureRoot $azureApplyArgs
    } else {
        Say 'Fase 3/7 omitida: no se crea el enlace AWS-Azure Site-to-Site; Azure P2S y Azure Files siguen disponibles.'
    }

    SetupSsh $bootstrapPublicIp
    Say 'Fase 4/7: comprobando la VM bootstrap temporal por SSH restringido a tu IP /32.'
    Remote 'aws-bootstrap' 'cloud-init status --wait'
    Say 'Fase 5/7: publicando la imagen privada y preparando ERP/PostgreSQL.'
    $null = PublishErpImage $ecrRepositoryUrl $awsRegion
    $regionalDrEnabled = TfOutput $awsRoot 'aws_regional_dr_enabled'
    $regionalEcrUrl = TfOutput $awsRoot 'dr_erp_repository_url'
    if ($regionalDrEnabled -notin @('true', 'false')) { throw 'No se pudo confirmar el estado de la recuperación regional AWS.' }
    if ($regionalDrEnabled -eq 'false' -and $regionalEcrUrl) { throw 'El registro regional no coincide con el estado DR deshabilitado.' }
    if ($regionalDrEnabled -eq 'true') {
        if (-not $regionalEcrUrl) { throw 'La recuperación regional está habilitada pero no tiene registro ECR de destino.' }
        Say 'Publicando y verificando la misma imagen ERP en la región de recuperación.'
        Native 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mirror-erp-image.ps1'), '-RegionalDrEnabled', 'true', '-SourceRepositoryUrl', $ecrRepositoryUrl, '-DestinationRepositoryUrl', $regionalEcrUrl, '-ImageTag', $script:ecrTag, '-ExpectedAccount', $ExpectedAwsAccount)
    }
    $dbPassword = PrepareSecrets $dbEndpoint
    InstallErp $dbPassword $dbEndpoint $dbMasterSecretArn $runtimeSecretArn
    TestErpAzureFlow $ErpImage
    ScaleWebAsg $asgName $targetGroup 2 2
    $alb = TfOutput $awsRoot 'alb_dns_name'
    if (-not $alb) { throw 'AWS no devolvió alb_dns_name.' }
    $ready = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri "http://$alb/api/health/ready" -TimeoutSec 10
            if ($health.status -ne 'ready' -or $health.database -ne 'ok') { throw 'El readiness no confirma PostgreSQL.' }
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ready) { throw "El ALB aún no confirma ERP y PostgreSQL listos en http://$alb/api/health/ready." }

    $script:bootstrapEnabled = $false
    $azureConnectionsEnabled = [bool]($script:intercloudVpnEnabled -and @($azureGatewayIps).Count -eq 2 -and $script:awsTunnelConfigJson)
    UpdateOverlays $azureGatewayIps $true $azureConnectionsEnabled
    Say 'Fase 6/7: eliminando la VM bootstrap temporal; el ASG, RDS y gateways permanecen multi-AZ.'
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    DownloadVpnClientProfile
    if ($script:filesDrGatewayRequested) {
        DownloadVpnClientProfile 'files_dr_gateway_name' 'andeslog-azure-files-dr-vpn-client.zip'
    }
    foreach ($root in @($awsRoot, $azureRoot)) {
        Push-Location $root
        try {
            $planArgs = @('plan', '-input=false', '-detailed-exitcode', '-no-color')
            if ($root -eq $azureRoot -and $azureVpnVarsFile) { $planArgs += "-var-file=$azureVpnVarsFile" }
            $script:finalPlanExitCode = -1
            $runFinalPlan = { & terraform @planArgs; $script:finalPlanExitCode = $LASTEXITCODE }
            if ($root -eq $awsRoot -and $script:rdsExternalSecretArn) {
                Invoke-WithAndeslogRdsPassword $script:rdsExternalSecretArn $runFinalPlan
            } else { & $runFinalPlan }
            if ($script:finalPlanExitCode -ne 0) { throw "Quedan diferencias o errores en el plan de $root (código $script:finalPlanExitCode)." }
        } finally { Pop-Location }
    }
    Say 'Fase 7/7: verificación final completa.'
    Say "ERP: http://$alb/ (ASG mínimo 2 nodos en AZ distintas, RDS PostgreSQL Multi-AZ)."
    if ($script:intercloudVpnEnabled) {
        Say 'VPN intercloud: BGP dinámico en dos conexiones AWS y cuatro túneles IPsec; gateway Azure activo-activo.'
    } else {
        Say 'VPN intercloud AWS-Azure: no desplegada por -SkipIntercloudVpn; no hay conectividad privada entre nubes.'
    }
    if ($script:remoteAccessRequested) { Say 'VPN usuarios: Azure VPN Client con Microsoft Entra ID; archivos SMB usan su autenticación separada.' }
    Say "Credenciales iniciales ERP: archivo local $secretPath (nunca se imprime su contenido)."
}
function GetRdsForDestroy([string]$identifier) {
    $raw = Capture 'aws' @('rds', 'describe-db-instances', '--query',
        'DBInstances[*].{id:DBInstanceIdentifier,status:DBInstanceStatus,protection:DeletionProtection}',
        '--output', 'json', '--no-cli-pager')
    $instances = @($raw | ConvertFrom-Json | Where-Object { $null -ne $_ -and $_.id -ceq $identifier })
    if ($instances.Count -gt 1) { throw 'AWS devolvió más de una base con el mismo identificador; se detiene la baja.' }
    if ($instances.Count -eq 0) { return $null }
    if ($instances[0].status -isnot [string] -or -not $instances[0].status -or $instances[0].protection -isnot [bool]) {
        throw 'AWS devolvió un estado RDS incompleto; se detiene la baja.'
    }
    return $instances[0]
}
function DestroyLab {
    Push-Location $awsRoot
    try { $backupState = Capture 'terraform' @('state', 'list') } finally { Pop-Location }
    Assert-AndeslogNoManagedRegionalBackup $backupState 'Destroy'
    $asgName = TfOutput $awsRoot 'web_auto_scaling_group_name'
    StopWebAsg $asgName
    $aw = ReadJson $awsOverlay
    $aw['rds_deletion_protection'] = $false
    $aw['dr_ecr_force_delete'] = $true
    SaveJson $awsOverlay $aw
    $dbIdentifier = TfOutput $awsRoot 'db_instance_identifier'
    if (-not $dbIdentifier -and @($backupState -split "`r?`n") -contains 'aws_db_instance.main') {
        throw 'RDS consta en el estado pero no se pudo confirmar su identificador; se detiene la baja.'
    }
    if ($dbIdentifier) {
        if ($dbIdentifier -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,62}$') { throw 'Identificador RDS inesperado; se detiene la baja.' }
        $db = GetRdsForDestroy $dbIdentifier
        if ($db -and $db.status -eq 'deleting') {
            Say 'RDS ya estaba eliminándose; se espera su finalización antes de continuar.'
            for ($attempt = 1; $attempt -le 60 -and $db; $attempt++) {
                Start-Sleep -Seconds 15
                $db = GetRdsForDestroy $dbIdentifier
                if ($db -and $db.status -ne 'deleting') { throw 'RDS dejó de estar en eliminación; revisa su estado antes de continuar.' }
            }
            if ($db) { throw 'RDS sigue eliminándose; reintenta la baja cuando termine.' }
        }
        if (-not $db) {
            Say 'RDS ya no existe en AWS; Terraform reconciliará el estado durante la baja.'
        } elseif ($db.protection -eq $true) {
            Say 'Desactivando protección contra borrado únicamente en la instancia RDS del estado.'
            Native 'aws' @('rds', 'modify-db-instance', '--db-instance-identifier', $dbIdentifier,
                           '--no-deletion-protection', '--no-apply-immediately', '--query', 'DBInstance.DBInstanceIdentifier', '--output', 'text', '--no-cli-pager')
            $unprotected = $false
            for ($attempt = 1; $attempt -le 60; $attempt++) {
                $db = GetRdsForDestroy $dbIdentifier
                if (-not $db) { throw 'RDS desapareció durante la verificación de protección; revisa su estado.' }
                if ($db.protection -eq $false) { $unprotected = $true; break }
                Start-Sleep -Seconds 5
            }
            if (-not $unprotected) { throw 'RDS todavía tiene protección de borrado; vuelve a comprobar antes de reintentar.' }
        }
    }
    Say 'Destruyendo primero AWS: ASG, NAT, Site-to-Site VPN y PostgreSQL Multi-AZ.'
    Tf $awsRoot @('destroy', '-input=false', '-auto-approve', '-no-color')

    $az = ReadJson $azureOverlay
    $az['subscription_id'] = $ExpectedAzureSubscription
    $az['enable_aws_vpn_connections'] = $false
    SaveJson $azureOverlay $az
    # Do not infer data ownership from a missing machine-local overlay. A fresh
    # clone can have the same remote state with either Azure Files resource.
    # Preserve the share first, both account variants, then the group itself.
    Push-Location $azureRoot
    try {
        $stateList = @(& terraform state list 2>$null | ForEach-Object { $_.Trim() })
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo inspeccionar el estado Azure; se detiene la baja para proteger Azure Files.' }
        foreach ($address in @('azurerm_storage_share.corporate[0]', 'azurerm_storage_account.shared_files[0]',
                                'azurerm_storage_account.shared_files_existing[0]', 'azurerm_resource_group.main')) {
            if ($stateList -contains $address) {
                Say "Conservando $address fuera del estado antes de destruir recursos temporales."
                Native 'terraform' @('state', 'rm', '-lock-timeout=5m', $address)
            }
        }
    } finally { Pop-Location }
    Say 'Destruyendo el gateway regional de recuperación, la copia Azure Files, DNS privado, endpoints, Blob y Function. El share primario existente se conserva.'
    Tf $azureRoot @('destroy', '-input=false', '-auto-approve', '-no-color')
    Remove-Item -LiteralPath $awsOverlay, $azureOverlay -ErrorAction SilentlyContinue
    Say 'Azure Files primario y su Resource Group se conservaron fuera de Terraform; revisa también que el grupo no contenga otros recursos facturables.'
    Say 'Estados cloud destruidos. El secreto local de acceso ERP se conserva para un despliegue posterior.'
}

try {
    if (($Action -eq 'Destroy' -or $Action -eq 'Recreate') -and -not $ConfirmDataLoss) {
        throw 'Destroy/Recreate borra PostgreSQL, Azure Blob y la copia regional de Azure Files. Repite con -ConfirmDataLoss.'
    }
    if (($script:rdsExternalSecretArn -and -not $script:rdsRotationLambdaArn) -or ($script:rdsRotationLambdaArn -and -not $script:rdsExternalSecretArn)) {
        throw 'Para credenciales maestras externas se requieren ambos ARN: secreto y Lambda de rotación.'
    }
    if ($script:regionalDrRequested -and -not $script:rdsExternalSecretArn) {
        throw 'La recuperación regional requiere un secreto maestro externo y una Lambda de rotación verificada.'
    }
    if ($Action -eq 'Recreate' -and $script:rdsExternalSecretArn) {
        throw 'Recreate con secreto maestro externo no está habilitado hasta probar la actualización de host y la rotación; usa un procedimiento de recuperación validado.'
    }
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    CheckIdentity
    InitRoots
    switch ($Action) {
        'Status' {
            Say "Azure VPN Gateway: $(TfOutput $azureRoot 'vpn_gateway_id')"
            Say "AWS VPN Gateway: $(TfOutput $awsRoot 'vpn_gateway_id')"
            Say "AWS VPN connections: $(TfOutput $awsRoot 'vpn_connection_ids')"
            Say "BackupAudit: $(TfOutput $azureRoot 'backup_audit_function_name')"
            $filesAccount = TfOutput $azureRoot 'files_storage_account_name'
            if ($filesAccount) { Say "Azure Files: $filesAccount" }
            else { Say 'Azure Files no está disponible en los outputs; la cuenta conservada puede seguir existiendo en Azure.' }
            $albName = TfOutput $awsRoot 'alb_dns_name'
            if ($albName) { Say "ERP: http://$albName/" }
            else { Say 'La dirección del ERP no está disponible en los outputs Terraform.' }
        }
        'Deploy' { Deploy }
        'PreviewDestroy' {
            Tf $awsRoot @('plan', '-destroy', '-input=false', '-no-color')
            Tf $azureRoot @('plan', '-destroy', '-input=false', '-no-color')
        }
        'Destroy' { DestroyLab }
        'Recreate' {
            BuildErp
            DestroyLab
            Deploy
        }
        'CleanupNat' {
            if (-not (Test-Path $awsOverlay)) { throw 'Falta el overlay AWS; ejecuta primero Deploy.' }
            $asgName = TfOutput $awsRoot 'web_auto_scaling_group_name'
            if ($asgName) {
                $desired = & aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --query 'AutoScalingGroups[0].DesiredCapacity' --output text --no-cli-pager 2>$null
                $instances = & aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --query 'length(AutoScalingGroups[0].Instances)' --output text --no-cli-pager 2>$null
                if ($LASTEXITCODE -eq 0 -and (($desired -as [int]) -gt 0 -or ($instances -as [int]) -gt 0)) {
                    throw 'No se retiran los NAT mientras el ASG ERP tiene capacidad: los nodos privados los necesitan para descargar imágenes y autorreemplazarse.'
                }
            }
            if (TfOutput $awsRoot 'bootstrap_private_ip') {
                throw 'Existe una VM bootstrap activa. Usa Destroy -ConfirmDataLoss para retirarla junto con su NAT.'
            }
            $aw = ReadJson $awsOverlay
            $aw['enable_temporary_nat'] = $false
            SaveJson $awsOverlay $aw
            Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
            Say 'NAT redundantes retirados porque no hay nodos ERP ni VM bootstrap activos; el auto-reemplazo no funcionará hasta reactivarlos.'
        }
    }
} catch {
    $reason = $_.Exception.Message
    if (-not $reason) { $reason = "error $($_.Exception.GetType().Name) en línea $($_.InvocationInfo.ScriptLineNumber)" }
    Write-Error "Se detuvo en la fase actual: $reason. Se conservaron los recursos creados para diagnóstico o reanudación; usa Status y verifica el gasto antes de dejar el laboratorio activo."
    exit 1
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $safeRoot = $tempRoot
    if ($resolved.StartsWith(($safeRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'andeslog-lab-run-*' -and (Test-Path $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
