// Authorized real smoke. Uses only isolated SpeedChat state and its dedicated threads.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {mkdtemp, readFile, stat, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {safeEnvironment} from '../backend/dist/runtime.js';
const state=await mkdtemp(join(tmpdir(),'speedchat-live-smoke-'));
const events=[];const children=[];
async function start() {
 const child=spawn(process.execPath,[resolve('backend/dist/bridge.js')],{env:{...safeEnvironment(),SPEEDCHAT_STATE_DIR:state},stdio:'pipe'});
 children.push(child); const waiting=[];let stderr='';let exited=false;
 child.stderr.on('data',d=>{stderr=(stderr+d).slice(-1000)});
 child.on('exit',()=>{exited=true;for(const waiter of waiting)waiter.reject(new Error('bridge exited'));});
 const lines=createInterface({input:child.stdout});
 lines.on('line',line=>{
  const event=JSON.parse(line);events.push(event);
  if(event.type==='fatal') {for(const waiter of waiting)waiter.reject(new Error(event.message));return}
  for(const waiter of [...waiting]) {if(waiter.type===event.type) {waiting.splice(waiting.indexOf(waiter),1);clearTimeout(waiter.timer);waiter.resolve(event)}}
 });
 function wait(type,ms=90000) {return new Promise((resolve,reject)=>{
  const waiter={type,resolve,reject,timer:setTimeout(()=>reject(new Error(`Timed out waiting for ${type}`)),ms)};waiting.push(waiter);
 })}
 function send(command) {child.stdin.write(JSON.stringify(command)+'\n')}
 async function close() {
  const end=new Promise(resolve=>child.once('exit',resolve));send({type:'close'});child.stdin.end();
  await Promise.race([end,new Promise((_,reject)=>setTimeout(()=>reject(new Error('bridge failed to exit')),5000))]);
  assert.equal(child.exitCode,0);
 }
 const ready=await wait('ready');return {child,ready,wait,send,close};
}
try {
 const first=await start();assert.ok(first.ready.models.length);assert.match(first.ready.model,/luna/i);
 const original=JSON.parse(await readFile(join(state,'state.json'),'utf8'));
 assert.equal((await stat(join(state,'state.json'))).mode & 0o777,0o600);
 let smokeModel=first.ready.model;
 if(process.env.SPEEDCHAT_SMOKE_MODEL) {smokeModel=process.env.SPEEDCHAT_SMOKE_MODEL;const chosen=first.wait('modelSelected');first.send({type:'selectModel',model:smokeModel});await chosen;}
 const done=first.wait('done');
 first.send({type:'send',text:'You must use your web search tool now, not your memory. Search the live web for the official OpenAI developer documentation homepage and the current title. Reply with its title, one short sentence, and a Markdown source link. Keep the response under 70 words.'});
 await done;
 assert.ok(events.some(e=>e.type==='delta'),'streamed output');
 assert.ok(events.some(e=>e.type==='searching'),'hosted web search');
 assert.ok(events.some(e=>e.type==='message' && /https?:\/\//.test(e.text)),'source link');
 assert.ok(!events.some(e=>e.type==='error' || e.type==='fatal'),'no errors');
 const streamedEvents=events.length;
 await first.close();
 const reopened=await start();assert.ok(reopened.ready.messages.length>=2);assert.match(reopened.ready.notice,/Resumed/);
 assert.equal(JSON.parse(await readFile(join(state,'state.json'),'utf8')).threadId,original.threadId);
 const selected=reopened.wait('modelSelected');reopened.send({type:'selectModel',model:reopened.ready.model});await selected;
 const newReady=reopened.wait('ready');reopened.send({type:'newChat'});const newChat=await newReady;assert.deepEqual(newChat.messages,[]);
 const replacement=JSON.parse(await readFile(join(state,'state.json'),'utf8'));assert.notEqual(replacement.threadId,original.threadId);assert.equal(replacement.model,smokeModel);
 await reopened.close();
 const final=await start();assert.equal(final.ready.model,replacement.model);assert.deepEqual(final.ready.messages,[]);assert.equal(JSON.parse(await readFile(join(state,'state.json'),'utf8')).threadId,replacement.threadId);await final.close();
 const report={passed:true,defaultModel:first.ready.model,model:smokeModel,models:first.ready.models,streamedEvents,deltaCount:events.filter(e=>e.type==='delta').length,webSearch:true,metrics:events.filter(e=>e.type==='metric'),response:events.find(e=>e.type==='message')?.text,persistence:true,newChat:true,reopen:true,cleanExit:true,stateMode:'0600',stateIsolation:'temporary SpeedChat-only state; no normal Codex history read'};
 await writeFile('docs/live-smoke.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
} catch(error) {
 await writeFile('docs/live-smoke-failure.json',JSON.stringify({error:error.message,events},null,2)+'\n'); console.error(JSON.stringify({error:error.message,events},null,2));throw error;
} finally {
 for(const child of children) {if(child.exitCode===null) {child.stdin.end();child.kill('SIGTERM')}}
 await rm(state,{recursive:true,force:true});
}
