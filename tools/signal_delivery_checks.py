"""Delivery checks injected ONLY into the disposable localhost fixture."""
import concurrent.futures,json,time,uuid
from pathlib import Path


def run(sql,user,lit,a,b,c,installation,identity):
 sql("create table public.chat_messages(id uuid primary key,sender_id uuid,receiver_id uuid,body text,encrypted_payload jsonb,read_at timestamptz,reactions jsonb,reply_to_id uuid); grant select,insert,update on public.chat_messages to authenticated;")
 migration=next((Path(__file__).resolve().parents[1]/'supabase/migrations').glob('*_signal_delivery_stage.sql'))
 sql(migration.read_text(encoding='utf-8'))
 def approve(actor,peer):return f"select public.signal_approve_conversation('{peer}',1,'{installation[actor]}',1,'{identity}');"
 def packet(actor,peer,id=None):return dict(v='pulsepath-signal-v2',id=id or str(uuid.uuid4()),conversation='dm:'+':'.join(sorted([actor,peer])),sender=actor,senderDevice=1,recipient=peer,recipientDevice=1,type=3,ciphertext='AQID')
 def send(actor,peer,p):return f"select public.signal_send_packet('{peer}',1,'{installation[actor]}',{lit(p)});"
 def pull(actor,device=1,inst=None):return f"select public.signal_pull_packets({device},'{inst or installation[actor]}',100);"
 def ack(actor,p,n):return f"select public.signal_ack_packet(1,'{installation[actor]}','{p['id']}',{n});"
 for table in ['signal_delivery_rollout','signal_conversations','signal_mailboxes','signal_messages','signal_wakeups']:
  assert sql(f"select relrowsecurity from pg_class where oid='app_private.{table}'::regclass;")=='t'
  assert sql(f"select has_table_privilege('authenticated','app_private.{table}','SELECT') or has_table_privilege('authenticated','app_private.{table}','INSERT') or has_table_privilege('authenticated','app_private.{table}','TRUNCATE');")=='f'
 user(a,approve(a,b),'SIGNAL_DELIVERY_DISABLED')
 sql('set role anon; '+pull(a),'permission denied')
 sql('insert into app_private.signal_delivery_rollout(user_id,enabled) values '+','.join(f"('{x}',true)" for x in [a,b,c])+';')
 user(a,pull(a,inst=str(uuid.uuid4())),'SIGNAL_DEVICE_UNAVAILABLE')
 user(a,pull(a,device=2),'SIGNAL_DEVICE_UNAVAILABLE')
 user(a,'begin isolation level repeatable read; '+pull(a),'SIGNAL_RETRY_READ_COMMITTED')
 user(a,approve(a,b).replace(identity, 'invalid'), 'SIGNAL_IDENTITY_MISMATCH')
 p=packet(a,b)
 user(a,send(a,b,p),'SIGNAL_CONVERSATION_NOT_ACTIVE')
 result=json.loads(user(a,approve(a,b)));assert not result['active'] and not result['peer_approved']
 legacy=str(uuid.uuid4())
 user(a,f"insert into public.chat_messages(id,sender_id,receiver_id,body) values('{legacy}','{a}','{b}','before cutover');")

 # Activate in an open transaction. A legacy write started while activation is
 # uncommitted MUST wait on the same pair lock and reject after COMMIT.
 tag='signal-stage-activation-wait'
 def activate():return user(b,"begin; "+approve(b,a)+f"select pg_sleep(2) /* {tag} */; commit;")
 def await_sleep(marker):
  until=time.monotonic()+8
  while time.monotonic()<until:
   if sql(f"select count(*) from pg_stat_activity where pid<>pg_backend_pid() and wait_event='PgSleep' and query like '%{marker}%';")!='0':return
   time.sleep(.05)
  raise AssertionError('fixture transaction did not reach its controlled wait')
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  f=pool.submit(activate);await_sleep(tag)
  user(a,f"insert into public.chat_messages(id,sender_id,receiver_id,body) values('{uuid.uuid4()}','{a}','{b}','raced legacy');",'SIGNAL_UPGRADE_REQUIRED')
  f.result()
 assert json.loads(user(b,approve(b,a)))['active']
 user(a,f"update public.chat_messages set read_at=now(),reactions='{{}}'::jsonb where id='{legacy}';")
 user(a,f"update public.chat_messages set body='edit downgrade' where id='{legacy}';",'SIGNAL_UPGRADE_REQUIRED')
 # Fail closed even if an administrator later closes delivery rollout.
 sql(f"update app_private.signal_delivery_rollout set enabled=false where user_id='{a}';")
 user(a,f"insert into public.chat_messages(id,sender_id,receiver_id) values('{uuid.uuid4()}','{a}','{b}');",'SIGNAL_UPGRADE_REQUIRED')
 sql(f"update app_private.signal_delivery_rollout set enabled=true where user_id='{a}';")
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
  receipts=list(pool.map(lambda _:user(a,send(a,b,p)),range(8)))
 assert len(set(receipts))==1
 r=json.loads(receipts[0]);assert r['seq']==1
 assert sql('select count(*) from app_private.signal_messages;')=='1'
 assert sql('select count(*) from app_private.signal_wakeups;')=='1'
 changed=dict(p,ciphertext='AQIE');user(a,send(a,b,changed),'SIGNAL_MESSAGE_CONFLICT')
 for changes in [dict(sender=c),dict(recipient=c),dict(senderDevice='1'),dict(type='3'),dict(v='pulsepath-box-v1'),dict(ciphertext='AA'),dict(ciphertext='AQID\n'),dict(body='plaintext')]:
  user(a,send(a,b,dict(packet(a,b),**changes)),'SIGNAL_INVALID_PACKET')
 user(c,send(c,b,packet(c,b)),'SIGNAL_CONVERSATION_NOT_ACTIVE')
 # Own-user mailbox scoping, ordered pull, lost ack, and exact ack retry.
 assert json.loads(user(a,pull(a)))==[]
 assert json.loads(user(c,pull(c)))==[]
 first=json.loads(user(b,pull(b)));assert len(first)==1 and first[0]['packet']==p
 p2=packet(a,b);assert json.loads(user(a,send(a,b,p2)))['seq']==2
 user(b,ack(b,p2,2),'SIGNAL_ACK_OUT_OF_ORDER')
 user(a,ack(a,p,1),'SIGNAL_ACK_OUT_OF_ORDER')
 assert json.loads(user(b,pull(b)))[0]['seq']==1
 user(b,ack(b,p,1));user(b,ack(b,p,1))
 assert [x['seq'] for x in json.loads(user(b,pull(b)))]==[2]
 user(b,ack(b,p2,2))
 assert json.loads(user(b,pull(b)))==[]
 # A consumed/acked packet still has its immutable send receipt.
 assert user(a,send(a,b,p))==receipts[0]
 # Queue counters and wake-up rows roll back with a failed transaction.
 p3=packet(a,b)
 user(a,'begin; '+send(a,b,p3)+'rollback;')
 assert json.loads(user(b,pull(b)))==[]
 assert json.loads(user(a,send(a,b,p3)))['seq']==3
 user(b,ack(b,p3,3))

 # Two independent senders share a mailbox. Do not use a global SQL sequence:
 # seq2 must not commit while seq1 is invisible, or a cursor could skip seq1.
 sql(f"insert into public.friends values('{b}','{c}'),('{c}','{b}') on conflict do nothing;")
 user(c,approve(c,b));user(b,approve(b,c))
 slow,fast=packet(a,b),packet(c,b)
 marker='signal-stage-mailbox-wait'
 def slow_send():return user(a,'begin; '+send(a,b,slow)+f"select pg_sleep(4) /* {marker} */; commit;")
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  f=pool.submit(slow_send);await_sleep(marker)
  g=pool.submit(lambda:user(c,send(c,b,fast)))
  until=time.monotonic()+3
  blocked=False
  while time.monotonic()<until and not g.done():
   if sql(f"select count(*) from pg_stat_activity where pid<>pg_backend_pid() and wait_event_type='Lock' and query like '%{fast['id']}%';")!='0':
    blocked=True;break
   time.sleep(.02)
  assert blocked and not g.done(),'second sender committed or never reached the mailbox lock'
  assert json.loads(user(b,pull(b)))==[]
  f.result();g.result()
 queued=json.loads(user(b,pull(b)));assert [x['seq'] for x in queued]==[4,5]
 assert [x['packet']['id'] for x in queued]==[slow['id'],fast['id']]
 user(b,ack(b,slow,4));user(b,ack(b,fast,5))
 # Block affects new sends, not packets already accepted for the recipient.
 sql(f"insert into public.chat_blocks values('{b}','{a}');")
 user(a,send(a,b,packet(a,b)),'SIGNAL_PEER_UNAVAILABLE')
 sql(f"delete from public.chat_blocks where blocker_id='{b}' and blocked_id='{a}';")
 user(b,"begin; "+f"select public.signal_revoke_device(1,'{installation[b]}'); "+pull(b),'SIGNAL_DEVICE_UNAVAILABLE')
 user(b,"begin; "+f"select public.signal_revoke_device(1,'{installation[b]}'); "+send(b,a,packet(b,a)),'SIGNAL_DEVICE_UNAVAILABLE')
 # Synthetic fixture administration only: test limits without sending 60 RPCs.
 sql(f"insert into app_private.signal_messages(id,sender,sender_device,recipient,recipient_device,seq,packet) select md5('quota-'||n)::uuid,'{a}',1,'{c}',1,10000+n,'{{}}'::jsonb from generate_series(1,60) n;")
 user(a,send(a,b,packet(a,b)),'SIGNAL_SEND_QUOTA')
 assert user(a,send(a,b,p))==receipts[0]
 sql(f"delete from app_private.signal_messages where recipient='{c}';")
 sql(f"update app_private.signal_mailboxes set next_seq=ack_seq+1000 where user_id='{b}';")
 user(a,send(a,b,packet(a,b)),'SIGNAL_MAILBOX_FULL')
 assert sql(f"select next_seq-ack_seq from app_private.signal_mailboxes where user_id='{b}';")=='1000'
 print('PASS: closed delivery gate, mutual approval, downgrade activation race, immutable retry, packet context/shape, own-only ordered inbox/ack, transactional rollback, concurrent mailbox commit ordering, block/revoke, send and backlog quotas. Synthetic packets only; no native crypto or FCM in this SQL fixture.')
