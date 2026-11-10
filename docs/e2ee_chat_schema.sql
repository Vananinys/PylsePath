-- Pairwise opt-in: first encrypted message locks that conversation against
-- plaintext writes, including old clients. Unrelated conversations are untouched.
alter table public.chat_messages add column encrypted_payload jsonb;
create table public.chat_e2ee_conversations (
  low_user uuid not null references auth.users(id) on delete cascade,
  high_user uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(low_user,high_user), check(low_user<high_user)
);
alter table public.chat_e2ee_conversations enable row level security;
revoke all on public.chat_e2ee_conversations from public,anon,authenticated;
grant select on public.chat_e2ee_conversations to authenticated;
create policy e2ee_conversation_participants on public.chat_e2ee_conversations
  for select to authenticated using ((select auth.uid()) in (low_user,high_user));

create function public.e2ee_guard_chat() returns trigger language plpgsql
security definer set search_path='' as $$
declare packet jsonb; recipient text; card boolean; locked boolean;
begin
  if TG_OP='UPDATE' and OLD.encrypted_payload is not null and NEW.encrypted_payload is null then
    raise exception 'E2EE_CANNOT_DISABLE' using errcode='42501';
  end if;
  if TG_OP='UPDATE' and OLD.encrypted_payload is not null
     and NEW.encrypted_payload is not distinct from OLD.encrypted_payload then
    if NEW.body is distinct from OLD.body then
      raise exception 'E2EE_PLAINTEXT_FIELDS_FORBIDDEN' using errcode='42501';
    end if;
    -- Read/reaction/FK-maintenance updates keep the original guards and must
    -- not depend on identities that can be removed during account deletion.
    return NEW;
  end if;
  if NEW.encrypted_payload is null then
    if TG_OP='UPDATE' and NEW.body is not distinct from OLD.body then return NEW; end if;
    select exists(select 1 from public.chat_e2ee_conversations c
      where c.low_user=least(NEW.sender_id,NEW.receiver_id)
        and c.high_user=greatest(NEW.sender_id,NEW.receiver_id)) into locked;
    card := (NEW.community_post_id is not null and NEW.body='Публикация сообщества'
      and NEW.group_invitation is null) or
      (NEW.group_invitation is not null and NEW.community_post_id is null and
       NEW.body='Приглашение в совместный заезд: '||(NEW.group_invitation->>'title'));
    if locked and not coalesce(card and NEW.sticker is null and NEW.photo_url is null
       and NEW.audio_url is null and NEW.video_url is null and NEW.video_poster_url is null
       and NEW.video_metadata is null and NEW.route_attachment is null,false) then
      raise exception 'E2EE_UPGRADE_REQUIRED' using errcode='42501';
    end if;
    return NEW;
  end if;
  if TG_OP='UPDATE' then
    if OLD.encrypted_payload is null then raise exception 'E2EE_LEGACY_EDIT_UNSUPPORTED'; end if;
    if NEW.encrypted_payload is distinct from OLD.encrypted_payload then
      if auth.uid() is distinct from OLD.sender_id then
        raise exception 'E2EE_SENDER_ONLY' using errcode='42501';
      end if;
      NEW.edited_at:=now();
    end if;
  elsif auth.uid() is distinct from NEW.sender_id then
    raise exception 'E2EE_SENDER_ONLY' using errcode='42501';
  end if;
  if NEW.sender_id=NEW.receiver_id or NEW.body is distinct from 'Зашифрованное сообщение · откройте новую UI Beta'
     or NEW.sticker is not null or NEW.photo_url is not null or NEW.audio_url is not null
     or NEW.audio_seconds is not null or NEW.video_url is not null
     or NEW.video_poster_url is not null or NEW.video_metadata is not null
     or NEW.route_attachment is not null or NEW.group_invitation is not null
     or NEW.community_post_id is not null then
    raise exception 'E2EE_PLAINTEXT_FIELDS_FORBIDDEN' using errcode='42501';
  end if;
  if jsonb_typeof(NEW.encrypted_payload)<>'object' or
    octet_length(NEW.encrypted_payload::text)>65536 or
    (NEW.encrypted_payload->>'v') is distinct from 'pulsepath-box-v1' or
    jsonb_typeof(NEW.encrypted_payload->'recipients') is distinct from 'object' then
    raise exception 'E2EE_INVALID_ENVELOPE';
  end if;
  if (select count(*) from jsonb_object_keys(NEW.encrypted_payload))<>2 or
    (select count(*) from jsonb_object_keys(NEW.encrypted_payload->'recipients'))<>2 or
    not ((NEW.encrypted_payload->'recipients') ? NEW.sender_id::text) or
    not ((NEW.encrypted_payload->'recipients') ? NEW.receiver_id::text) then
    raise exception 'E2EE_INVALID_RECIPIENTS';
  end if;
  foreach recipient in array array[NEW.sender_id::text,NEW.receiver_id::text] loop
    packet:=NEW.encrypted_payload->'recipients'->recipient;
    if jsonb_typeof(packet)<>'object' or (select count(*) from jsonb_object_keys(packet))<>2
      or jsonb_typeof(packet->'nonce') is distinct from 'string'
      or jsonb_typeof(packet->'ciphertext') is distinct from 'string'
      or (packet->>'nonce') !~ '^[A-Za-z0-9_-]{32}$'
      or length(packet->>'ciphertext') not between 24 and 32768
      or (packet->>'ciphertext') !~ '^[A-Za-z0-9_-]+={0,2}$' then
      raise exception 'E2EE_INVALID_PACKET';
    end if;
    if not exists(select 1 from public.e2ee_identities i where i.user_id=recipient::uuid) then
      raise exception 'E2EE_IDENTITY_REQUIRED';
    end if;
  end loop;
  insert into public.chat_e2ee_conversations(low_user,high_user)
    values(least(NEW.sender_id,NEW.receiver_id),greatest(NEW.sender_id,NEW.receiver_id))
    on conflict do nothing;
  return NEW;
