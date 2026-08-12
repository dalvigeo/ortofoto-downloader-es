#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12


# Arquitetura dos mosaicos virtuais:
# - os VRTs estaduais completos NÃO são armazenados no código;
# - resources/blocos_*.csv contém apenas a receita espacial de cada bloco;
# - o VRT de saída é construído do zero somente com os ECW existentes no destino.

$script:AppVersion = if ($env:ORTOFOTO_APP_VERSION) {
    [string]$env:ORTOFOTO_APP_VERSION
} else {
    $versionCandidate = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
    if (Test-Path -LiteralPath $versionCandidate -PathType Leaf) {
        [System.IO.File]::ReadAllText($versionCandidate, [System.Text.Encoding]::UTF8).Trim()
    } else {
        '1.1.0'
    }
}

$script:ResourceRoot = if ($env:ORTOFOTO_RESOURCE_ROOT) {
    [string]$env:ORTOFOTO_RESOURCE_ROOT
} else {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'resources'
}

function Get-ResourcePath([string]$name) {
    $path = Join-Path $script:ResourceRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Recurso obrigatório não encontrado: $path"
    }
    return $path
}

function Read-JsonResource([string]$name) {
    $path = Get-ResourcePath $name
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function ConvertTo-BlockMap($obj) {
    $map = [ordered]@{}
    foreach ($property in $obj.PSObject.Properties) {
        $values = New-Object System.Collections.Generic.List[string]
        foreach ($value in @($property.Value)) {
            $values.Add([string]$value)
        }
        $map[$property.Name] = @($values)
    }
    return $map
}

$MunicipalityBlocks_2012_2019 = ConvertTo-BlockMap (Read-JsonResource 'municipios_2012_2019.json')
$MunicipalityBlocks_2007 = ConvertTo-BlockMap (Read-JsonResource 'municipios_2007_2008.json')

$sourceDefinitions = Read-JsonResource 'fontes_online.json'
$DefaultOnlineSources = [ordered]@{
    '2012_2014' = [string]$sourceDefinitions.'2012_2014'
    '2019_2020' = [string]$sourceDefinitions.'2019_2020'
}

$OnlineFiles_2007 = [ordered]@{}
foreach ($property in $sourceDefinitions.'2007_2008'.PSObject.Properties) {
    $OnlineFiles_2007[$property.Name] = [string]$property.Value
}

$SurveyDefinitions = Read-JsonResource 'levantamentos.json'
$script:RecipeCache = @{}

function Get-SurveyDefinition([string]$selectedYear) {
    $property = $SurveyDefinitions.PSObject.Properties[$selectedYear]
    if (-not $property) {
        throw "Não existe definição espacial para o levantamento $selectedYear."
    }
    return $property.Value
}

function Get-VrtRecipe([string]$selectedYear) {
    if ($script:RecipeCache.ContainsKey($selectedYear)) {
        return $script:RecipeCache[$selectedYear]
    }

    $definition = Get-SurveyDefinition $selectedYear
    $recipePath = Get-ResourcePath ([string]$definition.recipeFile)
    $rows = @(Import-Csv -LiteralPath $recipePath -Delimiter ',' -Encoding UTF8)

    $byName = @{}
    foreach ($row in $rows) {
        $name = [string]$row.arquivo
        if (-not $name) {
            throw "A receita $($definition.recipeFile) contém uma linha sem nome de arquivo."
        }
        if ($byName.ContainsKey($name)) {
            throw "A receita $($definition.recipeFile) contém o arquivo duplicado: $name"
        }
        $byName[$name] = $row
    }

    $recipe = [pscustomobject]@{
        Rows   = $rows
        ByName = $byName
    }
    $script:RecipeCache[$selectedYear] = $recipe
    return $recipe
}

$ConfigRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'OrtofotoDownloaderES'
} else {
    Join-Path $env:APPDATA 'OrtofotoDownloaderES'
}
$ConfigPath = Join-Path $ConfigRoot 'config.json'

function Get-DefaultOnlineSources {
    return [ordered]@{
        '2012_2014' = $DefaultOnlineSources['2012_2014']
        '2019_2020' = $DefaultOnlineSources['2019_2020']
    }
}

function Normalize-BaseUrl([string]$url) {
    if (-not $url) { return '' }
    return $url.Trim().TrimEnd('/')
}

function Test-HttpUrl([string]$url) {
    if (-not $url) { return $false }
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
}

function Load-OnlineConfig {
    $cfg = Get-DefaultOnlineSources

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $cfg
    }

    try {
        $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json

        if ($obj.'2012_2014' -and (Test-HttpUrl ([string]$obj.'2012_2014'))) {
            $cfg['2012_2014'] = Normalize-BaseUrl ([string]$obj.'2012_2014')
        }

        if ($obj.'2019_2020' -and (Test-HttpUrl ([string]$obj.'2019_2020'))) {
            $cfg['2019_2020'] = Normalize-BaseUrl ([string]$obj.'2019_2020')
        }
    }
    catch {
        # Configuração inválida: usa os padrões internos.
    }

    return $cfg
}

function Save-OnlineConfig($cfg) {
    if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($ConfigRoot)
    }

    $obj = [ordered]@{
        '2012_2014' = Normalize-BaseUrl ([string]$cfg['2012_2014'])
        '2019_2020' = Normalize-BaseUrl ([string]$cfg['2019_2020'])
    }

    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$script:OnlineSources = Load-OnlineConfig

