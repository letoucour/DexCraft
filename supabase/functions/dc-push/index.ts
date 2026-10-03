// ============================================================
//  DexCraft — dc-push (fonction Supabase, 1.10.0) : envoie les notifications.
//  Appelée toutes les 2 minutes par pg_cron (tâche dc-push, partie 8 du serveur) avec le secret PUSH_SECRET dans l'en-tête
//  x-dc-secret (le même que dc_push_secret, dans le coffre « vault » de Supabase). Elle lit la version en ligne du jeu
//  (APP_VERSION de dexcraft.fr, pour la notification de mise à jour majeure), demande au serveur ce qu'il faut envoyer
//  (dc_push_due, qui note aussitôt chaque notification comme envoyée), puis envoie chacune au service de notifications du
//  navigateur (Web Push : signature VAPID et chiffrement aes128gcm de la RFC 8291, faits ici avec WebCrypto, sans bibliothèque).
//  Abonnements refusés (404, 410 : appareil désinscrit) : supprimés (dc_push_drop).
//  À déployer SANS vérification de connexion (« Verify JWT » désactivé) : c'est pg_cron qui l'appelle.
//  Secrets : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUSH_SECRET (créés par outils/cles-notifications.ps1).
//  SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par Supabase.
// ============================================================
const URL_ = Deno.env.get("SUPABASE_URL") ?? "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PUB = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const PRIV = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const SECRET = Deno.env.get("PUSH_SECRET") ?? "";
const SUBJECT = "mailto:contact@dexcraft.fr";
const te = new TextEncoder();

const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64 = (s: string) => Uint8Array.from(atob((s + "=".repeat((4 - s.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const concat = (...a: Uint8Array[]) => { const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; };

// clé privée VAPID (ECDSA P-256) : d (32 octets) + clé publique non compressée (65 octets : 04, x, y)
let vapidKey: CryptoKey | null = null;
async function vapid(): Promise<CryptoKey> {
  if (vapidKey) return vapidKey;
  const p = unb64(PUB);
  vapidKey = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: b64(p.slice(1, 33)), y: b64(p.slice(33, 65)), d: PRIV, ext: true },
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return vapidKey;
}
// en-tête Authorization : jeton JWT signé (ES256) pour le service de notifications de l'abonnement
async function vapidAuth(endpoint: string): Promise<string> {
  const h = b64(te.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const c = b64(te.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: SUBJECT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await vapid(), te.encode(h + "." + c)));
  return `vapid t=${h}.${c}.${b64(sig)}, k=${PUB}`;
}
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, len * 8));
}
// chiffrement du message pour un abonnement (RFC 8291, codage aes128gcm de la RFC 8188, un seul bloc)
async function encrypt(p256dh: string, auth: string, text: string): Promise<Uint8Array> {
  const ua = unb64(p256dh), secret = unb64(auth);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", ua, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(secret, shared, concat(te.encode("WebPush: info\0"), ua, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(te.encode(text), new Uint8Array([2]))));
  return concat(salt, new Uint8Array([0, 0, 16, 0]), new Uint8Array([asPub.length]), asPub, ct);
}
// version en ligne : début d'index.html sur le site, lu jusqu'à APP_VERSION
async function siteVersion(): Promise<string> {
  try {
    const r = await fetch("https://dexcraft.fr/?vc=" + Date.now(), { headers: { "Cache-Control": "no-cache" } });
    const rd = r.body!.getReader(), dec = new TextDecoder();
    let t = "";
    while (t.length < 700000) {
      const { done, value } = await rd.read();
      if (done) break;
      t += dec.decode(value, { stream: true });
      const m = t.match(/APP_VERSION="(\d+\.\d+\.\d+)"/);
      if (m) { rd.cancel().catch(() => {}); return m[1]; }
    }
  } catch (_) { /* site injoignable : pas de notification de version cette fois */ }
  return "";
}
async function rpc(fn: string, args: unknown) {
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${fn} : ${r.status} ${await r.text()}`);
  return r.json();
}

type Due = { endpoint: string; p256dh: string; auth: string; kind: string; title: string; body: string };

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-dc-secret") !== SECRET) return new Response("Refusé.", { status: 401 });
  if (!PUB || !PRIV) return new Response("Clés VAPID absentes.", { status: 500 });
  try {
    const due: Due[] = await rpc("dc_push_due", { p_ver: await siteVersion() });
    const gone: string[] = [];
    let sent = 0;
    await Promise.all(due.map(async (n) => {
      try {
        const body = await encrypt(n.p256dh, n.auth, JSON.stringify({ kind: n.kind, title: n.title, body: n.body }));
        const r = await fetch(n.endpoint, {
          method: "POST", body,
          headers: { "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", TTL: "86400", Urgency: "normal", Topic: "dc-" + n.kind,
            Authorization: await vapidAuth(n.endpoint) } });
        if (r.status === 404 || r.status === 410) gone.push(n.endpoint);
        else if (r.ok) sent++;
        else console.warn("notification refusée", r.status, await r.text());
      } catch (e) { console.warn("notification impossible", String(e)); }
    }));
    if (gone.length) await rpc("dc_push_drop", { p_endpoints: gone });
    return new Response(JSON.stringify({ due: due.length, sent, gone: gone.length }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
