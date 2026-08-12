-- ============================================================
-- Random Cup — записи «иду / ищу команду» ПО КОНКРЕТНОМУ ТУРНИРУ
-- Прогонять ТОЛЬКО этот файл. Требует Часть 1 (rc_check) и players.
-- Заменяет глобальные метки going/lft на записи по турнирам.
-- ============================================================

create table if not exists public.signups (
  tournament text not null,
  player_id  text not null,
  going  boolean not null default false,   -- «я иду» (в пул на драфт)
  lft    boolean not null default false,   -- «ищу команду» (нужна команда)
  at     timestamptz not null default now(),
  primary key (tournament, player_id)
);
alter table public.signups enable row level security;
drop policy if exists signups_read on public.signups;
create policy signups_read on public.signups for select using (true);   -- публичное чтение

-- Игрок сам записывается на конкретный турнир (без пароля). Оба false → запись удаляется.
create or replace function public.rc_signup(p_tournament text, p_id text, p_going boolean, p_lft boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_going,false) or coalesce(p_lft,false) then
    insert into public.signups(tournament, player_id, going, lft, at)
    values (p_tournament, p_id, coalesce(p_going,false), coalesce(p_lft,false), now())
    on conflict (tournament, player_id) do update
      set going = excluded.going, lft = excluded.lft, at = now();
  else
    delete from public.signups where tournament = p_tournament and player_id = p_id;
  end if;
end; $$;

-- Организатор чистит все записи турнира (между сборами)
create or replace function public.rc_signups_clear(p_secret text, p_tournament text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  delete from public.signups where tournament = p_tournament;
end; $$;

grant execute on function public.rc_signup(text, text, boolean, boolean) to anon;
grant execute on function public.rc_signups_clear(text, text)            to anon;

-- Перенос текущих глобальных «идёт / ищу команду» на ВОСКРЕСНЫЙ турик (JK Cup 25k CM).
insert into public.signups(tournament, player_id, going, lft, at)
  select 'xz1rd6u2w', id, coalesce(going,false), coalesce(lft,false), now()
  from public.players where going = true or lft = true
  on conflict (tournament, player_id) do update
    set going = excluded.going, lft = excluded.lft;

-- ============================================================
-- Клиент:
--   ссылка отметки: <сайт>/?join=<id турнира>
--   отметиться:     sb.rpc('rc_signup', { p_tournament, p_id, p_going, p_lft })
--   загрузка:       sb.from('signups').select('tournament,player_id,going,lft,at')
--   сброс турнира:  sb.rpc('rc_signups_clear', { p_secret, p_tournament })
-- ============================================================