function Show-FolderDialog([string]$description, [string]$initialPath) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $description
    $dialog.ShowNewFolderButton = $true

    if ($initialPath -and (Test-Path -LiteralPath $initialPath -PathType Container)) {
        $dialog.SelectedPath = $initialPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

function Show-ConfigurationDialog([System.Windows.Forms.IWin32Window]$owner) {
    $cfgForm = New-Object System.Windows.Forms.Form
    $cfgForm.Text = 'Ortofoto Downloader ES — Configurar fontes online'
    $cfgForm.StartPosition = 'CenterParent'
    $cfgForm.Size = New-Object System.Drawing.Size(760, 355)
    $cfgForm.MinimumSize = New-Object System.Drawing.Size(680, 355)
    $cfgForm.MaximizeBox = $false
    $cfgForm.MinimizeBox = $false
    $cfgForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $cfgForm.AutoScaleMode = 'Dpi'

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Fontes online dos mapeamentos'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20, 18)
    $cfgForm.Controls.Add($title)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = 'As URLs abaixo já estão configuradas corretamente. Altere somente se o GeoBases mudar oficialmente o endereço de distribuição. Em caso de dúvida, use Restaurar padrões.'
    $info.AutoSize = $false
    $info.Size = New-Object System.Drawing.Size(700, 42)
    $info.Location = New-Object System.Drawing.Point(22, 52)
    $cfgForm.Controls.Add($info)

    $lbl12 = New-Object System.Windows.Forms.Label
    $lbl12.Text = '2012_2014 — URL-base'
    $lbl12.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $lbl12.AutoSize = $true
    $lbl12.Location = New-Object System.Drawing.Point(22, 104)
    $cfgForm.Controls.Add($lbl12)

    $txt12 = New-Object System.Windows.Forms.TextBox
    $txt12.Location = New-Object System.Drawing.Point(22, 126)
    $txt12.Size = New-Object System.Drawing.Size(700, 25)
    $txt12.Anchor = 'Top,Left,Right'
    $txt12.Text = [string]$script:OnlineSources['2012_2014']
    $cfgForm.Controls.Add($txt12)

    $lbl19 = New-Object System.Windows.Forms.Label
    $lbl19.Text = '2019_2020 — URL-base'
    $lbl19.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $lbl19.AutoSize = $true
    $lbl19.Location = New-Object System.Drawing.Point(22, 169)
    $cfgForm.Controls.Add($lbl19)

    $txt19 = New-Object System.Windows.Forms.TextBox
    $txt19.Location = New-Object System.Drawing.Point(22, 191)
    $txt19.Size = New-Object System.Drawing.Size(700, 25)
    $txt19.Anchor = 'Top,Left,Right'
    $txt19.Text = [string]$script:OnlineSources['2019_2020']
    $cfgForm.Controls.Add($txt19)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = '2007_2008 utiliza links individuais já incorporados ao aplicativo e não exige configuração.'
    $note.AutoSize = $true
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $note.Location = New-Object System.Drawing.Point(22, 231)
    $cfgForm.Controls.Add($note)

    $btnDefaults = New-Object System.Windows.Forms.Button
    $btnDefaults.Text = 'Restaurar padrões'
    $btnDefaults.Location = New-Object System.Drawing.Point(22, 269)
    $btnDefaults.Size = New-Object System.Drawing.Size(135, 32)
    $btnDefaults.Add_Click({
        $txt12.Text = $DefaultOnlineSources['2012_2014']
        $txt19.Text = $DefaultOnlineSources['2019_2020']
    })
    $cfgForm.Controls.Add($btnDefaults)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(525, 269)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.Add_Click({ $cfgForm.Close() })
    $cfgForm.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Salvar'
    $btnSave.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $btnSave.Location = New-Object System.Drawing.Point(627, 269)
    $btnSave.Size = New-Object System.Drawing.Size(95, 32)
    $btnSave.Anchor = 'Bottom,Right'
    $btnSave.Add_Click({
        $u12 = Normalize-BaseUrl $txt12.Text
        $u19 = Normalize-BaseUrl $txt19.Text

        if (-not (Test-HttpUrl $u12) -or -not (Test-HttpUrl $u19)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Informe URLs-base HTTP ou HTTPS válidas para os dois levantamentos.',
                'URL inválida',
                'OK',
                'Warning'
            ) | Out-Null
            return
        }

        $newCfg = [ordered]@{
            '2012_2014' = $u12
            '2019_2020' = $u19
        }

        try {
            Save-OnlineConfig $newCfg
            $script:OnlineSources = $newCfg
            $cfgForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $cfgForm.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Não foi possível salvar a configuração.`r`n`r`n$($_.Exception.Message)",
                'Erro ao salvar',
                'OK',
                'Error'
            ) | Out-Null
        }
    })
    $cfgForm.Controls.Add($btnSave)

    $cfgForm.AcceptButton = $btnSave
    $cfgForm.CancelButton = $btnCancel
    [void]$cfgForm.ShowDialog($owner)
}

function Get-MunicipalityMap([string]$selectedYear) {
    if ($selectedYear -eq '2007_2008') {
        return $MunicipalityBlocks_2007
    }
    return $MunicipalityBlocks_2012_2019
}

function Get-BlockFileName([string]$selectedYear, [string]$block) {
    if ($selectedYear -eq '2007_2008') {
        return ($block.ToLowerInvariant() + '.ecw')
    }
    return ($block + '.ecw')
}

function Get-DownloadUrl([string]$selectedYear, [string]$block) {
    if ($selectedYear -eq '2007_2008') {
        return [string]$OnlineFiles_2007[$block]
    }

    $baseUrl = Normalize-BaseUrl ([string]$script:OnlineSources[$selectedYear])
    $fileName = Get-BlockFileName $selectedYear $block
    return ($baseUrl + '/' + $fileName)
}

function New-HttpClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 20
    $handler.AutomaticDecompression = (
        [System.Net.DecompressionMethods]::GZip -bor
        [System.Net.DecompressionMethods]::Deflate
    )

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.TimeSpan]::FromHours(12)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0'
    )
    $client.DefaultRequestHeaders.TryAddWithoutValidation('X-Ortofotos-App', ("OrtofotoDownloaderES/" + $script:AppVersion)) | Out-Null
    return $client
}

$script:HttpClient = New-HttpClient

function Resolve-OneDrivePersonalDownloadUrl(
    [string]$shareUrl,
    [System.Windows.Forms.Label]$statusLabel
) {
    if (-not $shareUrl -or $shareUrl -notmatch '^https://1drv\.ms/') {
        throw 'O endereço informado não é um link compartilhado 1drv.ms.'
    }

    $shareRequest = $null
    $shareResponse = $null
    $badgerRequest = $null
    $badgerResponse = $null
    $driveRequest = $null
    $driveResponse = $null

    try {
        if ($statusLabel) {
            $statusLabel.Text = 'Consultando o link compartilhado do OneDrive...'
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Abre apenas os cabeçalhos e segue os redirecionamentos.
        # O corpo HTML da página de visualização não é necessário.
        $shareRequest = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            $shareUrl
        )

        $shareResponse = $script:HttpClient.SendAsync(
            $shareRequest,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        if (-not $shareResponse.IsSuccessStatusCode) {
            throw "O OneDrive respondeu HTTP $([int]$shareResponse.StatusCode) ao abrir o link compartilhado."
        }

        $redirectedUri = $shareResponse.RequestMessage.RequestUri
        if (-not $redirectedUri) {
            throw 'O OneDrive não retornou a URL redirecionada do arquivo.'
        }

        $query = [System.Web.HttpUtility]::ParseQueryString($redirectedUri.Query)
        $redeem = [string]$query['redeem']

        if (-not $redeem) {
            # Alguns redirecionamentos intermediários usam v=validatepermission
            # e podem apresentar resid/id antes do URL final.
            $resid = [string]$query['resid']
            $idValue = [string]$query['id']

            if (-not $resid -and $idValue -and $idValue.Contains('!')) {
                $resid = $idValue
            }

            throw "O link chegou ao OneDrive, mas não apresentou o token 'redeem' necessário para o download automático. URL final: $redirectedUri"
        }

        if ($statusLabel) {
            $statusLabel.Text = 'Obtendo autorização temporária do OneDrive...'
            [System.Windows.Forms.Application]::DoEvents()
        }

        # O OneDrive Pessoal atual usa um token temporário ("Badger") para
        # resolver links públicos do novo formato /u/c/.
        $badgerJson = '{"appId":"5cbed6ac-a083-4e14-b191-b4ba07653de2"}'
        $badgerRequest = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Post,
            'https://api-badgerp.svc.ms/v1.0/token'
        )
        [void]$badgerRequest.Headers.TryAddWithoutValidation('AppId', '1141147648')
        $badgerRequest.Content = New-Object System.Net.Http.StringContent(
            $badgerJson,
            [System.Text.Encoding]::UTF8,
            'application/json'
        )

        $badgerResponse = $script:HttpClient.SendAsync($badgerRequest).GetAwaiter().GetResult()

        if (-not $badgerResponse.IsSuccessStatusCode) {
            $body = $badgerResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Não foi possível obter a autorização temporária do OneDrive. HTTP $([int]$badgerResponse.StatusCode). $body"
        }

        $badgerBody = $badgerResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try {
            $badgerObject = $badgerBody | ConvertFrom-Json
        }
        catch {
            throw 'A resposta do serviço de autorização do OneDrive não estava em formato JSON válido.'
        }

        $badgerToken = [string]$badgerObject.token
        if (-not $badgerToken) {
            throw 'O serviço de autorização do OneDrive não retornou um token.'
        }

        if ($statusLabel) {
            $statusLabel.Text = 'Obtendo o endereço temporário do arquivo no OneDrive...'
            [System.Windows.Forms.Application]::DoEvents()
        }

        $encodedRedeem = [System.Uri]::EscapeDataString($redeem)
        $driveItemUrl = "https://my.microsoftpersonalcontent.com/_api/v2.0/shares/u!${encodedRedeem}/driveitem"

        $driveRequest = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            $driveItemUrl
        )
        [void]$driveRequest.Headers.TryAddWithoutValidation('Accept', 'application/json')
        [void]$driveRequest.Headers.TryAddWithoutValidation('Prefer', 'autoredeem')
        [void]$driveRequest.Headers.TryAddWithoutValidation('Authorization', "Badger $badgerToken")

        $driveResponse = $script:HttpClient.SendAsync($driveRequest).GetAwaiter().GetResult()

        if (-not $driveResponse.IsSuccessStatusCode) {
            $body = $driveResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Não foi possível resolver o arquivo compartilhado no OneDrive. HTTP $([int]$driveResponse.StatusCode). $body"
        }

        $driveBody = $driveResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try {
            $driveObject = $driveBody | ConvertFrom-Json
        }
        catch {
            throw 'A resposta de metadados do OneDrive não estava em formato JSON válido.'
        }

        $downloadUrl = [string]$driveObject.'@content.downloadUrl'
        if (-not $downloadUrl) {
            $downloadUrl = [string]$driveObject.'@microsoft.graph.downloadUrl'
        }

        if (-not $downloadUrl) {
            throw 'O OneDrive resolveu o arquivo, mas não retornou uma URL temporária de download.'
        }

        return $downloadUrl
    }
    finally {
        if ($driveResponse) {
            try { $driveResponse.Dispose() } catch {}
        }
        if ($driveRequest) {
            try { $driveRequest.Dispose() } catch {}
        }
        if ($badgerResponse) {
            try { $badgerResponse.Dispose() } catch {}
        }
        if ($badgerRequest) {
            try { $badgerRequest.Dispose() } catch {}
        }
        if ($shareResponse) {
            try { $shareResponse.Dispose() } catch {}
        }
        if ($shareRequest) {
            try { $shareRequest.Dispose() } catch {}
        }
    }
}

