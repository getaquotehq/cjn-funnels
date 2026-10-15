-- CJN Solar: Gold Coast free quote funnel
--
-- 1. `leads` table. The website (anon / publishable key) can only INSERT.
--    Nobody can read leads back without the service role.
-- 2. On insert, pg_net calls the `crm-forward` edge function with the lead id.
--    It POSTs the lead to https://crm.cjnsolar.com.au/api/leads/quote with the
--    X-API-Key header and records the result in the crm_* columns.
--    The call is asynchronous, so the website always saves the lead even if the
--    CRM is down; `select public.send_leads_to_crm();` re-sends anything unsent.
--
-- BEFORE running this:
--   1. Edge Functions > Secrets: add CJN_CRM_API_KEY = <the CRM API key>
--   2. deploy supabase/functions/crm-forward with "Verify JWT" OFF.

create extension if not exists pg_net;

-- ---------- LEADS TABLE ----------
create table if not exists public.leads (
  id                     uuid primary key default gen_random_uuid(),
  created_at             timestamptz not null default now(),
  name                   text not null check (char_length(name) between 1 and 120),
  email                  text not null check (char_length(email) <= 200 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone                  text not null check (phone ~ '^0\d{9}$'),
  postcode               text not null check (postcode ~ '^\d{4}$'),
  average_quarterly_bill text not null check (average_quarterly_bill in ('Under $400','$400–$600','$600–$1,000','Over $1,000')),
  existing_solar         text not null check (existing_solar in ('Yes','No')),
  interested_in          text not null check (interested_in in ('Solar','Battery','Solar + Battery','Not sure')),
  purchase_timeframe     text not null check (purchase_timeframe in ('ASAP','Within 3 months','Within 6 months','Just researching')),
  source                 text check (char_length(source) <= 100),
  tracking               jsonb not null default '{}'::jsonb check (pg_column_size(tracking) < 4000),
  -- filled in by crm-forward
  crm_claimed_at         timestamptz,
  crm_synced_at          timestamptz,
  crm_status             integer,
  crm_response           text,
  crm_error              text,
  crm_attempts           integer not null default 0
);

create index if not exists leads_created_at_idx on public.leads (created_at desc);
create index if not exists leads_unsynced_idx   on public.leads (created_at) where crm_synced_at is null;

alter table public.leads enable row level security;

-- Website may insert new leads only. With no select/update/delete policies,
-- anon can't read anything back, and the column grant stops it setting crm_*.
drop policy if exists "anon can insert leads" on public.leads;
create policy "anon can insert leads"
  on public.leads for insert
  to anon
  with check (true);

revoke all on public.leads from anon, authenticated;
grant insert (name, email, phone, postcode, average_quarterly_bill, existing_solar,
              interested_in, purchase_timeframe, source, tracking)
  on public.leads to anon;

-- ---------- FORWARD TO CRM ----------

-- Hand a lead to exactly one forward run. Returns nothing if it's already in
-- the CRM or another run claimed it in the last 2 minutes.
create or replace function public.claim_lead_for_crm(lead_id uuid)
returns setof public.leads
language sql
security definer
set search_path = public
as $$
  update public.leads
     set crm_claimed_at = now(),
         crm_attempts   = crm_attempts + 1
   where id = lead_id
     and crm_synced_at is null
     and (crm_claimed_at is null or crm_claimed_at < now() - interval '2 minutes')
  returning *;
$$;

create or replace function public.send_lead_to_crm(lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url     := 'https://mbefnausrztqjayvurae.supabase.co/functions/v1/crm-forward',
    body    := jsonb_build_object('id', lead_id),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 30000
  );
end;
$$;

create or replace function public.leads_send_to_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Never let the forward break the website's insert.
  begin
    perform public.send_lead_to_crm(new.id);
  exception when others then
    raise warning 'send to CRM failed for lead %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists leads_send_to_crm on public.leads;
create trigger leads_send_to_crm
  after insert on public.leads
  for each row execute function public.leads_send_to_crm();

-- Re-send every lead the CRM doesn't have yet (safe to run repeatedly).
create or replace function public.send_leads_to_crm()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from public.leads where crm_synced_at is null order by created_at loop
    perform public.send_lead_to_crm(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- These run as the table owner; keep them away from the website's roles.
revoke all on function public.claim_lead_for_crm(uuid) from public, anon, authenticated;
revoke all on function public.send_lead_to_crm(uuid)   from public, anon, authenticated;
revoke all on function public.leads_send_to_crm()      from public, anon, authenticated;
revoke all on function public.send_leads_to_crm()      from public, anon, authenticated;
grant execute on function public.claim_lead_for_crm(uuid) to service_role;

-- ---------- LEAD INBOX VIEW ----------
-- Table Editor > Views > lead_inbox: newest first, Brisbane time, CRM status.
create or replace view public.lead_inbox
with (security_invoker = true) as
select
  to_char(created_at at time zone 'Australia/Brisbane', 'DD Mon YYYY HH12:MI am') as received,
  name,
  phone,
  email,
  postcode,
  interested_in,
  existing_solar,
  average_quarterly_bill,
  purchase_timeframe,
  case when crm_synced_at is not null then 'Sent'
       when crm_error is not null     then 'Failed'
       else 'Pending' end as crm,
  crm_error,
  tracking->>'utm_campaign' as campaign,
  id
from public.leads
order by created_at desc;

revoke all on public.lead_inbox from anon, authenticated;
