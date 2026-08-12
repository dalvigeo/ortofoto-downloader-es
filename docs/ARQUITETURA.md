# Arquitetura do mosaico virtual

## Princípio

As ortofotos ECW já possuem os pixels; o aplicativo precisa apenas saber **onde cada bloco ocupa o mosaico**. Por isso o repositório guarda a receita espacial e reconstrói o VRT sob demanda.

## Dados globais

`resources/levantamentos.json` armazena informações comuns a todos os blocos de um levantamento:

- SRS/WKT;
- GeoTransform do mosaico estadual de referência;
- número de bandas;
- interpretação de cor;
- tipo de dado;
- tamanho de bloco;
- nome do VRT de saída;
- arquivo de receita.

## Receita por bloco

Cada CSV contém:

```text
ordem,arquivo,xOff,yOff,xSize,ySize
```

`xOff` e `yOff` são as posições do bloco no sistema de pixels do mosaico estadual. `xSize` e `ySize` são suas dimensões em pixels.

A coluna `ordem` preserva a ordem original dos `SimpleSource` do VRT de referência.

## Construção

Para os ECWs existentes no destino:

```text
minX = menor xOff
minY = menor yOff
maxX = maior (xOff + xSize)
maxY = maior (yOff + ySize)
```

As dimensões do VRT resultante são calculadas a partir desse envelope.

A nova origem geográfica é obtida pelo GeoTransform original:

```text
newGT0 = GT0 + minX*GT1 + minY*GT2
newGT3 = GT3 + minX*GT4 + minY*GT5
```

Cada bloco passa a ser gravado com:

```text
novo xOff = xOff original - minX
novo yOff = yOff original - minY
```

O aplicativo então cria `VRTDataset`, `SRS`, `GeoTransform`, as bandas e os respectivos `SimpleSource`, `SourceFilename`, `SourceBand`, `SourceProperties`, `SrcRect` e `DstRect`.

## Empacotamento

O build não transforma os dados espaciais em Base64. O compilador C# incorpora o `.ps1` e os JSON/CSV diretamente como Manifest Resources do executável. Na inicialização, esses arquivos são extraídos para uma pasta temporária, utilizados pelo PowerShell e removidos ao encerrar.
