import {fetchJson,fetchText,query,resolved,SourceError} from './network.mjs';
import {clientCatalog} from './client_catalog.mjs';

const ne='https://interface.music.163.com';
const qq='https://u.y.qq.com/cgi-bin/musicu.fcg';
const kg='http://mobilecdn.kugou.com';
const legacy='http://161.118.252.183';
const qqHeaders={Referer:'https://y.qq.com/',Origin:'https://y.qq.com'};
const userAgent='Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const playlistIndexes=new Map();

function text(value,max=512) { return value==null?'':String(value).slice(0,max); }
function rows(value,max=100) { return Array.isArray(value)?value.slice(0,max):[]; }
function cover(value) {
  const url=text(value,2048).replace('{size}','500').replace(/^http:/,'https:');
  try { return ['https:','http:'].includes(new URL(url).protocol)?url:null; } catch { return null; }
}
function names(value,key='name') {
  if(!Array.isArray(value))return text(value);
  return value.slice(0,12).map(item=>text(item?.[key])).filter(Boolean).join(' / ');
}

/** 将三个上游目录结构转换为框架稳定消费的歌曲数据。SHIXIAOYANG，2026/11/19。 */
export function song(row,platform) {
  let id,name,artist,album,albumId,image,duration;
  if(platform==='163') {
    id=row.id;name=row.name;artist=names(row.ar || row.artists);
    const record=row.al || row.album || {};
    album=record.name || record;albumId=record.id;image=record.picUrl;duration=Number(row.dt || row.duration || 0)/1000;
  } else if(platform==='qq') {
    id=row.mid || row.songmid || row.id;name=row.name || row.title || row.songname;artist=names(row.singer);
    const record=row.album || {};
    album=record.name || record.title || row.albumname;albumId=record.mid || record.pmid || row.albummid;
    image=albumId?`https://y.gtimg.cn/music/photo_new/T002R300x300M000${encodeURIComponent(albumId)}.jpg`:null;
    duration=Number(row.interval || 0);
  } else {
    const filename=text(row.filename);const separator=filename.indexOf(' - ');
    id=row.hash;name=row.songname || (separator>=0?filename.slice(separator+3):filename);
    artist=row.singername || (separator>=0?filename.slice(0,separator):names(row.authors,'author_name'));
    album=row.album_name;albumId=row.album_id || row.albumid || row.AlbumID;
    image=row.album_sizable_cover || row.sizable_cover || row.imgurl || row.trans_param?.union_cover;
    duration=Number(row.duration || (Number(row.timelength || 0)/1000));
  }
  return {platform,id:text(id,128),name:text(name) || '未知歌曲',artist:text(artist) || '未知歌手',
    album:text(album),albumId:albumId==null?null:text(albumId,128),coverUrl:cover(image),
    duration:Number.isFinite(duration)?Math.max(0,Math.round(duration)):null};
}

function playlist(row,platform) {
  return {platform,id:text(row.id || row.content_id || row.dissid || row.specialid || row.tid,128),
    name:text(row.name || row.title || row.dissname || row.specialname) || '歌单',
    coverUrl:cover(row.coverImgUrl || row.cover || row.picurl || row.imgurl || row.cover_url_big),
    creator:text(row.creator?.nickname || row.creator?.name || row.username || row.nickname || row.nick || row.host_nick),
    trackCount:Number(row.trackCount || row.songnum || row.songcount || row.song_count || 0),description:text(row.description || row.desc,4096)};
}

async function json(url,signal,options={}) {
  const reply=await fetchJson(url,{...options,signal,timeout:5000,headers:{'User-Agent':userAgent,...options.headers}});
  if(reply.status!==200)throw new SourceError('CATALOG_UNAVAILABLE','平台目录暂不可用');
  if(reply.data && !Array.isArray(reply.data) && reply.data.code!==undefined && ![0,200,'0','200'].includes(reply.data.code))throw new SourceError('CATALOG_REJECTED','平台目录拒绝请求');
  return reply.data;
}

