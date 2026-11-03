# ARES static file server fallback (no Node.js required).
# Listens on 127.0.0.1 only, so Web Serial sees a secure localhost context.
param([int]$Port = 4173, [string]$Root = '')

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'
}

$root = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "ARES: dist not found at $root" -ForegroundColor Red
    exit 1
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
    '.ico'  = 'image/x-icon'
    '.woff2' = 'font/woff2'
    '.map'  = 'application/json'
}

function Send-Response {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$HeadOnly
    )
    $header = "HTTP/1.1 $Status $StatusText`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($Body.Length)`r`n" +
        "Cache-Control: no-store`r`n" +
        "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Write-Host "ARES: cannot listen on 127.0.0.1:$Port ($_)" -ForegroundColor Red
    exit 1
}

Write-Host "ARES static server: http://127.0.0.1:$Port/"
Write-Host "Root: $root"
Write-Host "Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
            }

            $parts = $requestLine.Split(' ')
            if ($parts.Length -lt 2) { continue }

            $method = $parts[0].ToUpperInvariant()
            $target = $parts[1]
            $path = $target.Split('?')[0]
            try { $path = [System.Uri]::UnescapeDataString($path) } catch { }

            if ($path -eq '' -or $path -eq '/') { $path = '/index.html' }

            $relative = $path.TrimStart('/').Replace('/', '\')
            $file = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
            $inside = $file.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)

            if (-not $inside) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
                Send-Response -Stream $stream -Status 403 -StatusText 'Forbidden' -ContentType 'text/plain; charset=utf-8' -Body $body -HeadOnly ($method -eq 'HEAD')
            } elseif ($method -ne 'GET' -and $method -ne 'HEAD') {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Method Not Allowed')
                Send-Response -Stream $stream -Status 405 -StatusText 'Method Not Allowed' -ContentType 'text/plain; charset=utf-8' -Body $body -HeadOnly $false
            } elseif (Test-Path -LiteralPath $file -PathType Leaf) {
                $body = [System.IO.File]::ReadAllBytes($file)
                $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
                $contentType = if ($mime.ContainsKey($extension)) { $mime[$extension] } else { 'application/octet-stream' }
                Send-Response -Stream $stream -Status 200 -StatusText 'OK' -ContentType $contentType -Body $body -HeadOnly ($method -eq 'HEAD')
            } else {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                Send-Response -Stream $stream -Status 404 -StatusText 'Not Found' -ContentType 'text/plain; charset=utf-8' -Body $body -HeadOnly ($method -eq 'HEAD')
            }
        } catch {
            # Ignore a single failed request and keep serving.
        } finally {
            if ($null -ne $client) {
                try { $client.Close() } catch { }
            }
        }
    }
} finally {
    if ($null -ne $listener) {
        try { $listener.Stop() } catch { }
    }
}
