-- ============================================================
-- Random Cup — облачный бэкап турниров (архив истории)
-- Прогонять ТОЛЬКО этот файл (новая таблица/функции, ничего не блокирует).
-- Требует Часть 1 (rc_check, rc_config с admin_secret).
-- ============================================================

-- Архив турниров. Публичное чтение (для истории/зала славы с любого устройства),
-- запись — только организатором (по паролю).
create table if not exists public.rc_tournaments (
  id          text primary key,
  name        text,
  data        jsonb  not null,          -- весь турнир целиком
  updated_at  bigint not null default 0, -- клиентская метка времени (мс) для last-write-wins
  saved_at    timestamptz not null default now()
);
alter table public.rc_tournaments enable row level security;
drop policy if exists rc_tournaments_read on public.rc_tournaments;
create policy rc_tournaments_read on public.rc_tournaments for select using (true);

-- Сохранить/обновить турнир (организатор)
create or replace function public.rc_save_tournament(p_secret text, p_id text, p_name text, p_updated bigint, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  insert into public.rc_tournaments(id, name, data, updated_at, saved_at)
  values (p_id, p_name, p_data, coalesce(p_updated, 0), now())
  on conflict (id) do update
    set name = excluded.name, data = excluded.data, updated_at = excluded.updated_at, saved_at = now();
end; $$;

-- Удалить турнир из архива (организатор)
create or replace function public.rc_del_tournament(p_secret text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  delete from public.rc_tournaments where id = p_id;
end; $$;

grant execute on function public.rc_save_tournament(text, text, text, bigint, jsonb) to anon;
grant execute on function public.rc_del_tournament(text, text)                       to anon;

-- ============================================================
-- Клиент:
--   загрузка архива: sb.from('rc_tournaments').select('id,data,updated_at')
--   сохранить:       sb.rpc('rc_save_tournament', { p_secret, p_id, p_name, p_updated, p_data })
--   удалить:         sb.rpc('rc_del_tournament', { p_secret, p_id })
-- ============================================================
