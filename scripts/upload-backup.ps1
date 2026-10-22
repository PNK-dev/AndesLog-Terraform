param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$S3Bucket = "",
    [Parameter(Mandatory = $true)][string]$AzureStorageAccount,
    [string]$AzureContainer = "backups"
)

$ErrorActionPreference = "Stop"
$resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path
$blobName = "backups/$([System.IO.Path]::GetFileName($resolvedFile))"

Write-Host "Uploading to private Azure Blob container $AzureContainer..."
& az storage blob upload --account-name $AzureStorageAccount --container-name $AzureContainer --name $blobName --file $resolvedFile --auth-mode login --overwrite true
if ($LASTEXITCODE -ne 0) { throw "Azure CLI upload failed with exit code $LASTEXITCODE." }

if (-not [string]::IsNullOrWhiteSpace($S3Bucket)) {
    Write-Host "Uploading to private S3 bucket $S3Bucket..."
    & aws s3 cp $resolvedFile "s3://$S3Bucket/$blobName"
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI upload failed with exit code $LASTEXITCODE." }
    Write-Host "Backup uploaded to Azure Blob and S3: $blobName"
} else {
    Write-Host "Backup uploaded to Azure Blob: $blobName"
}
