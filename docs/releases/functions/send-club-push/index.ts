import { googleAccessToken, secretMatches, tokenHash, fcmErrorCode, type ServiceAccount } from '../send-chat-push/core.ts';
const env=(key:string)=>Deno.env.get(key)??'';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json'}});
async function db(path:string,method='GET',body?:unknown){
 const res=await fetch(`${env('SUPABASE_URL')}/rest/v1/${path}`,{method,headers:{apikey:env('SUPABASE_SERVICE_ROLE_KEY'),Authorization:`Bearer ${env('SUPABASE_SERVICE_ROLE_KEY')}`,'Content-Type':'application/json',Prefer:'return=representation'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
 if(!res.ok)throw new Error(`Database HTTP ${res.status}`);
 const text=await res.text();return text?JSON.parse(text):null;
}
const row=async(path:string)=>(await db(path))[0]??null;
const done=async(id:string,sent:boolean)=>db(`club_push_outbox?id=eq.${id}`,'PATCH',{status:'done',locked_at:null,last_error:null,...(sent?{sent_at:new Date().toISOString()}:{})});
async function allowed(notice:any){
 const member=await row(`rider_club_members?club_id=eq.${notice.club_id}&user_id=eq.${notice.recipient_id}&left_at=is.null&select=notification_mode,last_read_at`);
 if(!member||member.notification_mode==='off'||member.notification_mode==='invitations'&&notice.kind==='message')return false;
 if(!await row(`rider_clubs?id=eq.${notice.club_id}&archived_at=is.null&select=id`))return false;
 const table=notice.kind==='message'||notice.kind==='ride'?'rider_club_messages':'rider_club_events';
 const ref=await row(`${table}?id=eq.${notice.reference_id}&club_id=eq.${notice.club_id}&select=id,created_at`);
 return !!ref && !((notice.kind==='message'||notice.kind==='ride')&&new Date(member.last_read_at)>=new Date(ref.created_at));
}
Deno.serve(async(req)=>{
 if(req.method!=='POST')return json({error:'method_not_allowed'},405);
 if(!secretMatches(req.headers.get('X-Push-Webhook-Secret')??'',env('PUSH_WEBHOOK_SECRET')))return json({error:'unauthorized'},401);
 let id:string;
 try{const text=await req.text();if(text.length>1024)return json({error:'payload_too_large'},413);id=JSON.parse(text).notificationId;if(typeof id!=='string'||!uuid.test(id))return json({error:'invalid_id'},400);}catch{return json({error:'invalid_json'},400);}
 let claimed=false;
 try{
  claimed=await db('rpc/claim_club_push','POST',{p_id:id});if(!claimed)return json({status:'already_done_or_busy'});
  const notice=await row(`club_push_outbox?id=eq.${id}&select=*`);
  if(!notice||!await allowed(notice)){await done(id,false);return json({status:'skipped'});}
  const capable=await db(`club_push_devices?user_id=eq.${notice.recipient_id}&select=token`);
  const registered=await db(`fcm_tokens?user_id=eq.${notice.recipient_id}&select=token,updated_at`);
  const devices=registered.filter((d:any)=>capable.some((c:any)=>c.token===d.token));
  if(!devices.length){await done(id,false);return json({status:'no_registered_ui_beta_devices',sent:0});}
  const account=JSON.parse(env('FIREBASE_SERVICE_ACCOUNT')) as ServiceAccount;
  const access=await googleAccessToken(account);let sent=0,failed=0,delivered=false;
  for(const device of devices){
   const hash=await tokenHash(device.token);
   if(await row(`club_push_deliveries?notification_id=eq.${id}&token_hash=eq.${hash}&select=token_hash`)){delivered=true;continue;}
   if(!await allowed(notice))continue;
   const current=await row(`fcm_tokens?user_id=eq.${notice.recipient_id}&token=eq.${encodeURIComponent(device.token)}&select=updated_at`);
   if(!current||current.updated_at!==device.updated_at)continue;
   const title=notice.kind==='ride'?'Приглашение на заезд':notice.kind==='event'?'Новое событие клуба':notice.kind==='event_cancel'?'Событие клуба отменено':'Новое сообщение клуба';
   const response=await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,{method:'POST',headers:{Authorization:`Bearer ${access}`,'Content-Type':'application/json'},body:JSON.stringify({message:{token:device.token,notification:{title,body:'Откройте PulsePath UI Beta, чтобы посмотреть'},data:{type:'club',clubId:notice.club_id,receiverId:notice.recipient_id,notificationId:id,kind:notice.kind},android:{priority:'HIGH',ttl:'3600s',notification:{channel_id:'chat_messages',tag:`club_${notice.club_id}`}},apns:{payload:{aps:{sound:'default','thread-id':`club_${notice.club_id}`}}}}}),signal:AbortSignal.timeout(10000)});
   const body=await response.json().catch(()=>({}));
   if(response.ok){await db('club_push_deliveries','POST',{notification_id:id,token_hash:hash});sent++;delivered=true;}
   else if(fcmErrorCode(body)!=='UNREGISTERED')failed++;
  }
  if(failed)throw new Error('Device dispatch failed');
  await done(id,delivered);return json({status:'done',sent});
 }catch{
  if(claimed)await db(`club_push_outbox?id=eq.${id}`,'PATCH',{status:'failed',locked_at:null,last_error:'worker_or_device_failure',next_attempt_at:new Date(Date.now()+60000).toISOString()}).catch(()=>{});
  return json({error:'retry_pending'},503);
 }
});
