import crypto from 'node:crypto';
import {fetchJson,query,resolved,SourceError} from './network.mjs';

const tokens=new Map();
const sourceCode={qq:'tx','163':'wy',kugou:'kg'};
export const sources=[
  {id:'qing_music',name:'QingMusic',platforms:['qq','163','kugou']},
  {id:'xinghai',name:'星海',platforms:['163','kugou'],authorizedPlatforms:['qq']},
  {id:'hyw',name:'HYWmusic 公益版',platforms:['163'],experimentalPlatforms:['qq']},
  {id:'gd_studio',name:'GDStudio 网易云匹配',platforms:['163','qq','kugou']},
  {id:'chksz',name:'ChKSz',platforms:[],authorizedPlatforms:['qq','163','kugou']},
];

function aggregateQuality(quality) {
  return ({standard:'128k',exhigh:'320k',lossless:'flac',jyeffect:'hires',sky:'master',jymaster:'master'})[quality] || quality;
}

async function qing(song,context) {
  const key=process.env.QING_CLIENT_KEY;
  if(!key)throw new SourceError('QING_AUTH_UNCONFIGURED','服务器尚未配置 QingMusic 客户端认证');
  let level = song.quality;
  if (song.platform !== '163') {
    const levels = {
      '128k': 'standard',
      '320k': 'exhigh',
      flac: 'lossless',
      hires: song.platform === 'qq' ? 'lossless' : 'hires',
      master: song.platform === 'qq' ? 'jymaster' : 'clear',
    };
    level = levels[song.quality] || 'lossless';
  }
  const body={source:sourceCode[song.platform],rid:song.id,level};
  const stamp=String(Date.now()),nonce=crypto.randomBytes(16).toString('hex');
  const signature=['qingmusic-android',stamp,nonce,'POST','/v1/music/resolve-url',crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex')].join('\n');
  const headers={'X-Qing-App-Id':'qingmusic-android','X-Qing-App-Version':'1.4.1','X-Qing-App-Version-Code':'25','X-Qing-App-Package':'com.qingmusic.changqing',
    'X-Qing-Device-Id':context.device,'X-Qing-Ts':stamp,'X-Qing-Nonce':nonce,'X-Qing-Sign':crypto.createHmac('sha256',key).update(signature).digest('hex')};
  const reply=await fetchJson('https://musicserver.haitangw.cc/v1/music/resolve-url',{body,headers,signal:context.signal});
  if(reply.status<200 || reply.status>=300 || String(reply.data?.code)!=='0')throw new SourceError('QING_REJECTED','QingMusic 当前请求不可用');
  return resolved(reply.data,'qing_music');
}

async function hyw(song,context) {
  if(song.platform==='kugou')throw new SourceError('SOURCE_UNSUPPORTED','当前 HYW 公益版未开放酷狗');
  const key=context.credentials.hywCardKey || process.env.HYW_CARD_KEY || '';
  let quality=aggregateQuality(song.quality);
  if(['master','hires'].includes(quality))quality='flac24bit';
  const url=query('http://103.79.184.97/api/music/url',{source:sourceCode[song.platform],platform:sourceCode[song.platform],songId:song.id,songmid:song.id,
    quality,name:song.name,singer:song.artist,albumName:song.album,albumId:song.albumId,interval:song.duration,key});
  const reply=await fetchJson(url,{headers:{'User-Agent':'lx-music-request/1.0.0'},signal:context.signal});
  if(reply.status===401 || String(reply.data?.code)==='401')throw new SourceError('HYW_KEY_INVALID','HYW 卡密无效或已过期');
  if(reply.status!==200 || String(reply.data?.code)!=='200')throw new SourceError('HYW_REJECTED','HYW 当前线路不可用');
  return resolved(reply.data,'hyw');
}

async function token(license,context) {
  const cacheKey=crypto.createHash('sha256').update(license+context.device).digest('hex');
  const entry=tokens.get(cacheKey);
  if(entry && entry.until>Date.now())return entry.value;
  if(tokens.size>=16)tokens.delete(tokens.keys().next().value);
  // 不共享带有请求取消信号的 Promise，避免一个断开的客户端取消其他人的令牌获取。
  const reply=await fetchJson(query('https://yy1.zddyr.top/lx/api/token.php',{device_id:context.device}),{headers:{'X-Client':'XingHaiMusicSource/v3.2.20 (Android)'},signal:context.signal,timeout:3000});
  const value=reply.data?.data?.token || reply.data?.token;
  if(typeof value!=='string' || !/^xh3\.[\x21-\x7e]{1,4092}$/.test(value))throw new SourceError('TOKEN_INVALID','星海未返回有效令牌');
  tokens.set(cacheKey,{value,until:Date.now()+180000});
  return value;
}

async function xinghai(song,context) {
  const license=context.credentials.xinghaiLicenseKey || process.env.XINGHAI_LICENSE_KEY || '';
  if(song.platform==='qq' && !license)throw new SourceError('LICENSE_REQUIRED','星海 QQ 需要个人授权卡密');
  const url=query('https://yy1.zddyr.top/lx/api/',{source:song.platform==='qq'?'qq':sourceCode[song.platform],songmid:song.id,quality:aggregateQuality(song.quality),
    name:song.name,singer:song.artist,albumName:song.album,albumMid:song.albumId,interval:song.duration,
    ...(song.platform==='kugou'?{hash:song.id,mainHash:song.id,albumId:song.albumId}:{})});
  for(let attempt=0;attempt<2;attempt++) {
    const value=await token(license,context);
    const reply=await fetchJson(url,{headers:{'X-Client':'XingHaiMusicSource/v3.2.20 (Android)','X-Token':value,...(license?{'X-License':license}:{})},signal:context.signal});
    if(attempt===0 && [401,403].includes(Number(reply.data?.code || reply.status))) {
      tokens.delete(crypto.createHash('sha256').update(license+context.device).digest('hex'));
      continue;
    }
    if(reply.status!==200 || String(reply.data?.code)!=='200')throw new SourceError('XINGHAI_REJECTED','星海当前线路或授权不可用');
    return resolved(reply.data,'xinghai');
  }
  throw new SourceError('TOKEN_INVALID','星海令牌刷新失败');
}

function normalized(value) { return String(value || '').normalize('NFKC').toLowerCase().replace(/[\s\u200b-\u200d]/g,''); }
function sameArtists(actual,expected) {
  const found=String(actual || '').split(/\s*[/、,&]\s*/).map(normalized);
  const requested=String(expected || '').split(/\s*[/、,&]\s*/).map(normalized);
  return requested.length>0 && requested.every(name=>name && found.includes(name));
}
async function gd(song,context) {
  let id=song.id;
  if(song.platform!=='163') {
    if(!song.name || !song.artist)throw new SourceError('GD_MATCH_NOT_FOUND','缺少原曲元数据');
    const cacheKey=`${song.platform}:${song.id}`;
    id=context.matches.get(cacheKey);
    if(!id) {
      const reply=await fetchJson(query('https://music-api.gdstudio.xyz/api.php',{types:'search',source:'netease',name:`${song.name} ${song.artist}`,count:20,pages:1}),{signal:context.signal});
      const rows=Array.isArray(reply.data)?reply.data:[];
      const match=rows.slice(0,20).find(row=>{
        const artist=Array.isArray(row.artist)?row.artist.join(' / '):row.artist;
        const duration=Number(row.extra_data?.duration || row.duration || 0);
        const seconds=duration>10000?duration/1000:duration;
        return normalized(row.name)===normalized(song.name) && sameArtists(artist,song.artist) && (!seconds || !song.duration || Math.abs(seconds-song.duration)<=10);
      });
      if(!match)throw new SourceError('GD_MATCH_NOT_FOUND','网易云未找到原唱及版本相符的歌曲');
      id=String(match.id);context.matches.set(cacheKey,id);
    }
  }
  const quality=aggregateQuality(song.quality);
  const br=({'128k':128,'320k':320,flac:740,hires:999,master:999})[quality] || 320;
  for(const bitrate of br===999?[999,740]:[br]) {
    if(context.bitrates.has(bitrate))continue;
    context.bitrates.add(bitrate);
    const reply=await fetchJson(query('https://music-api.gdstudio.xyz/api.php',{types:'url',source:'netease',id,br:bitrate}),{signal:context.signal});
    if(reply.status!==200)throw new SourceError('GD_UNAVAILABLE','GDStudio 当前请求不可用');
    try { return resolved(reply.data,'gd_studio'); }
    catch(error) { if(bitrate!==999)throw error; }
  }
  throw new SourceError('GD_QUALITY_FAILED','GDStudio 本轮音质均不可用');
}

async function chksz(song,context) {
  const key=context.credentials.apiKey || process.env.CHKSZ_API_KEY || '';
  if(!key)throw new SourceError('API_KEY_REQUIRED','ChKSz 需要个人 API Key');
  const endpoint={'163':'163_music',qq:'qq_music',kugou:'kugou_music'}[song.platform];
  let params;
  if (song.platform === '163') params = {id:song.id,level:song.quality,type:'json'};
  else if (song.platform === 'qq') params = {mid:song.id,size:song.quality};
  else params = {id:song.id,size:song.quality};
  const reply=await fetchJson(query(`https://api.chksz.com/api/${endpoint}`,{...params,apikey:key}),{signal:context.signal});
  if(reply.status!==200 || String(reply.data?.code)!=='200')throw new SourceError('CHKSZ_REJECTED','ChKSz 授权或资源不可用');
  return resolved(reply.data,'chksz');
}

const handlers={qing_music:qing,xinghai,hyw,gd_studio:gd,chksz};

/** 音源适配和回退全部在服务器执行，原生框架只消费统一结果。 */
export async function resolvePlayback(song,{signal,credentials={}}={}) {
  if(!sourceCode[song.platform] || typeof song.id!=='string' || song.id.length>128 || !song.id)throw new SourceError('INVALID_SONG','歌曲参数无效');
  const excluded=new Set(Array.isArray(song.excludedSources)?song.excludedSources.slice(0,8):[]);
  const automatic=!song.source || song.source==='automatic';
  // 实测未读通的实验线路只用于手动验证，不能抢先返回一个无法播放的自动结果。
  const experimental = new Set(sources
    .filter(source => (source.experimentalPlatforms || []).includes(song.platform))
    .map(source => source.id));
  const main = ['qing_music','xinghai','hyw','chksz'].filter(source => !experimental.has(source));
  const groups=automatic?[main,['gd_studio']]:[[song.source]];
  const fallback=song.platform==='163'?['lossless','exhigh','standard']:['flac','320k','128k'];
  const qualities=[song.quality || (song.platform==='163'?'exhigh':'320k'),...(automatic?fallback:[])];
  const deadline=new AbortController();
  const cancel=()=>deadline.abort();
  const timer=setTimeout(cancel,19000);
  signal?.addEventListener('abort',cancel,{once:true});
  if(signal?.aborted)cancel();
  const context={signal:deadline.signal,credentials,matches:new Map(),bitrates:new Set(),
    device:'qt-'+crypto.createHash('sha256').update(credentials.xinghaiLicenseKey || 'kuzai-runtime').digest('hex').slice(0,32)};
  const attempted=new Set();const failures=[];
  try {
    for(const quality of [...new Set(qualities)].slice(0,4)) {
      for(const group of groups) {
        if(deadline.signal.aborted)throw new SourceError('RESOLVE_TIMEOUT','音源解析超时');
        const selected=group.filter(source=>!excluded.has(source) && handlers[source] && !attempted.has(`${source}:${effectiveQuality(source,song.platform,quality)}`));
        if(!selected.length)continue;
        const winner=await raceSources(selected,{...song,quality},context,{excluded,attempted,failures});
        if(winner)return winner;
      }
    }
    throw new SourceError('SOURCES_UNAVAILABLE',`当前音源均不可用：${failures.slice(-5).map(item=>item.source+'/'+item.code).join('，')}`);
  } finally {
    clearTimeout(timer);signal?.removeEventListener('abort',cancel);deadline.abort();
  }
}

function effectiveQuality(source,platform,quality) {
  if(source==='gd_studio')return ({'128k':128,'320k':320,flac:740,hires:999,master:999})[aggregateQuality(quality)] || 320;
  if(source==='hyw' && ['hires','master'].includes(aggregateQuality(quality)))return 'flac24bit';
  if(source==='qing_music' && platform==='qq' && quality==='hires')return 'lossless';
  return quality;
}

async function raceSources(group,song,context,state) {
  const race=new AbortController();
  const cancel=()=>race.abort();
  context.signal.addEventListener('abort',cancel,{once:true});
  if(context.signal.aborted)cancel();
  async function run(source) {
    state.attempted.add(`${source}:${effectiveQuality(source,song.platform,song.quality)}`);
    try { return await handlers[source](song,{...context,signal:race.signal}); }
    catch(error) {
      if(state.failures.length<32)state.failures.push({source,code:error.code || 'UPSTREAM_ERROR'});
      if(['API_KEY_REQUIRED','LICENSE_REQUIRED','SOURCE_UNSUPPORTED','HYW_KEY_INVALID','QING_AUTH_UNCONFIGURED','UPSTREAM_NETWORK'].includes(error.code))state.excluded.add(source);
      throw error;
    }
  }
  const tasks=group.map(source=>run(source));
  try { return await Promise.any(tasks); }
  catch { return null; }
  finally {
    race.abort();context.signal.removeEventListener('abort',cancel);
    await Promise.allSettled(tasks);
  }
}
