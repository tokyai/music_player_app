/* 页面与原生播放会话分开；更换业务包后从会话状态恢复。SHIXIAOYANG，2026/11/19。 */
App.lyricLines=[];App.lyricKey='';App.lyricFetching=false;App.lyricWindow=0;App.lastLyricIndex=-1;

App.updatePlayer=function(state) {
  const previousKey=App.state.song?App.state.song.platform+':'+App.state.song.id:'';
  const key=state.song?state.song.platform+':'+state.song.id:'';
  const lyricsCompleted=App.state.lyricsLoading && !state.lyricsLoading;
  App.state=state;
  const song=state.song;
  document.getElementById('mini-title').textContent=(song || {}).name || '选择一首喜欢的歌';
  document.getElementById('mini-artist').textContent=(song || {}).artist || '支持 QQ、网易云和酷狗';
  const cover=document.getElementById('mini-cover');
  if(cover.dataset.url!==((song || {}).coverUrl || '')) {
    const art=App.art((song || {}).coverUrl,'cover-placeholder');cover.replaceChildren(...art.childNodes);cover.dataset.url=(song || {}).coverUrl || '';
  }
  let playLabel='▶';
  if(state.loading)playLabel='…';
  else if(state.playing)playLabel='Ⅱ';
  document.getElementById('play-pause').textContent=playLabel;
  document.getElementById('play-pause').setAttribute('aria-label',state.playing?'暂停':'播放');
  document.getElementById('mini-favorite').textContent=state.favorite?'♥':'♡';
  document.getElementById('mini-favorite').style.color=state.favorite?'var(--accent)':'';
  document.getElementById('position').textContent=App.formatTime(state.position);
  document.getElementById('duration').textContent=App.formatTime(state.duration);
  const seek=document.getElementById('seek');seek.max=String(state.duration || 1);
  if(document.activeElement!==seek)seek.value=String(state.position || 0);
  if(key!==previousKey) {App.lyricLines=[];App.lyricKey='';App.lastLyricIndex=-1;}
  if(App.route==='player') {
    if(key!==previousKey)App.renderPlayer();
    else {
      const progress=document.getElementById('player-seek');
      if(progress && document.activeElement!==progress){progress.max=String(state.duration || 1);progress.value=String(state.position || 0);}
      const time=document.getElementById('player-time');if(time)time.textContent=App.formatTime(state.position)+' / '+App.formatTime(state.duration);
      const source=document.getElementById('player-source');if(source)source.textContent=App.sourceName(state.source)+(state.loading?' · 正在解析':'');
      if(lyricsCompleted || App.lyricKey!==key)App.loadLyrics();
      App.updateLyricHighlight();
    }
  }
  if(state.error && state.error!==App.lastPlayerError){App.lastPlayerError=state.error;App.toast(state.error);}
};
App.sourceName=function(id){const source=(App.config || App.defaultConfig).sources.find(item=>item.id===id);return source?source.name:id || '自动备用';};
App.renderPlayer=function() {
  App.title('正在播放','收藏、队列与播放会话会自动保存');
  const song=App.state.song;
  if(!song){App.content(App.empty('还没有播放音乐','搜索歌曲或打开收藏开始播放。',App.el('button',{text:'搜索音乐',className:'primary',onClick:App.goSearch})));return;}
  const seek=App.input('player-seek',String(App.state.position || 0),'range');seek.min='0';seek.max=String(App.state.duration || 1);seek.setAttribute('aria-label','播放进度');
  seek.addEventListener('change',function(){App.perform('control',{action:'seek',position:Number(seek.value)});});
  const info=App.el('section',{className:'player-info'},[App.art(song.coverUrl,'player-art'),App.el('h2',{text:song.name}),App.el('p',{text:song.artist}),
    App.el('small',{id:'player-source',text:App.sourceName(App.state.source)}),seek,App.el('small',{id:'player-time',text:App.formatTime(App.state.position)+' / '+App.formatTime(App.state.duration)}),
    App.el('div',{className:'actions'},[App.el('button',{text:'播放模式',onClick:App.changeMode}),App.el('button',{text:'MV',onClick:App.currentMv}),
      App.el('button',{text:'歌词版本',onClick:App.currentLyrics}),App.el('button',{text:'定时关闭',onClick:App.sleepDialog})])]);
  const lyrics=App.el('section',{className:'lyrics',id:'lyrics','aria-label':'同步歌词'},[App.el('p',{text:'正在同步歌词…',className:'muted'})]);
  lyrics.addEventListener('pointerdown',function(){App.lyricManualUntil=Date.now()+5000;});
  App.content(App.el('div',{className:'player-view'},[info,lyrics]));App.loadLyrics();
};
App.goSearch=function(){App.go('search');};
App.changeMode=async function(){const result=await App.perform('control',{action:'mode'});if(result)App.toast({sequence:'顺序播放',repeat:'单曲循环',shuffle:'随机播放'}[result.mode]);};
App.currentMv=function(){if(App.state.song)App.playMv(App.state.song);};
App.currentLyrics=function(){if(App.state.song)App.findLyrics(App.state.song);};
App.loadLyrics=async function() {
  if(App.lyricFetching || App.route!=='player')return;
  App.lyricFetching=true;const key=App.state.song?App.state.song.platform+':'+App.state.song.id:'';
  try {
    const data=await App.native('lyrics');
    if(App.route!=='player' || key!==(App.state.song?App.state.song.platform+':'+App.state.song.id:''))return;
    App.lyricKey=key;App.lyricLines=(data.lines || []).slice(0,2000);App.lyricWindow=Math.max(0,(App.state.lyricIndex || 0)-40);
    App.renderLyrics();
  } catch(error){const lyrics=document.getElementById('lyrics');if(App.route==='player' && lyrics)lyrics.replaceChildren(App.el('p',{text:error.message,className:'muted'}));}
  finally{App.lyricFetching=false;}
};
App.renderLyrics=function() {
  const container=document.getElementById('lyrics');if(!container)return;
  if(!App.lyricLines.length){container.replaceChildren(App.el('p',{text:App.state.lyricsLoading?'正在加载歌词…':'这首歌暂时没有可用歌词',className:'muted'}));return;}
  const fragment=document.createDocumentFragment();
  // 只构建当前位置附近的 120 行，歌词异常长时也不会创建无上限的 DOM。
  for(let index=App.lyricWindow;index<Math.min(App.lyricLines.length,App.lyricWindow+120);index++)fragment.append(App.lyricRow(App.lyricLines[index],index));
  container.replaceChildren(fragment);App.lastLyricIndex=-1;App.updateLyricHighlight();
};
App.lyricRow=function(line,index) {
  const button=App.el('button',{className:'lyric-line','data-line':index});
  if(line.words && line.words.length) {
    for(const word of line.words)button.append(App.el('span',{className:'lyric-word',text:word.text,'data-time':word.time}));
  } else button.append(App.el('span',{text:line.text}));
  if(line.translated)button.append(App.el('small',{text:line.translated}));
  button.addEventListener('click',function(){App.perform('control',{action:'seek',position:Math.max(0,line.time)});});return button;
};
App.updateLyricHighlight=function() {
  if(App.route!=='player' || !App.lyricLines.length)return;
  const index=Math.max(0,App.state.lyricIndex || 0);
  if(index<App.lyricWindow || index>=App.lyricWindow+120){App.lyricWindow=Math.max(0,index-40);App.renderLyrics();return;}
  const node=document.querySelector('[data-line="'+index+'"]');
  if(index!==App.lastLyricIndex) {
    const previous=document.querySelector('.lyric-line.active');if(previous)previous.classList.remove('active');if(node)node.classList.add('active');
    if(node && Date.now()>(App.lyricManualUntil || 0))node.scrollIntoView({block:'center',behavior:'smooth'});
    App.lastLyricIndex=index;
  }
  if(node)for(const word of node.querySelectorAll('.lyric-word'))word.classList.toggle('past',Number(word.dataset.time)<=App.state.position);
};
App.renderQueue=async function() {
  App.title('播放队列','顺序、单曲循环或随机播放');const generation=App.generation;
  try {
    const offset=(App.page-1)*50;const result=await App.native('queue',{offset});if(generation!==App.generation)return;
    const clear=App.el('button',{text:'清空队列',className:'danger',onClick:App.clearQueue});
    App.content(App.el('div',{className:'toolbar'},[App.el('span',{text:result.total+' 首歌曲',className:'muted'}),clear,
      App.el('button',{text:'播放模式',onClick:App.changeMode})]),App.songList(result.songs || [],{queue:true,offset}),
      App.pagination(App.page,offset+50<result.total,App.queuePage));
  } catch(error){if(generation===App.generation)App.error(error,App.renderQueue);}
};
App.queuePage=function(page){App.page=page;App.renderQueue();};
App.clearQueue=function(){App.confirm('清空播放队列','清空队列会停止当前播放。',async function(){await App.native('control',{action:'queue_clear'});App.renderQueue();});};
App.playMv=async function(song) {
  const result=await App.perform('api',{operation:'mv',data:{platform:song.platform,id:song.id,name:song.name,artist:song.artist}});
  if(!result)return;App.closeModal();
  await App.perform('video',{url:result.url,title:song.name,artist:song.artist,platform:song.platform,mode:App.settings.mvMode || 'automatic'});
};
App.findLyrics=function(song) {
  const input=App.input('lyric-query',song.name);
  App.modal('查找歌词版本',App.field('歌曲名称',input),App.el('button',{text:'搜索歌词',className:'primary',onClick:App.searchLyrics}),App.el('div',{id:'lyric-results'}));
};
App.searchLyrics=async function() {
  const query=document.getElementById('lyric-query');const list=document.getElementById('lyric-results');if(!query || !list)return;
  const result=await App.perform('lyric_search',{keyword:query.value});if(!result || !list.isConnected)return;
  list.replaceChildren();for(const song of (result.songs || []).slice(0,30))list.append(App.lyricCandidate(song));
};
App.lyricCandidate=function(song) {
  const button=App.el('button',{className:'song-main',text:song.name+' · '+song.artist});
  button.addEventListener('click',async function(){const result=await App.perform('lyric_apply',{song});if(result){App.lyricLines=result.lines || [];App.closeModal();App.renderPlayer();}});
  return App.el('div',{className:'song-row'},[button]);
};
App.sleepDialog=function() {
  const buttons=[];for(const minutes of [0,15,30,60,90])buttons.push(App.sleepButton(minutes));
  buttons.push(App.el('button',{text:'当前歌曲结束后',onClick:App.sleepAfterTrack}));
  App.modal('定时关闭',App.el('p',{text:'定时器由原生播放会话管理，锁屏后继续生效。',className:'muted'}),App.el('div',{className:'actions'},buttons));
};
App.sleepButton=function(minutes) {
  const button=App.el('button',{text:minutes===0?'取消定时':minutes+' 分钟'});
  button.addEventListener('click',async function(){const result=await App.perform('control',{action:'sleep',minutes});if(result){App.closeModal();App.toast(minutes===0?'已取消定时':'已设置 '+minutes+' 分钟');}});return button;
};
App.sleepAfterTrack=async function(){await App.perform('control',{action:'sleep_track'});App.closeModal();};
