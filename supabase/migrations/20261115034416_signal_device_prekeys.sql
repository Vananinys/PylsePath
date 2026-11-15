-- Signal server foundation. Rollout is empty/disabled until a client rollout.
create table app_private.signal_rollout (
 user_id uuid primary key references auth.users(id) on delete cascade,
 enabled boolean not null default false
);
revoke all on app_private.signal_rollout from public,anon,authenticated;
create table public.signal_devices (
 user_id uuid not null references auth.users(id) on delete cascade,
 device_id smallint not null check(device_id between 1 and 127),
 installation_id uuid not null, registration_id integer not null check(registration_id between 1 and 16380),
 identity_key text not null, signed_prekey jsonb not null,
 created_at timestamptz not null default now(), revoked_at timestamptz,
 primary key(user_id,device_id), unique(user_id,installation_id)
);
create table public.signal_prekeys (
 user_id uuid not null, device_id smallint not null, key_id integer not null check(key_id>0),
 pq_id integer not null check(pq_id>0), public_key text not null, pq_public text not null,
 pq_signature text not null, claimed_at timestamptz,
 primary key(user_id,device_id,key_id), unique(user_id,device_id,pq_id),
 foreign key(user_id,device_id) references public.signal_devices on delete cascade
);
create index signal_prekeys_available on public.signal_prekeys(user_id,device_id,key_id) where claimed_at is null;
create table app_private.signal_claim_receipts (
 actor uuid not null references auth.users(id) on delete cascade, request_id uuid not null,
 peer uuid not null references auth.users(id) on delete cascade, device_id smallint not null, bundle jsonb not null,
 created_at timestamptz not null default now(), primary key(actor,request_id)
);
create index signal_claim_rate on app_private.signal_claim_receipts(actor,created_at);
alter table app_private.signal_rollout enable row level security;
alter table app_private.signal_claim_receipts enable row level security;
alter table public.signal_devices enable row level security;
alter table public.signal_prekeys enable row level security;
revoke all on public.signal_devices,public.signal_prekeys,app_private.signal_claim_receipts from public,anon,authenticated;

create function app_private.signal_bytes(p text,n integer) returns boolean
language plpgsql immutable set search_path='' as $$
declare b bytea;
begin
 if p is null or length(p)>4096 or p !~ '^[A-Za-z0-9+/]+={0,2}$' then return false; end if;
 begin b:=decode(p,'base64'); exception when others then return false; end;
 return octet_length(b)=n and replace(encode(b,'base64'),E'\n','')=p;
end $$;
create function app_private.signal_key_id(p jsonb) returns integer
language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(p) is distinct from 'number' or p::text !~ '^[0-9]{1,10}$' then raise exception 'SIGNAL_INVALID_KEY_ID' using errcode='22023'; end if;
 if (p::text)::bigint not between 1 and 2147483647 then raise exception 'SIGNAL_INVALID_KEY_ID' using errcode='22023'; end if;
 return (p::text)::integer;
end $$;
create function app_private.signal_actor() returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); allowed boolean;
begin
 if actor is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select enabled into allowed from app_private.signal_rollout where user_id=actor for share;
 if allowed is distinct from true then raise exception 'SIGNAL_ROLLOUT_DISABLED' using errcode='42501'; end if;
 return actor;
end $$;
create function app_private.signal_peer(actor uuid,peer uuid) returns void language plpgsql security definer set search_path='' as $$
declare allowed boolean;
begin
 select enabled into allowed from app_private.signal_rollout where user_id=peer for share;
 if peer=actor or allowed is distinct from true or
 not exists(select 1 from public.friends where user_id=actor and friend_id=peer) or
 not exists(select 1 from public.friends where user_id=peer and friend_id=actor) or
 exists(select 1 from public.chat_blocks where (blocker_id=actor and blocked_id=peer) or (blocker_id=peer and blocked_id=actor)) then
 raise exception 'SIGNAL_PEER_UNAVAILABLE' using errcode='42501'; end if;
end $$;

