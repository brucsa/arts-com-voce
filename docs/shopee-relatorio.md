# Módulo "Pedidos da Shopee" · Relatório

Situação: **pronto e testado no ambiente local; ainda não instalado nem publicado.**
Ramo local: `shopee-pedidos`. Base: versão publicada `d02cf9d` (Etapa 3).

## O que o módulo faz

- Tela "Pedidos da Shopee" no menu Operação, abaixo de "Pedidos", só para a Admin.
- Importa a planilha .xlsx exportada pela Shopee, com **prévia** (novos, atualizados, iguais e com erro)
  e **confirmação**. Nada é gravado antes da confirmação.
- Lista com busca (pedido, produto, rastreio), filtros por status e mês, totais e detalhe de cada pedido.

## Regras aprovadas

| Regra | Como foi feito |
|---|---|
| Só consulta | Não cria vendas; não mexe em Caixa, estoque nem comissão do Joca |
| Sem dados pessoais | Só uma lista fechada de colunas é lida; nome, usuário, telefone, CPF, endereço, cidade, bairro, UF, país, CEP e observação do comprador são descartados antes de qualquer gravação |
| Sem estimativas | Valor ausente = "Não informado". O líquido não existe na planilha e aparece sempre como "Não informado" |
| Cancelados | Status e valores exatamente como vêm na planilha |
| Sem duplicação | Pedido identificado pelo "ID do pedido". Item identificado por pedido + produto + variação + SKU + ocorrência (o SKU costuma vir vazio) |
| Reimportação segura | Tudo ou nada; itens nunca são apagados. Se os itens de um pedido registrado não baterem com a planilha (ex.: nome do produto mudou na Shopee), os registrados ficam como estão e o pedido recebe o selo "Conferir itens" |
| "Número de produtos pedidos" | Só informativo; nunca usado para recusar pedidos |
| "Desconto do vendedor" (coluna repetida) | As duas colunas guardadas separadas, sem somar. Se o valor mudar entre itens do mesmo pedido, no pedido fica "Não informado" e o de cada item fica no item |
| Valores exatos | Lidos como texto ("79.50") e gravados como número exato; somas em centavos inteiros |
| Arquivo duvidoso | Recusado com explicação; nada é importado |
| Acesso | Só a Admin lê e importa; gravação só pela função protegida; auditoria em todas as tabelas |

## Testes no ambiente local (dados de teste inventados + a planilha real da Shopee)

| Conjunto | Resultado |
|---|---|
| Fluxo completo (importar, reimportar, atualizar, erro em linha, nome de produto alterado, coluna ausente, falha no meio da gravação, planilha real, filtros, celular, Joca) | 47/47 OK |
| Arquivos inválidos e formatos inesperados (texto renomeado, arquivo cortado, vazio, protegido, .csv, .xls, só cabeçalho, outra planilha, colunas diferentes, coluna essencial ausente, milhar ambíguo, data inexistente, quantidade fracionada, aba com outro nome) | 16/16 OK; banco sem nenhuma mudança |
| Verificação do módulo (`sql/shopee_verificacao.sql`) | 10/10 OK |
| Verificação geral (`sql/02_verificacao.sql`) com o módulo instalado | 24/24 OK |
| Retrato: antes × depois da instalação | Iguais em A–I e no resumo; só o bloco N (objetos novos) aparece |
| Retrato: depois de importar pedidos | A–I e resumo continuam iguais |
| Retrato: antes da instalação × depois da desinstalação | Idênticos |
| Retrato detecta mudança | 13 alterações propositais detectadas: registro, gatilho desligado, gatilho novo, valor padrão de coluna, permissão de tabela, RLS forçado, regra de acesso, permissão e "security definer" de função, opção de view, novo valor de tipo, índice novo, contador |
| Retrato: Storage (testado com buckets e arquivos de teste locais) | Detecta mudança nos metadados de um arquivo, na configuração de um bucket, arquivo renomeado e bucket/arquivo novo; ignora só a data de último acesso; ciclo instalar → importar → desinstalar idêntico com Storage presente |
| Testes antigos da Etapa 1 e da Etapa 2, com o módulo instalado | 25/25 e 22/22 OK |

## Limitações conhecidas

1. **Teste antigo da Etapa 3 (limitação anterior ao módulo).** O teste automático da Etapa 3 depende de
   dados de preparação que não foram reproduzidos neste ambiente e para no mesmo ponto **com e sem** o
   módulo (conferido rodando o código original, sem nenhuma mudança). Não há relação identificada com o
   módulo da Shopee. A especificação oficial não foi alterada.
2. **Valor líquido:** a planilha de pedidos da Shopee não traz esse valor; aparece "Não informado".
3. **Pedidos com vários produtos e "Desconto do vendedor":** a planilha real recebida tinha só 1 pedido com
   1 produto e desconto zero. As regras acima são seguras, mas vale conferir o primeiro pedido real com
   2+ produtos ou com desconto do vendedor.
4. **Datas** são lidas no horário de Brasília, como a Shopee exporta.
