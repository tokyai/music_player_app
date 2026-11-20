/* 所有上游文字通过 textContent 展示，业务包不拼接不可信 HTML。SHIXIAOYANG，2026/11/19。 */
const App={token:null,settings:{},state:{},config:null,route:'home',platform:'qq',page:1,keyword:'',kind:'songs',
  songs:[],playlist:null,history:[],requestId:0,pending:new Map(),generation:0,modalOpen:false,toastTimer:null,
  defaultConfig:{platforms:[{id:'qq',name:'QQ音乐'},{id:'163',name:'网易云'},{id:'kugou',name:'酷狗'}],
    sources:[{id:'qing_music',name:'QingMusic',platforms:['qq','163','kugou']},{id:'xinghai',name:'星海',platforms:['163','kugou'],authorizedPlatforms:['qq']},
      {id:'hyw',name:'HYW 公益版',platforms:['163'],experimentalPlatforms:['qq']},{id:'gd_studio',name:'GDStudio 网易云匹配',platforms:['qq','163','kugou']},
      {id:'chksz',name:'ChKSz',platforms:[],authorizedPlatforms:['qq','163','kugou']}],
    qualities:{'163':[{id:'exhigh',name:'极高'},{id:'lossless',name:'无损'},{id:'hires',name:'Hi-Res'},{id:'jymaster',name:'高清母带'}],
      qq:[{id:'128k',name:'128k'},{id:'320k',name:'320k'},{id:'flac',name:'无损'},{id:'hires',name:'Hi-Res'},{id:'master',name:'母带'}],
      kugou:[{id:'128k',name:'128k'},{id:'320k',name:'320k'},{id:'flac',name:'无损'},{id:'hires',name:'Hi-Res'},{id:'master',name:'母带'}]}}};

/** 创建界面元素；外部文字和链接不会被当作脚本执行。 */
App.el=function(tag,options={},children=[]) {
  const node=document.createElement(tag);
  for(const [key,value] of Object.entries(options)) {
    if(value===undefined || value===null)continue;
    if(key==='text')node.textContent=String(value);
    else if(key==='onClick')node.addEventListener('click',value);
    else if(key==='className')node.className=value;
    else if(key==='checked')node.checked=value;
    else if(key==='value')node.value=value;
    else node.setAttribute(key,String(value));
  }
  for(const child of children)if(child)node.append(child);
  return node;
};

