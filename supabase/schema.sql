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
  phone        text,                                   -- для связи (WhatsApp): +7...
  pos          text,                                   -- позиция в Dota: "1".."5"
  account      jsonb,                                  -- на будущее: { "username": "...", "pass_hash": "..." }
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Догоняющие колонки (если таблица уже была создана раньше без них) — безопасно.
alter table public.players add column if not exists phone text;
alter table public.players add column if not exists pos   text;

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
  insert into public.players as pl (id, name, nick, mmr, mmr_history, note, phone, pos, account, updated_at)
  values (
    coalesce(p->>'id', gen_random_uuid()::text),
    p->>'name',
    p->>'nick',
    nullif(p->>'mmr','')::int,
    coalesce(p->'mmrHistory', '[]'::jsonb),
    p->>'note',
    p->>'phone',
    p->>'pos',
    p->'account',
    now()
  )
  on conflict (id) do update set
    name = excluded.name,
    nick = excluded.nick,
    mmr = excluded.mmr,
    mmr_history = excluded.mmr_history,
    note = excluded.note,
    phone = excluded.phone,
    pos = excluded.pos,
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
-- ЧАСТЬ 2. Вход игроков (логины) + статус LFT «ищу команду»
-- ============================================================

-- pgcrypto в Supabase живёт в схеме extensions; функции ниже ищут его там (search_path).
create extension if not exists pgcrypto with schema extensions;   -- crypt/gen_salt

-- LFT-поля на игроке (читаются публично вместе с профилем)
alter table public.players add column if not exists lft      boolean not null default false;
alter table public.players add column if not exists lft_note text;

-- Логины игроков. Пароли — только хешем. Наружу таблица НЕ читается.
create table if not exists public.player_auth (
  player_id  text primary key references public.players(id) on delete cascade,
  username   text unique not null,
  pass_hash  text not null,
  updated_at timestamptz not null default now()
);
alter table public.player_auth enable row level security;
-- политик нет => анон-ключ не может ни читать, ни писать напрямую. Только через RPC.

-- Админ включает/меняет вход игроку (ник + простой пароль)
create or replace function public.rc_set_login(p_secret text, p_id text, p_username text, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  insert into public.player_auth(player_id, username, pass_hash, updated_at)
  values (p_id, lower(p_username), crypt(p_password, gen_salt('bf')), now())
  on conflict (player_id) do update
    set username = lower(excluded.username), pass_hash = excluded.pass_hash, updated_at = now();
end; $$;

-- Админ выключает вход игроку
create or replace function public.rc_disable_login(p_secret text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  delete from public.player_auth where player_id = p_id;
end; $$;

-- Есть ли у игрока вход (для админ-UI; без пароля, только факт)
create or replace function public.rc_has_login(p_id text)
returns boolean language sql security definer set search_path = public as $$
  select exists(select 1 from public.player_auth where player_id = p_id);
$$;

-- Вход игрока: ник + пароль -> его player_id (или ошибка)
create or replace function public.rc_login(p_username text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  return pid;
end; $$;

-- Игрок ставит/снимает LFT (авторизуется своим ником+паролем)
create or replace function public.rc_set_lft(p_username text, p_password text, p_on boolean, p_note text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  update public.players set lft = p_on, lft_note = nullif(p_note, ''), updated_at = now() where id = pid;
end; $$;

grant execute on function public.rc_set_login(text, text, text, text) to anon;
grant execute on function public.rc_disable_login(text, text)         to anon;
grant execute on function public.rc_has_login(text)                   to anon;
grant execute on function public.rc_login(text, text)                 to anon;
grant execute on function public.rc_set_lft(text, text, boolean, text) to anon;

-- ============================================================
-- Клиент:
--   игроки:   sb.from('players').select('*')
--   upsert:   sb.rpc('rc_upsert_player', { p_secret, p })
--   удалить:  sb.rpc('rc_delete_player', { p_secret, p_id })
--   вкл вход: sb.rpc('rc_set_login', { p_secret, p_id, p_username, p_password })
--   вход:     sb.rpc('rc_login', { p_username, p_password }) -> player_id
--   LFT:      sb.rpc('rc_set_lft', { p_username, p_password, p_on, p_note })
-- ============================================================
