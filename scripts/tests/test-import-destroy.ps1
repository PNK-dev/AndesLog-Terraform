#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-import-destroy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    @'
terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "3.9.1" }
  }
}
resource "random_id" "example" { byte_length = 8 }
output "id" { value = random_id.example.id }
'@ | Set-Content -LiteralPath (Join-Path $testDir 'main.tf') -Encoding UTF8
    Push-Location $testDir
    try {
        & terraform init -backend=false -input=false -no-color | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'init falló' }
        & terraform apply -auto-approve -input=false -no-color | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'apply de recurso local falló' }
        $id = (& terraform output -raw id | Out-String).Trim()
        & terraform state rm random_id.example | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'state rm falló' }
        Add-Content -LiteralPath (Join-Path $testDir 'main.tf') -Value ("`nimport {`n  to = random_id.example`n  id = `"$id`"`n}`n") -Encoding UTF8
        & terraform plan -destroy '-out=destroy.tfplan' -input=false -no-color | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'plan destroy falló' }
        $plan = (& terraform show -json destroy.tfplan | Out-String) | ConvertFrom-Json
        $changes = @($plan.resource_changes | Where-Object { $_ -and ($_.change.actions -join ',') -ne 'no-op' })
        if ($changes.Count -ne 0) { throw 'El plan de destrucción contiene cambios inesperados.' }
        Write-Output 'OK: Terraform destroy no reimporta el recurso retirado del estado en esta versión.'
    } finally { Pop-Location }
} finally {
    if ((Split-Path $testDir -Leaf) -like 'andeslog-import-destroy-*' -and (Test-Path -LiteralPath $testDir)) {
        Remove-Item -LiteralPath $testDir -Recurse -Force
    }
}
