import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import https from 'node:https';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {validate,dispatch,createRuntimeServer} from './server.mjs';
import {resolvePlayback} from './sources.mjs';
import {resolved,fetchJson} from './network.mjs';
import {song,search,discover,playlistPage,mv} from './catalog.mjs';
import {clientCatalog,completeClientCatalog} from './client_catalog.mjs';

// 输入 → 执行 → 结果；所有上游由测试替身提供，不消耗实际个人授权。
// SHIXIAOYANG，2026/11/19。
const sample={platform:'163',id:'347230',name:'海阔天空',artist:'Beyond',album:'海阔天空',duration:326,quality:'exhigh'};
const reply=data=>new Response(JSON.stringify(data),{headers:{'Content-Type':'application/json'}});

function directoryPlan(transform) {
  return clientCatalog({url:'https://u.y.qq.com/cgi-bin/musicu.fcg',headers:{}},transform).clientRequest;
}

function directoryReceipt(plan, body, status=200) {
  return {id:plan.id,status,bodyBase64:Buffer.from(JSON.stringify(body)).toString('base64')};
}

function preserveDirectory(body) {
  return {songs:body.songs};
}

test('公共目录回执只能消费一次，正常大响应保留完整内容', async function () {
  const plan = directoryPlan(preserveDirectory);
  const songs = [{id:'1',name:'歌'.repeat(50000)}];
  const receipt = directoryReceipt(plan,{songs});
  assert(Buffer.from(receipt.bodyBase64,'base64').length > 128*1024);
  assert.deepEqual(await completeClientCatalog(receipt),{songs});
  await assert.rejects(completeClientCatalog(receipt),{code:'CLIENT_REQUEST_EXPIRED'});
});

test('公共目录拒绝缺失状态、重定向、非法 Base64、超大正文和非 JSON 回执', async function () {
  for (const kind of ['missing-status','redirect','bad-base64','oversized','not-json']) {
    const plan = directoryPlan(preserveDirectory);
    const receipt = directoryReceipt(plan,{songs:[]});
    if (kind==='missing-status') delete receipt.status;
    if (kind==='redirect') receipt.status=302;
    if (kind==='bad-base64') receipt.bodyBase64='not!base64';
    if (kind==='oversized') receipt.bodyBase64=Buffer.alloc(512*1024+1).toString('base64');
    if (kind==='not-json') receipt.bodyBase64=Buffer.from('upstream unavailable').toString('base64');
    await assert.rejects(completeClientCatalog(receipt));
    await assert.rejects(completeClientCatalog(directoryReceipt(plan,{songs:[]})),{code:'CLIENT_REQUEST_EXPIRED'});
  }
});

test('公共目录取消后不调用转换函数，过期和容量淘汰不会保留回调', async function () {
  let transformed = false;
  function transform() { transformed=true;return {}; }
  const cancelled = directoryPlan(transform);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(completeClientCatalog(directoryReceipt(cancelled,{}),controller.signal),{code:'REQUEST_CANCELLED'});
  assert.equal(transformed,false);
  const expired = directoryPlan(transform);
  const realNow = Date.now;
  try {
    Date.now = function () { return realNow()+45001; };
    await assert.rejects(completeClientCatalog(directoryReceipt(expired,{})),{code:'CLIENT_REQUEST_EXPIRED'});
  } finally {
    Date.now=realNow;
  }
  const plans=[];
  for (let index=0;index<17;index++) plans.push(directoryPlan(preserveDirectory));
  await assert.rejects(completeClientCatalog(directoryReceipt(plans[0],{})),{code:'CLIENT_REQUEST_EXPIRED'});
  for (const plan of plans.slice(1)) await completeClientCatalog(directoryReceipt(plan,{songs:[]}));
});

test('QQ 歌单出口失败后由设备补偿，仍按服务端请求的页码解析', async function () {
  const original=global.fetch;
  global.fetch=async function () {return reply({req_0:{code:2001}});};
  try {
    const result=await playlistPage({platform:'qq',id:'1234',page:2,limit:20});
    assert.equal(result.clientRequest.body.req_0.param.song_begin,20);
    const body={req_0:{code:0,data:{dirinfo:{title:'测试歌单',songnum:25},songlist:[
      {mid:'mid1',name:'海阔天空',singer:[{name:'Beyond'}]},
    ]}}};
    const restored=await completeClientCatalog(directoryReceipt(result.clientRequest,body));
    assert.equal(restored.playlist.id,'1234');
    assert.equal(restored.songs[0].id,'mid1');
    assert.equal(restored.total,25);
  } finally {
    global.fetch=original;
  }
});

