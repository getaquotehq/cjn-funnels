# cjn-funnels

CJN Solar Gold Coast free quote landing page (`index.html`) and its privacy policy (`privacy-policy/`). Static files with no build step, so they can be hosted anywhere (GitHub Pages, Netlify, etc.).

The Meta Pixel is not added yet. Paste CJN's pixel snippet where the `<!-- Meta Pixel -->` comment sits in `<head>`. The form already fires `fbq('track', 'Lead')` once a lead is saved.

## Backend (Supabase project `mbefnausrztqjayvurae`)

Supabase sits between the page and CJN's CRM. The page saves each lead into `leads` using the anon key, which can only insert. A trigger then hands the lead to the `crm-forward` edge function. That function POSTs it to `https://crm.cjnsolar.com.au/api/leads/quote` with the `X-API-Key` header. The CRM key never reaches the browser.

1. **Secret:** Dashboard > Edge Functions > Secrets > add `CJN_CRM_API_KEY` = the CRM API key.
2. **Function:** deploy `supabase/functions/crm-forward` with **Verify JWT off**. Either run `supabase functions deploy crm-forward --no-verify-jwt`, or go to Dashboard > Edge Functions > Deploy a new function > Via editor, name it `crm-forward`, paste `index.ts` and untick Verify JWT.
3. **SQL:** run `supabase/migrations/20261014000000_leads_and_crm_forward.sql` once in the SQL Editor.

Each lead's CRM result is recorded on its row:
- `crm_synced_at`, `crm_status` and `crm_response` are filled in when the CRM accepts it.
- `crm_error` says why when the CRM refuses it.

`lead_inbox` (Table Editor > Views) lists leads newest first with Sent / Failed / Pending.

To re-send anything the CRM doesn't have yet, run: `select public.send_leads_to_crm();`

### What the CRM receives

```json
{
  "name": "Jane Smith",
  "email": "jane@example.com",
  "phone": "0412345678",
  "postcode": "4215",
  "average_quarterly_bill": "$400–$600",
  "existing_solar": "No",
  "interested_in": "Solar + Battery",
  "purchase_timeframe": "Within 6 months"
}
```

| Field | Values |
|---|---|
| `interested_in` | `Solar + Battery`, `Battery`, `Solar`, `Not sure` |
| `existing_solar` | `Yes`, `No` |
| `average_quarterly_bill` | `Under $400`, `$400–$600`, `$600–$1,000`, `Over $1,000` (en dash) |
| `purchase_timeframe` | `ASAP`, `Within 3 months`, `Within 6 months`, `Just researching` |

Phone is sent as 10 digits starting with 0. A `+61` number is converted.

Postcodes that don't start with 4 or 9 (non-QLD) get an "outside our area" message and aren't submitted.