function Invoke-StreamDownload(
    [string]$url,
    [string]$destination,
    [string]$displayName,
    [int]$itemIndex,
    [int]$itemTotal,
    [System.Windows.Forms.ProgressBar]$progressBar,
    [System.Windows.Forms.Label]$statusLabel
) {
    $result = [ordered]@{
        Success = $false
        Bytes = [int64]0
        FinalUrl = ''
        Message = ''
    }

    $partPath = $destination + '.part'
    if (Test-Path -LiteralPath $partPath -PathType Leaf) {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
    }

    $candidate = $url

    # Links atuais do OneDrive Pessoal /u/c/ apontam para uma página de
    # visualização. Antes de baixar, resolve-se a URL temporária real.
    if ($url -match '^https://1drv\.ms/') {
        try {
            $candidate = Resolve-OneDrivePersonalDownloadUrl `
                -shareUrl $url `
                -statusLabel $statusLabel
        }
        catch {
            $result.Message = $_.Exception.Message
            return [pscustomobject]$result
        }
    }

    $response = $null
    $request = $null
    $stream = $null
    $fileStream = $null

    try {
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            $candidate
        )

        $response = $script:HttpClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode) - $($response.ReasonPhrase)"
        }

        $finalUri = $response.RequestMessage.RequestUri
        $result.FinalUrl = [string]$finalUri

        $contentType = ''
        if ($response.Content.Headers.ContentType) {
            $contentType = [string]$response.Content.Headers.ContentType.MediaType
        }

        if ($contentType -match '^text/html') {
            throw 'O servidor retornou uma página HTML em vez do arquivo ECW.'
        }

        $contentLength = $response.Content.Headers.ContentLength

        if ($contentLength -and $contentLength -gt 0) {
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $progressBar.Minimum = 0
            $progressBar.Maximum = 100
            $progressBar.Value = 0
        }
        else {
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            if ($script:ProgressPercentLabel) { $script:ProgressPercentLabel.Text = '...' }
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = New-Object System.IO.FileStream(
            $partPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            1048576,
            [System.IO.FileOptions]::SequentialScan
        )

        $buffer = New-Object byte[] 1048576
        [int64]$totalRead = 0
        $lastUiUpdate = [DateTime]::MinValue

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $totalRead += $read

            if (((Get-Date) - $lastUiUpdate).TotalMilliseconds -ge 120) {
                if ($contentLength -and $contentLength -gt 0) {
                    $pct = [int][Math]::Min(
                        100,
                        [Math]::Floor(($totalRead * 100.0) / [double]$contentLength)
                    )
                    $progressBar.Value = $pct
                    if ($script:ProgressPercentLabel) { $script:ProgressPercentLabel.Text = "$pct%" }

                    $mb = [Math]::Round($totalRead / 1MB, 1)
                    $totalMb = [Math]::Round([double]$contentLength / 1MB, 1)
                    $statusLabel.Text = "Baixando $itemIndex de ${itemTotal} — $displayName`r`n$pct% — $mb MB de $totalMb MB"
                }
                else {
                    $mb = [Math]::Round($totalRead / 1MB, 1)
                    $statusLabel.Text = "Baixando $itemIndex de ${itemTotal} — $displayName`r`n$mb MB recebidos"
                }

                [System.Windows.Forms.Application]::DoEvents()
                $lastUiUpdate = Get-Date
            }
        }

        $fileStream.Flush()
        $fileStream.Close()
        $fileStream = $null

        $stream.Close()
        $stream = $null

        if ($contentLength -and $contentLength -gt 0 -and $totalRead -ne [int64]$contentLength) {
            throw "Download incompleto: $totalRead de $contentLength bytes."
        }

        if ($totalRead -lt 1024) {
            throw "O arquivo recebido é anormalmente pequeno ($totalRead bytes)."
        }

        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }

        Move-Item -LiteralPath $partPath -Destination $destination -Force

        $result.Success = $true
        $result.Bytes = $totalRead
        $result.Message = 'Download concluído.'
        return [pscustomobject]$result
    }
    catch {
        $result.Message = $_.Exception.Message
    }
    finally {
        if ($fileStream) {
            try { $fileStream.Close() } catch {}
        }
        if ($stream) {
            try { $stream.Close() } catch {}
        }
        if ($response) {
            try { $response.Dispose() } catch {}
        }
        if ($request) {
            try { $request.Dispose() } catch {}
        }

        if (-not $result.Success -and (Test-Path -LiteralPath $partPath -PathType Leaf)) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]$result
}

function Test-VrtRecipe([string]$selectedYear) {
    try {
        $definition = Get-SurveyDefinition $selectedYear
        $recipe = Get-VrtRecipe $selectedYear
        $rows = @($recipe.Rows)

        $expectedCount = [int]$definition.recipeCount
        if ($rows.Count -ne $expectedCount) {
            throw "A receita possui $($rows.Count) bloco(s), mas a definição espera $expectedCount."
        }

        foreach ($row in $rows) {
            $xOff = ConvertTo-InvariantDouble ([string]$row.xOff)
            $yOff = ConvertTo-InvariantDouble ([string]$row.yOff)
            $xSize = ConvertTo-InvariantDouble ([string]$row.xSize)
            $ySize = ConvertTo-InvariantDouble ([string]$row.ySize)

            if ($xSize -le 0 -or $ySize -le 0) {
                throw "Dimensão inválida na receita para $($row.arquivo)."
            }

            # Avalia também os offsets para detectar valores numéricos corrompidos.
            [void]$xOff
            [void]$yOff
        }

        return [pscustomobject]@{
            Success = $true
            SourceCount = $rows.Count
            Message = "Receita espacial validada: $($rows.Count) bloco(s) indexado(s)."
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            SourceCount = 0
            Message = $_.Exception.Message
        }
    }
}

