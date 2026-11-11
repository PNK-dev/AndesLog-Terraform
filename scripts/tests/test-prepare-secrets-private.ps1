#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime-consistency-guard.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\lab.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
$definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'PrepareSecrets' }, $true))
if ($definition.Count -ne 1) { throw 'No se encontró PrepareSecrets.' }
Invoke-Expression $definition[0].Extent.Text
$secretPath = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-secret-test-' + [guid]::NewGuid().ToString('N') + '.secret')
$utf8 = New-Object Text.UTF8Encoding($false)
$script:erpIntegrationRequested = $false
function RandomSecret { return 'synthetic-test-secret' }
try {
    $first = PrepareSecrets 'db.example'
    $second = PrepareSecrets 'db.example'
    if ($first -cne $second -or -not $first) { throw 'El secreto existente no se preservó.' }
    $acl = Get-Acl -LiteralPath $secretPath
    if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object { $_.IsInherited }).Count) { throw 'El secreto heredó permisos.' }
    Write-Host 'OK: el secreto nuevo y uno existente conservan ACL privada y credenciales coherentes.'
} finally {
    if (Test-Path -LiteralPath $secretPath) { Remove-Item -LiteralPath $secretPath -Force }
}
