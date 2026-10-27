#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
foreach ($item in $manifest) {
    $originalDirectory = Join-Path $outputRoot 'originals'
    New-Item -ItemType Directory -Path $originalDirectory -Force | Out-Null
    Copy-Item -LiteralPath $item.source -Destination (Join-Path $originalDirectory ($item.key + '.png'))
    $group = ($item.key -split '-')[0]
    $targetDirectory = Join-Path $outputRoot $group
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    $outputFile = Join-Path $targetDirectory ($item.key + '.png')
    if (Test-Path -LiteralPath $outputFile) { throw "Refusing to overwrite existing output: $outputFile" }
    $width = [int]$item.size[0]
    $height = [int]$item.size[1]
    # 仅作商店要求的尺寸、RGB 文件格式规范化，不重绘界面或改动生成内容。
    $filter = "scale=${width}:${height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=0x07101E,setsar=1,format=rgb24"
    $ffmpegArguments = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-i',
        [string]$item.source, '-vf', $filter, '-frames:v', '1', '-f', 'image2', $outputFile)
    & ffmpeg @ffmpegArguments
    if ($LASTEXITCODE -ne 0) { throw "Export failed: $($item.key)" }
    Write-Output "$($item.key) ${width}x${height} $outputFile"
}
