// ============================================================
//  DexCraft — dc-paiement (fonction Supabase, 0.9.0)
//  Crée la session de paiement Stripe Checkout pour une offre de la boutique cosmétique.
//  Appelée par le jeu (supabase.functions.invoke) avec la connexion du joueur.
//  Le prix est relu dans la configuration du serveur (game_config, cfg.shop) : jamais celui envoyé par le navigateur.
//  Secrets à définir dans Supabase (Edge Functions, Secrets) : STRIPE_SECRET_KEY ; PAY_ADMIN_ONLY=1 pendant les tests
//  (seuls les administrateurs peuvent alors acheter). SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par Supabase.
// ============================================================
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", { apiVersion: "2024-06-20" });
const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
// adresses du jeu autorisées (retour après paiement)
const ORIGINS = ["https://dexcraft.fr", "https://www.dexcraft.fr", "http://localhost:8123", "http://127.0.0.1:8123"];

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  const base = ORIGINS.includes(origin) ? origin : "https://dexcraft.fr";
  const cors = {
    "Access-Control-Allow-Origin": base,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);

  try {
    // joueur connecté
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: { user }, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !user) return json({ error: "Connectez-vous pour acheter." }, 401);

    const { offer, consent } = await req.json().catch(() => ({}));
    if (consent !== true) return json({ error: "Cochez les deux cases pour continuer." }, 400);

    // pendant les tests : boutique réservée aux administrateurs
    if (Deno.env.get("PAY_ADMIN_ONLY") === "1") {
      const { data: a, error: aErr } = await admin.from("admins").select("uid").eq("uid", user.id).maybeSingle();
      if (aErr) throw aErr;
      if (!a) return json({ error: "La boutique ouvre très bientôt !" }, 403);
    }

    // offre et prix : configuration du serveur
    const { data: cfg, error: cfgErr } = await admin.from("game_config").select("data").eq("id", 1).single();
    if (cfgErr || !cfg) throw cfgErr ?? new Error("configuration introuvable");
    const o = cfg.data?.shop?.offers?.[String(offer)];
    if (!o || !Number.isInteger(o.eur) || o.eur < 50) return json({ error: "Cette offre n’existe pas." }, 400);

    // déjà possédée ?
    const { data: doc } = await admin.from("docs").select("data").eq("path", "players/" + user.id).maybeSingle();
    const cos = doc?.data?.cos ?? {};
    if ((o.items as string[]).every((i) => cos[i])) return json({ error: "Vous possédez déjà cette offre." }, 400);

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      locale: "fr",
      line_items: [{
        quantity: 1,
        price_data: { currency: "eur", unit_amount: o.eur, product_data: { name: "DexCraft — " + o.n } },
      }],
      customer_email: user.email ?? undefined,
      client_reference_id: user.id,
      metadata: { uid: user.id, offer: String(offer), consent: new Date().toISOString() },
      payment_intent_data: { metadata: { uid: user.id, offer: String(offer) } },
      success_url: base + "/?paiement=ok&offre=" + encodeURIComponent(String(offer)),
      cancel_url: base + "/?paiement=annule",
    });
    await admin.from("payments").insert({ session_id: session.id, uid: user.id, offer: String(offer), amount: o.eur });
    return json({ url: session.url });
  } catch (e) {
    console.error("dc-paiement", e);
    const detail = e instanceof Error ? e.message : (e as { message?: string })?.message ?? "";
    return json({ error: "Le paiement n’est pas disponible pour le moment. Réessayez plus tard." + (detail ? " (" + detail + ")" : "") }, 500);
  }
});
