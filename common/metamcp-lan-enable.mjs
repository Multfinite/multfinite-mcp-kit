// Pure helpers for converting an existing loopback-only MetaMCP installation
// to the explicit HTTP LAN mode. Docker, filesystem and confirmation effects
// remain in stack.mjs; these helpers only compute the next state and .env text.
import net from 'node:net';
import { LAN_PATCH_VERSION } from './metamcp-lan-source.mjs';

export function validateLanIp(value) {
  if (typeof value !== 'string' || net.isIP(value) !== 4) throw new Error('LAN IP must be a literal private IPv4 address.');
  const [a, b] = value.split('.').map(Number);
  if (!(a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168))) {
    throw new Error('LAN IP must be in an RFC 1918 private IPv4 range.');
  }
  return value;
}

// Returns the same object when LAN mode is already enabled on this address.
// A different existing LAN address is refused: changing it is a separate operation.
export function lanEnabledState(state, lanIp) {
  validateLanIp(lanIp);
  if (state.type !== 'meta') throw new Error('LAN mode applies only to MetaMCP.');
  if (state.lanIp !== undefined) {
    if (state.lanIp === lanIp) return state;
    throw new Error(`This MetaMCP already uses LAN address ${state.lanIp}; changing it is not supported here. No files were changed.`);
  }
  return { ...state, lanIp, lanPatch: LAN_PATCH_VERSION, appUrl: `http://${lanIp}:${state.port}` };
}

// Replaces the single APP_URL=... line, or appends one when absent. Every other
// line (secrets, admins, trusted origins) is preserved byte-for-byte.
export function withAppUrl(envText, origin) {
  const line = `APP_URL='${origin}'`;
  const lines = envText.split(/\r?\n/);
  const indexes = lines.flatMap((text, index) => (/^APP_URL=/.test(text) ? [index] : []));
  if (indexes.length > 1) throw new Error('Multiple APP_URL entries in the private .env; resolve them manually. No files were changed.');
  if (indexes.length === 1) {
    lines[indexes[0]] = line;
    return lines.join('\n');
  }
  const base = envText.endsWith('\n') ? envText : `${envText}\n`;
  return `${base}${line}\n`;
}
