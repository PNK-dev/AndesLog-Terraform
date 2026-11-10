#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lab = Join-Path $PSScriptRoot '..\lab.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($lab, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
foreach ($name in @('PublishErpImage', 'AssertUninitializedBootstrap')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw "No se encontró $name." }
    Invoke-Expression $definition[0].Extent.Text
}
$script:ecrTag = 'img-test'; $ErpImage = 'example/erp:v1'
$global:images = '[]'; $global:versions = 'null'; $global:desired = 0; $global:ops = @()
function Say([string]$Message) {}
function Capture([string]$Exe, [string[]]$ArgsList) {
    switch ("$($ArgsList[0]) $($ArgsList[1])") {
        'ecr list-images' { return $global:images }
        'ecr get-login-password' { return 'dummy' }
        'secretsmanager describe-secret' { return "{`"VersionIdsToStages`":$global:versions}" }
        'autoscaling describe-auto-scaling-groups' { return "{`"AutoScalingGroups`":[{`"AutoScalingGroupName`":`"test-asg`",`"MinSize`":0,`"DesiredCapacity`":$global:desired,`"Instances`":[]}]}" }
        default { throw 'Unexpected capture' }
    }
}
function Native([string]$Exe, [string[]]$ArgsList) { $global:ops += "$Exe $($ArgsList[0])" }
function docker { process { $global:LASTEXITCODE = 0 } }
$repo = '123456789012.dkr.ecr.us-east-1.amazonaws.com/erp'
$null = PublishErpImage $repo 'us-east-1'
if (($global:ops -join ',') -ne 'docker tag,docker push') { throw 'Una imagen ausente no inició la publicación.' }
$global:ops = @(); $global:images = '[{"imageTag":"img-test"}]'
$null = PublishErpImage $repo 'us-east-1'
if ($global:ops.Count -ne 0) { throw 'Una imagen existente se volvió a publicar.' }
$overlay = @{ bootstrap_instance_enabled = $true }
AssertUninitializedBootstrap 'secret-arn' 'test-asg' 'img-bootstrap' $overlay
foreach ($scenario in @('version', 'capacity', 'tag', 'bootstrap')) {
    $global:versions = if ($scenario -eq 'version') { '{"id":["AWSCURRENT"]}' } else { 'null' }
    $global:desired = if ($scenario -eq 'capacity') { 1 } else { 0 }
    $tag = if ($scenario -eq 'tag') { 'img-other' } else { 'img-bootstrap' }
    $config = @{ bootstrap_instance_enabled = ($scenario -ne 'bootstrap') }
    $rejected = $false
    try { AssertUninitializedBootstrap 'secret-arn' 'test-asg' $tag $config } catch { $rejected = $true }
    if (-not $rejected) { throw "No se rechazó el caso inseguro $scenario." }
}
Write-Host 'OK: ECR inicial y reanudación de bootstrap validados; casos inseguros rechazados.'
