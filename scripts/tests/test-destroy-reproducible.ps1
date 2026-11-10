#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$lab = Join-Path $PSScriptRoot '..\lab.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($lab, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
foreach ($name in @('CheckIdentity', 'StopWebAsg', 'DestroyLab')) {
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (@($definition).Count -ne 1) { throw 'No se encontró exactamente una función esperada.' }
    Invoke-Expression $definition[0].Extent.Text
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-destroy-test-' + [guid]::NewGuid().ToString('N'))
try {
    $awsRoot = Join-Path $root 'aws'; $azureRoot = Join-Path $root 'azure'
    New-Item -ItemType Directory -Force $awsRoot, $azureRoot | Out-Null
    $awsOverlay = Join-Path $awsRoot 'overlay.json'; $azureOverlay = Join-Path $azureRoot 'overlay.json'
    $ExpectedAzureSubscription = '75b45f81-0930-4278-8fd9-896cec6eebe1'
    $ExpectedAwsAccount = '406197219647'; $ExpectedHcpOrganization = 'AndesLog'
    $ErpImage = 'ghcr.io/example/erp:v1'; $Action = 'Destroy'
    $SshPrivateKey = Join-Path $root 'missing-ssh-key'
    $script:webInstanceProfileName = 'LabInstanceProfile'; $script:remoteAccessRequested = $true
    $savedOrg = $env:TF_CLOUD_ORGANIZATION; $env:TF_CLOUD_ORGANIZATION = 'AndesLog'
    $global:operations = New-Object System.Collections.ArrayList
    $global:failRds = $false
    $global:azureState = @('azurerm_storage_share.corporate[0]', 'azurerm_storage_account.shared_files[0]', 'azurerm_resource_group.main')
    function Say([string]$Message) {}
    function Need([string]$Name) {}
    function Capture([string]$Exe, [string[]]$ArgsList) {
        if ($Exe -eq 'aws') { return $ExpectedAwsAccount }
        if ($Exe -eq 'az') { return $ExpectedAzureSubscription }
        if ($Exe -ne 'terraform' -or $ArgsList[0] -ne 'state' -or $ArgsList[1] -ne 'list') { throw 'Captura no esperada.' }
        return "aws_db_instance.main`naws_autoscaling_group.web"
    }
    function Assert-AndeslogNoManagedRegionalBackup($State, $Action) {}
    function TfOutput($Directory, $Name) {
        switch ($Name) {
            'web_auto_scaling_group_name' { return 'andeslog-test-asg' }
            'db_instance_identifier' { return 'andeslog-test-db' }
            default { throw 'Output no esperado.' }
        }
    }
    function ReadJson($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return @{} }
        $object = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $result = @{}
        foreach ($property in $object.PSObject.Properties) { $result[$property.Name] = $property.Value }
        return $result
    }
    function SaveJson($Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json $Value)) }
    function Tf($Directory, [string[]]$ArgsList) { [void]$global:operations.Add("tf:$($ArgsList[0])") }
    function Native($Exe, [string[]]$ArgsList) {
        [void]$global:operations.Add("$Exe`:$($ArgsList -join ' ')")
        if ($global:failRds -and $Exe -eq 'aws' -and $ArgsList[0] -eq 'rds') { throw 'Fallo simulado de RDS.' }
    }
    function terraform { $global:LASTEXITCODE = 0; return $global:azureState }
    function aws {
        $global:LASTEXITCODE = 0
        if (($args -join ' ') -match 'AutoScalingGroups\[0\]\.AutoScalingGroupName') { return 'andeslog-test-asg' }
        if (($args -join ' ') -match 'length\(AutoScalingGroups') { return '0' }
        if (($args -join ' ') -match 'DeletionProtection') { return 'False' }
        throw 'Llamada AWS no esperada.'
    }
    CheckIdentity
    DestroyLab
    $joined = $global:operations -join "`n"
    if ($joined -match 'tf:apply' -or $joined -notmatch 'autoscaling update-auto-scaling-group' -or
        $joined -notmatch 'rds modify-db-instance' -or $joined -notmatch 'tf:destroy') { throw 'La baja intentó un apply o no ejecutó las operaciones esperadas.' }
    foreach ($name in $global:azureState) { if (-not $joined.Contains("state rm -lock-timeout=5m $name")) { throw "No se conservó $name." } }
    if ($joined.IndexOf('azurerm_storage_share.corporate[0]') -gt $joined.IndexOf('azurerm_storage_account.shared_files[0]') -or
        $joined.IndexOf('azurerm_storage_account.shared_files[0]') -gt $joined.IndexOf('azurerm_resource_group.main')) { throw 'Orden de conservación incorrecto.' }
    $global:operations.Clear()
    $global:failRds = $true
    $stopped = $false
    try { DestroyLab } catch { $stopped = $true }
    if (-not $stopped -or (($global:operations -join "`n") -match 'tf:destroy|state rm')) { throw 'Un error RDS debe detener la baja antes de destruir o alterar el estado Azure.' }
    Write-Host 'OK: un clon sin overlays no aplica cambios ajenos y conserva share, cuenta y grupo.'
} finally {
    $env:TF_CLOUD_ORGANIZATION = $savedOrg
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    Remove-Item function:aws, function:terraform -ErrorAction SilentlyContinue
    Remove-Variable operations, azureState, failRds -Scope Global -ErrorAction SilentlyContinue
}