/** 向受限原生能力发送带加载令牌的请求，最多同时保留 8 个。 */
App.native=function(operation,data={}) {
  if(!App.token || !window.KuzaiNative)return Promise.reject(new Error('原生框架尚未连接'));
  if(App.pending.size>=8)return Promise.reject(new Error('操作正在执行，请稍候'));
  const id='m'+(++App.requestId);
  const request=JSON.stringify({id,token:App.token,operation,data});
  if(request.length>256*1024)return Promise.reject(new Error('操作数据过大'));
  return new Promise(function(resolve,reject) {
    const timer=setTimeout(function(){App.pending.delete(id);reject(new Error('操作超时，请重试'));},operation==='video'?300000:45000);
    App.pending.set(id,{resolve,reject,timer});
    try {window.KuzaiNative.postMessage(request);}
    catch(error){App.pending.delete(id);clearTimeout(timer);reject(error);}
  });
};
App.api=function(operation,data) {return App.native('api',{operation,data});};
App.toast=function(message) {
  const node=document.getElementById('toast');
  node.textContent=String(message || '操作完成').slice(0,300);node.hidden=false;
  clearTimeout(App.toastTimer);App.toastTimer=setTimeout(function(){node.hidden=true;},4000);
};
App.perform=async function(operation,data,onDone) {
  try {const result=await App.native(operation,data);if(onDone)onDone(result);return result;}
  catch(error){App.toast(error.message);return null;}
};
App.title=function(title,subtitle='') {document.getElementById('page-title').textContent=title;document.getElementById('page-subtitle').textContent=subtitle;};
App.content=function(...nodes) {document.getElementById('content').replaceChildren(...nodes);};
App.loading=function() {App.content(App.el('div',{className:'loading',text:'正在加载…'}));};
App.empty=function(title,message,button) {return App.el('div',{className:'empty'},[App.el('h3',{text:title}),App.el('p',{text:message}),button]);};
App.error=function(error,retry) {
  App.content(App.el('section',{className:'error-card'},[App.el('h3',{text:'暂时没有加载成功'}),App.el('p',{text:error.message || '网络不可用'}),
    App.el('button',{text:'重新加载',onClick:retry}),App.el('button',{text:'打开本地音乐库',className:'secondary',onClick:App.goLibrary})]));
};
App.goLibrary=function(){App.go('library');};
App.formatTime=function(milliseconds) {const seconds=Math.max(0,Math.floor(Number(milliseconds || 0)/1000));return Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');};
App.formatBytes=function(bytes){return (Number(bytes || 0)/1024/1024).toFixed(1)+' MB';};
App.art=function(url,className='song-art') {
  const holder=App.el('span',{className,text:'♫'});
  if(typeof url!=='string' || url.length>2048)return holder;
  try {if(new URL(url).protocol!=='https:')return holder;}catch{return holder;}
  const image=App.el('img',{src:url,alt:'',loading:'lazy',referrerpolicy:'no-referrer'});
  image.addEventListener('error',function(){image.remove();holder.textContent='♫';},{once:true});
  holder.replaceChildren(image);return holder;
};

App.modal=function(title,...content) {
  App.previousFocus=document.activeElement;App.modalOpen=true;
  document.getElementById('modal-title').textContent=title;
  document.getElementById('modal-content').replaceChildren(...content);
  document.getElementById('modal').hidden=false;document.getElementById('modal-close').focus();
};
App.closeModal=function() {
  document.getElementById('modal').hidden=true;App.modalOpen=false;
  if(App.restorePending){App.restorePending=false;App.perform('backup',{action:'cancel'});}
  if(App.previousFocus && App.previousFocus.isConnected)App.previousFocus.focus();
};
App.confirm=function(title,message,action) {
  const confirm=App.el('button',{text:'确认',className:'primary'});
  confirm.addEventListener('click',async function(){confirm.disabled=true;try{await action();App.closeModal();}catch(error){App.toast(error.message);confirm.disabled=false;}});
  App.modal(title,App.el('p',{text:message}),App.el('div',{className:'actions'},[App.el('button',{text:'取消',onClick:App.closeModal}),confirm]));
};
App.field=function(label,input) {return App.el('div',{className:'field'},[App.el('label',{text:label,for:input.id}),input]);};
App.input=function(id,value='',type='text') {return App.el('input',{id,type,value,autocomplete:'off'});};
App.select=function(id,choices,value) {
  const select=App.el('select',{id});
  for(const item of choices)select.append(App.el('option',{value:item.id,text:item.name}));
  if(value!==undefined)select.value=value;return select;
};
App.panel=function(title,message,...children) {return App.el('section',{className:'panel'},[App.el('h3',{text:title}),App.el('p',{text:message}),...children]);};
App.platformTabs=function(onSelect,includeBilibili=false) {
  const items=[...(App.config || App.defaultConfig).platforms];
  if(includeBilibili)items.push({id:'bilibili',name:'B站'});
  const container=App.el('div',{className:'platform-tabs'});
  for(const item of items) {
    const button=App.el('button',{text:item.name,className:App.platform===item.id?'active':''});
    button.addEventListener('click',function(){App.platform=item.id;App.page=1;onSelect();});container.append(button);
  }
  return container;
};
App.pagination=function(page,hasMore,onPage) {
  const previous=App.el('button',{text:'上一页'});previous.disabled=page<=1;
  previous.addEventListener('click',function(){onPage(page-1);});
  const next=App.el('button',{text:'下一页'});next.disabled=!hasMore;
  next.addEventListener('click',function(){onPage(page+1);});
  return App.el('div',{className:'pagination'},[previous,App.el('span',{text:'第 '+page+' 页',className:'muted'}),next]);
};

App.songList=function(songs,{queue=false,offset=0}={}) {
  App.songs=songs.slice(0,200);
  if(!songs.length)return App.empty('这里暂时没有歌曲','可以搜索音乐，或导入你喜欢的歌单。');
  const list=App.el('div',{className:'song-list'});
  for(let index=0;index<App.songs.length;index++)list.append(App.songRow(App.songs[index],index,{queue,offset}));
  return list;
};
App.songRow=function(song,index,{queue,offset}) {
  const main=App.el('button',{className:'song-main','aria-label':'播放 '+song.name},[App.art(song.coverUrl),
    App.el('span',{className:'song-meta'},[App.el('strong',{text:song.name}),App.el('small',{text:[song.artist,song.album].filter(Boolean).join(' · ')})])]);
  main.addEventListener('click',function(){App.playSong(song,index,queue?index+offset:null);});
  const favorite=App.el('button',{text:'♡','aria-label':'收藏 '+song.name});
  favorite.addEventListener('click',async function(){const result=await App.perform('favorite',{song});if(result){favorite.textContent=result.favorite?'♥':'♡';favorite.classList.toggle('is-favorite',result.favorite);}});
  const add=App.el('button',{text:queue?'×':'+','aria-label':queue?'移出队列':'加入队列'});
  add.addEventListener('click',function(){App.rowQueueAction(song,queue,index+offset);});
  const more=App.el('button',{text:'⋯','aria-label':'更多歌曲操作'});
  more.addEventListener('click',function(){App.songMenu(song);});
  return App.el('div',{className:'song-row'},[main,App.el('div',{className:'row-actions'},[favorite,add,more])]);
};
App.rowQueueAction=async function(song,queue,index) {
  const result=await App.perform('control',queue?{action:'queue_remove',index}:{action:'queue_add',song});
  if(result){App.toast(queue?'已移出队列':'已加入队列');if(queue)App.renderQueue();}
};
App.playSong=async function(song,index,queueIndex) {
  const result=await App.perform(queueIndex===null?'play':'control',queueIndex===null?{song}:{action:'queue_play',index:queueIndex});
  if(result)App.updatePlayer(App.state);
};
App.songMenu=function(song) {
  App.modal(song.name,App.el('p',{text:song.artist,className:'muted'}),App.el('div',{className:'actions'},[
    App.el('button',{text:'播放',className:'primary',onClick:async function(){await App.perform('play',{song});App.closeModal();}}),
    App.el('button',{text:'下载',onClick:async function(){const quality=(App.settings.qualities || {})[song.platform] || (song.platform==='163'?'lossless':'flac');
      const result=await App.perform('library',{action:'download_add',song,quality});if(result){App.toast('已加入下载任务');App.closeModal();}}}),
    App.el('button',{text:'查看 MV',onClick:function(){App.playMv(song);}}),
    App.el('button',{text:'查找歌词',onClick:function(){App.findLyrics(song);}}),
  ]));
};

// iOS 13 的 DOM 缺少 replaceChildren，保持同一业务包在最低支持版本上可运行。
function replaceRuntimeChildren(...children) {
  while(this.firstChild)this.removeChild(this.firstChild);
  for(const child of children)this.append(child);
}
if(!Element.prototype.replaceChildren)Element.prototype.replaceChildren=replaceRuntimeChildren;
if(!DocumentFragment.prototype.replaceChildren)DocumentFragment.prototype.replaceChildren=replaceRuntimeChildren;

App.restoreDraft=function() {
  for(const [id,value] of Object.entries(App.formDraft || {})) {
    const input=document.getElementById(id);if(!input)continue;
    if(input.type==='checkbox')input.checked=value===true;
    else if(input.tagName!=='SELECT' || [...input.options].some(option=>option.value===value))input.value=String(value);
    delete App.formDraft[id];
  }
};
