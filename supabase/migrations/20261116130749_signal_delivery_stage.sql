-- Dormant Signal transport. Enrollment alone never enables delivery or migration.
create table app_private.signal_delivery_rollout (
 user_id uuid primary key references auth.users(id) on delete cascade,
 enabled boolean not null default false
);
create table app_private.signal_conversations (
 low_user uuid not null, high_user uuid not null,
 low_device smallint not null, high_device smallint not null,
 low_identity text not null, high_identity text not null,
 low_approved boolean not null default false, high_approved boolean not null default false,
 active_at timestamptz, primary key(low_user,high_user), check(low_user<high_user),
 foreign key(low_user,low_device) references public.signal_devices(user_id,device_id) on delete cascade,
 foreign key(high_user,high_device) references public.signal_devices(user_id,device_id) on delete cascade
);
create table app_private.signal_mailboxes (
 user_id uuid not null, device_id smallint not null,
 next_seq bigint not null default 0, ack_seq bigint not null default 0,
 primary key(user_id,device_id), check(ack_seq>=0 and ack_seq<=next_seq),
 foreign key(user_id,device_id) references public.signal_devices(user_id,device_id) on delete cascade
);
create table app_private.signal_messages (
 id uuid primary key, sender uuid not null, sender_device smallint not null,
 recipient uuid not null, recipient_device smallint not null,
 seq bigint not null, packet jsonb not null, created_at timestamptz not null default now(),
 unique(recipient,recipient_device,seq),
 foreign key(sender,sender_device) references public.signal_devices(user_id,device_id) on delete cascade,
 foreign key(recipient,recipient_device) references public.signal_devices(user_id,device_id) on delete cascade
);
create index signal_messages_sender_rate on app_private.signal_messages(sender,created_at);
-- Only an opaque wake-up is queued. No FCM worker is activated by this stage.
create table app_private.signal_wakeups (
 message_id uuid primary key references app_private.signal_messages(id) on delete cascade,
 recipient uuid not null, device_id smallint not null, seq bigint not null,
 created_at timestamptz not null default now()
);
alter table app_private.signal_delivery_rollout enable row level security;
alter table app_private.signal_conversations enable row level security;
alter table app_private.signal_mailboxes enable row level security;
alter table app_private.signal_messages enable row level security;
alter table app_private.signal_wakeups enable row level security;
revoke all on app_private.signal_delivery_rollout,app_private.signal_conversations,
 app_private.signal_mailboxes,app_private.signal_messages,app_private.signal_wakeups from public,anon,authenticated;

create function app_private.signal_delivery_actor() returns uuid
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_actor(); enabled boolean;
begin
 if current_setting('transaction_isolation')<>'read committed' then
  raise exception 'SIGNAL_RETRY_READ_COMMITTED' using errcode='40001';
 end if;
 select r.enabled into enabled from app_private.signal_delivery_rollout r where r.user_id=actor for share;
 if enabled is distinct from true then raise exception 'SIGNAL_DELIVERY_DISABLED' using errcode='42501'; end if;
 return actor;
end $$;
create function app_private.signal_delivery_peer(actor uuid,peer uuid) returns void
language plpgsql security definer set search_path='' as $$
declare enabled boolean;
begin
 perform app_private.signal_peer(actor,peer);
 select r.enabled into enabled from app_private.signal_delivery_rollout r where r.user_id=peer for share;
 if enabled is distinct from true then raise exception 'SIGNAL_DELIVERY_DISABLED' using errcode='42501'; end if;
