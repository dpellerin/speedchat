import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, mkdir, writeFile, chmod, stat, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {resolveExecutable, safeEnvironment, createRuntimeDirectory} from '../src/runtime.js';
test('dependency discovery uses paths with spaces and rejects invalid overrides', async () => {
 const root = await mkdtemp(join(tmpdir(),'mac-runtime-'));
 const bin = join(root,'tools with spaces'); await mkdir(bin);
 const exe = join(bin,'codex'); await writeFile(exe,''); await chmod(exe,0o700);
 assert.equal(resolveExecutable('codex',{PATH:bin},root),exe);
 assert.throws(()=>resolveExecutable('codex',{PATH:bin,SPEEDCHAT_CODEX:'/missing'},root),/executable/);
});
test('chat environment never inherits keys or Node injection options',()=>{
 const env = safeEnvironment({HOME:'/home',PATH:'/bin',OPENAI_API_KEY:'secret',ANTHROPIC_API_KEY:'secret',NODE_OPTIONS:'injection',SPEEDCHAT_STATE_DIR:'/tmp/test'});
 assert.equal(env.OPENAI_API_KEY,undefined); assert.equal(env.ANTHROPIC_API_KEY,undefined); assert.equal(env.NODE_OPTIONS,undefined);
 assert.equal(env.SPEEDCHAT_STATE_DIR,'/tmp/test'); assert.match(env.PATH!,/\/opt\/homebrew\/bin/);
});
test('each runtime cwd is private, empty, and unique', async()=>{
 const a=await createRuntimeDirectory(), b=await createRuntimeDirectory();
 assert.notEqual(a,b); assert.deepEqual(await readdir(a),[]); assert.equal((await stat(a)).mode & 0o777,0o700);
});
test('executable overrides reject directories even when searchable',async()=>{
 const root=await mkdtemp(join(tmpdir(),'mac-exe-dir-'));
 assert.throws(()=>resolveExecutable('codex',{SPEEDCHAT_CODEX:root},root),/executable/);
});