function ConvertTo-InvariantDouble([string]$value) {
    return [double]::Parse(
        $value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Format-InvariantDouble([double]$value) {
    return $value.ToString('G17', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-OrthophotoVrt([string]$outputDir, [string]$selectedYear) {
    $definition = Get-SurveyDefinition $selectedYear

    $result = [ordered]@{
        Success                = $false
        VrtPath                = $null
        VrtName                = [string]$definition.vrtName
        SourceCount            = 0
        IncludedCount          = 0
        NotInTemplateCount     = 0
        NotInTemplate          = @()
        TemplateDescription    = "Receita espacial $selectedYear"
        RasterXSize            = 0
        RasterYSize            = 0
        Message                = ''
    }

    $result.VrtPath = Join-Path $outputDir $result.VrtName

    $ecwFiles = @(
        Get-ChildItem -LiteralPath $outputDir -Filter '*.ecw' -File -ErrorAction SilentlyContinue |
        Sort-Object Name
    )

    $result.SourceCount = $ecwFiles.Count

    if ($ecwFiles.Count -eq 0) {
        $result.Message = 'Nenhum arquivo .ecw foi encontrado na pasta de destino; o VRT não pôde ser criado.'
        return [pscustomobject]$result
    }

    try {
        $recipe = Get-VrtRecipe $selectedYear
        $existingNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $ecwFiles) {
            [void]$existingNames.Add($file.Name)
        }

        $selectedRows = New-Object System.Collections.Generic.List[object]
        $foundNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        $minX = [double]::PositiveInfinity
        $minY = [double]::PositiveInfinity
        $maxX = [double]::NegativeInfinity
        $maxY = [double]::NegativeInfinity

        # Percorre a receita na ordem original do VRT estadual.
        foreach ($row in @($recipe.Rows)) {
            $sourceName = [string]$row.arquivo
            if (-not $existingNames.Contains($sourceName)) {
                continue
            }

            $selectedRows.Add($row)
            [void]$foundNames.Add($sourceName)

            $xOff  = ConvertTo-InvariantDouble ([string]$row.xOff)
            $yOff  = ConvertTo-InvariantDouble ([string]$row.yOff)
            $xSize = ConvertTo-InvariantDouble ([string]$row.xSize)
            $ySize = ConvertTo-InvariantDouble ([string]$row.ySize)

            if ($xOff -lt $minX) { $minX = $xOff }
            if ($yOff -lt $minY) { $minY = $yOff }

            $right = $xOff + $xSize
            $bottom = $yOff + $ySize

            if ($right -gt $maxX) { $maxX = $right }
            if ($bottom -gt $maxY) { $maxY = $bottom }
        }

        if ($selectedRows.Count -eq 0) {
            $result.NotInTemplate = @($ecwFiles | ForEach-Object { $_.Name })
            $result.NotInTemplateCount = $result.NotInTemplate.Count
            $result.Message = 'Nenhuma das ortofotos existentes no destino foi localizada na receita espacial do levantamento selecionado.'
            return [pscustomobject]$result
        }

        $notInRecipe = New-Object System.Collections.Generic.List[string]
        foreach ($file in $ecwFiles) {
            if (-not $foundNames.Contains($file.Name)) {
                $notInRecipe.Add($file.Name)
            }
        }

        $result.NotInTemplate = @($notInRecipe)
        $result.NotInTemplateCount = $notInRecipe.Count
        $result.IncludedCount = $selectedRows.Count

        $newRasterXSize = [int][Math]::Ceiling(($maxX - $minX) - 1.0e-9)
        $newRasterYSize = [int][Math]::Ceiling(($maxY - $minY) - 1.0e-9)

        if ($newRasterXSize -le 0 -or $newRasterYSize -le 0) {
            throw 'O envelope calculado para o VRT é inválido.'
        }

        $gtParts = @($definition.geoTransform | ForEach-Object {
            ConvertTo-InvariantDouble ([string]$_)
        })
        if ($gtParts.Count -ne 6) {
            throw 'GeoTransform inválido na definição do levantamento.'
        }

        $newGt0 = $gtParts[0] + ($minX * $gtParts[1]) + ($minY * $gtParts[2])
        $newGt3 = $gtParts[3] + ($minX * $gtParts[4]) + ($minY * $gtParts[5])
        $newGt = @($newGt0, $gtParts[1], $gtParts[2], $newGt3, $gtParts[4], $gtParts[5])

        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $false

        $root = $doc.CreateElement('VRTDataset')
        $root.SetAttribute('rasterXSize', [string]$newRasterXSize)
        $root.SetAttribute('rasterYSize', [string]$newRasterYSize)
        [void]$doc.AppendChild($root)

        $srsNode = $doc.CreateElement('SRS')
        $srsNode.SetAttribute('dataAxisToSRSAxisMapping', [string]$definition.dataAxisToSRSAxisMapping)
        $srsNode.InnerText = [string]$definition.srsWkt
        [void]$root.AppendChild($srsNode)

        $geoTransformNode = $doc.CreateElement('GeoTransform')
        $geoTransformNode.InnerText = ($newGt | ForEach-Object { Format-InvariantDouble $_ }) -join ', '
        [void]$root.AppendChild($geoTransformNode)

        $bandCount = [int]$definition.bandas
        $dataType = [string]$definition.dataType
        $blockXSize = [string]$definition.blockXSize
        $blockYSize = [string]$definition.blockYSize
        $colorInterps = @($definition.colorInterp)

        for ($bandNumber = 1; $bandNumber -le $bandCount; $bandNumber++) {
            $bandNode = $doc.CreateElement('VRTRasterBand')
            $bandNode.SetAttribute('dataType', $dataType)
            $bandNode.SetAttribute('band', [string]$bandNumber)
            [void]$root.AppendChild($bandNode)

            if ($bandNumber -le $colorInterps.Count -and $colorInterps[$bandNumber - 1]) {
                $colorNode = $doc.CreateElement('ColorInterp')
                $colorNode.InnerText = [string]$colorInterps[$bandNumber - 1]
                [void]$bandNode.AppendChild($colorNode)
            }

            foreach ($row in $selectedRows) {
                $xOff  = ConvertTo-InvariantDouble ([string]$row.xOff)
                $yOff  = ConvertTo-InvariantDouble ([string]$row.yOff)
                $xSize = [string]$row.xSize
                $ySize = [string]$row.ySize

                $sourceNode = $doc.CreateElement('SimpleSource')
                $sourceNode.SetAttribute('resampling', 'nearest')
                [void]$bandNode.AppendChild($sourceNode)

                $filenameNode = $doc.CreateElement('SourceFilename')
                $filenameNode.SetAttribute('relativeToVRT', '1')
                $filenameNode.InnerText = [string]$row.arquivo
                [void]$sourceNode.AppendChild($filenameNode)

                $sourceBandNode = $doc.CreateElement('SourceBand')
                $sourceBandNode.InnerText = [string]$bandNumber
                [void]$sourceNode.AppendChild($sourceBandNode)

                $sourcePropertiesNode = $doc.CreateElement('SourceProperties')
                $sourcePropertiesNode.SetAttribute('RasterXSize', $xSize)
                $sourcePropertiesNode.SetAttribute('RasterYSize', $ySize)
                $sourcePropertiesNode.SetAttribute('DataType', $dataType)
                $sourcePropertiesNode.SetAttribute('BlockXSize', $blockXSize)
                $sourcePropertiesNode.SetAttribute('BlockYSize', $blockYSize)
                [void]$sourceNode.AppendChild($sourcePropertiesNode)

                $srcRectNode = $doc.CreateElement('SrcRect')
                $srcRectNode.SetAttribute('xOff', '0')
                $srcRectNode.SetAttribute('yOff', '0')
                $srcRectNode.SetAttribute('xSize', $xSize)
                $srcRectNode.SetAttribute('ySize', $ySize)
                [void]$sourceNode.AppendChild($srcRectNode)

                $dstRectNode = $doc.CreateElement('DstRect')
                $dstRectNode.SetAttribute('xOff', (Format-InvariantDouble ($xOff - $minX)))
                $dstRectNode.SetAttribute('yOff', (Format-InvariantDouble ($yOff - $minY)))
                $dstRectNode.SetAttribute('xSize', $xSize)
                $dstRectNode.SetAttribute('ySize', $ySize)
                [void]$sourceNode.AppendChild($dstRectNode)
            }
        }

        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = '  '
        $settings.OmitXmlDeclaration = $true
        $settings.Encoding = New-Object System.Text.UTF8Encoding($false)

        $writer = [System.Xml.XmlWriter]::Create($result.VrtPath, $settings)
        try {
            $doc.Save($writer)
        }
        finally {
            $writer.Close()
        }

        if (-not (Test-Path -LiteralPath $result.VrtPath -PathType Leaf)) {
            throw 'O arquivo VRT não foi gravado no destino.'
        }

        $result.RasterXSize = $newRasterXSize
        $result.RasterYSize = $newRasterYSize
        $result.Success = $true

        if ($result.NotInTemplateCount -gt 0) {
            $result.Message = "Mosaico virtual criado com $($selectedRows.Count) ortofoto(s). $($result.NotInTemplateCount) arquivo(s) ECW não constam na receita espacial e foram ignorados."
        } else {
            $result.Message = "Mosaico virtual criado com $($selectedRows.Count) ortofoto(s), a partir da receita espacial do levantamento."
        }
    }
    catch {
        $result.Message = "Erro ao construir o mosaico virtual: $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

# ----------------------------
# Interface principal
# ----------------------------

$HelpUrl = 'https://github.com/dalvigeo/ortofoto-downloader-es/blob/main/docs/AJUDA.md'

$form = New-Object System.Windows.Forms.Form
$form.Text = "Ortofoto Downloader ES — v$($script:AppVersion)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1050, 850)
$form.MinimumSize = New-Object System.Drawing.Size(900, 720)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Padding = New-Object System.Windows.Forms.Padding(14)

# ---------- Layout raiz ----------
$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.ColumnCount = 1
$root.RowCount = 7
$root.Padding = New-Object System.Windows.Forms.Padding(0)
$root.Margin = New-Object System.Windows.Forms.Padding(0)
$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$form.Controls.Add($root)

# ---------- Cabeçalho ----------
$header = New-Object System.Windows.Forms.TableLayoutPanel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.AutoSize = $true
$header.ColumnCount = 3
$header.RowCount = 2
$header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 145))) | Out-Null

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Ortofoto Downloader ES'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$title.AutoSize = $true
$title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 2)
$header.Controls.Add($title, 0, 0)

$lblYear = New-Object System.Windows.Forms.Label
$lblYear.Text = 'Ano do mapeamento'
$lblYear.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$lblYear.AutoSize = $true
$lblYear.Anchor = [System.Windows.Forms.AnchorStyles]::Right
$lblYear.Margin = New-Object System.Windows.Forms.Padding(8, 5, 8, 0)
$header.Controls.Add($lblYear, 1, 0)

$cmbYear = New-Object System.Windows.Forms.ComboBox
$cmbYear.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbYear.Dock = [System.Windows.Forms.DockStyle]::Fill
$cmbYear.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
[void]$cmbYear.Items.Add('2007_2008')
[void]$cmbYear.Items.Add('2012_2014')
[void]$cmbYear.Items.Add('2019_2020')
$cmbYear.SelectedItem = '2012_2014'
$header.Controls.Add($cmbYear, 2, 0)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Download e construção de mosaicos virtuais dos mapeamentos capixabas.'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
$header.Controls.Add($subtitle, 0, 1)
$header.SetColumnSpan($subtitle, 3)

$root.Controls.Add($header, 0, 0)

# ---------- Origem ----------
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Origem das ortofotos'
$grpMode.Dock = [System.Windows.Forms.DockStyle]::Top
$grpMode.AutoSize = $true
$grpMode.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 10)
$grpMode.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$modeLayout = New-Object System.Windows.Forms.TableLayoutPanel
$modeLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$modeLayout.AutoSize = $true
$modeLayout.ColumnCount = 5
$modeLayout.RowCount = 1
$modeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$modeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$modeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$modeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$modeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$grpMode.Controls.Add($modeLayout)