async function catalog(base,path,params,fallbackPath,signal,fallbackParams=params) {
  try { return await json(query(base+path,params),signal); }
  catch(error) {
    if(signal?.aborted)throw error;
    let prefix = 'api-qq';
    if (base.includes('.music.163.com')) prefix = 'api-netease';
    else if (base === kg) prefix = 'api-kugou-search';
    return json(query(`${legacy}/${prefix}${fallbackPath}`,fallbackParams),signal);
  }
}

async function musicu(key,module,method,param,signal) {
  const result=await json(qq,signal,{headers:qqHeaders,body:{comm:{ct:24,cv:0},[key]:{module,method,param}}});
  const reply=result?.[key];
  if(reply?.code!==0 || !reply.data)throw new SourceError('QQ_CATALOG_FAILED','QQ 目录返回错误');
  return reply.data;
}

function qqData(body,key) {
  const reply=body?.[key];
  if(reply?.code!==0 || !reply.data)throw new SourceError('QQ_CATALOG_FAILED','当前设备网络的 QQ 目录不可用，状态 '+String(reply?.code ?? 'missing'));
  return reply.data;
}

async function qqCatalog(key,module,method,param,signal,transform,fallback) {
  try {
    const result=await transform(await musicu(key,module,method,param,signal),signal);
    if((Array.isArray(result.songs) && !result.songs.length) || (Array.isArray(result.playlists) && !result.playlists.length)) {
      throw new SourceError('QQ_EMPTY_CATALOG','服务器出口返回空目录');
    }
    return result;
  }
  catch(error) {
    if(signal?.aborted)throw error;
    async function complete(body,newSignal) {
      try {
        return await transform(qqData(body,key),newSignal);
      } catch (failure) {
        if (newSignal?.aborted || !fallback) throw failure;
        return fallback(newSignal);
      }
    }
    const body={[key]:{module,method,param}};
    if(key!=='req_1')body.comm={ct:24,cv:0};
    return clientCatalog({url:qq,headers:{...qqHeaders,'User-Agent':userAgent},body},complete);
  }
}

async function neteaseSearchData(data,{kind,limit},signal) {
  if(typeof data.result!=='object')throw new SourceError('NETEASE_REGION_RESTRICTED','当前设备网络的网易云目录不可用');
  if(kind==='playlists')return {playlists:rows(data.result?.playlists,limit).map(row=>playlist(row,'163'))};
  let list=rows(data.result?.songs,limit);
  try {
    const details=await detail(list.map(row=>String(row.id)),signal);
    const index=new Map(details.map(row=>[String(row.id),row]));
    list=list.map(row=>index.get(String(row.id)) || row);
  } catch(error) {if(signal?.aborted)throw error;}
  return {songs:list.map(row=>song(row,'163')),total:Number(data.result?.songCount || 0)};
}

async function detail(ids,signal) {
  const safe=ids.slice(0,100);
  if(!safe.length)return [];
  const data=await catalog(ne,'/api/song/detail',{ids:JSON.stringify(safe),c:JSON.stringify(safe.map(id=>({id:Number(id)})))},
    '/song/detail',signal,{ids:safe.join(',')});
  return rows(data.songs);
}

