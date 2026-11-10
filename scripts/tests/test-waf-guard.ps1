#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\regional-dr-guard.ps1')

function AssertBlocked([scriptblock]$operation) {
    try { & $operation } catch { return }
    throw 'Se esperaba que el control WAF bloqueara esta operación.'
}

Assert-AndeslogWaf '' '' '' 'logging' 0 $false $false
Assert-AndeslogWaf 'logging' '0' '' 'count' 300 $true $false
Assert-AndeslogWaf 'count' '300' '' 'enforce' 300 $true $true
AssertBlocked { Assert-AndeslogWaf 'count' '300' '' 'off' 0 $false $false }
AssertBlocked { Assert-AndeslogWaf 'off' '0' '' 'enforce' 300 $true $true }
AssertBlocked { Assert-AndeslogWaf 'logging' '0' '' 'count' 300 $false $false }
AssertBlocked { Assert-AndeslogWaf 'count' '300' '' 'enforce' 300 $true $false }
AssertBlocked { Assert-AndeslogWaf 'enforce' '300' '' 'enforce' 301 $true $true }
AssertBlocked { Assert-AndeslogWaf '' '' 'module.primary_waf[0].aws_wafv2_web_acl.waf' 'off' 0 $false $false }
AssertBlocked { Assert-AndeslogWaf 'off' '0' 'module.primary_waf[0].aws_wafv2_web_acl.waf' 'logging' 0 $false $false }
Write-Host 'OK: WAF exige revisión gradual y conserva la configuración existente.'
