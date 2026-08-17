-- ============================================================
-- Random Cup — «народный MMR»: игроки оценивают друг друга,
-- на базе берём МЕДИАНУ (устойчива к накрутке).
-- Прогонять ТОЛЬКО этот файл. Требует schema.sql (players, player_auth,
-- rc_check, pgcrypto) — уже накатан.
-- ============================================================

create table if not exists public.mmr_votes (
  rater_id  text not null references public.players(id) on delete cascade,
  target_id text not null references public.players(id) on delete cascade,
  mmr       integer not null,
  at        timestamptz not null default now(),
  primary key (rater_id, target_id)
);
alter table public.mmr_votes enable row level security;
-- Сырые голоса наружу НЕ читаются (нет select-политики): наружу — только агрегат
-- через RPC, а «кто как поставил» — только организатору (по паролю).

-- Игрок ставит MMR другому (авторизация ник+пароль). Себе — нельзя. 0..15000.
create or replace function public.rc_mmr_vote(p_username text, p_password text, p_target text, p_mmr integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  if pid = p_target then raise exception 'self_vote'; end if;
  if p_mmr is null or p_mmr < 0 or p_mmr > 15000 then raise exception 'bad_mmr'; end if;
  insert into public.mmr_votes(rater_id, target_id, mmr, at)
  values (pid, p_target, p_mmr, now())
  on conflict (rater_id, target_id) do update set mmr = excluded.mmr, at = now();
end; $$;

-- Игрок удаляет свой голос по кому-то.
create or replace function public.rc_mmr_unvote(p_username text, p_password text, p_target text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  delete from public.mmr_votes where rater_id = pid and target_id = p_target;
end; $$;

-- Публичный агрегат: по каждому игроку медиана, число голосов, min, max.
create or replace function public.rc_mmr_agg()
returns table(target_id text, med numeric, n integer, lo integer, hi integer)
language sql security definer set search_path = public as $$
  select target_id,
         percentile_cont(0.5) within group (order by mmr) as med,
         count(*)::int as n, min(mmr) as lo, max(mmr) as hi
    from public.mmr_votes
   group by target_id;
$$;

-- Свои голоса (чтобы страница оценок показала, что ты уже ставил).
create or replace function public.rc_mmr_mine(p_username text, p_password text)
returns table(target_id text, mmr integer)
language plpgsql security definer set search_path = public, extensions as $$
declare pid text;
begin
  select player_id into pid from public.player_auth
   where username = lower(p_username) and pass_hash = crypt(p_password, pass_hash);
  if pid is null then raise exception 'bad_credentials'; end if;
  return query select v.target_id, v.mmr from public.mmr_votes v where v.rater_id = pid;
end; $$;

-- Организатор видит, КТО как оценил игрока (аудит накруток). По паролю.
create or replace function public.rc_mmr_detail(p_secret text, p_target text)
returns table(rater text, mmr integer, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  return query
    select coalesce(p.nick, p.name) as rater, v.mmr, v.at
      from public.mmr_votes v
      join public.players p on p.id = v.rater_id
     where v.target_id = p_target
     order by v.mmr;
end; $$;

grant execute on function public.rc_mmr_vote(text, text, text, integer) to anon;
grant execute on function public.rc_mmr_unvote(text, text, text)        to anon;
grant execute on function public.rc_mmr_agg()                           to anon;
grant execute on function public.rc_mmr_mine(text, text)                to anon;
grant execute on function public.rc_mmr_detail(text, text)              to anon;

-- ============================================================
-- Клиент:
--   агрегат:   sb.rpc('rc_mmr_agg')            -> [{target_id, med, n, lo, hi}]
--   голос:     sb.rpc('rc_mmr_vote',   { p_username, p_password, p_target, p_mmr })
--   снять:     sb.rpc('rc_mmr_unvote', { p_username, p_password, p_target })
--   свои:      sb.rpc('rc_mmr_mine',   { p_username, p_password })
--   аудит:     sb.rpc('rc_mmr_detail', { p_secret, p_target })
--   Страница оценок: <сайт>/?rate
-- ============================================================