/** 搜索支持分页，目录协议可在服务器单独修复。 */
export async function search({platform,keyword,page=1,limit=20,kind='songs'},signal) {
  if(platform==='163') {
    const data=await catalog(ne,'/api/search/get/web',{s:keyword,type:kind==='playlists'?1000:1,limit,offset:(page-1)*limit,total:true},
      '/search',signal,{keywords:keyword,type:kind==='playlists'?1000:1,limit,offset:(page-1)*limit});
    if(typeof data.result==='string') {
      function complete(body,newSignal) {return neteaseSearchData(body,{kind,limit},newSignal);}
      return clientCatalog({url:query(ne+'/api/search/get/web',{s:keyword,type:kind==='playlists'?1000:1,limit,offset:(page-1)*limit,total:true}),headers:{'User-Agent':userAgent}},complete);
    }
    return neteaseSearchData(data,{kind,limit},signal);
  }
  if(platform==='qq') {
    function normalise(data) {
      const list=rows(kind==='playlists'?data.body?.songlist?.list:data.body?.song?.list,limit);
      return kind==='playlists'?{playlists:list.map(row=>playlist(row,platform))}:{songs:list.map(row=>song(row,platform))};
    }
    async function compatibility(newSignal) {
      // 现有兼容协议只确认了首屏；后续页失败时明确重试，不能重复首屏充当分页。
      if (page !== 1) throw new SourceError('QQ_CATALOG_FAILED','QQ 当前搜索页暂不可用，请重试');
      const result = await json(query(legacy+'/api-qq/search',
        {key:keyword,t:kind==='playlists'?2:0}),newSignal);
      const list = rows(result.data?.list,limit);
      if (kind === 'playlists') return {playlists:list.map(row=>playlist(row,platform))};
      return {songs:list.map(row=>song(row,platform))};
    }
    return qqCatalog('req_1','music.search.SearchCgiService','DoSearchForQQMusicDesktop',
      {num_per_page:limit,page_num:page,query:keyword,search_type:kind==='playlists'?3:0},signal,normalise,compatibility);
  }
  const endpoint=kind==='playlists'?'/api/v3/search/special':'/api/v3/search/song';
  const data=await catalog(kg,endpoint,{keyword,page,pagesize:limit},endpoint,signal);
  const list=rows(data.data?.info,limit);
  return kind==='playlists'?{playlists:list.map(row=>playlist(row,platform))}:{songs:list.map(row=>song(row,platform)),total:Number(data.data?.total || 0)};
}

/** 获取发现页歌单或榜单，单次最多 100 条。 */
export async function discover({platform,limit=20},signal) {
  if(platform==='163') {
    const data=await catalog(ne,'/api/playlist/list',{cat:'全部',limit,offset:0,order:'hot'},'/top/playlist',signal,{limit,order:'hot'});
    return {playlists:rows(data.playlists,limit).map(row=>playlist(row,platform))};
  }
  if(platform==='qq') {
    function normalise(data) {return {playlists:rows(data.v_hot,limit).map(row=>playlist(row,platform))};}
    async function compatibility(newSignal) {
      const result = await json(legacy+'/api-qq/recommend/playlist',newSignal);
      return {playlists:rows(result.data?.list,limit).map(row=>playlist(row,platform))};
    }
    return qqCatalog('req_0','playlist.HotRecommendServer','get_hot_recommend',{async:1,cmd:2},
      signal,normalise,compatibility);
  }
  const data=await catalog(kg,'/api/v3/rank/song',{rankid:'74534',page:1,pagesize:limit},'/api/v3/rank/song',signal);
  return {songs:rows(data.data?.info,limit).map(row=>song(row,platform))};
}

