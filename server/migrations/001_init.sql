-- Captylo API: users, login codes, sessions, subscriptions, monthly usage, applied Stripe events.
-- The server stores no audio and no text: only the account, its plan and monthly counts.

create extension if not exists citext;

create table users (
  id uuid primary key,
  email citext not null unique,
  stripe_customer_id text unique,
  created_at timestamptz not null default now()
);

create table login_codes (
  id uuid primary key,
  email citext not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  consumed_at timestamptz
);
create index login_codes_email on login_codes (email, expires_at);

create table sessions (
  id uuid primary key,
  user_id uuid not null references users (id) on delete cascade,
  token_hash text not null unique,
  device text not null default '',
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index sessions_user on sessions (user_id);

create table subscriptions (
  user_id uuid primary key references users (id) on delete cascade,
  stripe_subscription_id text not null unique,
  status text not null,                 -- Stripe status string
  plan text not null check (plan in ('yearly', 'monthly')),
  current_period_end timestamptz not null,
  cancel_at_period_end boolean not null default false,
  event_created bigint not null,        -- Stripe event.created of the last applied event
  updated_at timestamptz not null default now()
);

create table usage_monthly (
  user_id uuid not null references users (id) on delete cascade,
  month text not null,                  -- 'YYYY-MM' in UTC
  audio_seconds bigint not null default 0,
  ai_tokens bigint not null default 0,
  primary key (user_id, month)
);

create table stripe_events (
  id text primary key,
  received_at timestamptz not null default now()
);
