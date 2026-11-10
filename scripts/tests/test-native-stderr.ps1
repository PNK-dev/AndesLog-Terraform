#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lab = Join-Path $PSScriptRoot '..\lab.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($lab, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
foreach ($name in @('Capture', 'RedactRemoteDiagnostic', 'Remote')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw "No se encontró $name." }
    Invoke-Expression $definition[0].Extent.Text
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-stderr-test-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH; $savedExit = $env:ANDESLOG_TEST_EXIT
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fake = @'
@echo off
if "%ANDESLOG_TEST_EXIT%"=="2" exit /b 0
echo INFO migration on stderr 1>&2
if "%ANDESLOG_TEST_EXIT%"=="1" exit /b 7
exit /b 0
'@
    [IO.File]::WriteAllText((Join-Path $temp 'ssh.cmd'), $fake, [Text.Encoding]::ASCII)
    $env:PATH = "$temp;$savedPath"; $sshConfig = 'unused'; $env:ANDESLOG_TEST_EXIT = '0'
    Remote 'host' 'command'
    if ((Capture 'ssh' @('host', 'command')) -notmatch 'INFO migration') { throw 'No se conservó stderr informativo.' }
    if ($ErrorActionPreference -ne 'Stop') { throw 'No se restauró la preferencia de errores.' }
    $env:ANDESLOG_TEST_EXIT = '2'
    Remote 'host' 'command'
    if ((Capture 'ssh' @('host', 'command')) -ne '') { throw 'La salida vacía no se manejó correctamente.' }
    $env:ANDESLOG_TEST_EXIT = '1'
    $rejected = $false
    try { Remote 'host' 'command' } catch { $rejected = $_.Exception.Message -match 'código 7' }
    if (-not $rejected) { throw 'No se detectó el código SSH de error.' }
    $rejected = $false
    try { $null = Capture 'ssh' @('host', 'command') } catch { $rejected = $_.Exception.Message -match 'código 7' }
    if (-not $rejected) { throw 'No se detectó el código de error al capturar.' }
    Write-Host 'OK: stderr informativo es aceptado y los códigos de error detienen el proceso.'
} finally {
    $env:PATH = $savedPath; $env:ANDESLOG_TEST_EXIT = $savedExit
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