/** 打开歌单并按页返回曲目，避免把整个大歌单发给手机。 */
export async function playlistPage({platform,id,limit=20,page=1},signal) {
  const offset=(page-1)*limit;
  if(platform==='163') {
    let entry=playlistIndexes.get(id);
    if(!entry || entry.until<Date.now()) {
      const data=await catalog(ne,'/api/v6/playlist/detail',{id,n:0,s:0},'/playlist/detail',signal,{id});
      const record=data.playlist || data.data;
      if(!record?.id)throw new SourceError('PLAYLIST_NOT_FOUND','歌单不存在或不可访问');
      const ids=rows(record.trackIds,100000).map(item=>String(item.id));
      const tracks=rows(record.tracks,100000);
      entry={until:Date.now()+180000,ids:ids.length?ids:tracks.map(item=>String(item.id)),playlist:playlist(record,platform)};
      // 大型索引只保留最近一个，单个索引也限制为 100,000 首。
      playlistIndexes.clear();playlistIndexes.set(id,entry);
    }
    const tracks=await detail(entry.ids.slice(offset,offset+limit),signal);
    return {playlist:entry.playlist,songs:tracks.map(row=>song(row,platform)),total:entry.ids.length};
  }
  if(platform==='qq') {
    function normalise(data) {
      const record = data.dirinfo;
      if (!record?.title) throw new SourceError('PLAYLIST_NOT_FOUND', 'QQ 歌单不存在或不可访问');
      return {
        playlist: playlist({...record, id}, platform),
        songs: rows(data.songlist, limit).map(row => song(row, platform)),
        total: Number(record.songnum || 0),
      };
    }
    async function compatibility(newSignal) {
      // 部分歌单在设备出口也被 QQ 拒绝，复用已有兼容接口并在映射前截取当前页。
      const reply = await json(query(legacy+'/api-qq/songlist',
        {id,song_begin:offset,song_num:limit}),newSignal);
      const data = reply.data || reply;
      if (!data.dissname) throw new SourceError('PLAYLIST_NOT_FOUND','QQ 歌单不存在或不可访问');
      const tracks = rows(data.songlist,100000);
      const page = tracks.length > limit ? tracks.slice(offset,offset+limit) : tracks;
      return {
        playlist:playlist({...data,id},platform),
        songs:page.map(row=>song(row,platform)),
        total:Number(data.songnum || data.total_song_num || tracks.length),
      };
    }
    return qqCatalog('req_0', 'music.srfDissInfo.aiDissInfo', 'uniform_get_Dissinfo',
      {disstid:Number(id),enc_host_uin:'',tag:1,userinfo:1,song_begin:offset,song_num:limit,onlysonglist:0},
      signal, normalise, compatibility);
  }
  const data=await catalog(kg,'/api/v3/special/song',{specialid:id,page,pagesize:limit},'/api/v3/special/song',signal);
  return {playlist:{platform,id,name:'酷狗歌单'},songs:rows(data.data?.info,limit).map(row=>song(row,platform)),total:Number(data.data?.total || 0)};
}

function lyric(value) {
  const content=value && typeof value==='object'?value.lyric:value;
  return typeof content==='string'?content.slice(0,256*1024):null;
}
function qqLyric(value) {
  let content=lyric(value);
  if(!content)return null;
  if(!content.includes('[') && /^[A-Za-z0-9+/=\r\n]+$/.test(content))content=Buffer.from(content,'base64').toString('utf8');
  const xml=/LyricContent="([\s\S]*?)"/.exec(content);
  return (xml?xml[1]:content).replaceAll('&amp;','&').replaceAll('&quot;','"').replaceAll('&apos;',"'").replaceAll('&#10;','\n');
}

/** 歌词返回统一原文/译文/逐字字段，歌词协议不进入原生框架。 */
export async function lyrics({platform,id},signal) {
  if(platform==='163') {
    const data=await catalog('https://interface3.music.163.com','/api/song/lyric',
      {id,cp:false,lv:-1,tv:-1,rv:-1,kv:-1,yv:-1,ytv:-1,yrv:-1},'/lyric',signal,{id});
    const body=data.data || data;
    return {lyrics:{original:lyric(body.lrc),translated:lyric(body.tlyric),romaji:lyric(body.romalrc),wordSynced:lyric(body.yrc) || lyric(body.klyric)}};
  }
  if(platform==='qq') {
    let data;
    try { data=await json(query('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
      {songmid:id,format:'json',nobase64:1,g_tk:5381,loginUin:0,hostUin:0,inCharset:'utf8',outCharset:'utf-8',notice:0,platform:'yqq.json',needNewCode:0,qrc:1}),signal,{headers:qqHeaders}); }
    catch(error) {
      if(signal?.aborted)throw error;
      data=await json(query(`${legacy}/api-qq/lyric`,{songmid:id}),signal);
    }
    const body=data.data || data;
    return {lyrics:{original:qqLyric(body.lyric),translated:qqLyric(body.trans),wordSynced:qqLyric(body.qrc || body.lyric_qrc)}};
  }
  const response=await fetchText(query('https://m.kugou.com/app/i/krc.php',{cmd:100,hash:id,timelength:1}),{signal});
  if(response.status!==200)throw new SourceError('LYRIC_UNAVAILABLE','酷狗歌词暂不可用');
  const index=response.text.indexOf('[');
  return {lyrics:{original:index>=0?response.text.slice(index,index+256*1024):null}};
}

