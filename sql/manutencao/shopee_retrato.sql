-- =====================================================================
-- Arts com Você · Retrato de integridade (módulo "Pedidos da Shopee")
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- A primeira linha só fixa o fuso DESTA conexão em UTC, para que datas
-- sejam escritas sempre do mesmo jeito; ela não muda nenhum dado.
--
-- Como usar:
--   1. Rodar ANTES de instalar o módulo e salvar o resultado (Export → CSV).
--   2. Instalar sql/shopee_pedidos.sql, sem usar o sistema entre os passos.
--   3. Rodar DE NOVO e comparar com o primeiro.
--
-- Precisa ser IGUAL antes e depois: todas as linhas de A a I e o resumo Z.
-- Pode mudar: só o bloco N (objetos novos do módulo) e o cabeçalho 0.
--
-- O QUE O RETRATO VERIFICA (esquema public = tabelas do sistema; Storage):
--   A. Conteúdo de cada tabela: quantidade e impressão digital (md5) de
--      todas as colunas de todos os registros.
--   B. Estrutura de cada tabela: colunas (nome, tipo, obrigatória, valor
--      padrão), restrições, índices, dono, RLS ligado/forçado e permissões
--      completas de todos os papéis.
--   C. Funções: definição completa (inclui "security definer" e
--      configurações), dono e permissões completas.
--   D. Regras de acesso (RLS): nome, comando, papéis e condições de cada uma.
--   E. Gatilhos: definição completa e se está ativo.
--   F. Views: definição, opções (security_invoker), dono e permissões.
--   G. Contadores automáticos: definição e último valor.
--   H. Tipos (listas fixas, como formas de pagamento): nome e valores.
--   I. Storage: configuração de cada bucket e, de cada arquivo, nome,
--      bucket, tamanho/tipo/versão (metadados), dono, datas de criação e
--      atualização.
--
-- EXCLUSÕES (e por quê):
--   1. Objetos do próprio módulo (tabelas shopee_*, a função
--      importar_pedidos_shopee e os gatilhos, regras e índices delas):
--      são exatamente o que a instalação cria. Aparecem no bloco N.
--   2. Registros da auditoria sobre as tabelas shopee_*: só existem
--      porque o módulo foi usado. Todos os OUTROS registros da auditoria
--      são comparados no bloco A.
--   3. O contador da auditoria (auditoria_id_seq): avança junto com os
--      registros do item 2. O conteúdo da auditoria já é comparado em A.
--   4. A data de "último acesso" dos arquivos do Storage
--      (last_accessed_at): muda só porque alguém abriu ou baixou o
--      arquivo, sem nenhuma alteração nele.
--
-- O QUE O RETRATO NÃO VERIFICA:
--   · Esquemas internos do Supabase (auth, realtime, extensões etc.): são
--     mantidos pelo próprio Supabase e mudam sozinhos (por exemplo, a data
--     do último login). O módulo não toca neles. Os perfis do sistema
--     (tabela public.perfis) são comparados no bloco A.
--   · O conteúdo binário dos arquivos do Storage: o retrato compara os
--     metadados (tamanho, tipo, versão, datas), que mudam quando um
--     arquivo é trocado.
--   · Comportamento: o retrato compara definições; o comportamento é
--     testado separadamente.
--   · Mudanças desfeitas entre um retrato e outro.
-- =====================================================================

set timezone = 'UTC';

with
tabelas as (
  select c.oid, c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relname not like 'shopee\_%'
),
funcoes as (
  select p.oid, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as nome
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind in ('f', 'p') and p.proname <> 'importar_pedidos_shopee'
),

