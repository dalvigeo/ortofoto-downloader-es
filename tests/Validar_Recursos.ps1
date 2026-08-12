#requires -version 5.1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$resourceRoot = Join-Path $repoRoot 'resources'

function Read-Json([string]$name) {
    $path = Join-Path $resourceRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Arquivo ausente: $path"
    }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Parse-Invariant([string]$value) {
    return [double]::Parse(
        $value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

Write-Host ''
Write-Host 'Validando recursos do Ortofoto Downloader ES'
Write-Host '============================================='

$surveys = Read-Json 'levantamentos.json'
$municipiosAtual = Read-Json 'municipios_2012_2019.json'
$municipios2007 = Read-Json 'municipios_2007_2008.json'
$fontes = Read-Json 'fontes_online.json'

if ($municipiosAtual.PSObject.Properties.Count -ne 78) {
    throw "Mapa 2012/2019: esperados 78 municípios; encontrados $($municipiosAtual.PSObject.Properties.Count)."
}
if ($municipios2007.PSObject.Properties.Count -ne 78) {
    throw "Mapa 2007/2008: esperados 78 municípios; encontrados $($municipios2007.PSObject.Properties.Count)."
}

foreach ($year in @('2007_2008', '2012_2014', '2019_2020')) {
    $property = $surveys.PSObject.Properties[$year]
    if (-not $property) {
        throw "Definição ausente para $year."
    }

    $def = $property.Value
    $recipePath = Join-Path $resourceRoot ([string]$def.recipeFile)
    if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) {
        throw "Receita ausente para $year: $recipePath"
    }

    $rows = @(Import-Csv -LiteralPath $recipePath -Delimiter ',' -Encoding UTF8)
    $expected = [int]$def.recipeCount
    if ($rows.Count -ne $expected) {
        throw "$year: esperados $expected blocos; encontrados $($rows.Count)."
    }

    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        if (-not $names.Add([string]$row.arquivo)) {
            throw "$year: arquivo duplicado na receita: $($row.arquivo)"
        }

        [void](Parse-Invariant ([string]$row.xOff))
        [void](Parse-Invariant ([string]$row.yOff))
        $xSize = Parse-Invariant ([string]$row.xSize)
        $ySize = Parse-Invariant ([string]$row.ySize)
        if ($xSize -le 0 -or $ySize -le 0) {
            throw "$year: dimensão inválida em $($row.arquivo)."
        }
    }

    Write-Host ("  {0}: OK ({1} blocos)" -f $year, $rows.Count)
}

# Verificações funcionais simples dos dados municipais aprovados na RC2.
$rioBananal = @($municipiosAtual.'Rio Bananal')
if ($rioBananal.Count -ne 16) {
    throw "Rio Bananal deveria possuir 16 blocos nos levantamentos 2012/2019."
}

foreach ($macro in @('CENTROESTE','CENTROLESTE','NORDESTE','NOROESTE','SUDESTE','SUDOESTE')) {
    if (-not $fontes.'2007_2008'.PSObject.Properties[$macro]) {
        throw "Link 2007/2008 ausente para $macro."
    }
}

if (-not $fontes.'2012_2014' -or -not $fontes.'2019_2020') {
    throw 'URLs-base dos levantamentos atuais estão ausentes.'
}

Write-Host ''
Write-Host 'Recursos validados com sucesso.'
