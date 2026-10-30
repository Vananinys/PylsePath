export type ChatRow = { id: string; sender_id: string; receiver_id: string; body?: string | null;
  sticker?: string | null; photo_url?: string | null; audio_url?: string | null; read_at?: string | null };
export type Device = { token: string; user_id: string; platform: string | null; updated_at: string | null };
export interface PushStore {
  claim(id: string): Promise<boolean>;
  message(id: string): Promise<ChatRow | null>;
  friends(sender: string, receiver: string): Promise<boolean>;
  senderName(id: string): Promise<string>;
  devices(receiver: string): Promise<Device[]>;
  wasSent(id: string, hash: string): Promise<boolean>;
  sent(id: string, hash: string, fcmName: string): Promise<void>;
  removeDevice(device: Device): Promise<void>;
  complete(id: string): Promise<void>;
  retry(id: string, reason: string): Promise<void>;
}
export type ServiceAccount = { project_id: string; client_email: string; private_key: string };
export type Dependencies = {
  secret: string; account: ServiceAccount; store: PushStore;
  fetch: typeof fetch; accessToken: () => Promise<string>;
  includePreview?: boolean; log?: (event: string) => void;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function secretMatches(received: string, expected: string): boolean {
  if (expected.length < 32) return false;
  const a = new TextEncoder().encode(received), b = new TextEncoder().encode(expected);
  let mismatch = a.length ^ b.length;
  for (let i=0;i<b.length;i++) mismatch |= (a[i] ?? 0) ^ b[i];
  return mismatch === 0;
}
export function previewOf(row: ChatRow): string {
  if (row.body?.trim()) return row.body.trim().slice(0,200);
  if (row.sticker?.trim()) return `Стикер ${row.sticker.trim()}`;
  if (row.photo_url) return '📷 Фото';
  if (row.audio_url) return '🎤 Голосовое сообщение';
  return 'Новое сообщение';
}
export function buildFcm(row: ChatRow, device: Device, name: string, includePreview=false) {
  return { message: {
    token: device.token,
    notification: { title: name.trim() ? `Новое сообщение от ${name.trim().slice(0,64)}` : 'Новое сообщение',
      body: includePreview ? previewOf(row) : 'Откройте PulsePath, чтобы прочитать' },
    data: { type:'chat', senderId:row.sender_id, receiverId:row.receiver_id, messageId:row.id,
      click_action:'FLUTTER_NOTIFICATION_CLICK' },
    android: { priority:'HIGH', ttl:'3600s', notification:{ channel_id:'chat_messages',tag:`chat_${row.sender_id}` } },
    apns:{ headers:{'apns-priority':'10'},payload:{aps:{sound:'default','thread-id':`chat_${row.sender_id}`}} },
  }};
}
export function fcmErrorCode(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null;
  const error=(value as {error?:{details?:unknown[]}}).error;
  for(const detail of error?.details ?? []) {
    if (detail && typeof detail==='object') {
      const d=detail as Record<string,unknown>;
      if(d['@type']==='type.googleapis.com/google.firebase.fcm.v1.FcmError' && typeof d.errorCode==='string') return d.errorCode;
    }
  }
  return null;
}
export async function tokenHash(token: string): Promise<string> {
  const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token));
  return [...new Uint8Array(bytes)].map(b=>b.toString(16).padStart(2,'0')).join('');
}
function json(body: unknown,status=200) { return new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json'}}); }
export async function handlePush(request: Request, deps: Dependencies): Promise<Response> {
  if(request.method!=='POST') return json({error:'method_not_allowed'},405);
  if(!secretMatches(request.headers.get('X-Push-Webhook-Secret') ?? '',deps.secret)) return json({error:'unauthorized'},401);
  let id:string;
  try {
    if(Number(request.headers.get('content-length') ?? 0)>4096) return json({error:'payload_too_large'},413);
    const text=await request.text();if(text.length>4096)return json({error:'payload_too_large'},413);
    const parsed=JSON.parse(text);id=parsed.messageId;
    if(typeof id!=='string'||!uuid.test(id))return json({error:'invalid_message_id'},400);
  } catch { return json({error:'invalid_json'},400); }
  let claimed=false;
  try {
    claimed=await deps.store.claim(id);
    if(!claimed)return json({status:'already_done_or_busy'});
    const row=await deps.store.message(id);
    if(!row||row.read_at||!await deps.store.friends(row.sender_id,row.receiver_id)) {
      await deps.store.complete(id);return json({status:'skipped'});
    }
    const devices=await deps.store.devices(row.receiver_id);
    if(!devices.length){await deps.store.complete(id);return json({status:'no_registered_devices',sent:0});}
    const name=await deps.store.senderName(row.sender_id);
    const access=await deps.accessToken();
    let sent=0,invalid=0,failed=0;
    // Bound concurrent requests without blocking on dozens of sequential devices.
    for(let i=0;i<devices.length;i+=5) {
      const outcomes=await Promise.all(devices.slice(i,i+5).map(async(device)=>{
        const hash=await tokenHash(device.token);
        if(await deps.store.wasSent(id,hash))return 'already_sent';
        // Recheck ownership immediately before dispatch; logout removes the token.
        const current=await deps.store.devices(row.receiver_id);
        if(!current.some(d=>d.token===device.token&&d.updated_at===device.updated_at))return 'removed';
        try {
          const response=await deps.fetch(`https://fcm.googleapis.com/v1/projects/${deps.account.project_id}/messages:send`,{
            method:'POST',headers:{Authorization:`Bearer ${access}`,'Content-Type':'application/json'},
            body:JSON.stringify(buildFcm(row,device,name,deps.includePreview)),signal:AbortSignal.timeout(10000),
          });
          const body=await response.json().catch(()=>({}));
          if(response.ok) {
            // A lost response/DB acknowledgement can still cause at-least-once delivery.
            await deps.store.sent(id,hash,typeof body.name==='string'?body.name:'');return 'sent';
          }
          if(fcmErrorCode(body)==='UNREGISTERED') {
            await deps.store.removeDevice(device);return 'invalid';
          }
          deps.log?.(`FCM rejected message ${id}: HTTP ${response.status}, code ${fcmErrorCode(body) ?? 'unknown'}`);
          return 'failed';
        } catch { deps.log?.(`FCM/ack failure for message ${id}`);return 'failed'; }
      }));
      for(const o of outcomes){if(o==='sent')sent++;if(o==='invalid')invalid++;if(o==='failed')failed++;}
    }
    if(failed){await deps.store.retry(id,`${failed} device sends failed`);return json({status:'retry_pending',sent,invalid,failed},503);}
    await deps.store.complete(id);return json({status:'done',sent,invalid,failed});
  } catch {
    deps.log?.(`Push worker failed for message ${id}`);
    if(claimed)await deps.store.retry(id,'worker_failure').catch(()=>{});
    return json({error:'push_worker_failed'},503);
  }
}

const googleTokenUrl='https://oauth2.googleapis.com/token';
let cached:{key:string;value:string;until:number}|undefined;
let inflight:Promise<string>|undefined;
function b64url(bytes:Uint8Array){return btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');}
export async function googleAccessToken(account:ServiceAccount,http:typeof fetch=fetch):Promise<string> {
  const key=account.project_id+'|'+account.client_email;
  if(cached?.key===key&&cached.until>Date.now())return cached.value;
  if(inflight)return inflight;
  inflight=(async()=>{
    if(!account.project_id||!account.client_email||!account.private_key)throw new Error('Invalid Firebase service account');
    const now=Math.floor(Date.now()/1000), enc=new TextEncoder();
    const head=b64url(enc.encode(JSON.stringify({alg:'RS256',typ:'JWT'})));
    const claims=b64url(enc.encode(JSON.stringify({iss:account.client_email,
      scope:'https://www.googleapis.com/auth/firebase.messaging',aud:googleTokenUrl,iat:now,exp:now+3600})));
    const pem=account.private_key.replace(/-{5}(?:BEGIN|END) PRIVATE KEY-{5}|\s/g,'');
    const bytes=Uint8Array.from(atob(pem),c=>c.charCodeAt(0));
    const signingKey=await crypto.subtle.importKey('pkcs8',bytes,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
    const signature=new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',signingKey,enc.encode(`${head}.${claims}`)));
    const assertion=`${head}.${claims}.${b64url(signature)}`;
    const response=await http(googleTokenUrl,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}),signal:AbortSignal.timeout(10000)});
    if(!response.ok)throw new Error(`Google OAuth HTTP ${response.status}`);
    const body=await response.json();
    if(typeof body.access_token!=='string')throw new Error('Invalid Google OAuth response');
    cached={key,value:body.access_token,until:Date.now()+Math.max(0,(Number(body.expires_in)||3600)-60)*1000};
    return cached.value;
  })();
  try{return await inflight;}finally{inflight=undefined;}
}


