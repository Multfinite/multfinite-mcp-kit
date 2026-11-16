// Pure helpers for updating kit-owned MetaMCP records during registration.
//
// A record is kit-owned when its name is a known kit name, its description is
// exactly the kit description for the same profile and id, and it is public
// (user_id null). Only kit-owned records are updated; any other same-named record
// is never adopted, and private records are never made public by an update.

export const SERVER_UPDATE_FIELDS = ['name', 'description', 'type', 'command', 'args', 'env', 'url', 'bearerToken', 'headers', 'forward_headers'];

export function kitDescription(profile, id) {
  return `MCP Kit ${profile}: ${id}`;
}

export function isKitRecord(item, profile, id) {
  return Boolean(item) && item.user_id === null && item.description === kitDescription(profile, id);
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value ?? null;
}

// Returns the mcpServers.update body, or null when the existing record already
// matches the desired definition. Null-valued fields are omitted because the
// MetaMCP schema accepts only strings, arrays and records for them.
export function serverUpdateBody(existing, desired) {
  const merged = {};
  let changed = false;
  for (const key of SERVER_UPDATE_FIELDS) {
    // Headers merge: kit-managed keys win, other headers set by the user are kept.
    const wanted = key === 'headers' && desired.headers
      ? { ...(existing.headers || {}), ...desired.headers }
      : Object.hasOwn(desired, key) ? desired[key] : existing[key];
    if (JSON.stringify(canonical(wanted)) !== JSON.stringify(canonical(existing[key]))) changed = true;
    if (wanted !== null && wanted !== undefined) merged[key] = wanted;
  }
  if (!changed) return null;
  if (typeof merged.name !== 'string' || typeof merged.type !== 'string') throw new Error('Invalid server update input.');
  return { uuid: existing.uuid, ...merged, user_id: null };
}

// Returns the namespaces.update body, or null when membership and description already match.
// actualServerUuids must come from namespaces.get, which lists the members.
export function namespaceUpdateBody(existing, { name, description, serverUuids, actualServerUuids }) {
  const actual = [...actualServerUuids].sort();
  const wanted = [...serverUuids].sort();
  const same = JSON.stringify(actual) === JSON.stringify(wanted) && existing.name === name && existing.description === description;
  if (same) return null;
  return { uuid: existing.uuid, name, description, mcpServerUuids: serverUuids, user_id: null };
}
