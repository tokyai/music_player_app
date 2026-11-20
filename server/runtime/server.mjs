import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {SourceError} from './network.mjs';
import {resolvePlayback,sources} from './sources.mjs';
import {search,discover,playlistPage,lyrics,mv} from './catalog.mjs';
import {completeClientCatalog} from './client_catalog.mjs';

const platforms=['qq','163','kugou'];
const operations=['search','discover','playlist','lyrics','mv','resolve','sources','catalog_result'];
const qualities={
  '163':[{id:'standard',name:'标准'},{id:'exhigh',name:'极高'},{id:'lossless',name:'无损'},
    {id:'hires',name:'Hi-Res'},{id:'jyeffect',name:'高清环绕'},{id:'sky',name:'超清母带'},{id:'jymaster',name:'高清母带'}],
  common:[{id:'128k',name:'128k'},{id:'320k',name:'320k'},{id:'flac',name:'无损 FLAC'},{id:'hires',name:'Hi-Res'},{id:'master',name:'母带'}],
};

function object(value) {
  if(!value || typeof value!=='object' || Array.isArray(value))throw new SourceError('INVALID_INPUT','请求内容必须是对象');
  return value;
}
function string(value,name,max=128,required=true) {
  if(!required && (value===undefined || value===null))return '';
  if(typeof value!=='string' || value.length>max || (required && !value.trim()) || /[\u0000-\u001f]/.test(value)) {
    throw new SourceError('INVALID_INPUT',`${name}无效`);
  }
  return value.trim();
}
function integer(value,name,minimum,maximum,defaultValue) {
  const number=value===undefined?defaultValue:value;
  if(!Number.isInteger(number) || number<minimum || number>maximum)throw new SourceError('INVALID_INPUT',`${name}超出范围`);
  return number;
}
function platform(value) {
  if(!platforms.includes(value))throw new SourceError('INVALID_PLATFORM','不支持该音乐平台');
  return value;
}
function identifier(value,source) {
  const id=string(value,'歌曲或歌单 ID');
  const pattern=source==='163'?/^[0-9]{1,20}$/:/^[A-Za-z0-9]{1,128}$/;
  if(!pattern.test(id))throw new SourceError('INVALID_ID','歌曲或歌单 ID 格式无效');
  return id;
}
function credentials(value={}) {
  const data=object(value);
  if(Object.keys(data).length>16)throw new SourceError('INVALID_INPUT','线路凭据数量过多');
  const result={};
  for(const [key,item] of Object.entries(data)) {
    if(!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key))throw new SourceError('INVALID_INPUT','线路凭据名称无效');
    result[key]=string(item,'线路凭据',2048,false);
  }
  return result;
}

/** 校验所有外部业务参数，上游 URL 只在服务端代码内定义。SHIXIAOYANG，2026/11/19。 */
export function validate(operation,input) {
  const data=object(input);
  if(operation==='sources')return {};
  const raw=operation==='resolve'?object(data.song):data;
  const params={platform:platform(raw.platform)};
  if(['playlist','lyrics','mv','resolve'].includes(operation))params.id=identifier(raw.id,params.platform);
  if(['search','discover','playlist'].includes(operation)) {
    params.page=integer(raw.page,'页码',1,5000,1);
    params.limit=integer(raw.limit,'每页数量',1,100,20);
  }
  if(operation==='search') {
    params.keyword=string(raw.keyword,'搜索词',128);
    params.kind=raw.kind==='playlists'?'playlists':'songs';
  }
  if(['mv','resolve'].includes(operation)) {
    params.name=string(raw.name,'曲名',512,false);
    params.artist=string(raw.artist,'歌手',512,false);
  }
  if(operation==='resolve') {
    params.album=string(raw.album,'专辑',512,false);
    params.albumId=string(raw.albumId,'专辑 ID',128,false);
    params.duration=integer(raw.duration==null?undefined:raw.duration,'时长',0,86400,0);
    params.source=string(raw.source || 'automatic','音源',64);
    params.quality=string(raw.quality || (params.platform==='163'?'exhigh':'320k'),'音质',64);
    if(!/^[a-z0-9_]{1,64}$/.test(params.source) || !/^[a-zA-Z0-9_]{1,64}$/.test(params.quality))throw new SourceError('INVALID_INPUT','音源或音质格式无效');
    if(params.source!=='automatic' && !sources.some(item=>item.id===params.source))throw new SourceError('SOURCE_UNSUPPORTED','该音源已下线，请切换自动备用');
    if(raw.excludedSources!==undefined && (!Array.isArray(raw.excludedSources) || raw.excludedSources.length>16))throw new SourceError('INVALID_INPUT','排除音源列表无效');
    params.excludedSources=(raw.excludedSources || []).map(value=>string(value,'排除音源',64));
    return {song:params,credentials:credentials(data.credentials)};
  }
  return params;
}

/** 执行业务接口；新增音源与目录修复不改变手机协议。 */
export async function dispatch(operation,input,signal) {
  if(operation==='catalog_result')return completeClientCatalog(input,signal);
  const params=validate(operation,input);
  switch(operation) {
    case 'sources':return {sources,platforms:[{id:'qq',name:'QQ音乐'},{id:'163',name:'网易云'},{id:'kugou',name:'酷狗'}],
      qualities:{'163':qualities['163'],qq:qualities.common,kugou:qualities.common}};
    case 'search':return search(params,signal);
    case 'discover':return discover(params,signal);
    case 'playlist':return playlistPage(params,signal);
    case 'lyrics':return lyrics(params,signal);
    case 'mv':return mv(params,signal);
    case 'resolve':return {result:await resolvePlayback(params.song,{signal,credentials:params.credentials})};
    default:throw new SourceError('API_NOT_FOUND','接口不存在');
  }
}

