// Executed INSIDE a staged, unpublished MetaMCP container. Input arrives on
// stdin; only a private result is returned to the parent, never to the terminal.
import fs from 'node:fs';

function fail(message) { throw new Error(message); }
function cookies(response) {
  const lines = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : [response.headers.get('set-cookie') || ''];
  return lines.flatMap((line) => line.split(/,\s*(?=[^;,=\s]+=[^;,]*)/)).map((part) => part.split(';', 1)[0].trim()).filter((pair) => /^[^=;\s]+=[^;\r\n]+$/.test(pair)).join('; ');
}
function data(body) {
  const value = body?.result?.data;
  return value && typeof value === 'object' && Object.hasOwn(value, 'json') ? value.json : value;
}
try {
  const { origin, email, password } = JSON.parse(fs.readFileSync(0, 'utf8'));
  const u = new URL(origin);
  if (!['http:', 'https:'].includes(u.protocol) || u.origin !== origin || u.username || u.password ||
      typeof email !== 'string' || typeof password !== 'string' || !email || password.length < 12 || password.length > 128) fail('Invalid provisioning input.');
  const baseHeaders = { host: u.host, origin };
  async function call(pathname, { payload, cookie, allowError = false } = {}) {
    const headers = { ...baseHeaders, ...(cookie ? { cookie } : {}), ...(payload !== undefined ? { 'content-type': 'application/json' } : {}) };
    const response = await fetch(`http://127.0.0.1:12008${pathname}`, {
      method: payload === undefined ? 'GET' : 'POST', headers,
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
      redirect: 'error', signal: AbortSignal.timeout(15000),
    });
    let body;
    try { body = await response.json(); } catch { fail(`Non-JSON response from ${pathname}.`); }
    if (!response.ok && !allowError) fail(`Provisioning ${pathname} failed (HTTP ${response.status}).`);
    return { response, body };
  }
  let signed = await call('/api/auth/sign-in/email', { payload: { email, password }, allowError: true });
  if (!signed.response.ok) {
    const created = await call('/api/auth/sign-up/email', { payload: { email, password, name: 'Administrator' }, allowError: true });
    if (!created.response.ok) fail(`Could not create or sign in as the administrator (HTTP ${created.response.status}).`);
    signed = created;
  }
  const cookie = cookies(signed.response);
  if (!cookie) fail('Administrator login did not return a session.');
  const session = await call('/api/auth/get-session', { cookie });
  const user = session.body?.user;
  if (!user?.id || String(user.email || '').toLowerCase() !== email.toLowerCase()) fail('Administrator session did not match the requested account.');
  for (const procedure of ['setSignupDisabled', 'setSsoSignupDisabled']) {
    const result = await call(`/trpc/frontend.config.${procedure}`, { cookie, payload: { disabled: true } });
    if (data(result.body)?.success !== true) fail(`Could not close ${procedure}.`);
  }
  for (const procedure of ['getSignupDisabled', 'getSsoSignupDisabled']) {
    const result = await call(`/trpc/frontend.config.${procedure}`, { cookie });
    if (data(result.body) !== true) fail(`Registration is not closed (${procedure}).`);
  }
  const listed = data((await call('/trpc/frontend.apiKeys.list', { cookie })).body);
  if (!Array.isArray(listed?.apiKeys)) fail('Could not read the administrator API keys.');
  const matches = listed.apiKeys.filter((item) => item.name === 'mcpkit-client' && item.user_id === user.id && item.is_active);
  if (matches.length > 1) fail('Several matching client API keys already exist; inspect them before continuing.');
  let apiKey = matches[0]?.key;
  if (!apiKey) {
    const result = data((await call('/trpc/frontend.apiKeys.create', { cookie, payload: { name: 'mcpkit-client' } })).body);
    apiKey = result?.key;
  }
  if (typeof apiKey !== 'string' || !/^sk_mt_[A-Za-z0-9]{64}$/.test(apiKey)) fail('A private client API key was not returned.');
  process.stdout.write(JSON.stringify({ userId: user.id, apiKey }));
} catch (error) {
  console.error(`Provisioning error: ${error.message}`);
  process.exitCode = 1;
}
