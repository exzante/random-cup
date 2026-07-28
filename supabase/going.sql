-- ============================================================
-- Random Cup — метка «идёт на ближайший турик» (пул для драфта)
-- Прогонять ТОЛЬКО этот файл. Требует Часть 1 (rc_check) и players.
-- ============================================================

alter table public.players add column if not exists going boolean not null default false;

-- Организатор ставит/снимает участие игроку
create or replace function public.rc_set_going(p_secret text, p_id text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  update public.players set going = p_on, updated_at = now() where id = p_id;
end; $$;

-- Организатор сбрасывает участие у всех (между турниками)
create or replace function public.rc_clear_going(p_secret text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.rc_check(p_secret) then raise exception 'forbidden'; end if;
  update public.players set going = false, updated_at = now() where going = true;
end; $$;

grant execute on function public.rc_set_going(text, text, boolean) to anon;
grant execute on function public.rc_clear_going(text)             to anon;

-- ============================================================
-- Клиент:
--   отметить: sb.rpc('rc_set_going', { p_secret, p_id, p_on })
--   сбросить всех: sb.rpc('rc_clear_going', { p_secret })
-- ============================================================
