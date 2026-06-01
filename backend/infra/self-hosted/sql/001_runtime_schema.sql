create table if not exists runtime_conversations (
  conversation_id text primary key,
  conversation_seq bigint not null,
  policy_version text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists runtime_participants (
  conversation_id text not null references runtime_conversations(conversation_id) on delete cascade,
  participant_id text not null,
  friend_id text not null,
  primary key (conversation_id, participant_id)
);

create table if not exists runtime_participant_devices (
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  primary key (conversation_id, participant_id, device_id),
  foreign key (conversation_id, participant_id)
    references runtime_participants(conversation_id, participant_id)
    on delete cascade
);

create table if not exists runtime_sessions (
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  session_epoch bigint not null,
  last_seen_ms bigint not null,
  primary key (conversation_id, participant_id, device_id),
  foreign key (conversation_id, participant_id, device_id)
    references runtime_participant_devices(conversation_id, participant_id, device_id)
    on delete cascade
);

create table if not exists runtime_device_presence (
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  observed_at_ms bigint not null,
  primary key (conversation_id, participant_id, device_id),
  foreign key (conversation_id, participant_id, device_id)
    references runtime_participant_devices(conversation_id, participant_id, device_id)
    on delete cascade
);

create table if not exists runtime_device_audio_readiness (
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  session_epoch bigint not null,
  observed_at_ms bigint not null,
  primary key (conversation_id, participant_id, device_id),
  foreign key (conversation_id, participant_id, device_id)
    references runtime_participant_devices(conversation_id, participant_id, device_id)
    on delete cascade
);

create table if not exists runtime_wake_targets (
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  observed_at_ms bigint not null,
  token_ref text not null,
  primary key (conversation_id, participant_id, device_id),
  foreign key (conversation_id, participant_id, device_id)
    references runtime_participant_devices(conversation_id, participant_id, device_id)
    on delete cascade
);

create table if not exists runtime_current_talk_turns (
  conversation_id text primary key references runtime_conversations(conversation_id) on delete cascade,
  requesting_participant_id text not null,
  requesting_device_id text not null,
  target_participant_id text not null,
  target_device_id text not null,
  talk_turn_epoch bigint not null,
  expires_at_ms bigint not null,
  recorded_at timestamptz not null default now()
);

create table if not exists runtime_talk_turn_actor_events (
  event_row_id bigserial primary key,
  conversation_id text not null references runtime_conversations(conversation_id) on delete cascade,
  owner_runtime_id text not null,
  owner_epoch bigint not null,
  actor_event_id bigint not null,
  event_kind text not null,
  talk_turn_epoch bigint,
  operation_id text,
  event_json jsonb not null,
  created_at timestamptz not null default now(),
  unique (conversation_id, owner_epoch, actor_event_id)
);

create table if not exists runtime_talk_turn_actor_operation_results (
  result_id bigserial primary key,
  route text not null,
  conversation_id text not null references runtime_conversations(conversation_id) on delete cascade,
  operation_id text not null,
  command_hash text not null,
  result_kind text not null,
  talk_turn_json jsonb not null,
  actor_event_row_ids bigint[] not null,
  created_at timestamptz not null default now(),
  unique (route, operation_id),
  check (result_kind in ('renewed', 'released'))
);

create table if not exists runtime_kernel_replay_facts (
  replay_id bigserial primary key,
  route text not null,
  conversation_id text,
  operation_id text,
  command_hash text not null,
  snapshot_hash text not null,
  decision_hash text not null,
  decision_kind text not null,
  created_at timestamptz not null default now()
);

create unique index if not exists runtime_kernel_replay_facts_route_operation_unique
  on runtime_kernel_replay_facts (route, operation_id)
  where operation_id is not null;

create table if not exists runtime_websocket_authorization_facts (
  fact_id bigserial primary key,
  connection_id text not null,
  conversation_id text not null,
  participant_id text not null,
  device_id text not null,
  session_epoch bigint not null,
  decision text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  check (decision in ('accepted', 'rejected'))
);

create index if not exists runtime_websocket_authorization_facts_connection_created_at
  on runtime_websocket_authorization_facts (connection_id, created_at);

create table if not exists runtime_post_commit_outbox (
  outbox_id bigserial primary key,
  replay_id bigint references runtime_kernel_replay_facts(replay_id) on delete cascade,
  effect_kind text not null,
  effect_json jsonb not null,
  committed_at timestamptz not null default now(),
  delivered_at timestamptz
);