end $$;
create function app_private.signal_own_device(actor uuid,device integer,installation uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.signal_devices where user_id=actor and device_id=device
  and installation_id=installation and revoked_at is null for share;
 if not found then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
end $$;

-- The caller must verify/pin peer identity locally BEFORE this approval.
-- A JWT authorizes an account; it is not proof of possession of a device secret.
create function public.signal_approve_conversation(p_peer uuid,p_device integer,p_installation uuid,
 p_peer_device integer,p_peer_identity text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_delivery_actor(); own_key text; peer_key text;
 lo uuid:=least(actor,p_peer); hi uuid:=greatest(actor,p_peer);
 ld integer; hd integer; lk text; hk text; c app_private.signal_conversations;
begin
 perform app_private.signal_delivery_peer(actor,p_peer);
 perform app_private.signal_own_device(actor,p_device,p_installation);
 select identity_key into own_key from public.signal_devices where user_id=actor and device_id=p_device;
 select identity_key into peer_key from public.signal_devices
  where user_id=p_peer and device_id=p_peer_device and revoked_at is null for share;
 if peer_key is null then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
 if peer_key is distinct from p_peer_identity then raise exception 'SIGNAL_IDENTITY_MISMATCH' using errcode='42501'; end if;
 ld:=case when actor=lo then p_device else p_peer_device end;
 hd:=case when actor=hi then p_device else p_peer_device end;
 lk:=case when actor=lo then own_key else peer_key end;
 hk:=case when actor=hi then own_key else peer_key end;
 -- Same lock as the existing v1 guard. A waiting legacy write rechecks AFTER
 -- activation commits; a legacy write that owns it first commits before cutover.
 perform pg_advisory_xact_lock(hashtextextended(lo::text||':'||hi::text,90842));
 insert into app_private.signal_conversations(low_user,high_user,low_device,high_device,low_identity,high_identity)
 values(lo,hi,ld,hd,lk,hk) on conflict do nothing;
 select * into c from app_private.signal_conversations where low_user=lo and high_user=hi for update;
 if c.low_device<>ld or c.high_device<>hd or c.low_identity<>lk or c.high_identity<>hk then
  raise exception 'SIGNAL_APPROVAL_CONTEXT_CHANGED' using errcode='42501';
 end if;
 update app_private.signal_conversations set
  low_approved=low_approved or actor=lo, high_approved=high_approved or actor=hi,
  active_at=case when (low_approved or actor=lo) and (high_approved or actor=hi)
   then coalesce(active_at,now()) else active_at end
 where low_user=lo and high_user=hi returning * into c;
 return jsonb_build_object('conversation','dm:'||lo::text||':'||hi::text,
  'active',c.active_at is not null,'own_approved',true,
  'peer_approved',case when actor=lo then c.high_approved else c.low_approved end);
end $$;

create function public.signal_send_packet(p_peer uuid,p_device integer,p_installation uuid,p_packet jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_delivery_actor(); c app_private.signal_conversations;
 lo uuid:=least(actor,p_peer); hi uuid:=greatest(actor,p_peer);
 target_device integer; msg_id uuid; raw bytea; n bigint; old app_private.signal_messages;
begin
 perform app_private.signal_delivery_peer(actor,p_peer);
 perform app_private.signal_own_device(actor,p_device,p_installation);
 perform pg_advisory_xact_lock(hashtextextended(actor::text,92314));
 perform pg_advisory_xact_lock(hashtextextended(lo::text||':'||hi::text,90842));
 select * into c from app_private.signal_conversations where low_user=lo and high_user=hi;
 if c.active_at is null then raise exception 'SIGNAL_CONVERSATION_NOT_ACTIVE' using errcode='42501'; end if;
 if p_device<>(case when actor=lo then c.low_device else c.high_device end) then
  raise exception 'SIGNAL_APPROVAL_CONTEXT_CHANGED' using errcode='42501'; end if;
 target_device:=case when actor=lo then c.high_device else c.low_device end;
 perform 1 from public.signal_devices where user_id=p_peer and device_id=target_device and revoked_at is null for share;
 if not found then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
 if jsonb_typeof(p_packet) is distinct from 'object' or octet_length(p_packet::text)>98304 then
  raise exception 'SIGNAL_INVALID_PACKET' using errcode='22023'; end if;
 if (select count(*) from jsonb_object_keys(p_packet))<>9 or
  p_packet->>'v' is distinct from 'pulsepath-signal-v2' or
  p_packet->>'sender' is distinct from actor::text or p_packet->>'recipient' is distinct from p_peer::text or
  p_packet->'senderDevice' is distinct from to_jsonb(p_device) or
  p_packet->'recipientDevice' is distinct from to_jsonb(target_device) or
  p_packet->>'conversation' is distinct from 'dm:'||lo::text||':'||hi::text or
  (p_packet->'type' is distinct from '2'::jsonb and p_packet->'type' is distinct from '3'::jsonb) or
  jsonb_typeof(p_packet->'id') is distinct from 'string' or
  (p_packet->>'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or
  jsonb_typeof(p_packet->'ciphertext') is distinct from 'string' or
  length(p_packet->>'ciphertext') not between 4 and 87384 or
  (p_packet->>'ciphertext') !~ '^[A-Za-z0-9+/]+={0,2}$' then
  raise exception 'SIGNAL_INVALID_PACKET' using errcode='22023'; end if;
 begin raw:=decode(p_packet->>'ciphertext','base64');
 exception when others then raise exception 'SIGNAL_INVALID_PACKET' using errcode='22023'; end;
 if octet_length(raw) not between 1 and 65536 or
  replace(encode(raw,'base64'),E'\n','')<>p_packet->>'ciphertext' then
  raise exception 'SIGNAL_INVALID_PACKET' using errcode='22023'; end if;
 msg_id:=(p_packet->>'id')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(msg_id::text,92315));
 select * into old from app_private.signal_messages where id=msg_id;
 if found then
  if old.sender<>actor or old.packet<>p_packet then raise exception 'SIGNAL_MESSAGE_CONFLICT' using errcode='42501'; end if;
  return jsonb_build_object('id',old.id,'seq',old.seq,'accepted_at',old.created_at);
 end if;
 if (select count(*) from app_private.signal_messages where sender=actor and created_at>now()-interval '1 minute')>=60 or
  (select count(*) from app_private.signal_messages where sender=actor)>=10000 then
  raise exception 'SIGNAL_SEND_QUOTA' using errcode='54000'; end if;
 insert into app_private.signal_mailboxes(user_id,device_id,next_seq) values(p_peer,target_device,1)
 on conflict(user_id,device_id) do update set next_seq=signal_mailboxes.next_seq+1
 returning next_seq into n;
 if (select next_seq-ack_seq from app_private.signal_mailboxes where user_id=p_peer and device_id=target_device)>1000 then
  raise exception 'SIGNAL_MAILBOX_FULL' using errcode='54000'; end if;
 insert into app_private.signal_messages(id,sender,sender_device,recipient,recipient_device,seq,packet)
 values(msg_id,actor,p_device,p_peer,target_device,n,p_packet) returning * into old;
 insert into app_private.signal_wakeups(message_id,recipient,device_id,seq) values(msg_id,p_peer,target_device,n);
 return jsonb_build_object('id',old.id,'seq',old.seq,'accepted_at',old.created_at);
end $$;

-- No caller-supplied cursor: fetch always returns the oldest UNACKED packets.
-- The client must durably decrypt/cache each packet before acknowledging it.
create function public.signal_pull_packets(p_device integer,p_installation uuid,p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_delivery_actor(); result jsonb;
begin
 perform app_private.signal_own_device(actor,p_device,p_installation);
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'SIGNAL_INVALID_LIMIT' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('seq',s.seq,'packet',s.packet,'accepted_at',s.created_at) order by s.seq),'[]'::jsonb)
 into result from (select m.seq,m.packet,m.created_at from app_private.signal_messages m
  join app_private.signal_mailboxes b on b.user_id=m.recipient and b.device_id=m.recipient_device
  where m.recipient=actor and m.recipient_device=p_device and m.seq>b.ack_seq
  order by m.seq limit p_limit) s;
 return result;
end $$;
create function public.signal_ack_packet(p_device integer,p_installation uuid,p_id uuid,p_seq bigint)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_delivery_actor(); b app_private.signal_mailboxes;
begin
 perform app_private.signal_own_device(actor,p_device,p_installation);
 select * into b from app_private.signal_mailboxes where user_id=actor and device_id=p_device for update;
 if not found or p_id is null or p_seq is null or p_seq<1 or p_seq>b.ack_seq+1 or
  not exists(select 1 from app_private.signal_messages where id=p_id and recipient=actor and recipient_device=p_device and seq=p_seq) then
  raise exception 'SIGNAL_ACK_OUT_OF_ORDER' using errcode='22023'; end if;
 if p_seq=b.ack_seq+1 then
  update app_private.signal_mailboxes set ack_seq=p_seq where user_id=actor and device_id=p_device;
 end if;
end $$;

create function app_private.signal_downgrade_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' and
  (to_jsonb(NEW)-'read_at'-'reactions'-'reply_to_id') is not distinct from
  (to_jsonb(OLD)-'read_at'-'reactions'-'reply_to_id') then return NEW; end if;
 if current_setting('transaction_isolation')<>'read committed' then
  raise exception 'SIGNAL_RETRY_READ_COMMITTED' using errcode='40001'; end if;
 perform pg_advisory_xact_lock(hashtextextended(
  least(NEW.sender_id,NEW.receiver_id)::text||':'||greatest(NEW.sender_id,NEW.receiver_id)::text,90842));
 if exists(select 1 from app_private.signal_conversations where
  low_user=least(NEW.sender_id,NEW.receiver_id) and high_user=greatest(NEW.sender_id,NEW.receiver_id) and active_at is not null) then
  raise exception 'SIGNAL_UPGRADE_REQUIRED' using errcode='42501'; end if;
 return NEW;
end $$;
create trigger signal_downgrade_guard before insert or update on public.chat_messages
 for each row execute function app_private.signal_downgrade_guard();

revoke all on function app_private.signal_delivery_actor(),app_private.signal_delivery_peer(uuid,uuid),
 app_private.signal_own_device(uuid,integer,uuid),app_private.signal_downgrade_guard() from public,anon,authenticated;
revoke all on function public.signal_approve_conversation(uuid,integer,uuid,integer,text),
 public.signal_send_packet(uuid,integer,uuid,jsonb),public.signal_pull_packets(integer,uuid,integer),
 public.signal_ack_packet(integer,uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.signal_approve_conversation(uuid,integer,uuid,integer,text),
 public.signal_send_packet(uuid,integer,uuid,jsonb),public.signal_pull_packets(integer,uuid,integer),
 public.signal_ack_packet(integer,uuid,uuid,bigint) to authenticated;
