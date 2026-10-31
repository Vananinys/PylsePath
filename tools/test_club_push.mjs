// Isolated worker verification: all HTTP requests are intercepted locally.
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
const pair=await webcrypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const key=Buffer.from(await webcrypto.subtle.exportKey('pkcs8',pair.privateKey)).toString('base64');
const secret='test-only-secret-'.repeat(4);
const ids={notice:'11111111-1111-4111-8111-111111111111',club:'22222222-2222-4222-8222-222222222222',user:'33333333-3333-4333-8333-333333333333',ref:'44444444-4444-4444-8444-444444444444'};
const env={SUPABASE_URL:'https://db.example.invalid',SUPABASE_SERVICE_ROLE_KEY:'test-only',PUSH_WEBHOOK_SECRET:secret,FIREBASE_SERVICE_ACCOUNT:JSON.stringify({project_id:'local-test',client_email:'test@example.invalid',private_key:key})};
let handler,state;
globalThis.Deno={env:{get:(k)=>env[k]},serve:(h)=>{handler=h;}};
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
globalThis.fetch=async(input,options={})=>{
 const url=new URL(input);const method=options.method??'GET';
 if(url.hostname==='oauth2.googleapis.com')return json({access_token:'fake-access',expires_in:3600});
 if(url.hostname==='fcm.googleapis.com'){
  state.fcm.push(JSON.parse(options.body));
  return state.fail?json({error:'transient'},503):json({name:'fake-fcm-ack'});
 }
 assert.equal(url.hostname,'db.example.invalid','no external network permitted');
 const table=url.pathname.split('/').at(-1);
 if(table==='claim_club_push')return json(true);
 if(table==='club_push_outbox'){
  if(method==='PATCH'){state.result=JSON.parse(options.body);return json([state.result]);}
  return json([{id:ids.notice,club_id:ids.club,recipient_id:ids.user,reference_id:ids.ref,kind:state.kind}]);
 }
 if(table==='rider_club_members')return json(state.member?[{notification_mode:state.mode,last_read_at:state.read?'2030-01-01':'2026-01-01'}]:[]);
 if(table==='rider_clubs')return json([{id:ids.club}]);
 if(table==='rider_club_messages'||table==='rider_club_events')return json([{id:ids.ref,created_at:'2026-10-31'}]);
 if(table==='club_push_devices')return json(state.capable?[{token:'fake-device-token'}]:[]);
 if(table==='fcm_tokens')return json(url.searchParams.has('token')?(state.ownerChanged?[]:[{updated_at:'same'}]):[{token:'fake-device-token',updated_at:'same'}]);
 if(table==='club_push_deliveries'){
  if(method==='POST'){state.deliveries++;return json([{}]);}
  return json(state.alreadySent?[{token_hash:'already'}]:[]);
 }
 throw Error(`Unexpected request: ${url.pathname}`);
};
await import('../docs/releases/functions/send-club-push/index.ts');
function reset(patch={}){state={kind:'message',mode:'all',member:true,capable:true,read:false,fail:false,ownerChanged:false,alreadySent:false,fcm:[],deliveries:0,...patch};}
async function run(){return handler(new Request('https://worker.example.invalid',{method:'POST',headers:{'X-Push-Webhook-Secret':secret},body:JSON.stringify({notificationId:ids.notice})}));}
reset();assert.equal((await handler(new Request('https://worker.example.invalid',{method:'POST'}))).status,401);
for(const patch of [{mode:'off'},{mode:'invitations'},{member:false},{capable:false},{ownerChanged:true},{read:true},{alreadySent:true}]){
 reset(patch);assert.equal((await run()).status,200);assert.equal(state.fcm.length,0);assert.equal(state.result.status,'done');
}
reset();assert.equal((await run()).status,200);assert.equal(state.fcm.length,1);assert.equal(state.deliveries,1);assert.ok(state.result.sent_at);
assert.equal(state.fcm[0].message.data.receiverId,ids.user);assert.equal(state.fcm[0].message.data.clubId,ids.club);assert.equal(state.fcm[0].message.data.type,'club');
assert.equal(state.fcm[0].message.notification.body,'Откройте PulsePath UI Beta, чтобы посмотреть');
for(const kind of ['ride','event','event_cancel']){reset({kind,mode:'invitations'});assert.equal((await run()).status,200);assert.equal(state.fcm.length,1);}
reset({fail:true});assert.equal((await run()).status,503);assert.equal(state.result.status,'failed');assert.equal(state.deliveries,0);
console.log('13 club worker scenarios passed: authorization, preferences, ownership, UI capability, read state, duplicate protection, privacy, event/ride delivery and retry; no external requests');
