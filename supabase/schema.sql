-- ============================================================
-- Random Cup — общая база игроков (реестр / knowledge base)
-- Как накатить: Supabase Dashboard → SQL Editor → New query →
-- вставить весь файл → Run. Повторный запуск безопасен (idempotent).
-- ============================================================

-- 1) Таблица игроков (общая на всё сообщество)
create table if not exists public.players (
  id           text primary key,
  name         text not null,
  nick         text,
  mmr          integer,
  mmr_history  jsonb   not null default '[]'::jsonb,  -- [{ "v": 10050, "note": "2022, пик" }, ...]
  note         text,
  account      jsonb,                                  -- на будущее: { "username": "...", "pass_hash": "..." }
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 2) Приватный конфиг (секрет админа). НЕ читается анон-ключом.
create table if not exists public.rc_config (
  key   text primary key,
  value text not null
);

-- Задай здесь свой пароль организатора (потом можно поменять UPDATE-ом).
insert into public.rc_config(key, value)
values ('admin_secret', 'СМЕНИ_МЕНЯ_на_пароль_организатора')
on conflict (key) do nothing;

-- 3) RLS: игроков может читать кто угодно (публичный профиль),
--    но писать — только через RPC ниже (с секретом).
alter table public.players  enable row level security;
alter table public.rc_config enable row level security;

drop policy if exists players_public_read on public.players;
create policy players_public_read on public.players
  for select using (true);
-- запись напрямую запрещена (нет insert/update/delete политик) — только через RPC.

-- 4) Проверка секрета
create or replace function public.rc_check(p_secret text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(select 1 from public.rc_config where key = 'admin_secret' and value = p_secret);
$$;

-- 5) Upsert игрока (создать/обновить) — требует секрет
create or replace function public.rc_upsert_player(p_secret text, p jsonb)
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare r public.players;
begin
  if not public.rc_check(p_secret) then
    raise exception 'forbidden';
  end if;
  insert into public.players as pl (id, name, nick, mmr, mmr_history, note, account, updated_at)
  values (
    coalesce(p->>'id', gen_random_uuid()::text),
    p->>'name',
    p->>'nick',
    nullif(p->>'mmr','')::int,
    coalesce(p->'mmrHistory', '[]'::jsonb),
    p->>'note',
    p->'account',
    now()
  )
  on conflict (id) do update set
    name = excluded.name,
    nick = excluded.nick,
    mmr = excluded.mmr,
    mmr_history = excluded.mmr_history,
    note = excluded.note,
    account = coalesce(excluded.account, pl.account),
    updated_at = now()
  returning * into r;
  return r;
end;
$$;

-- 6) Удаление игрока — требует секрет
create or replace function public.rc_delete_player(p_secret text, p_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.rc_check(p_secret) then
    raise exception 'forbidden';
  end if;
  delete from public.players where id = p_id;
end;
$$;

-- Права на вызов RPC для анонимного клиента (секрет проверяется внутри)
grant execute on function public.rc_upsert_player(text, jsonb) to anon;
grant execute on function public.rc_delete_player(text, text) to anon;
grant execute on function public.rc_check(text)               to anon;

-- ============================================================
-- Клиент читает игроков так:   sb.from('players').select('*')
-- Пишет так:  sb.rpc('rc_upsert_player', { p_secret, p })
-- Удаляет:    sb.rpc('rc_delete_player', { p_secret, p_id })
-- ============================================================