test('QQ 设备目录也拒绝歌单时使用已有兼容线路，保留真实页码与总数', async function () {
  const original=global.fetch;
  global.fetch=async function (address) {
    const url=new URL(address);
    if (url.hostname==='u.y.qq.com') return reply({req_0:{code:2001}});
    assert.equal(url.hostname,'161.118.252.183');
    assert.equal(url.searchParams.get('song_begin'),'20');
    assert.equal(url.searchParams.get('song_num'),'20');
    return reply({data:{dissid:'1234',dissname:'公共歌单',songnum:25,
      songlist:[{songmid:'legacy-mid',songname:'海阔天空',singer:[{name:'Beyond'}]}]}});
  };
  try {
    const first=await playlistPage({platform:'qq',id:'1234',page:2,limit:20});
    const result=await completeClientCatalog(directoryReceipt(first.clientRequest,{req_0:{code:2001}}));
    assert.equal(result.songs[0].id,'legacy-mid');
    assert.equal(result.total,25);
    assert.equal(result.playlist.id,'1234');
  } finally {
    global.fetch=original;
  }
});

test('QQ 首屏搜索的设备出口被拒绝时复用已确认的歌曲与歌单兼容协议', async function () {
  const original=global.fetch;
  try {
    for (const kind of ['songs','playlists']) {
      global.fetch=async function (address) {
        const url=new URL(address);
        if (url.hostname==='u.y.qq.com') return reply({req_1:{code:2001}});
        assert.equal(url.pathname,'/api-qq/search');
        assert.equal(url.searchParams.get('key'),'Beyond');
        assert.equal(url.searchParams.get('t'),kind==='playlists'?'2':'0');
        return reply({data:{list:[{songmid:'mid1',songname:'海阔天空',dissid:'1234',dissname:'歌单'}]}});
      };
      const plan=await search({platform:'qq',keyword:'Beyond',kind,page:1,limit:20});
      const result=await completeClientCatalog(directoryReceipt(plan.clientRequest,{req_1:{code:2001}}));
      assert.equal((result.songs || result.playlists).length,1);
    }
  } finally {
    global.fetch=original;
  }
});

test('QQ 发现页设备出口被拒绝时仍可使用现有推荐兼容线路', async function () {
  const original=global.fetch;
  global.fetch=async function (address) {
    const url=new URL(address);
    if (url.hostname==='u.y.qq.com') return reply({req_0:{code:2001}});
    assert.equal(url.pathname,'/api-qq/recommend/playlist');
    return reply({data:{list:[{dissid:'1234',dissname:'歌单'}]}});
  };
  try {
    const plan=await discover({platform:'qq',limit:10});
    const result=await completeClientCatalog(directoryReceipt(plan.clientRequest,{req_0:{code:2001}}));
    assert.equal(result.playlists[0].id,'1234');
  } finally {
    global.fetch=original;
  }
});

test('QQ MV 可连续补偿歌曲目录与视频地址，设备只接收最终媒体地址', async function () {
  const original=global.fetch;
  global.fetch=async function () {return reply({code:2001});};
  try {
    const first=await mv({platform:'qq',id:'mid1',name:'海阔天空',artist:'Beyond'});
    const songReply={req_1:{code:0,data:{body:{song:{list:[{mid:'mid1',mv:{vid:'video1'}}]}}}}};
    const second=await completeClientCatalog(directoryReceipt(first.clientRequest,songReply));
    assert.deepEqual(second.clientRequest.body.getMvUrl.param.vids,['video1']);
    const videoReply={getMvUrl:{code:0,data:{video1:{mp4:[{comm_url:['https://example.com/video.mp4']}]}}}};
    assert.deepEqual(await completeClientCatalog(directoryReceipt(second.clientRequest,videoReply)),{url:'https://example.com/video.mp4'});
  } finally {
    global.fetch=original;
  }
});

test('酷狗 MV 服务器出口缺少地址时补偿设备目录，并跳过空的备用地址', async function () {
  const original=global.fetch;
  global.fetch=async function (url) {
    if (new URL(url).hostname==='mobilecdn.kugou.com') {
      return reply({data:{info:[{hash:'hash1',mvhash:'video1'}]}});
    }
    return reply({mvdata:{}});
  };
  try {
    const first=await mv({platform:'kugou',id:'hash1',name:'海阔天空',artist:'Beyond'});
    assert.equal(new URL(first.clientRequest.url).hostname,'m.kugou.com');
    const body={mvdata:{sq:{downurl:'',backupdownurl:['','https://example.com/kg.mp4']}}};
    assert.deepEqual(await completeClientCatalog(directoryReceipt(first.clientRequest,body)),{url:'https://example.com/kg.mp4'});
  } finally {
    global.fetch=original;
  }
});