$rbOnline = New-Object System.Windows.Forms.RadioButton
$rbOnline.Text = 'Baixar das fontes online (recomendado)'
$rbOnline.Checked = $true
$rbOnline.AutoSize = $true
$rbOnline.Margin = New-Object System.Windows.Forms.Padding(0, 4, 20, 0)
$modeLayout.Controls.Add($rbOnline, 0, 0)

$rbLocal = New-Object System.Windows.Forms.RadioButton
$rbLocal.Text = 'Copiar de acervo local (.ecw)'
$rbLocal.AutoSize = $true
$rbLocal.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$modeLayout.Controls.Add($rbLocal, 1, 0)

$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Text = 'Configurar fontes...'
$btnConfig.AutoSize = $true
$btnConfig.MinimumSize = New-Object System.Drawing.Size(135, 30)
$btnConfig.Margin = New-Object System.Windows.Forms.Padding(8, 0, 6, 0)
$btnConfig.Add_Click({
    Show-ConfigurationDialog $form
})
$modeLayout.Controls.Add($btnConfig, 3, 0)

$btnHelp = New-Object System.Windows.Forms.Button
$btnHelp.Text = 'Ajuda'
$btnHelp.AutoSize = $true
$btnHelp.MinimumSize = New-Object System.Drawing.Size(85, 30)
$btnHelp.Margin = New-Object System.Windows.Forms.Padding(0)
$btnHelp.Add_Click({
    try {
        Start-Process $HelpUrl
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Não foi possível abrir a página de ajuda.`r`n`r`n$HelpUrl",
            'Ajuda',
            'OK',
            'Information'
        ) | Out-Null
    }
})
$modeLayout.Controls.Add($btnHelp, 4, 0)

$root.Controls.Add($grpMode, 0, 1)

# ---------- Municípios ----------
$grpMunicipios = New-Object System.Windows.Forms.GroupBox
$grpMunicipios.Text = 'Municípios'
$grpMunicipios.Dock = [System.Windows.Forms.DockStyle]::Fill
$grpMunicipios.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 10)
$grpMunicipios.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$municipalityLayout = New-Object System.Windows.Forms.TableLayoutPanel
$municipalityLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$municipalityLayout.ColumnCount = 1
$municipalityLayout.RowCount = 3
$municipalityLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$municipalityLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$municipalityLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$municipalityLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$grpMunicipios.Controls.Add($municipalityLayout)

$searchLayout = New-Object System.Windows.Forms.TableLayoutPanel
$searchLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$searchLayout.AutoSize = $true
$searchLayout.ColumnCount = 2
$searchLayout.RowCount = 1
$searchLayout.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$searchLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$searchLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Pesquisar município'
$lblSearch.AutoSize = $true
$lblSearch.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$lblSearch.Margin = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
$searchLayout.Controls.Add($lblSearch, 0, 0)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtSearch.Margin = New-Object System.Windows.Forms.Padding(0)
$searchLayout.Controls.Add($txtSearch, 1, 0)