-- A. Conteúdo
bloco_a as (
  select 'A. Conteúdo' as bloco, t.relname::text as objeto,
         (xpath('/row/n/text()', query_to_xml(format(
            'select count(*) as n from public.%I t %s', t.relname,
            case when t.relname = 'auditoria' then 'where t.tabela not like ''shopee\_%''' else '' end),
          false, true, '')))[1]::text as quantidade,
         (xpath('/row/h/text()', query_to_xml(format(
            'select md5(coalesce(string_agg(t::text, ''|'' order by t::text), '''')) as h from public.%I t %s', t.relname,
            case when t.relname = 'auditoria' then 'where t.tabela not like ''shopee\_%''' else '' end),
          false, true, '')))[1]::text as hash
    from tabelas t
),

-- B. Estrutura de cada tabela
bloco_b as (
  select 'B. Estrutura', t.relname::text,
         (select count(*) from pg_attribute a where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped)::text,
         md5(concat_ws('#',
           (select string_agg(concat_ws(':', a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
                                        pg_get_expr(d.adbin, d.adrelid), a.attidentity, a.attgenerated), '|' order by a.attnum)
              from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
             where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped),
           (select string_agg(co.conname || ':' || pg_get_constraintdef(co.oid), '|' order by co.conname)
              from pg_constraint co where co.conrelid = t.oid),
           (select string_agg(pg_get_indexdef(i.indexrelid), '|' order by pg_get_indexdef(i.indexrelid))
              from pg_index i where i.indrelid = t.oid),
           c.relowner::regrole::text, c.relrowsecurity::text, c.relforcerowsecurity::text,
           coalesce(c.relacl::text, '')))
    from tabelas t join pg_class c on c.oid = t.oid
),

-- C. Funções
bloco_c as (
  select 'C. Funções', f.nome, null,
         md5(concat_ws('#', pg_get_functiondef(f.oid), p.proowner::regrole::text, coalesce(p.proacl::text, '')))
    from funcoes f join pg_proc p on p.oid = f.oid
),

-- D. Regras de acesso (RLS)
bloco_d as (
  select 'D. Regras de acesso', t.relname::text,
         (select count(*) from pg_policies pp where pp.schemaname = 'public' and pp.tablename = t.relname)::text,
         md5(coalesce((
           select string_agg(concat_ws(';', pp.policyname, pp.cmd, pp.permissive, pp.roles::text, pp.qual, pp.with_check),
                             '|' order by pp.policyname)
             from pg_policies pp where pp.schemaname = 'public' and pp.tablename = t.relname), ''))
    from tabelas t
),

-- E. Gatilhos (definição completa)
bloco_e as (
  select 'E. Gatilhos', t.relname::text, count(tg.oid)::text,
         md5(coalesce(string_agg(pg_get_triggerdef(tg.oid) || ' [' || tg.tgenabled::text || ']', '|' order by tg.tgname), ''))
    from tabelas t left join pg_trigger tg on tg.tgrelid = t.oid and not tg.tgisinternal
   group by t.relname
),

-- F. Views
bloco_f as (
  select 'F. Views', c.relname::text, null,
         md5(concat_ws('#', pg_get_viewdef(c.oid), coalesce(array_to_string(c.reloptions, ','), ''),
                       c.relowner::regrole::text, coalesce(c.relacl::text, '')))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')
),

-- G. Contadores automáticos
bloco_g as (
  select 'G. Contadores', s.sequencename::text, coalesce(s.last_value::text, 'nunca usado'),
         md5(concat_ws(':', s.data_type, s.start_value, s.min_value, s.max_value, s.increment_by, s.cycle, s.cache_size))
    from pg_sequences s
   where s.schemaname = 'public' and s.sequencename not like 'shopee\_%' and s.sequencename <> 'auditoria_id_seq'
),

-- H. Tipos (listas fixas de valores)
bloco_h as (
  select 'H. Tipos', ty.typname::text,
         (select count(*) from pg_enum e where e.enumtypid = ty.oid)::text,
         md5(coalesce((select string_agg(e.enumlabel, '|' order by e.enumsortorder) from pg_enum e where e.enumtypid = ty.oid), ''))
    from pg_type ty join pg_namespace n on n.oid = ty.typnamespace
   where n.nspname = 'public' and ty.typtype = 'e'
),

