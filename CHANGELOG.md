# Changelog

## 1.1.0

Reestruturação limpa do projeto com base na interface RC2 aprovada.

### Alterado

- VRTs estaduais completos removidos do código-fonte.
- Removidos Base64, GZip e fragmentação dos modelos VRT.
- Criadas receitas espaciais compactas em CSV, uma linha por bloco.
- Parâmetros globais dos levantamentos movidos para `resources/levantamentos.json`.
- Construção do VRT reescrita para gerar o XML do zero somente com os ECW existentes.
- Relações município/bloco movidas para arquivos JSON.
- Fontes online movidas para arquivo de configuração versionado.
- Build Windows passa a incorporar código e recursos como Manifest Resources.
- Workflow do GitHub Actions permanece exclusivamente manual.
- Mantidos os comportamentos funcionais e a organização visual da RC2 aprovada.

### Validação das receitas

- 2007–2008: 6 blocos.
- 2012–2014: 547 blocos.
- 2019–2020: 541 blocos.