function respond(response,status,data) {
  if(response.destroyed || response.writableEnded)return;
  const bytes=Buffer.from(JSON.stringify(data));
  response.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Content-Length':bytes.length,
    'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
  response.end(bytes);
}

async function readBody(request,maxBytes=256*1024) {
  if(Number(request.headers['content-length'] || 0)>maxBytes)throw new SourceError('BODY_TOO_LARGE','请求超过大小上限');
  if(!/^application\/json(?:\s*;|$)/i.test(String(request.headers['content-type'] || '')))throw new SourceError('INVALID_INPUT','仅接受 JSON 请求');
  const chunks=[];let length=0;
  for await(const chunk of request) {
    length+=chunk.length;
    if(length>maxBytes)throw new SourceError('BODY_TOO_LARGE','请求超过大小上限');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new SourceError('INVALID_INPUT','请求 JSON 无效'); }
}

/** 创建独立 HTTPS 更新服务，限制连接、并发、请求体和响应文件。 */
export function createRuntimeServer({root,tls,handler=dispatch}) {
  const rates=new Map();let active=0;
  const server=https.createServer({...tls,minVersion:'TLSv1.2',maxHeaderSize:8192},async (request,response)=>{
    const controller=new AbortController();
    const cancel=()=>controller.abort();
    const disconnected=()=>{if(!response.writableEnded)cancel();};
    request.on('aborted',cancel);response.on('close',disconnected);
    const timer=setTimeout(cancel,22000);
    let counted=false;
    try {
      const address=request.socket.remoteAddress || 'unknown';
      let rate=rates.get(address);
      if(!rate || rate.until<Date.now())rate={until:Date.now()+60000,count:0,active:0};
      if(rates.size>=256 && !rates.has(address))rates.delete(rates.keys().next().value);
      rates.set(address,rate);rate.count++;
      if(rate.count>180 || rate.active>=4 || active>=8) {
        respond(response,429,{ok:false,code:'RATE_LIMITED',message:'请求过多，请稍后重试'});return;
      }
      rate.active++;active++;counted=true;
      const pathname=new URL(request.url,'https://runtime.invalid').pathname;
      if(request.method==='GET' && (pathname==='/health' || pathname==='/')) {
        respond(response,200,{ok:true,service:'kuzai-music-runtime',framework:1});return;
      }
      if(request.method==='POST' && pathname.startsWith('/api/')) {
        const operation=pathname.slice(5);
        if(!operations.includes(operation))throw new SourceError('API_NOT_FOUND','接口不存在');
        const input=await readBody(request,operation==='catalog_result'?768*1024:256*1024);
        if(controller.signal.aborted)throw new SourceError('REQUEST_CANCELLED','请求已取消');
        const result=await handler(operation,input,controller.signal);
        respond(response,200,{ok:true,...result});return;
      }
      if(!['GET','HEAD'].includes(request.method) || !/^\/(manifest\.json|releases\/r[0-9]{6,12}\/bundle\.json)$/.test(pathname)) {
        respond(response,404,{ok:false,code:'NOT_FOUND',message:'资源不存在'});return;
      }
      const file=path.resolve(root,pathname.slice(1));
      if(!file.startsWith(path.resolve(root)+path.sep))throw new SourceError('INVALID_PATH','资源路径无效');
      const stat=await fs.promises.stat(file);
      if(!stat.isFile() || stat.size>(pathname==='/manifest.json'?64*1024:12*1024*1024))throw new SourceError('RESOURCE_INVALID','更新资源无效');
      response.writeHead(200,{'Content-Type':'application/json','Content-Length':stat.size,
        'Cache-Control':pathname==='/manifest.json'?'no-store':'public, max-age=31536000, immutable','X-Content-Type-Options':'nosniff'});
      if(request.method==='HEAD') {response.end();return;}
      const stream=fs.createReadStream(file);
      const stop=()=>stream.destroy();
      response.once('close',stop);
      stream.on('error',()=>response.destroy());
      stream.pipe(response);
      await new Promise(resolve=>response.once('close',resolve));
      response.removeListener('close',stop);
    } catch(error) {
      const known=error instanceof SourceError;
      let code = 'SERVER_ERROR';
      if (known) code = error.code;
      else if (error.code === 'ENOENT') code = 'NOT_FOUND';
      let status = 502;
      if (code === 'NOT_FOUND' || code === 'API_NOT_FOUND') status = 404;
      else if (code === 'BODY_TOO_LARGE') status = 413;
      else if (code.startsWith('INVALID_')) status = 400;
      respond(response,status,{ok:false,code,message:known?error.message:'服务暂不可用'});
    } finally {
      clearTimeout(timer);cancel();request.removeListener('aborted',cancel);response.removeListener('close',disconnected);
      if(counted) {
        active--;
        const rate=rates.get(request.socket.remoteAddress || 'unknown');
        if(rate)rate.active=Math.max(0,rate.active-1);
      }
    }
  });
  server.requestTimeout=25000;server.headersTimeout=10000;server.keepAliveTimeout=5000;
  server.maxRequestsPerSocket=200;server.maxConnections=64;
  return server;
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const root=process.env.RUNTIME_ROOT || '/runtime';
  const server=createRuntimeServer({root,tls:{key:fs.readFileSync(`${root}/tls/server.key`),cert:fs.readFileSync(`${root}/tls/server.crt`)}});
  server.listen(Number(process.env.PORT || 8443),'0.0.0.0',()=>console.log('库仔音乐更新服务已启动'));
  for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>server.close(()=>process.exit(0)));
}
