// Test-only loader: use a pre-provisioned model cache and forbid downloads.
// The application itself uses the upstream model download/cache behavior.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const entry = process.argv[2];
const cache = process.env.MCP_VECTORSTORE_TEST_CACHE;
if (!entry || !cache) throw new Error('Vectorstore entry point and model cache are required.');
const resolve = createRequire(entry);
const { env } = await import(pathToFileURL(resolve.resolve('@xenova/transformers')).href);
env.cacheDir = cache;
// Upstream sets allowLocalModels=false. Keep remote mode enabled so its
// cache can be read, but direct any cache miss to an unreachable loopback
// address rather than the Internet.
env.remoteHost = 'http://127.0.0.1:1/';
await import(pathToFileURL(entry).href);
