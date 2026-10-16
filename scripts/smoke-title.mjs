import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {ChatClient} from '../backend/dist/client.js';
import {JsonRpcProcess} from '../backend/dist/protocol.js';
const state=await mkdtemp(join(tmpdir(),'speedchat-title-'));
process.env.SPEEDCHAT_STATE_DIR=state;
const rpc=new JsonRpcProcess();const client=new ChatClient(rpc);
client.on('error',e=>console.error(e.message));
try {
 const ready=await client.connect();
 const done=new Promise((resolve,reject)=>{client.once('done',resolve);client.once('error',reject);});
 await client.send('Can you help me plan a weekend trip to Yosemite? Reply in one sentence.');
 await done;
 const result=await rpc.request('thread/read',{threadId:ready.threadId,includeTurns:false});
 assert.equal(result.thread.name,'Plan a weekend trip to Yosemite? Reply in one sentence');
 console.log(JSON.stringify({passed:true,threadId:ready.threadId,title:result.thread.name,readBack:true}));
} finally {await client.close();await rm(state,{recursive:true,force:true});}
