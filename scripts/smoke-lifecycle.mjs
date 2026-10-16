import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createInterface} from 'node:readline';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {safeEnvironment} from '../backend/dist/runtime.js';
const root=await mkdtemp(join(tmpdir(),'speedchat-cleanup-'));
const checks=[];
try {
 for(const mode of ['command','EOF','SIGTERM']) {
  const child=spawn(process.execPath,[resolve('backend/dist/bridge.js')],{env:{...safeEnvironment(),SPEEDCHAT_STATE_DIR:join(root,mode)},stdio:'pipe'});
  const ready=new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(new Error('ready timeout')),20000);const lines=createInterface({input:child.stdout});lines.on('line',line=>{const event=JSON.parse(line);if(event.type==='ready'){clearTimeout(timer);resolve()}if(event.type==='fatal'){clearTimeout(timer);reject(new Error(event.message))}});
  });
  await ready;
  const snapshot=execFileSync('/bin/ps',['-axo','pid=,ppid=,comm='],{encoding:'utf8'}).split('\n').map(line=>line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean).map(m=>({pid:Number(m[1]),parent:Number(m[2]),name:m[3]}));
  const descendants=new Set([child.pid]);let added=true;
  while(added) {added=false;for(const row of snapshot) {if(descendants.has(row.parent)&&!descendants.has(row.pid)){descendants.add(row.pid);added=true}}}
  assert.ok(descendants.size>=2,'Codex child present');
  const ended=new Promise(resolve=>child.once('exit',resolve));
  if(mode==='command')child.stdin.write('{"type":"close"}\n');
  if(mode==='EOF')child.stdin.end();
  if(mode==='SIGTERM')child.kill('SIGTERM');
  await Promise.race([ended,new Promise((_,reject)=>setTimeout(()=>reject(new Error('shutdown timeout')),5000))]);
  await new Promise(resolve=>setTimeout(resolve,200));
  for(const pid of descendants) {let alive=false;try{process.kill(pid,0);alive=true}catch{}assert.ok(!alive,`orphan child ${pid}`)}
  checks.push({mode,passed:true,descendantsExited:descendants.size});
 }
 await writeFile('docs/lifecycle-smoke.json',JSON.stringify({passed:true,checks,quotaUsed:false},null,2)+'\n');console.log(JSON.stringify(checks));
} finally {await rm(root,{recursive:true,force:true})}
