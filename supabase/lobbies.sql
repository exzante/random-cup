-- ============================================================
-- Random Cup — ЧАСТЬ 3. Лобби (пикапы) + заявки
-- Прогонять ТОЛЬКО этот файл (новые таблицы/функции, players не трогает —
-- дедлока не будет). Supabase → SQL Editor → New query → Run.
-- Требует уже накатанные Часть 1 и 2 (players, player_auth, rc_check, pgcrypto).
-- ============================================================

-- Лобби (публичное чтение; запись — через RPC)
create table if not exists public.lobbies (
  id           text primary key,
  title        text not null,
  format       text,
  when_text    text,
  mmr_cap      integer,
  note         text,
  status       text not null default 'open',   -- open | closed
  created_by   text not null,                  -- 'admin' или player_id капитана
  creator_name text,
  created_at   timestamptz not null default now()
);
alter table public.lobbies enable row level security;
drop policy if exists lobbies_read on public.lobbies;
create policy lobbies_read on public.lobbies for select using (true);

-- Заявки / участники лобби (публичное чтение)
create table if not exists public.lobby_signups (
  id          text primary key,
  lobby_id    text not null,
  player_id   text not null,
  player_name text,
  pos         text,
  note        text,
  status      text not null default 'requested', -- requested | accepted | declined
  created_at  timestamptz not null default now(),
  unique (lobby_id, player_id)
);
alter table public.lobby_signups enable row level security;
drop policy if exists lobby_signups_read on public.lobby_signups;
create policy lobby_signups_read on public.lobby_signups for select using (true);

-- Кто действует: 'admin' по секрету организатора ИЛИ player_id по нику+паролю
create or replace function public.rc_actor(p_secret text, p_username text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  if p_secret is not null and public.rc_check(p_secret) then return 'admin'; end if;
  if p_username is not null and p_username <> '' then
    select player_id into pid from public.player_auth
     where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
    if pid is not null then return pid; end if;
  end if;
  raise exception 'unauthorized';
end; $$;

-- Создать лобби (организатор или залогиненный игрок-капитан)
create or replace function public.rc_lobby_create(p_secret text, p_username text, p_password text, l jsonb)
returns public.lobbies language plpgsql security definer set search_path = public, extensions as $$
declare actor text; cname text; r public.lobbies;
begin
  actor := public.rc_actor(p_secret, p_username, p_password);
  if actor = 'admin' then cname := 'Организатор';
  else select coalesce(nick, name) into cname from public.players where id = actor; end if;
  insert into public.lobbies(id, title, format, when_text, mmr_cap, note, created_by, creator_name)
  values (coalesce(l->>'id', gen_random_uuid()::text), coalesce(nullif(l->>'title',''),'Лобби'),
          l->>'format', l->>'when', nullif(l->>'mmrCap','')::int, l->>'note', actor, cname)
  returning * into r;
  return r;
end; $$;

-- Игрок подаёт заявку (или обновляет свою) в лобби
create or replace function public.rc_lobby_join(p_username text, p_password text, p_lobby text, p_note text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text; pnm text; ppos text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  select coalesce(nick, name), pos into pnm, ppos from public.players where id = pid;
  insert into public.lobby_signups(id, lobby_id, player_id, player_name, pos, note, status)
  values (gen_random_uuid()::text, p_lobby, pid, pnm, ppos, p_note, 'requested')
  on conflict (lobby_id, player_id) do update
    set note = excluded.note, status = 'requested', created_at = now();
end; $$;

-- Игрок отзывает свою заявку
create or replace function public.rc_lobby_leave(p_username text, p_password text, p_lobby text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  delete from public.lobby_signups where lobby_id = p_lobby and player_id = pid;
end; $$;

-- Капитан/организатор добавляет игрока вручную (сразу в состав, без заявки)
create or replace function public.rc_lobby_add(p_secret text, p_username text, p_password text, p_lobby text, p_player text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare actor text; owner text; pnm text; ppos text;
begin
  actor := public.rc_actor(p_secret, p_username, p_password);
  select created_by into owner from public.lobbies where id = p_lobby;
  if actor <> 'admin' and actor <> owner then raise exception 'forbidden'; end if;
  select coalesce(nick, name), pos into pnm, ppos from public.players where id = p_player;
  insert into public.lobby_signups(id, lobby_id, player_id, player_name, pos, note, status)
  values (gen_random_uuid()::text, p_lobby, p_player, pnm, ppos, null, 'accepted')
  on conflict (lobby_id, player_id) do update set status = 'accepted';
end; $$;

-- Капитан/организатор принимает/отклоняет заявку
create or replace function public.rc_lobby_signup_status(p_secret text, p_username text, p_password text, p_signup text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare actor text; lob text; owner text;
begin
  actor := public.rc_actor(p_secret, p_username, p_password);
  select lobby_id into lob from public.lobby_signups where id = p_signup;
  select created_by into owner from public.lobbies where id = lob;
  if actor <> 'admin' and actor <> owner then raise exception 'forbidden'; end if;
  update public.lobby_signups set status = p_status where id = p_signup;
end; $$;

-- Капитан/организатор закрывает (удаляет) лобби вместе с заявками
create or replace function public.rc_lobby_close(p_secret text, p_username text, p_password text, p_lobby text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare actor text; owner text;
begin
  actor := public.rc_actor(p_secret, p_username, p_password);
  select created_by into owner from public.lobbies where id = p_lobby;
  if actor <> 'admin' and actor <> owner then raise exception 'forbidden'; end if;
  delete from public.lobby_signups where lobby_id = p_lobby;
  delete from public.lobbies where id = p_lobby;
end; $$;

grant execute on function public.rc_actor(text, text, text)                                   to anon;
grant execute on function public.rc_lobby_create(text, text, text, jsonb)                      to anon;
grant execute on function public.rc_lobby_join(text, text, text, text)                         to anon;
grant execute on function public.rc_lobby_leave(text, text, text)                              to anon;
grant execute on function public.rc_lobby_add(text, text, text, text, text)                    to anon;
grant execute on function public.rc_lobby_signup_status(text, text, text, text, text)          to anon;
grant execute on function public.rc_lobby_close(text, text, text, text)                        to anon;

-- ============================================================
-- Клиент:
--   лобби:    sb.from('lobbies').select('*')
--   заявки:   sb.from('lobby_signups').select('*')
--   создать:  sb.rpc('rc_lobby_create', { p_secret|p_username/p_password, l })
--   заявка:   sb.rpc('rc_lobby_join', { p_username, p_password, p_lobby, p_note })
--   принять:  sb.rpc('rc_lobby_signup_status', { ...actor, p_signup, p_status })
--   закрыть:  sb.rpc('rc_lobby_close', { ...actor, p_lobby })
-- ============================================================
