-- ============================================================
-- ТОЧЕЧНЫЙ ФИКС входа игроков (crypt/gen_salt из схемы extensions).
-- Прогонять ТОЛЬКО этот файл — он НЕ трогает таблицы, значит дедлока не будет.
-- Supabase → SQL Editor → New query → вставить → Run.
-- ============================================================

-- pgcrypto в Supabase обычно уже стоит в схеме extensions. Строку ниже можно
-- НЕ запускать, если она приводит к дедлоку — функциям хватит search_path.
-- create extension if not exists pgcrypto with schema extensions;

create or replace function public.rc_set_login(p_secret text, p_id text, p_username text, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  insert into public.player_auth(player_id, username, pass_hash, updated_at)
  values (p_id, lower(p_username), crypt(p_password, gen_salt('bf')), now())
  on conflict (player_id) do update
    set username = lower(excluded.username), pass_hash = excluded.pass_hash, updated_at = now();
end; $$;

create or replace function public.rc_login(p_username text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  return pid;
end; $$;

create or replace function public.rc_set_lft(p_username text, p_password text, p_on boolean, p_note text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  update public.players set lft = p_on, lft_note = nullif(p_note, ''), updated_at = now() where id = pid;
end; $$;