test('外部输入拒绝任意平台、路径、超大分页与非文字凭据',()=>{
  for(const input of [{platform:'file',id:'347230'},{platform:'163',id:'../password'},{platform:'163',id:'1',limit:10000}]) {
    assert.throws(()=>validate('playlist',input));
  }
  assert.throws(()=>validate('resolve',{song:sample,credentials:{apiKey:{secret:'x'}}}));
  assert.throws(()=>validate('resolve',{song:{...sample,source:'http://private-host'}}));
});

test('统一播放地址拒绝加密、脚本协议、身份信息和换行请求头',()=>{
  for(const value of [{url:'javascript:alert(1)'},{url:'https://user:secret@example.com/a.mp3'},
    {url:'https://example.com/a.mflac',format:'mflac'},
    {url:'https://example.com/a.mp3',headers:{Referer:'value\r\nInjected: yes'}}])assert.throws(()=>resolved(value,'test'));
});

test('目录标准化保留歌曲和专辑身份',()=>{
  const result=song({mid:'001yS0N33yPm1B',name:'海阔天空',singer:[{name:'BEYOND'}],album:{name:'乐与怒',mid:'002qcJuX3lO3EZ'},interval:324},'qq');
  assert.equal(result.id,'001yS0N33yPm1B');assert.equal(result.albumId,'002qcJuX3lO3EZ');assert.equal(result.duration,324);
});

test('公开音源能力仍明确个人授权和公益版平台边界',async()=>{
  const data=await dispatch('sources',{});
  assert(data.sources.find(item=>item.id==='qing_music').platforms.includes('kugou'));
  assert(data.sources.find(item=>item.id==='xinghai').authorizedPlatforms.includes('qq'));
  assert(!data.sources.find(item=>item.id==='hyw').platforms.includes('kugou'));
});

test('自动模式依据渠道表排除 QQ 实验线，不让不可读取的 HYW 地址抢先返回', async function () {
  const original=global.fetch;
  const oldKey=process.env.QING_CLIENT_KEY;
  delete process.env.QING_CLIENT_KEY;
  const hosts=[];
  global.fetch=async function (address) {
    const url=new URL(address);
    hosts.push(url.hostname);
    if (url.searchParams.get('types')==='search') {
      return reply([{id:'347230',name:sample.name,artist:[sample.artist],duration:326}]);
    }
    return reply({url:'https://example.com/audio.mp3'});
  };
  try {
    const result=await resolvePlayback({...sample,platform:'qq',source:'automatic'});
    assert.equal(result.providerId,'gd_studio');
    assert(!hosts.includes('103.79.184.97'));
  } finally {
    global.fetch=original;
    if (oldKey!==undefined) process.env.QING_CLIENT_KEY=oldKey;
  }
});

test('用户手动选择 QQ 实验线时仍可用自己的 HYW 配置验证', async function () {
  const original=global.fetch;
  global.fetch=async function () {
    return reply({code:200,data:{url:'https://example.com/audio.mp3'}});
  };
  try {
    const result=await resolvePlayback({...sample,platform:'qq',source:'hyw'},
      {credentials:{hywCardKey:'private-test-key'}});
    assert.equal(result.providerId,'hyw');
  } finally {
    global.fetch=original;
  }
});

test('QingMusic 使用发布包协议签署同一请求正文',async()=>{
  const original=global.fetch;const oldKey=process.env.QING_CLIENT_KEY;process.env.QING_CLIENT_KEY='test-client-key';
  let actual;
  global.fetch=async(url,options)=>{actual={url:String(url),...options};return reply({code:0,data:{url:'https://example.com/audio.mp3'}});};
  try {
    const result=await resolvePlayback({...sample,source:'qing_music'});
    const sign=['qingmusic-android',actual.headers['X-Qing-Ts'],actual.headers['X-Qing-Nonce'],'POST','/v1/music/resolve-url',
      crypto.createHash('sha256').update(actual.body).digest('hex')].join('\n');
    assert.equal(actual.headers['X-Qing-Sign'],crypto.createHmac('sha256','test-client-key').update(sign).digest('hex'));
    assert.equal(result.providerId,'qing_music');assert.equal(JSON.parse(actual.body).level,'exhigh');
  } finally {global.fetch=original;if(oldKey===undefined)delete process.env.QING_CLIENT_KEY;else process.env.QING_CLIENT_KEY=oldKey;}
});

