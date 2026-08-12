#requires -version 5.1

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $repoRoot 'VERSION'
$appSource = Join-Path $repoRoot 'src\Ortofoto_Downloader_ES.ps1'
$resourceRoot = Join-Path $repoRoot 'resources'
$distDir = Join-Path $repoRoot 'dist'
$outputFile = Join-Path $distDir 'Ortofoto_Downloader_ES.exe'
$validationScript = Join-Path $repoRoot 'tests\Validar_Recursos.ps1'

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "VERSION não encontrado: $versionPath"
}

if (-not (Test-Path -LiteralPath $appSource -PathType Leaf)) {
    throw "Código-fonte não encontrado: $appSource"
}

if (-not (Test-Path -LiteralPath $validationScript -PathType Leaf)) {
    throw "Script de validação não encontrado: $validationScript"
}

$version = [System.IO.File]::ReadAllText(
    $versionPath,
    [System.Text.Encoding]::UTF8
).Trim()

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION inválida: $version"
}

Write-Host ''
Write-Host "Ortofoto Downloader ES v$version"
Write-Host '========================================'
Write-Host 'Validando recursos...'

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $validationScript

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

# Localiza a biblioteca do Windows PowerShell instalada no sistema.
$automationAssembly = [System.Management.Automation.PowerShell].Assembly.Location

if (
    -not $automationAssembly -or
    -not (Test-Path -LiteralPath $automationAssembly -PathType Leaf)
) {
    throw 'System.Management.Automation.dll não foi localizada.'
}

Write-Host ''
Write-Host 'PowerShell host:'
Write-Host $automationAssembly

# Recursos incorporados ao executável.
$resourceArgs = New-Object System.Collections.Generic.List[string]
$extractLines = New-Object System.Collections.Generic.List[string]

$appLogicalName = 'OrtofotoDownloaderES.src.Ortofoto_Downloader_ES.ps1'

$resourceArgs.Add(
    "/resource:$appSource,$appLogicalName"
)

