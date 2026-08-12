# Ajuda — Ortofoto Downloader ES

O Ortofoto Downloader ES permite selecionar um ou mais municípios e reunir, em uma pasta única por levantamento, as ortofotos necessárias para a área escolhida.

## Uso básico

1. Escolha o levantamento: `2007_2008`, `2012_2014` ou `2019_2020`.
2. Pesquise e marque os municípios desejados.
3. Escolha o modo:
   - **Baixar das fontes online (recomendado)**; ou
   - **Copiar de acervo local (.ecw)**.
4. Informe a pasta de armazenamento.
5. Execute a operação.

A seleção de municípios é cumulativa. Blocos compartilhados por dois ou mais municípios são processados apenas uma vez.

## Armazenamento

Cada levantamento utiliza uma pasta própria, por exemplo:

```text
ORTOFOTOS_2012_2014_selec
```

Arquivos `.ecw` que já existem no destino são preservados e não são transferidos novamente. Isso permite ampliar o acervo em execuções posteriores.

## Mosaico virtual VRT

Ao final, a ferramenta cria automaticamente:

- `ortomosaico_2007_2008.vrt`
- `ortomosaico_2012_2014.vrt`
- `ortomosaico_2019_2020.vrt`

O mosaico é construído somente com os `.ecw` encontrados na pasta de destino.

A posição de cada ortofoto não é inferida pelo nome do arquivo. Ela é obtida da receita espacial versionada junto ao aplicativo. A receita contém os offsets e dimensões originalmente extraídos dos mosaicos estaduais de referência.

## Modo online

Para 2012–2014 e 2019–2020, o aplicativo utiliza URLs-base configuráveis. O botão **Configurar fontes...** permite alterar esses endereços caso a distribuição oficial seja modificada.

Para 2007–2008, os seis macroblocos usam links individuais.

## Modo acervo local

Selecione uma pasta que contenha os arquivos `.ecw`. A ferramenta copia apenas os blocos necessários e informa no relatório qualquer arquivo que não tenha sido encontrado.

## Relatório

Após a execução é gerado `_RELATORIO_ORTOFOTOS.txt`, contendo municípios selecionados, blocos solicitados, arquivos transferidos, arquivos já existentes, falhas e resultado da geração do VRT.

## Observação

O VRT é um mosaico virtual: ele referencia os arquivos `.ecw` e não duplica os dados raster. Mantenha o `.vrt` na mesma pasta dos ECWs correspondentes.
