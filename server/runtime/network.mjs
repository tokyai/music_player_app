/** 固定上游接口的有界请求。SHIXIAOYANG，2026/11/19。 */
export class SourceError extends Error {
  constructor(code,message) { super(message); this.code=code; }
}

async function fetchBounded(url,{body,headers={},signal,timeout=6500}={}) {
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  signal?.addEventListener('abort',onAbort,{once:true});
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(onAbort,timeout);
  let reader;
  try {
    const response = await fetch(url,{method:body===undefined?'GET':'POST',
      headers:{'Accept':'application/json','User-Agent':'LX-Music-Mobile',...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},
      body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal,redirect:'error'});
    reader=response.body.getReader();
    const pieces=[]; let length=0;
    while(true) {
      const part=await reader.read(); if(part.done)break;
      length+=part.value.length;
      if(length>5*1024*1024)throw new SourceError('RESPONSE_TOO_LARGE','上游响应过大');
      pieces.push(Buffer.from(part.value));
    }
    return {status:response.status,text:Buffer.concat(pieces).toString('utf8')};
  } catch(error) {
    if(error instanceof SourceError)throw error;
    throw new SourceError(controller.signal.aborted?'UPSTREAM_TIMEOUT':'UPSTREAM_NETWORK','上游网络请求失败');
  } finally {
    clearTimeout(timer); signal?.removeEventListener('abort',onAbort);
    await reader?.cancel().catch(()=>{}); controller.abort();
  }
}

/** 获取固定上游的 JSON，响应体受统一大小和时间上限约束。 */
export async function fetchJson(url,options) {
  const response=await fetchBounded(url,options);
  let data;
  try { data=JSON.parse(response.text); }
  catch { throw new SourceError(`HTTP_${response.status}`,'上游返回非 JSON 内容'); }
  return {status:response.status,data};
}

/** 获取歌词文本，避免把大响应无限缓存在服务器。 */
export async function fetchText(url,options) { return fetchBounded(url,options); }

export function query(base,params) {
  const url=new URL(base);
  for(const [key,value] of Object.entries(params)) {
    if(value!==undefined && value!==null && value!=='')url.searchParams.set(key,String(value));
  }
  return url;
}

export function resolved(body,providerId) {
  const data=body?.data;
  const value=data && typeof data==='object'?data:body;
  const url=typeof data==='string'?data:(value?.url || body?.url || value?.musicUrl);
  if(body?.encrypted || value?.encrypted || body?.encryption==='cenc' || value?.encryption==='cenc') {
    throw new SourceError('ENCRYPTED_AUDIO','上游返回加密音频');
  }
  if(typeof url!=='string')throw new SourceError('EMPTY_URL','上游未返回音频地址');
  let parsed;try{parsed=new URL(url);}catch{throw new SourceError('INVALID_AUDIO_URL','音频地址无效');}
  if(!['http:','https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.hash)throw new SourceError('INVALID_AUDIO_URL','音频地址协议无效');
  const format=String(value?.format || parsed.pathname.split('.').at(-1) || '').toLowerCase();
  if(['mgg','mflac','cenc'].includes(format))throw new SourceError('ENCRYPTED_AUDIO','上游返回加密音频');
  const rawHeaders=value?.playbackHeaders || value?.headers || body?.playbackHeaders || body?.headers || {};
  const playbackHeaders={};
  for(const [key,value] of Object.entries(rawHeaders)) {
    if(!/^[A-Za-z0-9-]{1,64}$/.test(key) || typeof value!=='string' || value.length>4096 || /[^\x20-\x7e]/.test(value))throw new SourceError('INVALID_HEADERS','播放请求头无效');
    playbackHeaders[key]=value;
  }
  return {url,providerId,format:/^[a-z0-9]{1,12}$/.test(format)?format:null,playbackHeaders};
}
