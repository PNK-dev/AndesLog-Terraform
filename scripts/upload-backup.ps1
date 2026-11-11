param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$S3Bucket = "",
    [Parameter(Mandatory = $true)][string]$AzureStorageAccount,
    [string]$AzureContainer = "backups"
)

$ErrorActionPreference = "Stop"
$resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path
$source = Get-Item -LiteralPath $resolvedFile
if ($source.PSIsContainer -or $source.Length -eq 0) { throw 'El respaldo debe ser un archivo no vacío.' }
if (-not [string]::IsNullOrWhiteSpace($S3Bucket) -and $source.Length -gt 5GB) {
    throw 'La carga condicional S3 usa PutObject y admite hasta 5 GiB; usa un procedimiento multipart validado antes de subir.'
}
$blobName = "backups/$([System.IO.Path]::GetFileName($resolvedFile))"

Write-Host "Uploading to private Azure Blob container $AzureContainer..."
& az storage blob upload --account-name $AzureStorageAccount --container-name $AzureContainer --name $blobName --file $resolvedFile --auth-mode login --type block --overwrite false --if-none-match '*' --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Azure CLI upload failed with exit code $LASTEXITCODE." }

if (-not [string]::IsNullOrWhiteSpace($S3Bucket)) {
    Write-Host "Uploading to private S3 bucket $S3Bucket..."
    & aws s3api put-object --bucket $S3Bucket --key $blobName --body $resolvedFile --if-none-match '*' --no-cli-pager --query ETag --output text
    if ($LASTEXITCODE -ne 0) { throw "Azure recibió el respaldo, pero S3 falló con código $LASTEXITCODE. La copia Azure se conserva; revisa ambos destinos antes de reintentar." }
    Write-Host "Backup uploaded to Azure Blob and S3: $blobName"
} else {
    Write-Host "Backup uploaded to Azure Blob: $blobName"
}
