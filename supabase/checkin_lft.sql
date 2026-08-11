-- ============================================================
-- Random Cup — отметка «иду» + флаг «ищу команду» (LFT)
-- Прогонять ТОЛЬКО этот файл. Требует checkin.sql (going, going_at)
-- и колонку lft в players (она уже есть — используется в базе игроков).
-- ============================================================

-- Игрок сам отмечается «иду»; p_lft = true → ещё и «ищу команду».
-- Открытый чек-ин (без пароля). Меняет только свои going / lft / время.
create or replace function public.rc_self_going_lft(p_id text, p_lft boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.players
     set going = true, lft = coalesce(p_lft, false), going_at = now(), updated_at = now()
   where id = p_id;
end; $$;

-- При снятии отметки — сбрасываем и «иду», и «ищу команду».
create or replace function public.rc_self_leave(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.players set going = false, lft = false, updated_at = now() where id = p_id;
end; $$;

grant execute on function public.rc_self_going_lft(text, boolean) to anon;
grant execute on function public.rc_self_leave(text)             to anon;

-- ============================================================
-- Клиент: sb.rpc('rc_self_going_lft', { p_id, p_lft })
--   «я иду»        → p_lft = false
--   «ищу команду»  → p_lft = true
-- Организатор видит «ищущих команду» на странице «Игроки» (бейдж 🔎 LFT).
-- ============================================================