$municipalityLayout.Controls.Add($searchLayout, 0, 0)

$municipalityList = New-Object System.Windows.Forms.CheckedListBox
$municipalityList.CheckOnClick = $true
$municipalityList.HorizontalScrollbar = $true
$municipalityList.Dock = [System.Windows.Forms.DockStyle]::Fill
$municipalityList.IntegralHeight = $false
$municipalityList.Margin = New-Object System.Windows.Forms.Padding(0)
$municipalityList.TabStop = $true
$municipalityLayout.Controls.Add($municipalityList, 0, 1)

$selectionFooter = New-Object System.Windows.Forms.TableLayoutPanel
$selectionFooter.Dock = [System.Windows.Forms.DockStyle]::Top
$selectionFooter.AutoSize = $true
$selectionFooter.ColumnCount = 3
$selectionFooter.RowCount = 1
$selectionFooter.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$selectionFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$selectionFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$selectionFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = 'Selecionar todos'
$btnAll.AutoSize = $true
$btnAll.MinimumSize = New-Object System.Drawing.Size(115, 30)
$btnAll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$selectionFooter.Controls.Add($btnAll, 0, 0)

$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text = 'Limpar seleção'
$btnNone.AutoSize = $true
$btnNone.MinimumSize = New-Object System.Drawing.Size(110, 30)
$btnNone.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
$selectionFooter.Controls.Add($btnNone, 1, 0)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = 'Selecionados: 0'
$lblCount.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$lblCount.AutoSize = $true
$lblCount.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$lblCount.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$selectionFooter.Controls.Add($lblCount, 2, 0)

$municipalityLayout.Controls.Add($selectionFooter, 0, 2)
$root.Controls.Add($grpMunicipios, 0, 2)

# Estado persistente da seleção, independente do filtro da busca.
$script:SelectedMunicipalities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:UpdatingMunicipalityList = $false
$AllMunicipalities = @($MunicipalityBlocks_2012_2019.Keys)

function ConvertTo-SearchKey([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    $normalized = $value.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder

    foreach ($ch in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append([char]::ToLowerInvariant($ch))
        }
    }

    return $sb.ToString()
}

$MunicipalitySearchKeys = @{}
foreach ($municipality in $AllMunicipalities) {
    $MunicipalitySearchKeys[$municipality] = ConvertTo-SearchKey $municipality
}

function Update-SelectedCount {
    $lblCount.Text = "Selecionados: $($script:SelectedMunicipalities.Count)"
}

function Refresh-MunicipalityList {
    $query = ConvertTo-SearchKey $txtSearch.Text

    $script:UpdatingMunicipalityList = $true
    $municipalityList.BeginUpdate()
    try {
        $municipalityList.Items.Clear()

        foreach ($municipality in $AllMunicipalities) {
            if ($query -and $MunicipalitySearchKeys[$municipality].IndexOf(
                    $query,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -lt 0) {
                continue
            }

            $index = $municipalityList.Items.Add([string]$municipality)
            if ($script:SelectedMunicipalities.Contains($municipality)) {
                $municipalityList.SetItemChecked($index, $true)
            }
        }
    }
    finally {
        $municipalityList.EndUpdate()
        $script:UpdatingMunicipalityList = $false
    }

    Update-SelectedCount
}

$municipalityList.Add_ItemCheck({
    if ($script:UpdatingMunicipalityList) {
        return
    }

    $municipality = [string]$municipalityList.Items[$_.Index]

    if ($_.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
        [void]$script:SelectedMunicipalities.Add($municipality)
    }
    else {
        [void]$script:SelectedMunicipalities.Remove($municipality)
    }

    Update-SelectedCount
})

$txtSearch.Add_TextChanged({
    Refresh-MunicipalityList
})

# Se o usuário começar a digitar com foco na lista, a digitação é
# redirecionada à pesquisa e nunca marca um município por acidente.
$municipalityList.Add_KeyPress({
    if (-not [char]::IsControl($_.KeyChar) -and $_.KeyChar -ne ' ') {
        $txtSearch.Focus()
        $txtSearch.SelectionStart = $txtSearch.TextLength
        $txtSearch.SelectedText = [string]$_.KeyChar
        $_.Handled = $true
    }
})

$btnAll.Add_Click({
    $script:SelectedMunicipalities.Clear()
    foreach ($municipality in $AllMunicipalities) {
        [void]$script:SelectedMunicipalities.Add($municipality)
    }
    Refresh-MunicipalityList
})

$btnNone.Add_Click({
    $script:SelectedMunicipalities.Clear()
    Refresh-MunicipalityList
})

Refresh-MunicipalityList

# ---------- Acervo local ----------
$grpLocal = New-Object System.Windows.Forms.GroupBox
$grpLocal.Text = 'Acervo local'
$grpLocal.Dock = [System.Windows.Forms.DockStyle]::Top
$grpLocal.AutoSize = $true
$grpLocal.Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 9)
$grpLocal.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$localLayout = New-Object System.Windows.Forms.TableLayoutPanel
$localLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$localLayout.AutoSize = $true
$localLayout.ColumnCount = 2
$localLayout.RowCount = 2
$localLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$localLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$grpLocal.Controls.Add($localLayout)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = 'Pasta do acervo local (.ecw)'
$lblSource.AutoSize = $true
$lblSource.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$localLayout.Controls.Add($lblSource, 0, 0)
$localLayout.SetColumnSpan($lblSource, 2)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtSource.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$txtSource.Text = ''
$localLayout.Controls.Add($txtSource, 0, 1)

$btnSource = New-Object System.Windows.Forms.Button
$btnSource.Text = 'Selecionar...'
$btnSource.AutoSize = $true
$btnSource.MinimumSize = New-Object System.Drawing.Size(100, 28)
$btnSource.Margin = New-Object System.Windows.Forms.Padding(0)
$btnSource.Add_Click({
    $selected = Show-FolderDialog 'Selecione a pasta do acervo local de arquivos .ecw' $txtSource.Text
    if ($selected) {
        $txtSource.Text = $selected
    }
})
$localLayout.Controls.Add($btnSource, 1, 1)

$root.Controls.Add($grpLocal, 0, 3)

# ---------- Armazenamento ----------
$grpDest = New-Object System.Windows.Forms.GroupBox
$grpDest.Text = 'Armazenamento'
$grpDest.Dock = [System.Windows.Forms.DockStyle]::Top
$grpDest.AutoSize = $true
$grpDest.Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 9)
$grpDest.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$destLayout = New-Object System.Windows.Forms.TableLayoutPanel
$destLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$destLayout.AutoSize = $true
$destLayout.ColumnCount = 2
$destLayout.RowCount = 3
$destLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$destLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$grpDest.Controls.Add($destLayout)

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Pasta de armazenamento'
$lblDest.AutoSize = $true
$lblDest.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$destLayout.Controls.Add($lblDest, 0, 0)
$destLayout.SetColumnSpan($lblDest, 2)

$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtDest.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$txtDest.Text = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
$destLayout.Controls.Add($txtDest, 0, 1)

$btnDest = New-Object System.Windows.Forms.Button
$btnDest.Text = 'Selecionar...'
$btnDest.AutoSize = $true
$btnDest.MinimumSize = New-Object System.Drawing.Size(100, 28)
$btnDest.Margin = New-Object System.Windows.Forms.Padding(0)
$btnDest.Add_Click({
    $selectedYear = [string]$cmbYear.SelectedItem
    $selected = Show-FolderDialog "Selecione onde manter as ortofotos do levantamento $selectedYear" $txtDest.Text
    if ($selected) {
        $txtDest.Text = $selected
    }
})
$destLayout.Controls.Add($btnDest, 1, 1)

