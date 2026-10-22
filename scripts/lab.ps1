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
    [string]$ErpDirectory = '',
    [string]$ErpImage = 'ghcr.io/pnk-dev/andeslog-erp:v1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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

function Say([string]$message) { Write-Host "[AndesLog] $message" }
function Need([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Falta $name en PATH." }
}
function Native([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe falló con código $LASTEXITCODE." }
}
function Capture([string]$exe, [string[]]$arguments) {
    $result = & $exe @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$exe falló: $result" }
    return $result.Trim()
}
function Tf([string]$root, [string[]]$arguments) {
    Push-Location $root
    try { Native 'terraform' $arguments } finally { Pop-Location }
}
function TfOutput([string]$root, [string]$name) {
    Push-Location $root
    try {
        $result = & terraform output -raw $name 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return ($result | Out-String).Trim()
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
function RandomSecret {
    $bytes = New-Object byte[] 36
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function SetupSsh([string]$azureIp, [string]$awsIp) {
    $key = ([IO.Path]::GetFullPath($SshPrivateKey)).Replace('\', '/')
    $known = (Join-Path $work 'known_hosts').Replace('\', '/')
    $config = @"
Host *
  BatchMode yes
  LogLevel ERROR
Host azure-vpn
  HostName $azureIp
  User $AzureUser
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
Host aws-vpn
  HostName $awsIp
  User ubuntu
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
Host aws-db
  HostName 10.10.21.10
  User ubuntu
  ProxyJump aws-vpn
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
Host aws-web-a
  HostName 10.10.11.10
  User ubuntu
  ProxyJump aws-vpn
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
Host aws-web-b
  HostName 10.10.12.10
  User ubuntu
  ProxyJump aws-vpn
  IdentityFile `"$key`"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile `"$known`"
  ConnectTimeout 20
"@
    [IO.File]::WriteAllText($sshConfig, $config, $utf8)
}
function Remote([string]$hostName, [string]$command) {
    try { Native 'ssh' @('-F', $sshConfig, $hostName, $command) }
    catch { throw "SSH en ${hostName}: $($_.Exception.Message)" }
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
    $subscription = Capture 'az' @('account', 'show', '--query', 'id', '-o', 'tsv')
    if ($subscription -ne $ExpectedAzureSubscription) { throw "Suscripción Azure $subscription, esperada $ExpectedAzureSubscription." }
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
}
function InitRoots {
    foreach ($root in @($azureRoot, $awsRoot)) {
        $vars = Join-Path $root 'terraform.tfvars'
        if (-not (Test-Path $vars)) { Copy-Item (Join-Path $root 'terraform.tfvars.example') $vars }
        Tf $root @('init', '-input=false')
        Tf $root @('validate', '-no-color')
    }
}
function UpdateOverlays([string]$azureIp, [string]$azureKey, [string]$awsIp, [bool]$nat) {
    $az = ReadJson $azureOverlay
    $az['subscription_id'] = $ExpectedAzureSubscription
    $az['admin_username'] = $AzureUser
    $az['admin_public_cidr'] = $AdminPublicCidr
    $az['admin_ssh_public_key'] = $publicKey
    $az['aws_peer_public_cidr'] = if ($awsIp) { "$awsIp/32" } else { '' }
    SaveJson $azureOverlay $az
    $aw = ReadJson $awsOverlay
    $aw['admin_public_cidr'] = $AdminPublicCidr
    $aw['ssh_public_key'] = $publicKey
    $aw['azure_peer_public_cidr'] = if ($azureIp) { "$azureIp/32" } else { '' }
    $aw['azure_wireguard_public_key'] = if ($azureKey) { $azureKey } else { 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' }
    $aw['erp_image'] = $ErpImage
    $aw['enable_temporary_nat'] = $nat
    SaveJson $awsOverlay $aw
}
function PrepareSecrets([string]$dbIp) {
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
    $vars['DATABASE_URL'] = "postgresql+psycopg://andeslog_app:$([uri]::EscapeDataString($dbPassword))@${dbIp}:5432/andeslog"
    $lines = @('APP_ENV', 'SECRET_KEY', 'DATABASE_URL', 'BOOTSTRAP_ADMIN_USERNAME', 'BOOTSTRAP_ADMIN_PASSWORD') | ForEach-Object { "$_=$($vars[$_])" }
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
    $script:archive = Join-Path $work 'andeslog-erp.tar'
    Native 'docker' @('save', '-o', $archive, $ErpImage)
    $script:archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
}
function EnsureWebBootstrap([string]$hostName) {
    $status = RemoteOutput $hostName 'cloud-init status --wait; exit 0'
    $ready = RemoteOutput $hostName 'if command -v docker >/dev/null 2>&1 && test -f /etc/systemd/system/andeslog-web.service && systemctl is-active --quiet docker; then echo ready; else echo incomplete; fi'
    if ($ready -eq 'ready') { return }
    if ($status -notmatch 'status:\s*error') {
        throw "Bootstrap web incompleto en $hostName (cloud-init: $status)."
    }
    Say "cloud-init falló en $hostName; reintentando bootstrap web con la salida NAT disponible."
    Remote $hostName 'sudo test -f /var/lib/cloud/instance/scripts/part-001 && curl --fail --silent --show-error --head --max-time 10 http://us-east-1.ec2.archive.ubuntu.com/ubuntu/dists/noble/InRelease >/dev/null && sudo bash /var/lib/cloud/instance/scripts/part-001'
    Remote $hostName 'sudo test -x /usr/bin/docker && sudo test -f /etc/systemd/system/andeslog-web.service && sudo systemctl is-active --quiet docker'
}
function InstallErp([string]$dbPassword) {
    Say 'Configurando PostgreSQL y cargando ERP en ambas EC2.'
    Remote 'aws-db' 'cloud-init status --wait'
    if ($dbPassword -match '[\r\n\x00]') { throw 'La contraseña PostgreSQL existente contiene un salto de línea o NUL.' }
    $sqlPassword = $dbPassword.Replace("'", "''")
    $sql = @"
SELECT 'CREATE ROLE andeslog_app LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'andeslog_app') \gexec
ALTER ROLE andeslog_app PASSWORD '$sqlPassword';
SELECT 'CREATE DATABASE andeslog OWNER andeslog_app' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'andeslog') \gexec
"@
    $sqlFile = Join-Path $work 'init-db.sql'
    [IO.File]::WriteAllText($sqlFile, $sql.Replace("`r`n", "`n") + "`n", $utf8)
    Upload $sqlFile 'aws-db' '/home/ubuntu/.andeslog-init.sql'
    try {
        Remote 'aws-db' 'chmod 600 /home/ubuntu/.andeslog-init.sql && sudo -u postgres psql -v ON_ERROR_STOP=1 < /home/ubuntu/.andeslog-init.sql'
    } finally { Remote 'aws-db' 'rm -f /home/ubuntu/.andeslog-init.sql' }
    foreach ($hostName in @('aws-web-a', 'aws-web-b')) {
        EnsureWebBootstrap $hostName
        Upload $archive $hostName '/home/ubuntu/andeslog-erp.tar'
        $actual = RemoteOutput $hostName 'sha256sum /home/ubuntu/andeslog-erp.tar'
        if (-not $actual.StartsWith($archiveHash)) { throw "Hash de imagen incorrecto en $hostName." }
        Remote $hostName 'sudo docker load -i /home/ubuntu/andeslog-erp.tar && rm -f /home/ubuntu/andeslog-erp.tar'
        Upload $secretPath $hostName '/home/ubuntu/.andeslog-erp.env'
        Remote $hostName 'chmod 600 /home/ubuntu/.andeslog-erp.env && sudo install -o root -g root -m 0600 /home/ubuntu/.andeslog-erp.env /etc/andeslog-app/erp.env && rm -f /home/ubuntu/.andeslog-erp.env'
    }
    Remote 'aws-web-a' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env $ErpImage flask --app app:create_app db upgrade"
    Remote 'aws-web-a' "sudo docker run --rm --env-file /etc/andeslog-app/erp.env $ErpImage flask --app app:create_app seed-admin"
    foreach ($hostName in @('aws-web-a', 'aws-web-b')) {
        Remote $hostName 'sudo systemctl restart andeslog-web && for n in $(seq 1 30); do curl --fail --silent http://127.0.0.1:8080/api/health && exit 0; sleep 2; done; exit 1'
    }
}
function Deploy {
    if (-not (Test-Path $secretPath) -and (TfOutput $awsRoot 'db_private_ip')) {
        throw "Existe una base AWS y falta $secretPath. Recupera el secreto local previo o usa Recreate si aceptas perder los datos."
    }
    if (-not $script:archive) { BuildErp }
    $oldAwsIp = TfOutput $awsRoot 'vpn_public_ip'
    $oldAzureIp = TfOutput $azureRoot 'vpn_public_ip'
    $oldAzKey = (ReadJson $awsOverlay)['azure_wireguard_public_key']
    UpdateOverlays $oldAzureIp $oldAzKey $oldAwsIp $true
    Say 'Fase 1/5: Azure.'
    Tf $azureRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    $azureIp = TfOutput $azureRoot 'vpn_public_ip'
    if (-not $azureIp) { throw 'Azure no devolvió vpn_public_ip.' }
    SetupSsh $azureIp '127.0.0.1'
    Remote 'azure-vpn' 'cloud-init status --wait'
    $azureKey = RemoteOutput 'azure-vpn' "sudo sh -c 'umask 077; test -s /etc/wireguard/privatekey || wg genkey > /etc/wireguard/privatekey; wg pubkey < /etc/wireguard/privatekey'"
    if ($azureKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'Clave WireGuard Azure inválida.' }
    UpdateOverlays $azureIp $azureKey $oldAwsIp $true
    Say 'Fase 2/5: AWS con NAT temporal.'
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    $awsIp = TfOutput $awsRoot 'vpn_public_ip'
    $dbIp = TfOutput $awsRoot 'db_private_ip'
    if (-not $awsIp -or -not $dbIp) { throw 'AWS no devolvió las IP necesarias.' }
    SetupSsh $azureIp $awsIp
    Remote 'aws-vpn' 'cloud-init status --wait'
    $awsKey = RemoteOutput 'aws-vpn' 'sudo wg show wg0 public-key'
    if ($awsKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'Clave WireGuard AWS inválida.' }
    Say 'Fase 3/5: reglas Azure y WireGuard.'
    UpdateOverlays $azureIp $azureKey $awsIp $true
    Tf $azureRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    $wgFile = Join-Path $work 'configure-wireguard.sh'
    $wgSource = [IO.File]::ReadAllText((Join-Path $repo 'scripts\configure-wireguard.sh')).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($wgFile, $wgSource, $utf8)
    Upload $wgFile 'azure-vpn' '/tmp/andeslog-configure-wireguard.sh'
    Remote 'azure-vpn' "sudo bash /tmp/andeslog-configure-wireguard.sh azure $awsKey $awsIp"
    Remote 'azure-vpn' 'rm -f /tmp/andeslog-configure-wireguard.sh'
    $handshake = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $null = & ssh -F $sshConfig azure-vpn 'ping -c 1 -W 2 172.30.50.1' 2>$null
        $timestamps = RemoteOutput 'azure-vpn' 'sudo wg show wg0 latest-handshakes'
        if ($timestamps -match '\s([1-9][0-9]*)\s*$') { $handshake = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $handshake) { throw 'WireGuard no estableció handshake entre Azure y AWS.' }
    Say 'Fase 4/5: base de datos y ERP.'
    $dbPassword = PrepareSecrets $dbIp
    InstallErp $dbPassword
    $alb = TfOutput $awsRoot 'alb_dns_name'
    if (-not $alb) { throw 'AWS no devolvió alb_dns_name.' }
    $ready = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri "http://$alb/api/health" -TimeoutSec 10
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 3 }
    }
    if (-not $ready) { throw "El ALB aún no responde en http://$alb/api/health." }
    Say "ERP responde en http://$alb/api/health"
    Say 'Fase 5/5: retirada del NAT temporal.'
    UpdateOverlays $azureIp $azureKey $awsIp $false
    Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
    foreach ($root in @($awsRoot, $azureRoot)) {
        Push-Location $root
        try {
            & terraform plan -input=false -detailed-exitcode -no-color
            if ($LASTEXITCODE -ne 0) { throw "Quedan diferencias o errores en el plan de $root (código $LASTEXITCODE)." }
        } finally { Pop-Location }
    }
    Say "Despliegue completo: http://$alb/"
    Say "Credenciales iniciales: archivo local $secretPath (nunca se imprime su contenido)."
}
function DestroyLab {
    $azureIp = TfOutput $azureRoot 'vpn_public_ip'
    $awsIp = TfOutput $awsRoot 'vpn_public_ip'
    $azKey = (ReadJson $awsOverlay)['azure_wireguard_public_key']
    UpdateOverlays $azureIp $azKey $awsIp $false
    Say 'Destruyendo AWS primero, incluida la base de datos y su EBS.'
    Tf $awsRoot @('destroy', '-input=false', '-auto-approve', '-no-color')
    Say 'Destruyendo Azure, incluido el contenedor Blob.'
    Tf $azureRoot @('destroy', '-input=false', '-auto-approve', '-no-color')
    Remove-Item -LiteralPath $awsOverlay, $azureOverlay -ErrorAction SilentlyContinue
    Say 'Ambos estados destruidos. El secreto local se conserva para un futuro despliegue.'
}

try {
    if ($tempRoot -match '\s') {
        throw "La ruta temporal $tempRoot contiene espacios y OpenSSH ProxyJump no puede abrir su archivo de configuración. Configura TEMP/TMP en una ruta privada sin espacios antes de continuar."
    }
    if (($Action -eq 'Destroy' -or $Action -eq 'Recreate') -and -not $ConfirmDataLoss) {
        throw 'Destroy/Recreate borra PostgreSQL y Azure Blob. Repite con -ConfirmDataLoss.'
    }
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    CheckIdentity
    InitRoots
    switch ($Action) {
        'Status' {
            Say "Azure VPN: $(TfOutput $azureRoot 'vpn_public_ip')"
            Say "AWS VPN: $(TfOutput $awsRoot 'vpn_public_ip')"
            Say "ERP: http://$(TfOutput $awsRoot 'alb_dns_name')/"
        }
        'Deploy' { Deploy }
        'PreviewDestroy' {
            $azureIp = TfOutput $azureRoot 'vpn_public_ip'
            $awsIp = TfOutput $awsRoot 'vpn_public_ip'
            $azKey = (ReadJson $awsOverlay)['azure_wireguard_public_key']
            UpdateOverlays $azureIp $azKey $awsIp $false
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
            if (-not (Test-Path $awsOverlay)) { throw 'Falta el overlay AWS con la clave pública Azure; no se puede aplicar CleanupNat de forma segura.' }
            $azureIp = TfOutput $azureRoot 'vpn_public_ip'
            $awsIp = TfOutput $awsRoot 'vpn_public_ip'
            if (-not $azureIp -or -not $awsIp) { throw 'CleanupNat requiere los dos estados VPN activos.' }
            $azKey = (ReadJson $awsOverlay)['azure_wireguard_public_key']
            if (-not $azKey -or $azKey -eq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=') { throw 'Falta la clave pública Azure real; no se puede aplicar CleanupNat.' }
            UpdateOverlays $azureIp $azKey $awsIp $false
            Tf $awsRoot @('apply', '-input=false', '-auto-approve', '-no-color')
            Say 'NAT temporal retirado.'
        }
    }
} catch {
    Write-Error "Se detuvo en la fase actual: $($_.Exception.Message). Si quedó NAT, ejecuta .\scripts\lab.ps1 -Action CleanupNat."
    exit 1
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    $safeRoot = $tempRoot
    if ($resolved.StartsWith(($safeRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'andeslog-lab-run-*' -and (Test-Path $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
