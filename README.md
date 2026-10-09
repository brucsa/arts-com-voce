# Arts com Você · Sistema de Gestão

Sistema web de vendas, produção, estoque e financeiro da Arts com Você.
Regras oficiais: **Especificação Oficial v1.1** (documento do projeto).

**Situação:** Etapa 0, Fundação: concluída ✅ (07/10/2026). Etapa 1, Configurações: concluída ✅ (07/10/2026). Etapa 2, Caixa e gastos: concluída ✅ (07/10/2026). Etapa 3, Estoque de materiais: em andamento.

Publicado em https://brucsa.github.io/arts-com-voce/

## Estrutura

```
index.html              Página única do sistema
css/app.css             Identidade visual e layout (celular e computador)
img/flor.png            Flor da Arts com Você (cabeçalho e login)
img/favicon*, apple-touch-icon.png   Ícones da aba e da tela inicial do celular
js/config.js            URL e chave pública do Supabase  ← você preenche
js/supabase.js          Conexão com o Supabase
js/app.js               Login, perfis, layout e navegação
js/menu.js              Mapa de telas, barra inferior, atalhos e etapas
js/format.js            R$, datas brasileiras, fuso de São Paulo
js/db.js                Mensagens de erro do banco em português
js/ui/formulario.js     Formulários em folha (celular e computador)
js/ui/dialogo.js        Fechar folhas só ao clicar fora delas
js/financeiro.js        Formas de pagamento, situações e meses
js/estoque-util.js      Quantidades, custo médio e rateio de frete/desconto
js/telas/               Uma tela por arquivo
sql/00_fundacao.sql     Banco: perfis, papéis, auditoria, segurança
sql/01_usuarios.sql     Liga as contas da Bruna e do Joca aos perfis
sql/02_verificacao.sql  Confere a segurança do banco (só leitura)
sql/03_configuracoes.sql  Etapa 1: parâmetros, canais, categorias, materiais
sql/04_caixa_gastos.sql   Etapa 2: gastos, pagamentos, caixa, aporte, retirada, estornos
sql/05_estoque.sql        Etapa 3: compras de estoque, estoque inicial, saldo e custo médio
sql/manutencao/           Scripts únicos de manutenção (não fazem parte da instalação normal)
```

## Como colocar no ar (uma vez)

### 1. Criar o projeto no Supabase
1. Em supabase.com, crie um projeto novo (por exemplo, `arts-com-voce`).
   Região sugerida: São Paulo (`sa-east-1`).
2. Guarde a senha do banco em um lugar seguro.

### 2. Criar o banco
1. Supabase → **SQL Editor** → New query.
2. Cole o conteúdo de `sql/00_fundacao.sql` → **Run**.

### 3. Fechar o cadastro público
Supabase → **Authentication → Sign In / Providers** (ou Settings):
desative **Allow new users to sign up**. Só você cria contas.

### 4. Criar as duas contas
1. **Authentication → Users → Add user → Create new user**.
2. Crie a sua conta (e-mail + senha) com **Auto Confirm User** marcado.
3. Crie a conta do Joca. Pode ser um alias do seu e-mail, como `seuemail+joca@gmail.com`.
4. Abra `sql/01_usuarios.sql`, troque os dois e-mails e rode no SQL Editor.
   A conferência no fim deve mostrar Bruna = ADMIN e Joca = JOCA.

### 5. Conferir o banco
Rode `sql/02_verificacao.sql` no SQL Editor. As 12 linhas devem mostrar **OK**.
Esse script só consulta, então pode ser rodado sempre que quiser conferir a segurança.

### 6. Ligar o site ao banco
No Supabase, botão **Connect** no topo do projeto (ou **Project Settings → API Keys**).
Copie para `js/config.js`:
- **Project URL** → `SUPABASE_URL`
- **Publishable key** (`sb_publishable_…`) → `SUPABASE_ANON_KEY`
  (projetos antigos mostram a **anon public** key, que começa com `eyJ`; ela também serve)

Nunca use a **Secret key** (`sb_secret_…`) nem a `service_role`. Se uma delas for colada,
o sistema se recusa a abrir e mostra um aviso.

### 7. Publicar no GitHub Pages
1. Crie um repositório (pode ser privado se sua conta permitir Pages privado; senão, público).
   O código não contém segredos: a proteção dos dados está no banco.