$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.AutoSize = $true
$lblOutput.ForeColor = [System.Drawing.Color]::DimGray
$lblOutput.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$destLayout.Controls.Add($lblOutput, 0, 2)
$destLayout.SetColumnSpan($lblOutput, 2)

$root.Controls.Add($grpDest, 0, 4)

# ---------- Progresso ----------
$grpProgress = New-Object System.Windows.Forms.GroupBox
$grpProgress.Text = 'Progresso'
$grpProgress.Dock = [System.Windows.Forms.DockStyle]::Top
$grpProgress.AutoSize = $true
$grpProgress.Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 9)
$grpProgress.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$progressLayout = New-Object System.Windows.Forms.TableLayoutPanel
$progressLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$progressLayout.AutoSize = $true
$progressLayout.ColumnCount = 2
$progressLayout.RowCount = 2
$progressLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$progressLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 58))) | Out-Null
$grpProgress.Controls.Add($progressLayout)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = [System.Windows.Forms.DockStyle]::Fill
$progress.Height = 20
$progress.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$progressLayout.Controls.Add($progress, 0, 0)

$lblProgressPct = New-Object System.Windows.Forms.Label
$lblProgressPct.Text = '0%'
$lblProgressPct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblProgressPct.Dock = [System.Windows.Forms.DockStyle]::Fill
$lblProgressPct.Margin = New-Object System.Windows.Forms.Padding(0)
$progressLayout.Controls.Add($lblProgressPct, 1, 0)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Pronto para iniciar.'
$status.AutoSize = $false
$status.Height = 40
$status.Dock = [System.Windows.Forms.DockStyle]::Fill
$status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$status.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$progressLayout.Controls.Add($status, 0, 1)
$progressLayout.SetColumnSpan($status, 2)

$root.Controls.Add($grpProgress, 0, 5)

# ---------- Rodapé ----------
$footer = New-Object System.Windows.Forms.TableLayoutPanel
$footer.Dock = [System.Windows.Forms.DockStyle]::Top
$footer.AutoSize = $true
$footer.ColumnCount = 2
$footer.RowCount = 1
$footer.Margin = New-Object System.Windows.Forms.Padding(0)
$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

$chkOpen = New-Object System.Windows.Forms.CheckBox
$chkOpen.Text = 'Abrir pasta de destino ao concluir'
$chkOpen.Checked = $true
$chkOpen.AutoSize = $true
$chkOpen.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$chkOpen.Margin = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)
$footer.Controls.Add($chkOpen, 0, 0)

$btnAction = New-Object System.Windows.Forms.Button
$btnAction.Text = 'BAIXAR ORTOFOTOS'
$btnAction.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnAction.AutoSize = $true
$btnAction.MinimumSize = New-Object System.Drawing.Size(190, 38)
$btnAction.Margin = New-Object System.Windows.Forms.Padding(0)
$footer.Controls.Add($btnAction, 1, 0)

$root.Controls.Add($footer, 0, 6)

# ---------- Atualizações dinâmicas ----------
$updateOutput = {
    $year = [string]$cmbYear.SelectedItem
    if (-not $year) {
        $year = '2012_2014'
    }

    $folderName = "ORTOFOTOS_${year}_selec"

    if ($txtDest.Text.Trim()) {
        $lblOutput.Text = 'Será criada/atualizada: ' + (Join-Path $txtDest.Text.Trim() $folderName)
    }
    else {
        $lblOutput.Text = "Será criada/atualizada: $folderName"
    }
}

$updateYear = {
    & $updateOutput
}

$updateMode = {
    $isLocal = $rbLocal.Checked

    # Somente o acervo local depende desta opção.
    $grpLocal.Enabled = $isLocal

    if ($isLocal) {
        $btnAction.Text = 'COPIAR ORTOFOTOS'
    }
    else {
        $btnAction.Text = 'BAIXAR ORTOFOTOS'
    }
}

$txtDest.Add_TextChanged($updateOutput)
$cmbYear.Add_SelectedIndexChanged($updateYear)
$rbLocal.Add_CheckedChanged($updateMode)
$rbOnline.Add_CheckedChanged($updateMode)

& $updateOutput
& $updateMode

function Set-ProgressPercent([int]$value) {
    $safeValue = [Math]::Max(0, [Math]::Min(100, $value))
    $lblProgressPct.Text = "$safeValue%"
}

function Set-UiBusy([bool]$busy) {
    $enabled = -not $busy

    $btnAction.Enabled = $enabled
    $btnDest.Enabled = $enabled
    $txtDest.Enabled = $enabled
    $municipalityList.Enabled = $enabled
    $txtSearch.Enabled = $enabled
    $cmbYear.Enabled = $enabled
    $btnAll.Enabled = $enabled
    $btnNone.Enabled = $enabled
    $btnConfig.Enabled = $enabled
    $rbLocal.Enabled = $enabled
    $rbOnline.Enabled = $enabled

    # A ajuda permanece acessível inclusive durante downloads longos.
    $btnHelp.Enabled = $true

    if ($enabled) {
        & $updateMode
    }
    else {
        $grpLocal.Enabled = $false
    }
}

$form.AcceptButton = $btnAction
$script:ProgressPercentLabel = $lblProgressPct

