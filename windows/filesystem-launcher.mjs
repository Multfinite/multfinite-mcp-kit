// @j0hanz/filesystem-mcp 2.20 uses an Emscripten dependency that treats
// process.argv[1] as ASCII. A Windows profile or checkout can contain Unicode;
// keep the real module path for import, but give the dependency a safe label.
import { pathToFileURL } from 'node:url';

const [entry, ...args] = process.argv.slice(2);
if (!entry) throw new Error('filesystem-mcp entry point is missing');
process.argv = [process.execPath, 'filesystem-mcp', ...args];
await import(pathToFileURL(entry).href);
