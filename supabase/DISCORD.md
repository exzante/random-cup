# Random Cup × Discord — слэш-команды

Serverless-бот (без сервера 24/7): Discord шлёт «интеракции» на нашу
Supabase Edge Function `discord`, она отвечает данными из общей базы.

Команды: `/lobbies` (открытые лобби), `/lft` (кто ищет команду),
`/player nick` (профиль игрока).

---

## 0. Что понадобится
- Установить **Supabase CLI**: https://supabase.com/docs/guides/cli (через scoop/npm/brew).
- Доступ к нашему проекту Supabase (ref: `zfskwyfhzwhfogcysojg`).
- Права управлять Discord-сервером.

## 1. Создать Discord-приложение
1. https://discord.com/developers/applications → **New Application** (назови «Random Cup»).
2. На вкладке **General Information** скопируй:
   - **Application ID**
   - **Public Key**  ← понадобится в секретах функции
3. Вкладка **Bot** → **Reset Token**, скопируй **Bot Token** (нужен только чтобы зарегистрировать команды и пригласить приложение).

## 2. Задеплоить Edge Function
В папке проекта (где лежит `supabase/`):
```bash
supabase login
supabase link --project-ref zfskwyfhzwhfogcysojg

# секреты (Public Key из шага 1; anon-ключ — тот же, что в index.html)
supabase secrets set DISCORD_PUBLIC_KEY=ВСТАВЬ_PUBLIC_KEY
supabase secrets set SB_URL=https://zfskwyfhzwhfogcysojg.supabase.co
supabase secrets set SB_ANON=ВСТАВЬ_ANON_KEY

supabase functions deploy discord --no-verify-jwt
```
URL функции будет:
```
https://zfskwyfhzwhfogcysojg.supabase.co/functions/v1/discord
```

## 3. Привязать endpoint к Discord
В приложении на вкладке **General Information** →
**Interactions Endpoint URL** вставь URL функции (из шага 2) → **Save**.
Discord пришлёт проверочный PING; если функция задеплоена и Public Key
верный — сохранится. (Если ругается — перепроверь `DISCORD_PUBLIC_KEY`.)

## 4. Зарегистрировать команды
Подставь свои `APP_ID`, `BOT_TOKEN`, `GUILD_ID` (ID сервера: включи в
Discord режим разработчика → ПКМ по серверу → «Копировать ID»).
Команды сервера появляются мгновенно.

```bash
curl -X PUT "https://discord.com/api/v10/applications/APP_ID/guilds/GUILD_ID/commands" \
  -H "Authorization: Bot BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '[
    {"name":"lobbies","description":"Открытые лобби Random Cup"},
    {"name":"lft","description":"Кто ищет команду (LFT)"},
    {"name":"player","description":"Профиль игрока из базы",
     "options":[{"name":"nick","description":"ник или имя","type":3,"required":true}]}
  ]'
```

## 5. Пригласить приложение на сервер
Открой в браузере (подставь APP_ID), выбери сервер:
```
https://discord.com/api/oauth2/authorize?client_id=APP_ID&scope=applications.commands
```

Готово. Пиши в канале `/lobbies`, `/lft`, `/player <ник>`.

---

## Заметки
- Функция **только читает** общие таблицы (lobbies, lobby_signups, players) —
  писать из Discord (ставить LFT/заявки) пока нельзя: для этого нужна
  привязка Discord-аккаунта к профилю (следующий шаг, если захотим).
- Обновить логику — правишь `supabase/functions/discord/index.ts` и снова
  `supabase functions deploy discord --no-verify-jwt`.
- Имена секретов не могут начинаться с `SUPABASE_` — поэтому `SB_URL`/`SB_ANON`.
