# Recursos

Esta pasta contém os dados versionados usados pela aplicação.

## Receitas espaciais

Os arquivos `blocos_*.csv` foram extraídos dos três VRTs de referência utilizados na RC2 aprovada:

- 2007–2008: 6 blocos;
- 2012–2014: 547 blocos;
- 2019–2020: 541 blocos.

Cada linha preserva a ordem do `SimpleSource`, o nome do ECW, os offsets no mosaico estadual e as dimensões do bloco.

Os VRTs completos não fazem parte do repositório.

## Municípios

`municipios_2007_2008.json` contém a associação entre municípios e macroblocos do levantamento 2007–2008.

`municipios_2012_2019.json` contém a associação utilizada pelos levantamentos 2012–2014 e 2019–2020.

## Fontes online

`fontes_online.json` mantém as URLs-base dos levantamentos 2012–2014 e 2019–2020 e os links individuais dos seis macroblocos 2007–2008.

## Parâmetros globais

`levantamentos.json` contém SRS/WKT, GeoTransform, bandas, interpretação de cor, tipo de dado e demais parâmetros necessários para gerar o VRT.
