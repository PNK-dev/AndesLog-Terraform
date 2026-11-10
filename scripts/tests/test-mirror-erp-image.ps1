#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\mirror-erp-image.ps1') -LibraryOnly
$originalGetMirrorDigest = (Get-Command Get-MirrorDigest).ScriptBlock

$script:digestA = 'sha256:' + ('a' * 64)
$script:digestB = 'sha256:' + ('b' * 64)
$script:account = '123456789012'
$script:target = ''
$script:pushDigest = $script:digestA
$script:commands = @()
$script:logins = @()

function Get-MirrorAccount { return $script:account }
function Get-MirrorDigest([string]$Region, [string]$RepositoryName, [string]$Tag) {
    if ($Region -eq 'us-east-1') { return $script:digestA }
    return $script:target
}
function Connect-MirrorRegistry([string]$Region, [string]$Registry) { $script:logins += $Region }
function Invoke-MirrorDocker([string[]]$Arguments) {
    $script:commands += ,$Arguments
    if ($Arguments[0] -eq 'push') { $script:target = $script:pushDigest }
}
function ExpectFailure([scriptblock]$Operation, [string]$Pattern) {
    try { & $Operation } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw
    }
    throw "Se esperaba un error que contuviera: $Pattern"
}

Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-fixture' '123456789012'
if ($script:commands.Count -ne 3 -or $script:commands[0][0] -ne 'pull' -or $script:commands[0].Count -ne 2 -or $script:commands[1][0] -ne 'tag' -or $script:commands[1].Count -ne 3 -or $script:commands[2][0] -ne 'push' -or $script:logins.Count -ne 2 -or $script:target -ne $script:digestA) { throw 'La publicación no realizó las operaciones esperadas.' }

$script:commands = @(); $script:logins = @()
Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-fixture' '123456789012'
if ($script:commands.Count -ne 0 -or $script:logins.Count -ne 0) { throw 'Una imagen idéntica debe omitirse sin autenticarse ni publicar.' }

$script:target = $script:digestB
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-fixture' '123456789012' } 'digest distinto'
if ($script:commands.Count -ne 0) { throw 'No se debe publicar sobre una etiqueta incompatible.' }

$script:target = ''; $script:pushDigest = $script:digestB
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-fixture' '123456789012' } 'digest de destino difiere'
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-fixture' '999999999999' } 'cuenta AWS activa'
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'us-east-1' 'andeslog-lab-erp' 'img-fixture' '123456789012' } 'regiones deben ser distintas'
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'cn-north-1' 'andeslog-lab-erp' 'img-fixture' '123456789012' } 'partición de China'
ExpectFailure { Sync-AndeslogImage 'us-east-1' 'us-west-2' 'andeslog-lab-erp' 'img-evil''tag' '123456789012' } 'etiqueta'

# Exercise real JSON parsing under Windows PowerShell 5.1 without network.
$script:fakeAwsOutput = '[]'
function aws { $global:LASTEXITCODE = 0; return $script:fakeAwsOutput }
$emptyDigest = & $originalGetMirrorDigest 'us-west-2' 'andeslog-lab-erp' 'img-fixture'
if ($emptyDigest -ne '') { throw 'Una lista ECR vacía no debe producir un digest.' }
$script:fakeAwsOutput = '["' + $script:digestA + '"]'
$parsedDigest = & $originalGetMirrorDigest 'us-west-2' 'andeslog-lab-erp' 'img-fixture'
if ($parsedDigest -ne $script:digestA) { throw 'No se interpretó el digest de ECR.' }

$script:configuredCalls = @()
function Sync-AndeslogImage([string]$From, [string]$To, [string]$RepositoryName, [string]$Tag, [string]$Account) {
    $script:configuredCalls += ,@($From, $To, $RepositoryName, $Tag, $Account)
}
$sourceUrl = '123456789012.dkr.ecr.us-east-1.amazonaws.com/andeslog-lab-erp'
$destinationUrl = '123456789012.dkr.ecr.us-west-2.amazonaws.com/andeslog-lab-erp'
Sync-AndeslogConfiguredImage 'false' $sourceUrl '' 'img-fixture' '123456789012'
if ($script:configuredCalls.Count -ne 0) { throw 'No se debe publicar si DR está deshabilitado.' }
Sync-AndeslogConfiguredImage 'true' $sourceUrl $destinationUrl 'img-fixture' '123456789012'
if ($script:configuredCalls.Count -ne 1 -or ($script:configuredCalls[0] -join '|') -ne 'us-east-1|us-west-2|andeslog-lab-erp|img-fixture|123456789012') { throw 'No se transmitieron las regiones y el repositorio correctos.' }
ExpectFailure { Sync-AndeslogConfiguredImage 'true' $sourceUrl '' 'img-fixture' '123456789012' } 'URLs de ECR'
ExpectFailure { Sync-AndeslogConfiguredImage 'false' $sourceUrl $destinationUrl 'img-fixture' '123456789012' } 'deshabilitado'
ExpectFailure { Sync-AndeslogConfiguredImage 'unknown' $sourceUrl $destinationUrl 'img-fixture' '123456789012' } 'No se pudo determinar'
ExpectFailure { Sync-AndeslogConfiguredImage 'true' $sourceUrl '999999999999.dkr.ecr.us-west-2.amazonaws.com/andeslog-lab-erp' 'img-fixture' '123456789012' } 'cuenta esperada'
ExpectFailure { Sync-AndeslogConfiguredImage 'true' $sourceUrl '123456789012.dkr.ecr.us-west-2.amazonaws.com/otro' 'img-fixture' '123456789012' } 'mismo repositorio'

Write-Host 'OK: publicación, repetición idempotente, conflicto de etiqueta, digest incorrecto e identificación.'
