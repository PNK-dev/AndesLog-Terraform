#requires -Version 5.1
<#
.SYNOPSIS
  Inventario de solo lectura de la identidad actual y el perfil AWS del laboratorio.
.DESCRIPTION
  No imprime documentos de políticas, credenciales ni tokens y no modifica roles.
  No determina permisos efectivos ni sustituye una evaluación de IAM/Entra.
#>
[CmdletBinding()]
param(
    [string]$ExpectedAwsAccount = '406197219647',
    [string]$ExpectedAzureSubscription = '75b45f81-0930-4278-8fd9-896cec6eebe1',
    [string]$AwsInstanceProfile = 'LabInstanceProfile',
    [string]$AzureResourceGroup = 'andeslog-lab-rg'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-NativeJson([string]$Program, [string[]]$Arguments, [string]$Context) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = & $Program @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "No se pudo consultar $Context (código $code); el inventario está incompleto." }
    try { return ((@($lines) -join "`n") | ConvertFrom-Json) }
    catch { throw "La respuesta de $Context no es JSON válido." }
}

try {
    if ($ExpectedAwsAccount -notmatch '^\d{12}$' -or $ExpectedAzureSubscription -notmatch '^[a-fA-F0-9-]{36}$' -or
        $AwsInstanceProfile -notmatch '^[A-Za-z0-9+=,.@_-]{1,128}$' -or $AzureResourceGroup -notmatch '^[A-Za-z0-9_.()\-]{1,90}$') {
        throw 'Los identificadores esperados tienen formato inválido.'
    }
    $caller = Read-NativeJson 'aws' @('sts', 'get-caller-identity', '--output', 'json', '--no-cli-pager') 'identidad AWS'
    if ($caller.Account -cne $ExpectedAwsAccount) { throw 'La cuenta AWS no coincide con la cuenta esperada.' }
    $profile = Read-NativeJson 'aws' @('iam', 'get-instance-profile', '--instance-profile-name', $AwsInstanceProfile, '--output', 'json', '--no-cli-pager') 'perfil de instancia'
    $roles = @($profile.InstanceProfile.Roles)
    if ($roles.Count -ne 1 -or -not $roles[0].RoleName -or -not $roles[0].Arn) { throw 'El perfil no contiene exactamente un rol verificable.' }
    $roleName = [string]$roles[0].RoleName
    $role = Read-NativeJson 'aws' @('iam', 'get-role', '--role-name', $roleName, '--output', 'json', '--no-cli-pager') 'rol AWS'
    $managed = Read-NativeJson 'aws' @('iam', 'list-attached-role-policies', '--role-name', $roleName, '--output', 'json', '--no-cli-pager') 'políticas administradas'
    $inline = Read-NativeJson 'aws' @('iam', 'list-role-policies', '--role-name', $roleName, '--output', 'json', '--no-cli-pager') 'políticas inline'
    $account = Read-NativeJson 'az' @('account', 'show', '--output', 'json', '--only-show-errors') 'suscripción Azure'
    if ($account.id -cne $ExpectedAzureSubscription -or $account.user.type -ne 'user') { throw 'La suscripción Azure o el tipo de identidad no coincide con el esperado.' }
    $principal = Read-NativeJson 'az' @('ad', 'signed-in-user', 'show', '--query', '{id:id}', '--output', 'json', '--only-show-errors') 'identidad Azure'
    if ($principal.id -notmatch '^[a-fA-F0-9-]{36}$') { throw 'No se pudo identificar el usuario Azure.' }
    $subscriptionScope = "/subscriptions/$ExpectedAzureSubscription"
    $resourceGroupScope = "$subscriptionScope/resourceGroups/$AzureResourceGroup"
    $subscriptionRoles = Read-NativeJson 'az' @('role', 'assignment', 'list', '--assignee-object-id', $principal.id, '--scope', $subscriptionScope, '--include-inherited', '--output', 'json', '--only-show-errors') 'roles Azure de suscripción'
    $groupRoles = Read-NativeJson 'az' @('role', 'assignment', 'list', '--assignee-object-id', $principal.id, '--scope', $resourceGroupScope, '--include-inherited', '--output', 'json', '--only-show-errors') 'roles Azure del grupo de recursos'

    Write-Output "AWS: perfil $AwsInstanceProfile; rol $roleName"
    $boundaryProperty = $role.Role.PSObject.Properties['PermissionsBoundary']
    $boundary = if ($boundaryProperty -and $null -ne $boundaryProperty.Value) { $boundaryProperty.Value.PermissionsBoundaryArn } else { $null }
    if ($boundary) { Write-Output "Límite de permisos: $boundary" } else { Write-Output 'No se observó un límite de permisos IAM para este rol.' }
    foreach ($policy in @($managed.AttachedPolicies)) { Write-Output "Política administrada: $($policy.PolicyName)" }
    foreach ($policyName in @($inline.PolicyNames)) { Write-Output "Política inline: $policyName" }
    foreach ($assignment in @(@($subscriptionRoles) + @($groupRoles) | Sort-Object roleDefinitionName, scope -Unique)) {
        if ($null -ne $assignment -and $assignment.roleDefinitionName -and $assignment.scope) {
            Write-Output "Azure: $($assignment.roleDefinitionName) en $($assignment.scope)"
        }
    }
    Write-Output 'Inventario de solo lectura: no demuestra permisos efectivos, mínimo privilegio ni ausencia de otras asignaciones.'
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
