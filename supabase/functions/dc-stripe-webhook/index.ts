// ============================================================
//  DexCraft — dc-stripe-webhook (fonction Supabase, 0.9.0)
//  Reçoit les événements de Stripe. C'est le SEUL chemin qui livre un pack payant : la signature de Stripe est
//  vérifiée, puis dc_pay_grant (SQL, réservée au service Supabase) ajoute les articles au compte, une seule fois.
//  À déployer SANS vérification de connexion (« Verify JWT » désactivé) : c'est Stripe qui l'appelle.
//  Secrets : STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET (whsec_…, donné par Stripe à la création du webhook).
//  Événements à cocher dans Stripe : checkout.session.completed, checkout.session.async_payment_succeeded.
// ============================================================
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", { apiVersion: "2024-06-20" });
const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Méthode non autorisée", { status: 405 });
  const sig = req.headers.get("stripe-signature");
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "", undefined, cryptoProvider);
  } catch (e) {
    console.error("signature Stripe invalide", e);
    return new Response("Signature invalide", { status: 400 });
  }

  try {
    if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
      const s = event.data.object as Stripe.Checkout.Session;
      if (s.payment_status === "paid" && s.metadata?.uid && s.metadata?.offer) {
        const { error } = await admin.rpc("dc_pay_grant", {
          p_session: s.id, p_uid: s.metadata.uid, p_offer: s.metadata.offer,
          p_amount: s.amount_total ?? 0, p_pi: typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id ?? null,
        });
        if (error) throw error; // Stripe réessaiera plus tard
      }
    }
    return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("dc-stripe-webhook", event.type, e);
    return new Response("Erreur de traitement", { status: 500 });
  }
});
