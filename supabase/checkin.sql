-- ============================================================
-- Random Cup — самостоятельная отметка «иду» по ссылке (?join=1)
-- Прогонять ТОЛЬКО этот файл. Требует таблицу players и колонку going
-- (из going.sql). Ничего не блокирует — просто добавляет открытые функции.
-- ============================================================

-- Когда игрок отметился (для списка «идут» у организатора)
alter table public.players add column if not exists going_at timestamptz;

-- Игрок сам отмечается «иду» (БЕЗ пароля — открытый чек-ин).
-- Может только выставить свою метку going + время. Больше ничего изменить нельзя.
create or replace function public.rc_self_going(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.players
     set going = true, going_at = now(), updated_at = now()
   where id = p_id;
end; $$;

-- Игрок сам снимает свою отметку
create or replace function public.rc_self_leave(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.players set going = false, updated_at = now() where id = p_id;
end; $$;

grant execute on function public.rc_self_going(text) to anon;
grant execute on function public.rc_self_leave(text) to anon;

-- ============================================================
-- Ссылка для игроков:  <адрес сайта>/?join=1
-- Клиент: sb.rpc('rc_self_going', { p_id })  /  sb.rpc('rc_self_leave', { p_id })
-- Организатор видит отметившихся на странице «Игроки» → фильтр «✅ Идут».
-- Открытый чек-ин: кто угодно с ссылкой может отметить любого из базы —
-- организатор видит список и убирает лишних. Нужна усиленная защита? добавим
-- подтверждение по номеру позже.
-- ============================================================
