begin; create temp table audit_pairs(low_user uuid,high_user uuid,primary key(low_user,high_user)); create temp table audit_identities(user_id uuid); create temp table audit_invitations(id uuid,group_id uuid,sender_id uuid,receiver_id uuid); create temp table audit_rides(id uuid,title text); create temp table audit_profiles(id uuid,username text); create temp table audit_messages(like public.chat_messages including defaults); create or replace function pg_temp.audit_guard() returns trigger language plpgsql
security definer set search_path='' as $$
declare packet jsonb; recipient text; card boolean; locked boolean;
begin
  -- A fresh snapshot after waiting is required for the pairwise lock check.
  if TG_OP='INSERT' or NEW.body is distinct from OLD.body or NEW.encrypted_payload is distinct from OLD.encrypted_payload then
    if current_setting('transaction_isolation') <> 'read committed' then
      raise exception 'E2EE_RETRY_READ_COMMITTED' using errcode='40001';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(
      least(NEW.sender_id,NEW.receiver_id)::text || ':' || greatest(NEW.sender_id,NEW.receiver_id)::text,90842));
  end if;
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
    select exists(select 1 from pg_temp.audit_pairs c
      where c.low_user=least(NEW.sender_id,NEW.receiver_id)
        and c.high_user=greatest(NEW.sender_id,NEW.receiver_id)) into locked;
    if locked and NEW.group_invitation is not null and not exists (select 1 from pg_temp.audit_invitations i join pg_temp.audit_rides g on g.id=i.group_id where i.id=NEW.id and i.sender_id=NEW.sender_id and i.receiver_id=NEW.receiver_id and NEW.group_invitation=jsonb_build_object('id',i.id,'title',g.title,'organizer',(select username from pg_temp.audit_profiles where id=i.sender_id))) then
      raise exception 'E2EE_CARD_REQUIRES_SERVER_RPC' using errcode='42501';
    end if;
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
    if not exists(select 1 from pg_temp.audit_identities i where i.user_id=recipient::uuid) then
      raise exception 'E2EE_IDENTITY_REQUIRED';
    end if;
  end loop;
  insert into pg_temp.audit_pairs(low_user,high_user)
    values(least(NEW.sender_id,NEW.receiver_id),greatest(NEW.sender_id,NEW.receiver_id))
    on conflict do nothing;
  return NEW;
end $$;

 create trigger audit_guard before insert or update on audit_messages for each row execute function pg_temp.audit_guard(); do $test$ declare a uuid:='00000000-0000-4000-8000-000000000001'; b uuid:='00000000-0000-4000-8000-000000000002'; m uuid:='00000000-0000-4000-8000-000000000003'; packet jsonb:=jsonb_build_object('nonce',repeat('A',32),'ciphertext',repeat('B',24)); begin
perform set_config('request.jwt.claim.sub',a::text,true);
insert into audit_identities values(a),(b);
insert into audit_messages(id,sender_id,receiver_id,body,encrypted_payload) values(m,a,b,'Зашифрованное сообщение · откройте новую UI Beta',jsonb_build_object('v','pulsepath-box-v1','recipients',jsonb_build_object(a::text,packet,b::text,packet)));
if not exists(select 1 from audit_pairs where low_user=a and high_user=b) then raise exception 'PAIR_NOT_LOCKED'; end if;
begin insert into audit_messages(sender_id,receiver_id,body) values(a,b,'plaintext'); raise exception 'PLAINTEXT_ACCEPTED'; exception when insufficient_privilege then if sqlerrm<>'E2EE_UPGRADE_REQUIRED' then raise; end if; end;
begin insert into audit_messages(sender_id,receiver_id,body,group_invitation) values(a,b,'Приглашение в совместный заезд: forged',jsonb_build_object('title','forged')); raise exception 'FORGED_CARD_ACCEPTED'; exception when insufficient_privilege then if sqlerrm<>'E2EE_CARD_REQUIRES_SERVER_RPC' then raise; end if; end;
insert into audit_profiles values(a,'QA'); insert into audit_rides values(m,'QA ride'); insert into audit_invitations values('00000000-0000-4000-8000-000000000004',m,a,b);
insert into audit_messages(id,sender_id,receiver_id,body,group_invitation) values('00000000-0000-4000-8000-000000000004',a,b,'Приглашение в совместный заезд: QA ride',jsonb_build_object('id','00000000-0000-4000-8000-000000000004'::uuid,'title','QA ride','organizer','QA'));
end $test$; rollback;
