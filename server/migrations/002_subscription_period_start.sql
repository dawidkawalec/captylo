-- The start of the current period. Stripe moves the period to the next one when it creates the
-- renewal invoice, before it charges the card, so a subscription that turns past_due on a failed
-- renewal already has its period end a month or a year ahead. The past_due grace counts from
-- this start instead (src/lib/entitlement.ts).
alter table subscriptions add column current_period_start timestamptz;

-- Rows written before this migration: one plan interval before the end, which is what Stripe
-- stores for a renewing subscription. The next webhook event replaces it with Stripe's value.
update subscriptions
   set current_period_start = current_period_end - case plan when 'yearly' then interval '1 year' else interval '1 month' end;

alter table subscriptions alter column current_period_start set not null;
