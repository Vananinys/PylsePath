"""Disposable localhost PostgreSQL fixture only; never accepts a database URL."""
import argparse,base64,concurrent.futures,json,os,shlex,socket,subprocess,tempfile,uuid
from pathlib import Path

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--pg-bin',required=True);args=parser.parse_args()
 pg=Path(args.pg_bin);suffix='.exe' if os.name=='nt' else ''
 def exe(name):return str(pg/(name+suffix))
 directory=Path(tempfile.mkdtemp(prefix='pulsepath-signal-server-'));data=directory/'data'
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 subprocess.run([exe('initdb'),'-D',str(data),'-U','postgres','-A','trust','--encoding=UTF8','--no-locale'],check=True,capture_output=True)
 options=f'-h 127.0.0.1 -p {port}'
 if os.name!='nt':options+=' -k '+shlex.quote(str(directory))
 started=subprocess.run([exe('pg_ctl'),'-D',str(data),'-l',str(directory/'postgres.log'),'-o',options,'-w','start'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 if started.returncode:
  log=directory/'postgres.log'
  if log.exists():print(log.read_text(errors='replace')[-8000:])
  subprocess.run([exe('pg_ctl'),'-D',str(data),'-m','fast','-w','stop'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  raise RuntimeError('Isolated PostgreSQL startup failed; see synthetic fixture log above')
 env=os.environ.copy();env.update(PGHOST='127.0.0.1',PGPORT=str(port),PGUSER='postgres',PGDATABASE='postgres',PGCONNECT_TIMEOUT='5')
 def sql(query,error=None):
  r=subprocess.run([exe('psql'),'-X','-qAt','-v','ON_ERROR_STOP=1','-f','-'],input=query,env=env,text=True,capture_output=True,encoding='utf-8')
  if error:
   assert r.returncode!=0 and error in r.stderr,(error,r.stdout,r.stderr)
   return
  assert r.returncode==0,r.stderr
  return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ''
 def user(actor,query,error=None):return sql("set role authenticated; select set_config('request.jwt.claim.sub','"+actor+"',false); "+query,error)
 def lit(value):return "'"+json.dumps(value).replace("'","''")+"'::jsonb"
 a,b,c,d=[f'00000000-0000-4000-8000-{i:012d}' for i in range(1,5)]
 installation={actor:str(uuid.uuid4()) for actor in [a,b,c,d]}
 ec=base64.b64encode(bytes([5])+bytes(32)).decode();sig=base64.b64encode(bytes(64)).decode();pq=base64.b64encode(bytes([8])+bytes(1568)).decode()
 signed={'id':1,'public_key':ec,'signature':sig}
 def key(i):return {'id':i,'pq_id':i,'public_key':ec,'pq_public':pq,'pq_signature':sig}
 def register(actor,device=1,inst=None,identity=ec):return f"select public.signal_register_device('{inst or installation[actor]}',{device},100,'{identity}',{lit(signed)});"
 def publish(actor,keys):return f"select public.signal_publish_prekeys(1,'{installation[actor]}',{lit(keys)});"
 def claim(peer,request,device=1):return f"select public.signal_claim_bundle('{peer}',{device},'{request}');"
 try:
  sql("create role anon nologin;create role authenticated nologin;create schema auth;create schema app_private;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to public;create table public.friends(user_id uuid,friend_id uuid);create table public.chat_blocks(blocker_id uuid,blocked_id uuid);")
  migration=next((Path(__file__).resolve().parents[1]/'supabase/migrations').glob('*_signal_device_prekeys.sql'))
  sql(migration.read_text(encoding='utf-8'))
  sql('insert into auth.users values '+','.join(f"('{v}')" for v in [a,b,c,d])+';')
  sql('insert into app_private.signal_rollout(user_id,enabled) values '+','.join(f"('{v}',true)" for v in [a,b,c])+';')
  sql(f"insert into public.friends values('{a}','{b}'),('{b}','{a}'),('{a}','{c}'),('{c}','{a}');")
  sql('set role anon; select public.signal_list_devices(null);','permission denied')
  user('',register(a),'AUTH_REQUIRED');user(d,register(d),'SIGNAL_ROLLOUT_DISABLED')
  for actor in [a,b,c]:
   first=user(actor,register(actor));assert user(actor,register(actor))==first
  user(a,register(a,device=2,inst=str(uuid.uuid4())),'SIGNAL_LINK_APPROVAL_REQUIRED')
  user(a,register(a,identity=base64.b64encode(bytes([5])+bytes([1])*32).decode()),'SIGNAL_DEVICE_IMMUTABLE')
  for table in ['public.signal_devices','public.signal_prekeys','app_private.signal_rollout','app_private.signal_claim_receipts']:
   assert sql(f"select has_table_privilege('authenticated','{table}','SELECT') or has_table_privilege('authenticated','{table}','INSERT') or has_table_privilege('authenticated','{table}','TRUNCATE');")=='f'
  user(a,'select * from public.signal_devices;','permission denied')
  user(c,publish(b,[key(1)]),'SIGNAL_DEVICE_UNAVAILABLE')
  assert user(b,publish(b,[key(i) for i in range(1,41)]))=='40'
  assert user(b,publish(b,[key(1)]))=='0'
  user(c,claim(b,str(uuid.uuid4())),'SIGNAL_PEER_UNAVAILABLE')
  request=str(uuid.uuid4())
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
   receipts=list(pool.map(lambda _:user(a,claim(b,request)),range(8)))
  assert len(set(receipts))==1
  assert sql(f"select count(*) from public.signal_prekeys where user_id='{b}' and claimed_at is not null;")=='1'
  user(a,claim(c,request),'SIGNAL_REQUEST_CONFLICT')
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
   receipts=list(pool.map(lambda _:json.loads(user(a,claim(b,str(uuid.uuid4())))),range(12)))
  assert len({v['prekey']['id'] for v in receipts})==12
  assert user(b,publish(b,[key(1)]))=='0'
  assert sql(f"select claimed_at is not null from public.signal_prekeys where user_id='{b}' and key_id=1;")=='t'
  changed=key(1);changed['public_key']=base64.b64encode(bytes([5])+bytes([1])*32).decode()
  user(b,publish(b,[changed]),'SIGNAL_PREKEY_ID_REUSED')
  invalid=key(43);invalid['pq_public']='bad'
  user(b,publish(b,[key(42),invalid]),'SIGNAL_INVALID_PREKEY')
  assert sql(f"select count(*) from public.signal_prekeys where user_id='{b}' and key_id=42;")=='0'
  sql(f"insert into public.friends values('{c}','{b}'),('{b}','{c}');")
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
   raced=list(pool.map(lambda actor:json.loads(user(actor,claim(b,str(uuid.uuid4())))),[a,c]*4))
  assert len({v['prekey']['id'] for v in raced})==8
  for _ in range(13):user(a,claim(b,str(uuid.uuid4())))
  user(a,claim(b,str(uuid.uuid4())),'SIGNAL_CLAIM_QUOTA')
  assert user(a,claim(b,request))
  sql(f"insert into public.chat_blocks values('{b}','{a}');")
  user(a,claim(b,str(uuid.uuid4())),'SIGNAL_PEER_UNAVAILABLE');user(a,f"select public.signal_list_devices('{b}');",'SIGNAL_PEER_UNAVAILABLE')
  sql(f"delete from public.chat_blocks where blocker_id='{b}';")
  user(b,f"select public.signal_revoke_device(1,'{installation[b]}');")
  user(a,claim(b,request),'SIGNAL_DEVICE_UNAVAILABLE')
  user(b,publish(b,[key(41)]),'SIGNAL_DEVICE_UNAVAILABLE')
  user(b,register(b),'SIGNAL_DEVICE_IMMUTABLE')
  user(b,register(b,inst=str(uuid.uuid4())),'SIGNAL_DEVICE_SLOT_USED')
  print('PASS: isolated PostgreSQL role/access checks, immutable enrollment, atomic batch rollback, block/revoke checks; 8 same-request races yielded one key; 12 distinct requests and 8 multi-actor requests yielded distinct keys; quota enforced.')
 finally:
  subprocess.run([exe('pg_ctl'),'-D',str(data),'-m','fast','-w','stop'],check=True,capture_output=True)

if __name__=='__main__':main()