create function public.signal_register_device(p_installation uuid,p_device integer,p_registration integer,p_identity text,p_signed jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_actor(); d public.signal_devices;
begin
 if p_installation is null or p_device is null or p_device not between 1 and 127 or p_registration is null or p_registration not between 1 and 16380
 or not app_private.signal_bytes(p_identity,33) or jsonb_typeof(p_signed) is distinct from 'object' then
 raise exception 'SIGNAL_INVALID_DEVICE' using errcode='22023'; end if;
 if (select count(*) from jsonb_object_keys(p_signed))<>3 or not app_private.signal_bytes(p_signed->>'public_key',33)
 or not app_private.signal_bytes(p_signed->>'signature',64) then raise exception 'SIGNAL_INVALID_SIGNED_KEY' using errcode='22023'; end if;
 perform app_private.signal_key_id(p_signed->'id');
 perform pg_advisory_xact_lock(hashtextextended(actor::text,92311));
 select * into d from public.signal_devices where user_id=actor and installation_id=p_installation;
 if found then
  if d.revoked_at is not null or d.device_id<>p_device or d.registration_id<>p_registration or d.identity_key<>p_identity or d.signed_prekey<>p_signed then
  raise exception 'SIGNAL_DEVICE_IMMUTABLE' using errcode='42501'; end if;
  return to_jsonb(d);
 end if;
 if exists(select 1 from public.signal_devices where user_id=actor and revoked_at is null) then
 raise exception 'SIGNAL_LINK_APPROVAL_REQUIRED' using errcode='42501'; end if;
 if exists(select 1 from public.signal_devices where user_id=actor and device_id=p_device) then
 raise exception 'SIGNAL_DEVICE_SLOT_USED' using errcode='42501'; end if;
 insert into public.signal_devices(user_id,device_id,installation_id,registration_id,identity_key,signed_prekey)
 values(actor,p_device,p_installation,p_registration,p_identity,p_signed) returning * into d;
 return to_jsonb(d);
end $$;

create function public.signal_publish_prekeys(p_device integer,p_installation uuid,p_keys jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_actor(); d public.signal_devices; k jsonb; old public.signal_prekeys; ec integer; pq integer; inserted integer:=0;
begin
 select * into d from public.signal_devices where user_id=actor and device_id=p_device and installation_id=p_installation and revoked_at is null for update;
 if not found then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
 if jsonb_typeof(p_keys) is distinct from 'array' or octet_length(p_keys::text)>524288 then raise exception 'SIGNAL_INVALID_BATCH' using errcode='22023'; end if;
 if jsonb_array_length(p_keys) not between 1 and 100 then raise exception 'SIGNAL_INVALID_BATCH' using errcode='22023'; end if;
 for k in select value from jsonb_array_elements(p_keys) loop
  if jsonb_typeof(k) is distinct from 'object' then raise exception 'SIGNAL_INVALID_PREKEY' using errcode='22023'; end if;
  if (select count(*) from jsonb_object_keys(k))<>5 or not app_private.signal_bytes(k->>'public_key',33)
  or not app_private.signal_bytes(k->>'pq_public',1569) or not app_private.signal_bytes(k->>'pq_signature',64) then
  raise exception 'SIGNAL_INVALID_PREKEY' using errcode='22023'; end if;
  ec:=app_private.signal_key_id(k->'id'); pq:=app_private.signal_key_id(k->'pq_id');
  select * into old from public.signal_prekeys where user_id=actor and device_id=p_device and key_id=ec;
  if found then
   if old.pq_id<>pq or old.public_key<>k->>'public_key' or old.pq_public<>k->>'pq_public' or old.pq_signature<>k->>'pq_signature' then
   raise exception 'SIGNAL_PREKEY_ID_REUSED' using errcode='42501'; end if;
   continue;
  end if;
  if (select count(*) from public.signal_prekeys where user_id=actor and device_id=p_device)>=10000
  or (select count(*) from public.signal_prekeys where user_id=actor and device_id=p_device and claimed_at is null)>=1000 then
  raise exception 'SIGNAL_PREKEY_QUOTA' using errcode='54000'; end if;
  insert into public.signal_prekeys(user_id,device_id,key_id,pq_id,public_key,pq_public,pq_signature)
  values(actor,p_device,ec,pq,k->>'public_key',k->>'pq_public',k->>'pq_signature');
  inserted:=inserted+1;
 end loop;
 return inserted;
end $$;

create function public.signal_claim_bundle(p_peer uuid,p_device integer,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=app_private.signal_actor(); d public.signal_devices; receipt app_private.signal_claim_receipts; k public.signal_prekeys; bundle jsonb;
begin
 if p_request is null then raise exception 'SIGNAL_REQUEST_REQUIRED' using errcode='22023'; end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'SIGNAL_RETRY_READ_COMMITTED' using errcode='40001'; end if;
 perform app_private.signal_peer(v_actor,p_peer);
 perform pg_advisory_xact_lock(hashtextextended(v_actor::text,92312));
 select * into d from public.signal_devices where user_id=p_peer and device_id=p_device and revoked_at is null for share;
 if not found then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
 select * into receipt from app_private.signal_claim_receipts r where r.actor=v_actor and request_id=p_request;
 if found then
  if receipt.peer<>p_peer or receipt.device_id<>p_device then raise exception 'SIGNAL_REQUEST_CONFLICT' using errcode='22023'; end if;
  return receipt.bundle;
 end if;
 if (select count(*) from app_private.signal_claim_receipts r where r.actor=v_actor and created_at>now()-interval '1 minute')>=30
 or (select count(*) from app_private.signal_claim_receipts r where r.actor=v_actor)>=5000 then
 raise exception 'SIGNAL_CLAIM_QUOTA' using errcode='54000'; end if;
 select * into k from public.signal_prekeys where user_id=p_peer and device_id=p_device and claimed_at is null order by key_id for update skip locked limit 1;
 if not found then raise exception 'SIGNAL_PREKEYS_EXHAUSTED' using errcode='P0001'; end if;
 update public.signal_prekeys set claimed_at=now() where user_id=p_peer and device_id=p_device and key_id=k.key_id;
 bundle:=jsonb_build_object('user_id',p_peer,'device_id',d.device_id,'installation_id',d.installation_id,'registration_id',d.registration_id,
 'identity_key',d.identity_key,'signed_prekey',d.signed_prekey,'prekey',jsonb_build_object('id',k.key_id,'public_key',k.public_key,'pq_id',k.pq_id,'pq_public',k.pq_public,'pq_signature',k.pq_signature));
 insert into app_private.signal_claim_receipts(actor,request_id,peer,device_id,bundle) values(v_actor,p_request,p_peer,p_device,bundle);
 return bundle;
end $$;

create function public.signal_list_devices(p_peer uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_actor(); result jsonb;
begin
 if p_peer is distinct from actor then perform app_private.signal_peer(actor,p_peer); end if;
 select coalesce(jsonb_agg(jsonb_build_object('device_id',device_id,'installation_id',installation_id,'identity_key',identity_key,'revoked_at',revoked_at) order by device_id),'[]'::jsonb)
 into result from public.signal_devices where user_id=p_peer;
 return result;
end $$;
create function public.signal_revoke_device(p_device integer,p_installation uuid) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.signal_actor();
begin
 update public.signal_devices set revoked_at=coalesce(revoked_at,now()) where user_id=actor and device_id=p_device and installation_id=p_installation;
 if not found then raise exception 'SIGNAL_DEVICE_UNAVAILABLE' using errcode='42501'; end if;
end $$;
revoke all on function app_private.signal_bytes(text,integer),app_private.signal_key_id(jsonb),app_private.signal_actor(),app_private.signal_peer(uuid,uuid) from public,anon,authenticated;
revoke all on function public.signal_register_device(uuid,integer,integer,text,jsonb),public.signal_publish_prekeys(integer,uuid,jsonb),public.signal_claim_bundle(uuid,integer,uuid),public.signal_list_devices(uuid),public.signal_revoke_device(integer,uuid) from public,anon,authenticated;
grant execute on function public.signal_register_device(uuid,integer,integer,text,jsonb),public.signal_publish_prekeys(integer,uuid,jsonb),public.signal_claim_bundle(uuid,integer,uuid),public.signal_list_devices(uuid),public.signal_revoke_device(integer,uuid) to authenticated;