end $$;
revoke all on function public.e2ee_guard_chat() from public,anon,authenticated;
create trigger e2ee_chat_guard before insert or update on public.chat_messages
  for each row execute function public.e2ee_guard_chat();

-- Preserve the existing read/reaction/ownership guards. Only permit the new
-- protected field to change; the preceding trigger authorizes its sender.
do $$
declare original text; changed text;
begin
  original:=pg_get_functiondef('public.pulsepath_guard_chat_update()'::regprocedure);
  if strpos(original,'to_jsonb(NEW)-''read_at''-''reactions''-''body''-''edited_at''-''reply_to_id''')=0
    or strpos(original,'ELSIF NEW.edited_at IS DISTINCT FROM OLD.edited_at THEN')=0 then
    raise exception 'Unexpected current chat update guard; review before migration';
  end if;
  changed:=replace(original, 'to_jsonb(NEW)-''read_at''-''reactions''-''body''-''edited_at''-''reply_to_id''',
    'to_jsonb(NEW)-''read_at''-''reactions''-''body''-''edited_at''-''reply_to_id''-''encrypted_payload''');
  changed:=replace(changed, 'to_jsonb(OLD)-''read_at''-''reactions''-''body''-''edited_at''-''reply_to_id''',
    'to_jsonb(OLD)-''read_at''-''reactions''-''body''-''edited_at''-''reply_to_id''-''encrypted_payload''');
  changed:=replace(changed, 'ELSIF NEW.edited_at IS DISTINCT FROM OLD.edited_at THEN',
    'ELSIF NEW.edited_at IS DISTINCT FROM OLD.edited_at AND NEW.encrypted_payload IS NOT DISTINCT FROM OLD.encrypted_payload THEN');
  execute changed;
end $$;
