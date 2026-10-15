import { createClient } from "npm:@supabase/supabase-js@2";

// CJN Solar funnel -> CJN CRM.
//
// Fired by the AFTER INSERT trigger on `leads` (see the
// 20261014000000_leads_and_crm_forward.sql migration) with { id }. We claim
// the lead, POST it to the CRM as JSON with the X-API-Key header, and write
// crm_synced_at / crm_status / crm_response back, or crm_error if the CRM
// refused. Re-sends of a lead the CRM already has are no-ops.
//
// The CRM key is the CJN_CRM_API_KEY edge function secret. The function only
// ever sends leads from this project to that one CRM, so it needs no caller
// secret (deploy with Verify JWT off).

const CRM_URL = "https://crm.cjnsolar.com.au/api/leads/quote";
const CRM_API_KEY = Deno.env.get("CJN_CRM_API_KEY");

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const { id } = await req.json().catch(() => ({}));
  if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) {
    return json({ error: "id (uuid) required" }, 400);
  }
  if (!CRM_API_KEY) return json({ error: "CJN_CRM_API_KEY secret is not set" }, 500);

  const { data: claimed, error: claimErr } = await db.rpc("claim_lead_for_crm", { lead_id: id });
  if (claimErr) return json({ error: claimErr.message }, 500);
  const lead = claimed?.[0];
  if (!lead) return json({ ok: true, skipped: "already sent, in progress, or not found" });

  // Exactly the fields the CRM expects.
  const payload = {
    name: lead.name,
    email: lead.email,
    phone: lead.phone,
    postcode: lead.postcode,
    average_quarterly_bill: lead.average_quarterly_bill,
    existing_solar: lead.existing_solar,
    interested_in: lead.interested_in,
    purchase_timeframe: lead.purchase_timeframe,
  };

  let status = 0;
  let body = "";
  try {
    const res = await fetch(CRM_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-API-Key": CRM_API_KEY,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(20000),
    });
    status = res.status;
    body = (await res.text()).slice(0, 2000);
  } catch (e) {
    body = String(e).slice(0, 2000);
  }

  const ok = status >= 200 && status < 300;
  const { error: saveErr } = await db.from("leads").update(
    ok
      ? { crm_synced_at: new Date().toISOString(), crm_status: status, crm_response: body, crm_error: null }
      // release the claim so send_leads_to_crm() can retry straight away
      : { crm_status: status || null, crm_response: body, crm_error: status ? `CRM returned ${status}` : body, crm_claimed_at: null },
  ).eq("id", id);
  if (saveErr) console.error("Could not record CRM result for", id, saveErr.message);

  if (!ok) {
    console.error(`CRM refused lead ${id}: ${status} ${body}`);
    return json({ ok: false, status, body }, 502);
  }
  return json({ ok: true, status });
});
