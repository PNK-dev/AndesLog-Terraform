#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][ValidateSet('Add', 'Disable')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Username
)

$ErrorActionPreference = 'Stop'
throw 'La VPN ya no administra usuarios locales. Azure VPN Gateway autentica con Microsoft Entra ID; gestiona altas, bajas y bloqueo desde el tenant institucional. La credencial SMB de Azure Files sigue siendo independiente.'
