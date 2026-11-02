#Requires -Version 7.0
param(
    [string]$SourceIndex = 'store-assets/2026-11-02/source-index.json',
    [string]$OutputDirectory = 'store-assets/2026-11-02'
)
$ErrorActionPreference = 'Stop'
$items = Get-Content -LiteralPath $SourceIndex -Raw -Encoding UTF8 | ConvertFrom-Json
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($item in $items) {
    $target = [IO.Path]::GetFullPath((Join-Path $outputRoot $item.file))
    if (-not $target.StartsWith($outputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '输出路径越界' }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
    if (Test-Path -LiteralPath $target) { throw "输出已存在，不覆盖未检查的素材：$target" }
    $width = [int]$item.size[0]
    $height = [int]$item.size[1]
    # 只规范化尺寸及 RGB 格式；不绘制、翻译或修补图片内容。
    $filter = "scale=${width}:${height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=0x07101E,setsar=1,format=rgb24"
    & ffmpeg -hide_banner -loglevel error -nostdin -i $item.source -vf $filter -frames:v 1 -f image2 $target
    if ($LASTEXITCODE -ne 0) { throw "素材尺寸导出失败：$($item.key)" }
    Write-Output "$($item.key) ${width}x${height}"
}
