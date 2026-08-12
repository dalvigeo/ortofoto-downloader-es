#requires -version 5.1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $repoRoot 'VERSION'
$appSource = Join-Path $repoRoot 'src\Ortofoto_Downloader_ES.ps1'
$resourceRoot = Join-Path $repoRoot 'resources'
$distDir = Join-Path $repoRoot 'dist'
$outputFile = Join-Path $distDir 'Ortofoto_Downloader_ES.exe'
$validationScript = Join-Path $repoRoot 'tests\Validar_Recursos.ps1'

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw "VERSION não encontrado: $versionPath" }
if (-not (Test-Path -LiteralPath $appSource -PathType Leaf)) { throw "Código-fonte não encontrado: $appSource" }

$version = [System.IO.File]::ReadAllText($versionPath, [System.Text.Encoding]::UTF8).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION inválida: $version"
}

Write-Host ''
Write-Host "Ortofoto Downloader ES v$version"
Write-Host '========================================'
Write-Host 'Validando recursos...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validationScript
if ($LASTEXITCODE -ne 0) {
    throw "A validação dos recursos retornou o código $LASTEXITCODE."
}

$resourceFiles = @(
    'levantamentos.json',
    'municipios_2007_2008.json',
    'municipios_2012_2019.json',
    'fontes_online.json',
    'blocos_2007_2008.csv',
    'blocos_2012_2014.csv',
    'blocos_2019_2020.csv'
)

foreach ($name in $resourceFiles) {
    $path = Join-Path $resourceRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Recurso não encontrado: $path"
    }
}

if (-not (Test-Path -LiteralPath $distDir -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($distDir)
}

$extractLines = New-Object System.Collections.Generic.List[string]
$resourceArgs = New-Object System.Collections.Generic.List[string]

$appLogicalName = 'OrtofotoDownloaderES.src.Ortofoto_Downloader_ES.ps1'
$resourceArgs.Add("/resource:$appSource,$appLogicalName")
$extractLines.Add('            ExtractResource(assembly, "' + $appLogicalName + '", scriptPath);')

foreach ($name in $resourceFiles) {
    $path = Join-Path $resourceRoot $name
    $logicalName = 'OrtofotoDownloaderES.resources.' + $name
    $resourceArgs.Add("/resource:$path,$logicalName")
    $escapedName = $name.Replace('\', '\\').Replace('"', '\"')
    $extractLines.Add('            ExtractResource(assembly, "' + $logicalName + '", Path.Combine(resourcesDir, "' + $escapedName + '"));')
}

$extractCode = ($extractLines -join "`r`n")

$csharp = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Program
{
    private const string AppVersion = "$version";

    private static void ExtractResource(Assembly assembly, string resourceName, string outputPath)
    {
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        {
            if (input == null)
                throw new InvalidOperationException("Recurso interno não encontrado: " + resourceName);

            string parent = Path.GetDirectoryName(outputPath);
            if (!String.IsNullOrEmpty(parent))
                Directory.CreateDirectory(parent);

            using (FileStream output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
            }
        }
    }

    [STAThread]
    private static void Main()
    {
        string tempRoot = null;

        try
        {
            tempRoot = Path.Combine(
                Path.GetTempPath(),
                "OrtofotoDownloaderES",
                Guid.NewGuid().ToString("N")
            );

            string srcDir = Path.Combine(tempRoot, "src");
            string resourcesDir = Path.Combine(tempRoot, "resources");
            Directory.CreateDirectory(srcDir);
            Directory.CreateDirectory(resourcesDir);

            string scriptPath = Path.Combine(srcDir, "Ortofoto_Downloader_ES.ps1");
            Assembly assembly = Assembly.GetExecutingAssembly();

$extractCode

            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powershell = Path.Combine(
                windows,
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe"
            );

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + scriptPath + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.EnvironmentVariables["ORTOFOTO_RESOURCE_ROOT"] = resourcesDir;
            psi.EnvironmentVariables["ORTOFOTO_APP_VERSION"] = AppVersion;

            using (Process process = Process.Start(psi))
            {
                process.WaitForExit();
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Não foi possível iniciar o Ortofoto Downloader ES.\r\n\r\n" + ex.Message,
                "Ortofoto Downloader ES",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
        }
        finally
        {
            if (!String.IsNullOrEmpty(tempRoot))
            {
                try
                {
                    if (Directory.Exists(tempRoot))
                        Directory.Delete(tempRoot, true);
                }
                catch { }
            }
        }
    }
}
"@

$sourceFile = Join-Path $env:TEMP ("OrtofotoDownloaderES_" + [Guid]::NewGuid().ToString('N') + ".cs")

try {
    [System.IO.File]::WriteAllText(
        $sourceFile,
        $csharp,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $cscCandidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    $csc = $cscCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if (-not $csc) {
        throw 'O compilador C# nativo do .NET Framework não foi localizado.'
    }

    if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
        Remove-Item -LiteralPath $outputFile -Force
    }

    $compilerArgs = @(
        '/nologo',
        '/target:winexe',
        '/platform:x64',
        '/optimize+',
        "/out:$outputFile",
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Windows.Forms.dll'
    )
    $compilerArgs += @($resourceArgs)
    $compilerArgs += $sourceFile

    Write-Host ''
    Write-Host 'Compilando executável nativo...'
    & $csc @compilerArgs

    if ($LASTEXITCODE -ne 0) {
        throw "O compilador C# retornou o código $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) {
        throw 'O executável não foi criado.'
    }

    Write-Host ''
    Write-Host 'Executável criado com sucesso:'
    Write-Host $outputFile
}
finally {
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        Remove-Item -LiteralPath $sourceFile -Force -ErrorAction SilentlyContinue
    }
}
