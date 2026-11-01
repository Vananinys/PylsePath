import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  googleAccessToken,
  secretMatches,
  type ServiceAccount,
} from '../send-chat-push/core.ts';

const env = (key: string) => Deno.env.get(key) ?? '';
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = env('PUSH_WEBHOOK_SECRET');
  if (!secretMatches(request.headers.get('X-Push-Webhook-Secret') ?? '', secret)) {
    return json({ error: 'unauthorized' }, 401);
  }
  let versionCode: number;
  try {
    if (Number(request.headers.get('content-length') ?? 0) > 1024) {
      return json({ error: 'payload_too_large' }, 413);
    }
    const body = await request.text();
    if (body.length > 1024) return json({ error: 'payload_too_large' }, 413);
    versionCode = JSON.parse(body).versionCode;
    if (!Number.isInteger(versionCode) || versionCode <= 0) {
      return json({ error: 'invalid_version_code' }, 400);
    }
  } catch {
    return json({ error: 'invalid_json' }, 400);
  }

  const { data: claimed, error: claimError } = await db.rpc(
    'pulsepath_claim_ui_beta_release_push',
    { p_version_code: versionCode },
  );
  if (claimError) return json({ error: 'claim_failed' }, 503);
  if (claimed !== true) return json({ status: 'already_done_or_busy' });

  try {
    const { data: release, error: releaseError } = await db
      .from('app_ui_beta_releases')
      .select('version_code,version_name,published_at')
      .eq('version_code', versionCode)
      .maybeSingle();
    if (releaseError) throw releaseError;
    if (!release?.published_at ||
        new Date(release.published_at).getTime() > Date.now()) {
      await db.from('app_ui_beta_release_push_outbox').update({
        status: 'done', locked_at: null, last_error: null,
      }).eq('version_code', versionCode);
      return json({ status: 'not_published' });
    }
    const account = JSON.parse(env('FIREBASE_SERVICE_ACCOUNT')) as ServiceAccount;
    const accessToken = await googleAccessToken(account);
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            topic: 'pulsepath_ui_beta_updates',
            notification: {
              title: 'Обновление PulsePath UI Beta',
              body: `Доступна версия ${String(release.version_name).slice(0, 40)}`,
            },
            data: {
              type: 'app_update',
              versionCode: String(versionCode),
            },
            android: {
              priority: 'HIGH',
              ttl: '86400s',
              notification: { channel_id: 'app_updates', tag: 'app_update' },
            },
          },
        }),
        signal: AbortSignal.timeout(10000),
      },
    );
    if (!response.ok) throw new Error(`FCM HTTP ${response.status}`);
    const { error: doneError } = await db.from('app_ui_beta_release_push_outbox')
      .update({
        status: 'done', sent_at: new Date().toISOString(),
        locked_at: null, last_error: null,
      }).eq('version_code', versionCode);
    if (doneError) throw doneError;
    return json({ status: 'sent' });
  } catch (error) {
    const reason = error instanceof Error ? error.message.slice(0, 200) : 'unknown';
    await db.from('app_ui_beta_release_push_outbox').update({
      status: 'failed', locked_at: null,
      next_attempt_at: new Date(Date.now() + 300000).toISOString(),
      last_error: reason,
    }).eq('version_code', versionCode);
    console.error(`Release push failed for ${versionCode}: ${reason}`);
    return json({ error: 'push_failed' }, 503);
  }
});