$btnAction.Add_Click({
    $selectedMunicipalities = @($script:SelectedMunicipalities | Sort-Object)

    if ($selectedMunicipalities.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Selecione pelo menos um município.',
            'Nenhum município selecionado',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $selectedYear = [string]$cmbYear.SelectedItem
    if (-not $selectedYear) { $selectedYear = '2012_2014' }

    # Validação preventiva: confere a receita espacial antes de iniciar qualquer transferência.
    $vrtPreflight = Test-VrtRecipe $selectedYear
    if (-not $vrtPreflight.Success) {
        [System.Windows.Forms.MessageBox]::Show(
            "A receita espacial do levantamento $selectedYear não pôde ser validada.`r`n`r`n$($vrtPreflight.Message)`r`n`r`nNenhum arquivo será baixado.",
            'Falha na validação da receita',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $isLocal = $rbLocal.Checked
    $sourceDir = $txtSource.Text.Trim()
    $destBase = $txtDest.Text.Trim()

    if ($isLocal -and -not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            'A pasta do acervo local informada não existe.',
            'Acervo local inválido',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    if (-not $destBase) {
        [System.Windows.Forms.MessageBox]::Show(
            'Selecione uma pasta de armazenamento.',
            'Armazenamento não informado',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    if (-not $isLocal -and $selectedYear -ne '2007_2008') {
        $baseUrl = [string]$script:OnlineSources[$selectedYear]
        if (-not (Test-HttpUrl $baseUrl)) {
            [System.Windows.Forms.MessageBox]::Show(
                'A URL-base configurada para este levantamento é inválida. Use o botão Configurações.',
                'Fonte online inválida',
                'OK',
                'Error'
            ) | Out-Null
            return
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $destBase -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($destBase)
        }

        $outputDir = Join-Path $destBase "ORTOFOTOS_${selectedYear}_selec"

        if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($outputDir)
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Não foi possível criar a pasta de destino.`r`n`r`n$($_.Exception.Message)",
            'Erro no destino',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $map = Get-MunicipalityMap $selectedYear

    $blockSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($municipality in $selectedMunicipalities) {
        foreach ($block in $map[$municipality]) {
            [void]$blockSet.Add([string]$block)
        }
    }
    $blocks = @($blockSet | Sort-Object)

    if ($blocks.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Nenhum bloco foi associado aos municípios selecionados para este levantamento.',
            'Nenhum bloco',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    Set-UiBusy $true

    $copied = 0
    $downloaded = 0
    [int64]$downloadedBytes = 0
    $alreadyExists = 0
    $missing = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        if ($isLocal) {
            $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $progress.Minimum = 0
            $progress.Maximum = [Math]::Max(1, $blocks.Count)
            $progress.Value = 0
            Set-ProgressPercent 0
        }

        $i = 0
        foreach ($block in $blocks) {
            $i++
            $fileName = Get-BlockFileName $selectedYear $block
            $dst = Join-Path $outputDir $fileName

            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                $alreadyExists++

                if ($isLocal) {
                    $progress.Value = [Math]::Min($i, $progress.Maximum)
                    if ($progress.Maximum -gt 0) { Set-ProgressPercent ([int](($progress.Value * 100.0) / $progress.Maximum)) }
                    $status.Text = "Processando $i de $($blocks.Count): $fileName — já existente"
                    [System.Windows.Forms.Application]::DoEvents()
                }

                continue
            }

            if ($isLocal) {
                $src = Join-Path $sourceDir $fileName

                $status.Text = "Copiando $i de $($blocks.Count): $fileName"
                $progress.Value = [Math]::Min($i, $progress.Maximum)
                if ($progress.Maximum -gt 0) { Set-ProgressPercent ([int](($progress.Value * 100.0) / $progress.Maximum)) }
                [System.Windows.Forms.Application]::DoEvents()

                if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
                    $missing.Add($fileName)
                    continue
                }

                try {
                    Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
                    $copied++
                }
                catch {
                    $errors.Add("$fileName`t$($_.Exception.Message)")
                }
            }
            else {
                $url = Get-DownloadUrl $selectedYear $block

                if (-not $url) {
                    $errors.Add("$fileName`tURL não configurada.")
                    continue
                }

                $downloadResult = Invoke-StreamDownload `
                    -url $url `
                    -destination $dst `
                    -displayName $fileName `
                    -itemIndex $i `
                    -itemTotal $blocks.Count `
                    -progressBar $progress `
                    -statusLabel $status

                if ($downloadResult.Success) {
                    $downloaded++
                    $downloadedBytes += [int64]$downloadResult.Bytes
                }
                else {
                    $errors.Add("$fileName`t$($downloadResult.Message)`t$url")
                }
            }
        }

        $status.Text = 'Reconstruindo mosaico virtual VRT com todas as ortofotos existentes no destino...'
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        [System.Windows.Forms.Application]::DoEvents()

        $vrtResult = New-OrthophotoVrt -outputDir $outputDir -selectedYear $selectedYear

        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $progress.Minimum = 0
        $progress.Maximum = 100
        $progress.Value = 100

        $reportPath = Join-Path $outputDir '_RELATORIO_ORTOFOTOS.txt'
        $report = New-Object System.Collections.Generic.List[string]

        $report.Add('ORTOFOTO DOWNLOADER ES')
        $report.Add('=======================================')
        $report.Add("Data/hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
        $report.Add("Ano do mapeamento: $selectedYear")
        $report.Add("Modo: $(if ($isLocal) { 'Cópia local' } else { 'Download pela internet' })")

        if ($isLocal) {
            $report.Add("Origem local: $sourceDir")
        }
        elseif ($selectedYear -eq '2007_2008') {
            $report.Add('Fonte online: links individuais OneDrive incorporados ao aplicativo')
        }
        else {
            $report.Add("URL-base: $($script:OnlineSources[$selectedYear])")
        }

        $report.Add("Destino: $outputDir")
        $report.Add('')
        $report.Add("Municípios selecionados ($($selectedMunicipalities.Count)):")
        foreach ($m in ($selectedMunicipalities | Sort-Object)) {
            $report.Add(" - $m")
        }

        $report.Add('')
        $report.Add("Blocos únicos selecionados: $($blocks.Count)")
        $report.Add("Já existentes no destino: $alreadyExists")

        if ($isLocal) {
            $report.Add("Copiados nesta execução: $copied")
            $report.Add("Não encontrados na origem: $($missing.Count)")
        }
        else {
            $report.Add("Baixados nesta execução: $downloaded")
            $report.Add("Volume baixado: $([Math]::Round($downloadedBytes / 1MB, 1)) MB")
        }

        $report.Add("Erros: $($errors.Count)")
        $report.Add('')
        $report.Add('MOSAICO VIRTUAL')
        $report.Add('---------------')
        $report.Add("Ortofotos .ecw encontradas no destino: $($vrtResult.SourceCount)")
        $report.Add("Arquivo VRT: $($vrtResult.VrtName)")
        $report.Add("VRT criado com sucesso: $($vrtResult.Success)")
        $report.Add("Resultado: $($vrtResult.Message)")
        $report.Add("Ortofotos incluídas no VRT: $($vrtResult.IncludedCount)")
        $report.Add("ECW não encontrados na receita: $($vrtResult.NotInTemplateCount)")
        $report.Add("Dimensão do VRT: $($vrtResult.RasterXSize) x $($vrtResult.RasterYSize) pixels")
        $report.Add("Receita: $($vrtResult.TemplateDescription)")

        if ($vrtResult.NotInTemplateCount -gt 0) {
            $report.Add('')
            $report.Add('ECW NÃO ENCONTRADOS NO VRT MODELO')
            $report.Add('---------------------------------')
            foreach ($f in $vrtResult.NotInTemplate) {
                $report.Add($f)
            }
        }

        if ($missing.Count -gt 0) {
            $report.Add('')
            $report.Add('ARQUIVOS NÃO ENCONTRADOS NA ORIGEM')
            $report.Add('---------------------------------')
            foreach ($f in $missing) {
                $report.Add($f)
            }
        }

        if ($errors.Count -gt 0) {
            $report.Add('')
            $report.Add('ERROS')
            $report.Add('-----')
            foreach ($e in $errors) {
                $report.Add($e)
            }
        }

        [System.IO.File]::WriteAllLines(
            $reportPath,
            $report,
            [System.Text.Encoding]::UTF8
        )

        if ($vrtResult.Success) {
            $status.Text = "Concluído.`r`nVRT criado com $($vrtResult.IncludedCount) ortofoto(s): $($vrtResult.VrtName)"
        }
        else {
            $status.Text = "Arquivos processados, mas o VRT não foi criado.`r`n$($vrtResult.Message)"
        }

        $obtainedText = if ($isLocal) {
            "Copiados: $copied"
        } else {
            "Baixados: $downloaded"
        }

        $message = @"
Processo concluído.

Levantamento: $selectedYear
Municípios selecionados: $($selectedMunicipalities.Count)
Blocos únicos: $($blocks.Count)
$obtainedText
Já existentes: $alreadyExists
Erros: $($errors.Count)

Ortofotos existentes no destino: $($vrtResult.SourceCount)
Ortofotos incluídas no VRT: $($vrtResult.IncludedCount)
Mosaico: $($vrtResult.VrtName)
VRT criado: $($vrtResult.Success)

$($vrtResult.Message)

Destino:
$outputDir
"@

        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Processo concluído',
            'OK',
            'Information'
        ) | Out-Null

        if ($chkOpen.Checked) {
            Start-Process explorer.exe -ArgumentList ('"' + $outputDir + '"')
        }
    }
    finally {
        Set-UiBusy $false
    }
})

$form.Add_FormClosed({
    if ($script:HttpClient) {
        try { $script:HttpClient.Dispose() } catch {}
    }
})

[void]$form.ShowDialog()