test('GD 高音质空地址只回退一次，999 和 740 各请求一次',async()=>{
  const original=global.fetch;const bitrates=[];
  global.fetch=async(url)=>{const br=new URL(url).searchParams.get('br');bitrates.push(br);return reply(br==='999'?{url:''}:{url:'https://example.com/audio.flac'});};
  try {
    const result=await resolvePlayback({...sample,source:'gd_studio',quality:'hires'});
    assert.equal(result.providerId,'gd_studio');assert.deepEqual(bitrates,['999','740']);
  } finally {global.fetch=original;}
});

test('GD 不会把同名翻唱歌手匹配成原曲',async()=>{
  const original=global.fetch;
  global.fetch=async()=>reply([{id:'1',name:'海阔天空',artist:['Beyond Tribute'],duration:324}]);
  try {await assert.rejects(resolvePlayback({...sample,platform:'qq',source:'gd_studio'}),error=>error.code==='SOURCES_UNAVAILABLE');}
  finally {global.fetch=original;}
});

test('已经取消的解析不会启动任何上游请求',async()=>{
  const original=global.fetch;let calls=0;global.fetch=async()=>{calls++;return reply({});};
  const controller=new AbortController();controller.abort();
  try {await assert.rejects(resolvePlayback(sample,{signal:controller.signal}));assert.equal(calls,0);}
  finally {global.fetch=original;}
});

test('上游响应超过 5 MB 时取消读取',async()=>{
  const original=global.fetch;let cancelled=false;
  global.fetch=async()=>new Response(new ReadableStream({start(controller){controller.enqueue(new Uint8Array(5*1024*1024+1));},cancel(){cancelled=true;}}));
  try {await assert.rejects(fetchJson('https://example.com/'),error=>error.code==='RESPONSE_TOO_LARGE');assert(cancelled);}
  finally {global.fetch=original;}
});

test('HTTPS 服务有界读取、拒绝非法接口并取消断开的客户端',async()=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'music-runtime-server-test-'));
  const key=path.join(directory,'key.pem'),cert=path.join(directory,'cert.pem');
  const openssl=process.env.OPENSSL_TEST_BINARY || 'openssl';
  const generated=spawnSync(openssl,['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost',
    '-addext','subjectAltName=IP:127.0.0.1,DNS:localhost','-keyout',key,'-out',cert],{windowsHide:true,encoding:'utf8'});
  assert.equal(generated.status,0,'测试需要本机 OpenSSL，使用 OPENSSL_TEST_BINARY 指定已有工具');
  fs.writeFileSync(path.join(directory,'manifest.json'),'{}');
  const cancelled=new Promise(resolve=>{
    const handler=async(operation,input,signal)=>{if(operation==='search'){await new Promise(done=>signal.addEventListener('abort',done,{once:true}));resolve();return {};}
      return dispatch(operation,input,signal);};
    globalThis.testServer=createRuntimeServer({root:directory,tls:{key:fs.readFileSync(key),cert:fs.readFileSync(cert)},handler});
  });
  const server=globalThis.testServer;delete globalThis.testServer;
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port;
  const request=(route,body,options={})=>new Promise((resolve,reject)=>{
    const value=body===undefined?null:JSON.stringify(body);
    const call=https.request({hostname:'127.0.0.1',port,path:route,ca:fs.readFileSync(cert),method:value===null?'GET':'POST',
      headers:value===null?{}:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(value)},...options},response=>{
      const parts=[];response.on('data',part=>parts.push(part));response.on('end',()=>resolve({status:response.statusCode,body:Buffer.concat(parts).toString()}));
    });call.on('error',reject);if(value)call.write(value);call.end();
  });
  try {
    assert.equal((await request('/health')).status,200);
    assert.equal((await request('/manifest.json')).body,'{}');
    assert.equal((await request('/api/execute',{command:'id'})).status,404);
    assert.equal((await request('/api/lyrics',{platform:'local',id:'file:///private'})).status,400);
    const slow=https.request({hostname:'127.0.0.1',port,path:'/api/search',method:'POST',ca:fs.readFileSync(cert),headers:{'Content-Type':'application/json'}},()=>{});
    slow.on('error',()=>{});slow.end(JSON.stringify({platform:'163',keyword:'test'}));
    await new Promise(resolve=>setTimeout(resolve,100));slow.destroy();
    await Promise.race([cancelled,new Promise((_,reject)=>setTimeout(()=>reject(new Error('客户端断开后未取消上游')),1500))]);
  } finally {
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
    assert(path.resolve(directory).startsWith(path.resolve(os.tmpdir())+path.sep));
    fs.rmSync(directory,{recursive:true,force:true});
  }
});
