// Mapa de telas do sistema (Especificação v1.1, seção "Telas e navegação").
// "etapa" indica em qual etapa de desenvolvimento a tela fica pronta.

export const GRUPOS = [
  {
    nome: 'Visão geral',
    telas: [
      { rota: 'inicio', titulo: 'Início', icone: 'ti-home', etapa: 10,
        itens: ['Resultado do período', 'Dinheiro: caixa e a receber', 'Custos, taxas e despesas', 'Canais e Joca', 'Alertas'] },
    ],
  },
  {
    nome: 'Operação',
    telas: [
      { rota: 'vendas', titulo: 'Vendas', icone: 'ti-receipt', etapa: 6,
        itens: ['Lista com filtros por período, canal e status', 'Nova venda com lucro previsto ao vivo', 'Itens do catálogo ou personalizados'] },
      { rota: 'pedidos', titulo: 'Pedidos', icone: 'ti-truck-delivery', etapa: 6,
        itens: ['Quadro por status do pedido', 'Vínculo com produção por item', 'Embalagens em Pronto para envio'] },
      // Módulo independente (sem etapa): só consulta, não mexe em vendas, Caixa, estoque nem comissão.
      { rota: 'shopee', titulo: 'Pedidos da Shopee', icone: 'ti-brand-shopee', modulo: true,
        itens: ['Importar a planilha da Shopee com prévia', 'Status, rastreio, valores e taxas', 'Sem duplicar pedidos'] },
      { rota: 'producao', titulo: 'Produção', icone: 'ti-printer', etapa: 5,
        itens: ['Produção OK ou falha', 'Consumo por material, cor e purga', 'Peças prontas e perdas com motivo'] },
      { rota: 'produtos', titulo: 'Produtos', icone: 'ti-box', etapa: 4,
        itens: ['Catálogo com foto', 'Ficha técnica de materiais e embalagem', 'Custo, margem e lucro por canal'] },
      { rota: 'estoque', titulo: 'Estoque', icone: 'ti-stack-2', etapa: 3,
        itens: ['Filamentos e embalagens com custo médio', 'Alerta de estoque baixo', 'Peças prontas e histórico de movimentos'] },
    ],
  },
  {
    nome: 'Dinheiro',
    telas: [
      { rota: 'gastos', titulo: 'Gastos e compras', icone: 'ti-shopping-cart', etapa: 2,
        itens: ['Despesa, estoque ou investimento', 'Comprovante', 'Compra de estoque gera entrada de material'] },
      { rota: 'caixa', titulo: 'Caixa', icone: 'ti-wallet', etapa: 2,
        itens: ['Saldo e extrato', 'Aporte e retirada', 'A receber (Etapa 7)'] },
    ],
  },
  {
    nome: 'Pessoas',
    telas: [
      { rota: 'joca', titulo: 'Joca ⭐', icone: 'ti-star', etapa: 8,
        itens: ['Percentual atual', 'A receber, disponível e pago', 'Comissões, estornos e pagamentos'] },
    ],
  },
  {
    nome: 'Análise',
    telas: [
      { rota: 'canais', titulo: 'Canais', icone: 'ti-chart-bar', etapa: 11,
        itens: ['Shopee, Mercado Livre e Boca a Boca lado a lado', 'Lucro real e margem por canal'] },
      { rota: 'relatorios', titulo: 'Relatórios', icone: 'ti-report-analytics', etapa: 11,
        itens: ['Vendas, gastos e lucro por período', 'Produtos mais vendidos e lucrativos', 'Perdas por motivo'] },
      { rota: 'fechamento', titulo: 'Fechamento mensal', icone: 'ti-calendar-check', etapa: 12,
        itens: ['Cascata do resultado', 'Checklist antes de fechar', 'Fechar e reabrir mês'] },
    ],
  },
  {
    nome: 'Sistema',
    telas: [
      { rota: 'configuracoes', titulo: 'Configurações', icone: 'ti-settings', etapa: 1,
        itens: ['Percentual do Joca', 'Impressora e tarifa de energia', 'Canais, categorias e materiais'] },
    ],
  },
];

// Todas as telas continuam aqui e abrem pelo endereço (#/rota), mesmo as que
// não aparecem no menu do Essencial.
export const TELAS = Object.fromEntries(GRUPOS.flatMap(g => g.telas).map(t => [t.rota, t]));

// ---- Arts com Você Essencial (E1): navegação com três áreas ----------------
// Tela aberta ao entrar e quando o endereço não existe.
export const ROTA_INICIAL = 'pedidos';
// Menu principal (no celular, aparece dentro de "Mais"; a barra inferior não muda).
export const MENU_PRINCIPAL = ['pedidos', 'produtos', 'caixa', 'joca'];
// Grupo "Mais": telas prontas que ficam fora do menu principal.
export const MENU_MAIS = ['gastos', 'estoque', 'configuracoes'];
// As demais telas (Início, Vendas, Produção, Canais, Relatórios,
// Fechamento e Pedidos da Shopee como tela própria) ficam fora do menu, mas
// continuam abrindo pelo endereço. A Shopee aparece na aba Shopee de Pedidos.

// Barra inferior do celular (Admin).
export const BARRA_INFERIOR = [
  { rota: 'pedidos', titulo: 'Pedidos', icone: 'ti-truck-delivery' },
  { rota: 'caixa', titulo: 'Caixa', icone: 'ti-wallet' },
  { acao: 'atalhos', titulo: 'Novo', icone: 'ti-plus', destaque: true },
  { rota: 'joca', titulo: 'Joca ⭐', icone: 'ti-star' },
  { acao: 'menu', titulo: 'Mais', icone: 'ti-menu-2' },
];

// Atalhos do botão ＋. Abrem os formulários existentes, sem mudar de tela.
export const ATALHOS = [
  { acao: 'novo-pedido', titulo: 'Novo pedido', icone: 'ti-clipboard-plus' },
  { acao: 'novo-gasto', titulo: 'Novo gasto', icone: 'ti-shopping-cart' },
  { acao: 'nova-compra', titulo: 'Nova compra de material', icone: 'ti-package' },
];

// Ordem de desenvolvimento (Especificação v1.1).
export const ETAPAS = [
  'Fundação', 'Configurações', 'Caixa e gastos', 'Estoque de materiais', 'Produtos',
  'Produção', 'Vendas e pedidos', 'Recebimentos', 'Joca ⭐', 'Cancelamentos e devoluções',
  'Dashboard', 'Canais e relatórios', 'Fechamento mensal', 'Exportação e polimento',
];
export const ETAPA_ATUAL = 3;
// Como a etapa atual aparece no Início: 'Em planejamento' até o escopo ser aprovado,
// depois 'Em andamento'.
export const ETAPA_ATUAL_ROTULO = 'Em andamento';