2. Envie todos os arquivos desta pasta, incluindo `.nojekyll`.
3. Repositório → **Settings → Pages** → Source: `Deploy from a branch` → `main` / `root`.
4. Em Supabase → **Authentication → URL Configuration**, coloque o endereço do Pages em **Site URL**.

## Roteiro de validação da Etapa 0 (ambiente real)

| # | Teste | Como fazer | Resultado esperado |
|---|---|---|---|
| 1 | Login da Admin | Entrar com a conta da Bruna | Abre o Início com menu completo e "Olá, Bruna" |
| 2 | Login do Joca | Entrar com a conta do Joca (outra aba anônima) | Abre direto "Olá, Joca ⭐", sem menu |
| 3 | Sessão mantida | Atualizar a página (F5) nas duas contas | Continua logado, na mesma tela |
| 4 | Sair | Botão Sair | Volta para a tela de login; atualizar não reabre a sessão |
| 5 | Permissão da Admin | Navegar por todas as telas do menu | Todas abrem; nenhum erro |
| 6 | Joca direto na área dele | Logar como Joca | Endereço termina em `#/meu` |
| 7 | Joca forçando rota | Logado como Joca, digitar `…/#/configuracoes` | Volta para `#/meu`, sem mostrar nada administrativo |
| 8 | Computador | Testes 1–7 no navegador do computador | Menu lateral, botão "+ Novo" no topo |
| 9 | Celular | Testes 1–7 no celular | Barra inferior; ＋ e "Mais" abrem as folhas; sem rolagem lateral |
| 10 | Publicado com Supabase real | Testes acima no endereço do GitHub Pages | Tudo funciona sem a faixa "Modo demonstração" |

Extra de segurança: senha errada mostra "E-mail ou senha incorretos." e não entra.

## Ver sem configurar
Abra o `index.html` por um servidor local (por exemplo, a extensão Live Server do VS Code).
Sem `config.js` preenchido, o sistema abre em **modo demonstração**: só visual, nada é salvo.
Use `?demo=joca` no endereço para ver a tela do Joca.

## Segurança aplicada na Etapa 0
- Visitante não logado não acessa nenhuma tabela nem função.
- Cada pessoa lê só o próprio perfil; a Admin lê todos.
- Ninguém cria ou apaga perfis pelo site, só pelo SQL Editor.
- O Joca não consegue mudar o próprio papel.
- A Admin não consegue se desativar ou tirar o próprio acesso por engano.
- Toda alteração de perfil fica registrada na auditoria (antes, depois, quem e quando).
- O Joca só enxerga a área dele; qualquer outro endereço volta para ela.

## Padrões para as próximas etapas
- Toda tabela nova: `created_at`, `created_by default auth.uid()`, `updated_at`,
  gatilho `tg_updated_at`, gatilho `tg_auditoria`, RLS ligado.
- Dinheiro sempre em `numeric(12,2)`.
- Nada financeiro é apagado: cancelar ou estornar.

## Módulo "Pedidos da Shopee" (consulta)

Importa a planilha que a Shopee exporta (Meus Pedidos › Exportar) para acompanhar pedidos,
valores, descontos, taxas, status e rastreio. **Só consulta:** não cria vendas e não mexe no
Caixa, no estoque nem na comissão do Joca. Não guarda dados pessoais do comprador. Só a Admin vê.
Relatório completo (regras, testes e limitações): `docs/shopee-relatorio.md`.

Arquivos: `sql/shopee_pedidos.sql` (instalação), `sql/shopee_verificacao.sql` (conferência),
`sql/manutencao/shopee_retrato.sql` (retrato só de leitura), `sql/manutencao/shopee_desinstalar.sql`,
`js/planilha-xlsx.js`, `js/shopee-planilha.js`, `js/telas/shopee.js`.

Instalação (uma vez, só com autorização):
1. SQL Editor → rodar `sql/manutencao/shopee_retrato.sql` e salvar o resultado (Export → CSV).
2. Rodar `sql/shopee_pedidos.sql` (tudo ou nada).
3. Rodar `sql/shopee_verificacao.sql` (10 linhas OK) e `sql/02_verificacao.sql` (24 linhas OK).
4. Rodar o retrato de novo: tudo igual ao passo 1, exceto o bloco "N. Objetos novos".

Desinstalação (só com autorização): `sql/manutencao/shopee_desinstalar.sql` remove apenas as
3 tabelas e a função do módulo. Depois dela, o retrato volta a ser igual ao do passo 1.
