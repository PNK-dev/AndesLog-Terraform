#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lab = Join-Path $PSScriptRoot '..\lab.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($lab, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
$definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'BootstrapRds' }, $true))
if ($definition.Count -ne 1) { throw 'No se encontró BootstrapRds.' }
Invoke-Expression $definition[0].Extent.Text
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$work = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-rds-sequence-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$ErpImage = 'example/erp:test'
$global:commands = @(); $global:failMigration = $false
function Say([string]$Message) {}
function Capture([string]$Exe, [string[]]$Arguments) { return '{"username":"local-owner","password":"local-only"}' }
function Upload([string]$File, [string]$HostName, [string]$RemotePath) {
    if (-not (Test-Path -LiteralPath $File)) { throw 'Falta un archivo para bootstrap.' }
}
function Remote([string]$HostName, [string]$Command) {
    $global:commands += $Command
    if ($global:failMigration -and $Command -match 'flask --app app:create_app db upgrade') { throw 'synthetic migration failure' }
}
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    BootstrapRds 'db.example' 'arn:aws:secretsmanager:us-east-1:123456789012:secret:test' 'local-only-app'
    if ($global:commands.Count -ne 6 -or $global:commands[0] -notmatch 'umask 077 && mkdir -m 700' -or
        $global:commands[1] -notmatch 'bootstrap-rds.py prepare$' -or $global:commands[2] -notmatch 'prepare-rds-migration-env.py' -or
        $global:commands[3] -notmatch 'flask --app app:create_app db upgrade' -or
        $global:commands[4] -notmatch 'bootstrap-rds.py finalize$' -or $global:commands[5] -notmatch 'sudo rm -f.*&& rmdir') {
        throw 'El orden de bootstrap y limpieza no es el esperado.'
    }
    $global:commands = @(); $global:failMigration = $true; $failed = $false
    try { BootstrapRds 'db.example' 'arn:aws:secretsmanager:us-east-1:123456789012:secret:test' 'local-only-app' } catch { $failed = $true }
    if (-not $failed -or @($global:commands | Where-Object { $_ -match 'bootstrap-rds.py finalize$' }).Count -ne 0 -or
        $global:commands[-1] -notmatch 'sudo rm -f') { throw 'El fallo no detuvo la concesión de permisos o no intentó limpiar secretos.' }
    if (Test-Path -LiteralPath (Join-Path $work 'rds-master.json')) { throw 'Quedó un secreto local de prueba.' }
    Write-Host 'OK: el bootstrap separa migración y runtime, y limpia secretos al fallar.'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Force }
}