foreach ($name in $resourceFiles) {

    $path = Join-Path $resourceRoot $name
    $logicalName = 'OrtofotoDownloaderES.resources.' + $name

    $resourceArgs.Add(
        "/resource:$path,$logicalName"
    )

    $escapedName = $name.Replace('\', '\\').Replace('"', '\"')

    $extractLines.Add(
        '            ExtractResource(' +
        'assembly, "' +
        $logicalName +
        '", Path.Combine(resourcesDir, "' +
        $escapedName +
        '"));'
    )
}

$extractCode = $extractLines -join "`r`n"

$csharp = @"
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    private const string AppVersion = "$version";

    private const string ScriptResourceName =
        "$appLogicalName";

    private static void ExtractResource(
        Assembly assembly,
        string resourceName,
        string outputPath
    )
    {
        using (
            Stream input =
                assembly.GetManifestResourceStream(resourceName)
        )
        {
            if (input == null)
            {
                throw new InvalidOperationException(
                    "Recurso interno não encontrado: " +
                    resourceName
                );
            }

            string parent =
                Path.GetDirectoryName(outputPath);

            if (!String.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            using (
                FileStream output =
                    new FileStream(
                        outputPath,
                        FileMode.Create,
                        FileAccess.Write,
                        FileShare.None
                    )
            )
            {
                input.CopyTo(output);
            }
        }
    }

    private static string ReadTextResource(
        Assembly assembly,
        string resourceName
    )
    {
        using (
            Stream input =
                assembly.GetManifestResourceStream(resourceName)
        )
        {
            if (input == null)
            {
                throw new InvalidOperationException(
                    "Recurso interno não encontrado: " +
                    resourceName
                );
            }

            using (
                StreamReader reader =
                    new StreamReader(
                        input,
                        Encoding.UTF8,
                        true
                    )
            )
            {
                return reader.ReadToEnd();
            }
        }
    }

    private static string GetPowerShellErrors(
        PowerShell powerShell
    )
    {
        if (
            powerShell == null ||
            powerShell.Streams == null ||
            powerShell.Streams.Error == null ||
            powerShell.Streams.Error.Count == 0
        )
        {
            return "Erro não detalhado pelo mecanismo PowerShell.";
        }

        StringBuilder builder = new StringBuilder();

        foreach (
            ErrorRecord error in
            powerShell.Streams.Error
        )
        {
            if (builder.Length > 0)
            {
                builder.AppendLine();
                builder.AppendLine();
            }

            builder.Append(error.ToString());

            if (error.InvocationInfo != null)
            {
                string position =
                    error.InvocationInfo.PositionMessage;

                if (!String.IsNullOrWhiteSpace(position))
                {
                    builder.AppendLine();
                    builder.Append(position);
                }
            }
        }

        return builder.ToString();
    }

    [STAThread]
    private static void Main()
    {
        string tempRoot = null;

        string previousResourceRoot =
            Environment.GetEnvironmentVariable(
                "ORTOFOTO_RESOURCE_ROOT"
            );

        string previousAppVersion =
            Environment.GetEnvironmentVariable(
                "ORTOFOTO_APP_VERSION"
            );

        try
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            tempRoot = Path.Combine(
                Path.GetTempPath(),
                "OrtofotoDownloaderES",
                Guid.NewGuid().ToString("N")
            );

            string resourcesDir =
                Path.Combine(
                    tempRoot,
                    "resources"
                );

            Directory.CreateDirectory(resourcesDir);

            Assembly assembly =
                Assembly.GetExecutingAssembly();

$extractCode

            string scriptText =
                ReadTextResource(
                    assembly,
                    ScriptResourceName
                );

            Environment.SetEnvironmentVariable(
                "ORTOFOTO_RESOURCE_ROOT",
                resourcesDir
            );

            Environment.SetEnvironmentVariable(
                "ORTOFOTO_APP_VERSION",
                AppVersion
            );

            InitialSessionState sessionState =
                InitialSessionState.CreateDefault();

            using (
                Runspace runspace =
                    RunspaceFactory.CreateRunspace(
                        sessionState
                    )
            )
            {
                runspace.ApartmentState =
                    ApartmentState.STA;

                runspace.ThreadOptions =
                    PSThreadOptions.UseCurrentThread;

                runspace.Open();

                using (
                    PowerShell powerShell =
                        PowerShell.Create()
                )
                {
                    powerShell.Runspace = runspace;

                    powerShell.AddScript(
                        scriptText,
                        false
                    );

                    powerShell.Invoke();

                    if (powerShell.HadErrors)
                    {
                        throw new InvalidOperationException(
                            "O aplicativo encontrou um erro " +
                            "durante a execução." +
                            Environment.NewLine +
                            Environment.NewLine +
                            GetPowerShellErrors(powerShell)
                        );
                    }
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Não foi possível iniciar o " +
                "Ortofoto Downloader ES." +
                Environment.NewLine +
                Environment.NewLine +
                ex.Message,
                "Ortofoto Downloader ES",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
        }
        finally
        {
            Environment.SetEnvironmentVariable(
                "ORTOFOTO_RESOURCE_ROOT",
                previousResourceRoot
            );

            Environment.SetEnvironmentVariable(
                "ORTOFOTO_APP_VERSION",
                previousAppVersion
            );

            if (!String.IsNullOrEmpty(tempRoot))
            {
                try
                {
                    if (Directory.Exists(tempRoot))
                    {
                        Directory.Delete(
                            tempRoot,
                            true
                        );
                    }
                }
                catch
                {
                    // A limpeza da pasta temporária não
                    // deve impedir o encerramento.
                }
            }
        }
    }
}
"@

$sourceFile = Join-Path `
    $env:TEMP `
    (
        'OrtofotoDownloaderES_' +
        [Guid]::NewGuid().ToString('N') +
        '.cs'
    )

try {

    [System.IO.File]::WriteAllText(
        $sourceFile,
        $csharp,
        (
            New-Object `
                System.Text.UTF8Encoding($false)
        )
    )

    $cscCandidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    $csc = $cscCandidates |
        Where-Object {
            Test-Path `
                -LiteralPath $_ `
                -PathType Leaf
        } |
        Select-Object -First 1

    if (-not $csc) {
        throw (
            'O compilador C# nativo do ' +
            '.NET Framework não foi localizado.'
        )
    }

    if (
        Test-Path `
            -LiteralPath $outputFile `
            -PathType Leaf
    ) {
        Remove-Item `
            -LiteralPath $outputFile `
            -Force
    }

    $compilerArgs = @(
        '/nologo',
        '/target:winexe',
        '/platform:x64',
        '/optimize+',
        "/out:$outputFile",
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Windows.Forms.dll',
        "/reference:$automationAssembly"
    )

    $compilerArgs += @($resourceArgs)
    $compilerArgs += $sourceFile

    Write-Host ''
    Write-Host 'Compilando executável com PowerShell incorporado...'

    & $csc @compilerArgs

    if ($LASTEXITCODE -ne 0) {
        throw (
            "O compilador C# retornou o código " +
            "$LASTEXITCODE."
        )
    }

    if (
        -not (
            Test-Path `
                -LiteralPath $outputFile `
                -PathType Leaf
        )
    ) {
        throw 'O executável não foi criado.'
    }

    $hash = Get-FileHash `
        -LiteralPath $outputFile `
        -Algorithm SHA256

    Write-Host ''
    Write-Host 'Executável criado com sucesso:'
    Write-Host $outputFile

    Write-Host ''
    Write-Host 'SHA-256:'
    Write-Host $hash.Hash
}
finally {

    if (
        Test-Path `
            -LiteralPath $sourceFile `
            -PathType Leaf
    ) {
        Remove-Item `
            -LiteralPath $sourceFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
