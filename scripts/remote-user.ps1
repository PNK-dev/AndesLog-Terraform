#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][ValidateSet('Add', 'Disable')][string]$Action,
    [Parameter(Mandatory = $true)][ValidatePattern('^vpn_[a-z][a-z0-9_-]{2,26}$')][string]$Username,
    [string]$ExpectedHcpOrganization = 'AndesLog',
    [string]$AzureVpnIp = '',
    [string]$AzureUser = 'azureuser',
    [string]$SshPrivateKey = "$env:USERPROFILE\.ssh\id_ed25519"
)

$ErrorActionPreference = 'Stop'
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = $ExpectedHcpOrganization }
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'Falta OpenSSH en PATH.' }
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) { throw 'Falta scp en PATH.' }
if (-not (Test-Path -LiteralPath $SshPrivateKey)) { throw "No existe la clave SSH $SshPrivateKey." }
if (-not $AzureVpnIp) {
    $azureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\environments\lab\azure'))
    $terraformOutput = & terraform "-chdir=$azureRoot" output -raw vpn_public_ip 2>&1
    $terraformExitCode = $LASTEXITCODE
    $AzureVpnIp = ($terraformOutput | Out-String).Trim()
    if ($terraformExitCode -ne 0 -or -not $AzureVpnIp) {
        throw "Terraform no pudo leer vpn_public_ip del workspace remoto de Azure (código $terraformExitCode): $AzureVpnIp"
    }
}
if ($AzureVpnIp -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { throw 'AzureVpnIp debe ser IPv4.' }
$target = "${AzureUser}@${AzureVpnIp}"
$remoteAction = if ($Action -eq 'Add') { 'add' } else { 'disable' }
$remoteCommand = "sudo /usr/local/sbin/andeslog-manage-user $remoteAction $Username"
$helper = Join-Path $PSScriptRoot 'manage-remote-user.sh'
if (-not (Test-Path -LiteralPath $helper)) { throw "No se encontró el helper $helper." }
$remoteHelper = "/tmp/andeslog-manage-user-$Username.sh"
& scp -i $SshPrivateKey -o StrictHostKeyChecking=accept-new $helper "${target}:$remoteHelper"
if ($LASTEXITCODE -ne 0) { throw 'No se pudo copiar el helper de administración VPN al servidor.' }
& ssh -i $SshPrivateKey -o StrictHostKeyChecking=accept-new $target "sudo install -o root -g root -m 0750 $remoteHelper /usr/local/sbin/andeslog-manage-user && rm -f $remoteHelper"
if ($LASTEXITCODE -ne 0) { throw 'No se pudo instalar el helper de administración VPN en el servidor.' }

if ($Action -eq 'Disable') {
    & ssh -i $SshPrivateKey -o StrictHostKeyChecking=accept-new $target $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "No se pudo desactivar $Username." }
    return
}

$secure = Read-Host "Contraseña VPN para $Username (mínimo 12 caracteres)" -AsSecureString
$confirm = Read-Host 'Repítela' -AsSecureString
$ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
    $repeated = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
    if ($password -ne $repeated) { throw 'Las contraseñas no coinciden.' }
    if ($password.Length -lt 12 -or $password.Contains(':') -or $password.Contains("`n")) {
        throw 'Usa al menos 12 caracteres, sin dos puntos ni saltos de línea.'
    }
    $password | & ssh -i $SshPrivateKey -o StrictHostKeyChecking=accept-new $target $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear o actualizar $Username." }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)
    Remove-Variable password, repeated -ErrorAction SilentlyContinue
}
