import assert from 'node:assert/strict';
import {buildFcm,previewOf} from './chat_push/core.ts';
const row={id:'message',sender_id:'alice',receiver_id:'bob',body:'PRIVATE TEXT',sticker:'PRIVATE STICKER',encrypted_payload:{v:'pulsepath-box-v1'}};
assert.equal(previewOf(row),'Зашифрованное сообщение · откройте UI Beta');
for(const platform of ['android','ios']) for(const supports_actions of [true,false]) {
 const payload=buildFcm(row,{token:'test-token',user_id:'bob',platform,updated_at:null,supports_actions},'Alice',true,true);
 const wire=JSON.stringify(payload);
 assert(!wire.includes('PRIVATE TEXT')&&!wire.includes('PRIVATE STICKER'));
 assert.equal(payload.message.data.encrypted,'true');
 if(payload.message.data.showPreview!==undefined) assert.equal(payload.message.data.showPreview,'false');
}
const old=buildFcm({...row,encrypted_payload:undefined},{token:'test-token',user_id:'bob',platform:'ios',updated_at:null},'Alice',true);
assert.equal(old.message.notification.body,'PRIVATE TEXT');
console.log('Encrypted push remains neutral; legacy previews preserved.');
