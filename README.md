# Ortofoto Downloader ES

**Download e construção de mosaicos virtuais dos mapeamentos capixabas.**

Aplicativo Windows em PowerShell para selecionar municípios do Espírito Santo, identificar os blocos de ortofoto correspondentes, baixar ou copiar os arquivos `.ecw` e gerar automaticamente um mosaico virtual `.vrt`.

## Levantamentos suportados

- 2007–2008 — seis macroblocos.
- 2012–2014 — blocos numerados.
- 2019–2020 — blocos numerados.

## Arquitetura dos mosaicos

O projeto **não armazena VRTs estaduais completos** e não usa Base64/GZip para representar os mosaicos.

Os arquivos `resources/blocos_*.csv` contêm somente a receita espacial necessária para posicionar cada ECW:

```text
ordem,arquivo,xOff,yOff,xSize,ySize
```

Os parâmetros globais de cada levantamento — SRC, GeoTransform, bandas, tipo de dado e demais informações comuns — ficam em `resources/levantamentos.json`.

Quando o usuário conclui o download/cópia, o aplicativo:

1. identifica os `.ecw` existentes na pasta de destino;
2. localiza somente esses arquivos na receita;
3. calcula o envelope do conjunto;
4. recalcula a origem do GeoTransform;
5. escreve um novo VRT do zero, contendo apenas as ortofotos disponíveis.

Assim, o VRT passa a ser **produto da ferramenta**, e não um arquivo-modelo que precisa ser lido e podado.

## Estrutura

```text
.
├── .github/workflows/build-windows.yml
├── build/Gerar_Executavel.ps1
├── docs/
│   ├── AJUDA.md
│   └── ARQUITETURA.md
├── resources/
│   ├── blocos_2007_2008.csv
│   ├── blocos_2012_2014.csv
│   ├── blocos_2019_2020.csv
│   ├── fontes_online.json
│   ├── levantamentos.json
│   ├── municipios_2007_2008.json
│   └── municipios_2012_2019.json
├── src/Ortofoto_Downloader_ES.ps1
├── tests/Validar_Recursos.ps1
├── ABRIR_SEM_COMPILAR.cmd
├── GERAR_EXECUTAVEL.cmd
├── VALIDAR_RECURSOS.cmd
├── VERSION
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## Executar o código-fonte

No Windows, execute `ABRIR_SEM_COMPILAR.cmd`.

Também é possível executar diretamente:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\Ortofoto_Downloader_ES.ps1
```

## Validar os recursos

Execute `VALIDAR_RECURSOS.cmd`. A validação confere os arquivos JSON/CSV e a integridade básica das receitas antes do build.

## Gerar o executável

Execute `GERAR_EXECUTAVEL.cmd`.

O build usa somente componentes nativos do Windows e o compilador C# do .NET Framework. O `.exe` incorpora o script e os arquivos de recurso como **Manifest Resources**. Não há conversão dos VRTs para Base64 e nenhum VRT completo é incorporado.

O executável é criado em:

```text
dist/Ortofoto_Downloader_ES.exe
```

## GitHub Actions

O workflow é exclusivamente manual (`workflow_dispatch`). Por padrão, ele:

1. valida os recursos;
2. compila o executável;
3. disponibiliza o `.exe` como Artifact.

A Release somente é publicada quando a opção **Publicar também a Release desta versão** é marcada explicitamente.

## Dados e fontes

Os endereços de distribuição ficam em `resources/fontes_online.json`. Os vínculos município/bloco ficam separados do código em arquivos JSON, facilitando revisão e manutenção.

## Licença

MIT. Consulte `LICENSE`.
