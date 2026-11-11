#requires -Version 5.1
Set-StrictMode -Version Latest

function Protect-AndeslogRuntimeSecret([string]$Path) {
    $phase = 'lectura'
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'invalid' }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $phase = 'preparación de ACL'
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) { $null = $acl.RemoveAccessRuleSpecific($existingRule) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
        $phase = 'aplicación de ACL'
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
        } else {
            $item.SetAccessControl($acl)
        }
    } catch { throw "No se pudo proteger el archivo local del ERP ($phase, $($_.Exception.GetType().Name)); se detiene el proceso." }
}

function Assert-AndeslogRuntimeConsistency([string]$Path, [string]$RemoteJson) {
    # Never include file content, JSON or parsing exceptions in errors.
    $errorMessage = 'El secreto local ERP no coincide con el secreto activo de AWS o está incompleto. Se detiene Deploy antes de modificar recursos; recupera y verifica el secreto correcto mediante un procedimiento seguro.'
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or -not $RemoteJson) { throw 'invalid' }
        $local = @{}
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
            if (-not $line) { continue }
            if ($line -notmatch '^([A-Z_][A-Z0-9_]*)=(.*)$') { throw 'invalid' }
            $name = $matches[1]; $value = $matches[2]
            if ($local.ContainsKey($name)) { throw 'invalid' }
            $local[$name] = $value
        }
        $remote = $RemoteJson | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $remote -or $remote -is [array] -or $remote -is [string]) { throw 'invalid' }
        foreach ($name in @('APP_ENV', 'SECRET_KEY', 'DATABASE_URL', 'BOOTSTRAP_ADMIN_USERNAME', 'BOOTSTRAP_ADMIN_PASSWORD')) {
            $property = $remote.PSObject.Properties[$name]
            if (-not $local.ContainsKey($name) -or -not $local[$name] -or $null -eq $property -or
                $property.Value -isnot [string] -or -not $property.Value -or $local[$name] -cne $property.Value) {
                throw 'invalid'
            }
        }
        # This lab deploy currently forces development (HTTP). Never silently
        # downgrade an existing production runtime's cookie security.
        if ($local['APP_ENV'] -cne 'development') { throw 'invalid' }
        # PrepareSecrets must be able to recover the existing DB password. If
        # this check is skipped, an unparseable URL silently generates a new one.
        if ($local['DATABASE_URL'] -cnotmatch '^postgresql\+psycopg://andeslog_app:([^@]+)@') { throw 'invalid' }
        if (-not [uri]::UnescapeDataString($matches[1])) { throw 'invalid' }
        $integrationFlags = @()
        foreach ($name in @('ERP_AZURE_INGEST_URL', 'ERP_AZURE_INGEST_HMAC_SECRET')) {
            $property = $remote.PSObject.Properties[$name]
            if ($null -ne $property -and $property.Value -isnot [string]) { throw 'invalid' }
            $remoteHasValue = $null -ne $property -and $property.Value -is [string] -and [bool]$property.Value
            $localHasValue = $local.ContainsKey($name) -and [bool]$local[$name]
            $integrationFlags += [bool]$remoteHasValue
            if ($remoteHasValue -ne $localHasValue -or ($remoteHasValue -and $local[$name] -cne $property.Value)) {
                throw 'invalid'
            }
        }
        if ($integrationFlags[0] -ne $integrationFlags[1]) { throw 'invalid' }
    } catch { throw $errorMessage }
}

function Get-AndeslogRuntimeSecretString([string]$SecretArn) {
    if ($SecretArn -notmatch '^arn:(?:aws|aws-us-gov|aws-cn):secretsmanager:([a-z0-9-]+):[0-9]{12}:secret:.+$') {
        throw 'No se pudo identificar el secreto de runtime existente; se detiene Deploy.'
    }
    $region = $matches[1]
    try {
        $result = & aws secretsmanager get-secret-value --secret-id $SecretArn --region $region --output json --no-cli-pager 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'failed' }
        $response = ($result | Out-String) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $response -or $null -eq $response.PSObject.Properties['SecretString'] -or -not $response.SecretString) { throw 'invalid' }
        return [string]$response.SecretString
    } catch { throw 'No se pudo verificar el secreto activo de AWS; se detiene Deploy antes de modificar recursos.' }
}

function Restore-AndeslogRuntimeSecret([string]$Path, [string]$RemoteJson) {
    # CreateNew refuses to overwrite an existing local file. Create a protected
    # NTFS ACL before writing any secret bytes, and never echo values/errors.
    $stream = $null
    $created = $false
    try {
        $remote = $RemoteJson | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $remote -or $remote -is [array] -or $remote -is [string]) { throw 'invalid' }
        $required = @('APP_ENV', 'SECRET_KEY', 'DATABASE_URL', 'BOOTSTRAP_ADMIN_USERNAME', 'BOOTSTRAP_ADMIN_PASSWORD')
        $optional = @('ERP_AZURE_INGEST_URL', 'ERP_AZURE_INGEST_HMAC_SECRET', 'OUTBOX_POLL_SECONDS')
        $lines = @()
        foreach ($name in ($required + $optional)) {
            $property = $remote.PSObject.Properties[$name]
            if ($null -eq $property) {
                if ($name -in $required) { throw 'invalid' }
                continue
            }
            if ($property.Value -isnot [string] -or $property.Value -match '[\r\n\x00]' -or ($name -in $required -and -not $property.Value)) { throw 'invalid' }
            $lines += "$name=$($property.Value)"
        }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $file = New-Object IO.FileInfo($Path)
            $stream = [System.IO.FileSystemAclExtensions]::Create($file, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $acl)
        } else {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $acl)
        }
        $created = $true
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($lines -join "`n") + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $stream.Dispose()
        $stream = $null
        Assert-AndeslogRuntimeConsistency $Path $RemoteJson
    } catch {
        if ($stream) { $stream.Dispose() }
        if ($created) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        throw 'No se pudo recuperar de forma segura el secreto ERP en este equipo; se detiene Deploy sin modificar la nube.'
    }
}
