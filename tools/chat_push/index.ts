import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {handlePush,googleAccessToken, type PushStore, type Device, type ServiceAccount} from './core.ts';
const env=(key:string)=>Deno.env.get(key) ?? '';
const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
function check(error:unknown){if(error)throw new Error('Database operation failed');}
const store:PushStore={
 async claim(id){const {data,error}=await db.rpc('pulsepath_claim_push',{p_message_id:id});check(error);return data===true;},
 async message(id){const {data,error}=await db.from('chat_messages').select('id,sender_id,receiver_id,body,sticker,photo_url,audio_url,read_at,encrypted_payload').eq('id',id).maybeSingle();check(error);return data;},
 async friends(sender,receiver){const {data,error}=await db.from('friends').select('user_id').eq('user_id',sender).eq('friend_id',receiver).maybeSingle();check(error);return data!==null;},
 async senderName(id){const {data,error}=await db.from('profiles').select('username').eq('id',id).maybeSingle();check(error);return typeof data?.username==='string'?data.username:'';},
 async devices(receiver){const {data,error}=await db.from('fcm_tokens').select('token,user_id,platform,updated_at,supports_actions').eq('user_id',receiver);check(error);return (data ?? []) as Device[];},
 async wasSent(id,hash){const {data,error}=await db.from('push_deliveries').select('message_id').eq('message_id',id).eq('token_hash',hash).maybeSingle();check(error);return data!==null;},
 async sent(id,hash,name){const {error}=await db.from('push_deliveries').upsert({message_id:id,token_hash:hash,fcm_message_name:name},{onConflict:'message_id,token_hash'});check(error);},
 async removeDevice(device){let query=db.from('fcm_tokens').delete().eq('token',device.token).eq('user_id',device.user_id); query=device.updated_at===null?query.is('updated_at',null):query.eq('updated_at',device.updated_at); const {error}=await query;check(error);},
 async complete(id){const {error}=await db.from('push_outbox').update({status:'done',locked_at:null,last_error:null}).eq('message_id',id);check(error);},
 async retry(id,reason){const {error}=await db.from('push_outbox').update({status:'failed',locked_at:null,last_error:reason,next_attempt_at:new Date(Date.now()+60000).toISOString()}).eq('message_id',id);check(error);},
};
Deno.serve(async(request)=>{
 try {
  const secret=env('PUSH_WEBHOOK_SECRET');
  // Reject unauthorized requests before parsing private configuration.
  const {secretMatches}=await import('./core.ts');
  if(!secretMatches(request.headers.get('X-Push-Webhook-Secret') ?? '',secret))return new Response('Unauthorized',{status:401});
  const account=JSON.parse(env('FIREBASE_SERVICE_ACCOUNT')) as ServiceAccount;
  return await handlePush(request,{secret,account,store,fetch,accessToken:()=>googleAccessToken(account),
    // Chat text must be readable with the app closed; lock-screen privacy is controlled by the OS.
    includePreview:true,
    androidActions:false,log:(event)=>console.warn(event)});
 }catch{console.error('send-chat-push: configuration or initialization error');return new Response('Push configuration error',{status:503});}
});
