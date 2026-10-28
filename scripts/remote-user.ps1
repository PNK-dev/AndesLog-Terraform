#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][ValidateSet('Add', 'Disable')][string]$Action,
    [Parameter(Mandatory = $true)][ValidatePattern('^vpn_[a-z][a-z0-9_-]{2,26}$')][string]$Username,
    [string]$AzureVpnIp = '',
    [string]$AzureUser = 'azureuser',
    [string]$SshPrivateKey = "$env:USERPROFILE\.ssh\id_ed25519"
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'Falta OpenSSH en PATH.' }
if (-not (Test-Path -LiteralPath $SshPrivateKey)) { throw "No existe la clave SSH $SshPrivateKey." }
if (-not $AzureVpnIp) {
    $azureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\environments\lab\azure'))
    $AzureVpnIp = (& terraform "-chdir=$azureRoot" output -raw vpn_public_ip 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $AzureVpnIp) { throw 'No se encontró vpn_public_ip. Pasa -AzureVpnIp.' }
}
if ($AzureVpnIp -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { throw 'AzureVpnIp debe ser IPv4.' }
$target = "${AzureUser}@${AzureVpnIp}"
$remoteAction = if ($Action -eq 'Add') { 'add' } else { 'disable' }
$remoteCommand = "sudo /usr/local/sbin/andeslog-manage-user $remoteAction $Username"

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