-- I. Storage: configuração de cada bucket e metadados dos arquivos dele
-- query_to_xml(..., tableforest = false) devolve <table><row><b/><q/><h/></row>...</table>;
-- xpath('/table/row') separa uma linha por bucket. O texto volta com
-- &amp; &lt; &gt; escapados; os replace abaixo devolvem o nome original.
storage_linhas as (
  select replace(replace(replace(replace(replace(
           (xpath('/row/b/text()', x))[1]::text,
           '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&') as objeto,
         (xpath('/row/q/text()', x))[1]::text as quantidade,
         (xpath('/row/h/text()', x))[1]::text as hash
    from unnest(case when to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null
                     then array[]::xml[]
                     else xpath('/table/row', query_to_xml($q$
      select 'bucket ' || b.id as b,
             (select count(*) from storage.objects o where o.bucket_id = b.id)::text as q,
             md5(concat_ws('#', (to_jsonb(b))::text,
               (select coalesce(string_agg((to_jsonb(o) - 'last_accessed_at')::text, '|' order by o.name, o.id::text), '')
                  from storage.objects o where o.bucket_id = b.id))) as h
        from storage.buckets b order by b.id
    $q$, false, false, '')) end) as x
),
-- Contagem direta dos buckets (sem passar pelo XML), para conferir a lista.
storage_total as (
  select case when to_regclass('storage.buckets') is null then null
              else (xpath('/row/n/text()', query_to_xml('select count(*) as n from storage.buckets', false, true, '')))[1]::text::int
         end as n
),
bloco_i as (
  select 'I. Storage' as bloco, objeto, quantidade, hash from storage_linhas
  union all
  select 'I. Storage', 'total de buckets',
         case when t.n is null then 'sem Storage neste banco'
              when t.n = (select count(*) from storage_linhas) then t.n::text || ' (todos listados)'
              else 'ATENÇÃO: ' || t.n::text || ' buckets, mas só ' || (select count(*) from storage_linhas)::text || ' listados'
         end,
         null
    from storage_total t
  union all
  select 'I. Storage', 'arquivos sem bucket conhecido',
         case when to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then 'sem Storage neste banco'
              else (xpath('/row/n/text()', query_to_xml(
                'select count(*) as n from storage.objects o where not exists (select 1 from storage.buckets b where b.id = o.bucket_id)',
                false, true, '')))[1]::text end,
         null
),

existentes as (
  select * from bloco_a union all select * from bloco_b union all select * from bloco_c union all
  select * from bloco_d union all select * from bloco_e union all select * from bloco_f union all
  select * from bloco_g union all select * from bloco_h union all select * from bloco_i
),

-- Z. Resumo: impressão digital de tudo de A a I.
resumo as (
  select 'Z. Resumo', 'impressão digital de A a I', count(*)::text,
         md5(string_agg(concat_ws('#', bloco, objeto, quantidade, hash), '|' order by bloco, objeto))
    from existentes
),

-- N. Objetos novos do módulo (só informativo).
novos as (
  select 'N. Objetos novos (módulo Shopee)', c.relname::text,
         (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text,
         null
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'shopee\_%'
  union all
  select 'N. Objetos novos (módulo Shopee)', 'função ' || p.proname, null, null
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'importar_pedidos_shopee'
),

-- 0. Conexão (fora do resumo): o retrato precisa enxergar todas as linhas.
conexao as (
  select '0. Conexão' as bloco, 'usuário ' || current_user as objeto,
         case when (select rolsuper or rolbypassrls from pg_roles where rolname = current_user)
              then 'vê todas as linhas' else 'ATENÇÃO: não vê todas as linhas' end as quantidade,
         null::text as hash
)

select bloco, objeto, quantidade, hash from (
  select * from conexao union all
  select * from existentes union all select * from resumo union all select * from novos
) x
order by bloco, objeto;