/** 查询 MV 地址，返回后仍由设备原生视频能力播放。 */
export async function mv({platform,id,name,artist},signal) {
  let url;
  if(platform==='163') {
    const tracks=await detail([id],signal);const mvId=tracks[0]?.mv || tracks[0]?.mvid;
    if(!mvId)throw new SourceError('MV_NOT_FOUND','该歌曲没有 MV');
    const data=await catalog(ne,'/api/song/enhance/play/mv/url',{id:mvId,r:1080},'/mv/url',signal);
    url=data.data?.url;
  } else if(platform==='qq') {
    async function findVideo(data, newSignal) {
      const track = rows(data.body?.song?.list).find(item => String(item.mid || item.songmid) === id);
      const vid = track?.mv?.vid || track?.vid;
      if (!vid) throw new SourceError('MV_NOT_FOUND', '未找到当前歌曲的 MV');
      function videoUrl(result) {
        const formats = rows(result[vid]?.mp4).reverse();
        const chosen = formats.find(item => item.freeflow_url?.length || item.comm_url?.length);
        const address = chosen?.freeflow_url?.[0] || chosen?.comm_url?.[0];
        return {url: resolved({url: address}, 'mv').url};
      }
      return qqCatalog('getMvUrl', 'gosrf.Stream.MvUrlProxy', 'GetMvUrls',
        {vids:[vid],request_type:10001,addrtype:3,format:264}, newSignal, videoUrl);
    }
    return qqCatalog('req_1', 'music.search.SearchCgiService', 'DoSearchForQQMusicDesktop',
      {num_per_page:30,page_num:1,query:`${name} ${artist}`,search_type:0}, signal, findVideo);
  } else {
    const data=await catalog(kg,'/api/v3/search/song',{keyword:`${name} ${artist}`,page:1,pagesize:30},'/api/v3/search/song',signal);
    const track=rows(data.data?.info).find(item=>String(item.hash).toLowerCase()===id.toLowerCase());
    const hash=track?.mvhash || track?.MvHash;
    if(!hash)throw new SourceError('MV_NOT_FOUND','未找到当前歌曲的 MV');
    const requestUrl = query('https://m.kugou.com/app/i/mv.php',{cmd:100,hash,ismp3:1,ext:'mp4'});
    function videoUrl(result) {
      for (const quality of ['sq','hd','sd','le','rq']) {
        const format = result.mvdata?.[quality];
        const candidates = [format?.downurl, ...rows(format?.backupdownurl,8)];
        const address = candidates.find(value => typeof value === 'string' && value.trim());
        if (address) return {url:resolved({url:address.trim()},'mv').url};
      }
      throw new SourceError('MV_UNAVAILABLE','酷狗当前网络未返回可播放的 MV');
    }
    try {
      return videoUrl(await json(requestUrl,signal));
    } catch (error) {
      if (signal?.aborted) throw error;
      return clientCatalog({url:requestUrl,headers:{'User-Agent':userAgent}},videoUrl);
    }
  }
  return {url:resolved({url},'mv').url};
}
