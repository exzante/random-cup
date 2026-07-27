// Random Cup — Discord slash-команды (serverless, Supabase Edge Function).
// Обрабатывает Discord Interactions: /lobbies, /lft, /player.
// Деплой: supabase functions deploy discord --no-verify-jwt
// Секреты:  supabase secrets set DISCORD_PUBLIC_KEY=... SB_URL=... SB_ANON=...
//
// Отвечает read-only данными из общих таблиц (lobbies, lobby_signups, players).

const SITE = "https://exzante.github.io/random-cup/";
const PUBLIC_KEY = Deno.env.get("DISCORD_PUBLIC_KEY")!;
const SB_URL = Deno.env.get("SB_URL")!;
const SB_ANON = Deno.env.get("SB_ANON")!;

const POS: Record<string, string> = { "1": "Керри", "2": "Мид", "3": "Оффлейн", "4": "Саппорт", "5": "Хард сап" };
const GOLD = 0xD4AF37;

function hexToBytes(hex: string): Uint8Array {
  const b = new Uint8Array(hex.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}

// Проверка подписи Discord (Ed25519). Обязательна — иначе Discord не примет endpoint.
async function verify(req: Request, body: string): Promise<boolean> {
  const sig = req.headers.get("X-Signature-Ed25519");
  const ts = req.headers.get("X-Signature-Timestamp");
  if (!sig || !ts) return false;
  try {
    const key = await crypto.subtle.importKey(
      "raw", hexToBytes(PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "Ed25519" }, key, hexToBytes(sig), new TextEncoder().encode(ts + body),
    );
  } catch {
    return false;
  }
}

async function sb(path: string): Promise<any[]> {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, {
    headers: { apikey: SB_ANON, Authorization: `Bearer ${SB_ANON}` },
  });
  if (!r.ok) return [];
  return await r.json();
}

const posStr = (p?: string) =>
  (p || "").split(",").map((s) => s.trim()).filter(Boolean).map((n) => POS[n] || n).join(", ");

// Ответ сообщением (embed). flags:64 = только тому, кто вызвал (ephemeral).
function reply(embed: unknown, ephemeral = false) {
  return json({ type: 4, data: { embeds: [embed], flags: ephemeral ? 64 : 0 } });
}
function json(obj: unknown) {
  return new Response(JSON.stringify(obj), { headers: { "Content-Type": "application/json" } });
}

async function cmdLobbies() {
  const [lobbies, signups] = await Promise.all([
    sb("lobbies?select=*&status=eq.open&order=created_at.desc&limit=10"),
    sb("lobby_signups?select=lobby_id,status"),
  ]);
  if (!lobbies.length) {
    return reply({ title: "🎮 Лобби", description: "Сейчас нет открытых лобби.", color: GOLD, url: SITE });
  }
  const fields = lobbies.map((l) => {
    const su = signups.filter((s) => s.lobby_id === l.id);
    const acc = su.filter((s) => s.status === "accepted").length;
    const pend = su.filter((s) => s.status === "requested").length;
    const meta = [l.format, l.when_text, l.mmr_cap ? `лимит ${l.mmr_cap} MMR` : ""].filter(Boolean).join(" · ");
    return {
      name: `🎮 ${l.title}`,
      value: `${meta || "—"}\nсостав: ${acc}${pend ? ` · заявок: ${pend}` : ""} · кэп: ${l.creator_name || "—"}`,
    };
  });
  return reply({ title: "Открытые лобби", color: GOLD, url: SITE, fields });
}

async function cmdLft() {
  const players = await sb("players?select=name,nick,mmr,pos,lft_note&lft=eq.true&order=mmr.desc&limit=15");
  if (!players.length) {
    return reply({ title: "🔎 Ищут команду", description: "Сейчас никто не в поиске.", color: GOLD, url: SITE + "?lft" });
  }
  const desc = players.map((p) =>
    `**${p.name}**${p.nick ? ` (@${p.nick})` : ""} — ${p.mmr ?? "—"} MMR${p.pos ? ` · ${posStr(p.pos)}` : ""}${p.lft_note ? `\n_${p.lft_note}_` : ""}`
  ).join("\n");
  return reply({ title: "🔎 Ищут команду (LFT)", description: desc, color: GOLD, url: SITE });
}

async function cmdPlayer(q: string) {
  if (!q) return reply({ title: "Игрок", description: "Укажи ник или имя.", color: GOLD }, true);
  const enc = encodeURIComponent(`%${q}%`);
  const players = await sb(`players?select=*&or=(name.ilike.${enc},nick.ilike.${enc})&order=mmr.desc&limit=5`);
  if (!players.length) return reply({ title: "Игрок", description: `Не нашёл «${q}» в базе.`, color: GOLD }, true);
  const p = players[0];
  const hist = Array.isArray(p.mmr_history) ? p.mmr_history : [];
  const peak = Math.max(p.mmr || 0, ...hist.map((h: any) => h.v || 0), 0);
  const fields = [
    { name: "MMR", value: `${p.mmr ?? "—"}${peak > (p.mmr || 0) ? ` (пик ${peak})` : ""}`, inline: true },
    { name: "Позиции", value: posStr(p.pos) || "—", inline: true },
    { name: "LFT", value: p.lft ? `да${p.lft_note ? ` — ${p.lft_note}` : ""}` : "нет", inline: true },
  ];
  if (p.note) fields.push({ name: "Заметка", value: String(p.note), inline: false });
  return reply({
    title: `${p.name}${p.nick ? ` (@${p.nick})` : ""}`,
    color: GOLD, url: SITE, fields,
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const body = await req.text();
  if (!(await verify(req, body))) return new Response("bad signature", { status: 401 });
  const i = JSON.parse(body);

  if (i.type === 1) return json({ type: 1 }); // PING -> PONG

  if (i.type === 2) {
    const name = i.data?.name;
    const opt = (n: string) => i.data?.options?.find((o: any) => o.name === n)?.value ?? "";
    try {
      if (name === "lobbies") return await cmdLobbies();
      if (name === "lft") return await cmdLft();
      if (name === "player") return await cmdPlayer(String(opt("nick")));
    } catch (_e) {
      return reply({ title: "Ошибка", description: "Что-то пошло не так, попробуй позже.", color: GOLD }, true);
    }
    return reply({ title: "Random Cup", description: "Неизвестная команда.", color: GOLD }, true);
  }
  return json({ type: 4, data: { content: "?" } });
});
