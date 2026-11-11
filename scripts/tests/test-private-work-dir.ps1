#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\lab.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
$definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'NewPrivateWorkDirectory' }, $true))
if ($definition.Count -ne 1) { throw 'No se encontró NewPrivateWorkDirectory.' }
Invoke-Expression $definition[0].Extent.Text
$path = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-private-test-' + [guid]::NewGuid().ToString('N'))
try {
    NewPrivateWorkDirectory $path
    $acl = Get-Acl -LiteralPath $path
    if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object { $_.IsInherited }).Count) { throw 'El directorio de trabajo heredó permisos.' }
    $fake = Join-Path $path 'synthetic.secret'
    [IO.File]::WriteAllText($fake, 'fake-only')
    $fileAcl = Get-Acl -LiteralPath $fake
    if (@($fileAcl.Access | Where-Object { $_.IdentityReference.Value -match 'Everyone|Todos|Users|Usuarios' }).Count) { throw 'El archivo heredó acceso amplio.' }
    Remove-Item -LiteralPath $fake -Force
    $blocked = $false
    try { NewPrivateWorkDirectory $path } catch { $blocked = $true }
    if (-not $blocked) { throw 'No se debe reutilizar un directorio existente.' }
    Write-Host 'OK: el directorio temporal y sus archivos heredan acceso restringido.'
} finally {
    if (Test-Path -LiteralPath (Join-Path $path 'synthetic.secret')) { Remove-Item -LiteralPath (Join-Path $path 'synthetic.secret') -Force }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
