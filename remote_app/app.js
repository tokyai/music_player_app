/* 原生握手完成后才显示业务；页面不能绕过原生网络和存储边界。SHIXIAOYANG，2026/11/19。 */
App.probeSongs={
  qq:{platform:'qq',id:'001yS0N33yPm1B',name:'海阔天空',artist:'BEYOND',album:'乐与怒',albumId:'002qcJuX3lO3EZ',duration:324},
  '163':{platform:'163',id:'347230',name:'海阔天空',artist:'Beyond',album:'海阔天空',duration:326},
  kugou:{platform:'kugou',id:'c41e80a18d1448fa47086372999c7f43',name:'海阔天空',artist:'BEYOND',album:'乐与怒',albumId:'973001',duration:324},
};
App.go=function(route) {
  if(!['home','search','library','settings','player','queue','playlist','assistant'].includes(route))return;
  if(App.route!==route) {App.history.push(App.route);if(App.history.length>12)App.history.shift();App.page=1;}
  if(App.route==='library' && App.libraryTab==='backup' && route!=='library')App.perform('backup',{action:'lan_stop'});
  App.route=route;App.generation++;
  for(const button of document.querySelectorAll('[data-route]'))button.classList.toggle('active',button.dataset.route===route);
  document.getElementById('content').scrollTop=0;
  switch(route) {
    case 'home':App.renderHome();break;
    case 'search':App.renderSearch();break;
    case 'library':App.renderLibrary();break;
    case 'settings':App.renderSettings();break;
    case 'player':App.renderPlayer();break;
    case 'queue':App.renderQueue();break;
    case 'playlist':App.renderPlaylist();break;
    case 'assistant':App.renderAssistant();break;
  }
};
App.renderHome=async function() {
  App.title('发现','音乐，让每一段路都有声音');const generation=App.generation;
  const hero=App.el('section',{className:'hero'},[App.el('small',{text:'YOUR EVERYDAY SOUNDTRACK'}),App.el('h2',{text:'让好音乐，一直陪着你'}),
    App.el('p',{text:'聚合你喜欢的平台，打开歌单，发现下一首想循环的歌。'}),App.el('span',{className:'badge',text:'♫','aria-hidden':'true'})]);
  const body=App.el('section',{id:'discover-results'});App.content(hero,App.platformTabs(App.renderHome),body);
  if(App.platform==='bilibili'){App.platform='qq';App.renderHome();return;}
  try {
    const result=await App.api('discover',{platform:App.platform,limit:20});if(generation!==App.generation || !body.isConnected)return;
    body.append(App.el('div',{className:'section-head'},[App.el('h3',{text:result.playlists?'精选歌单':'新歌速递'}),App.el('button',{text:'导入歌单',className:'secondary',onClick:App.importPlaylistDialog})]),
      result.playlists?App.playlistCards(result.playlists):App.songList(result.songs || []));
  } catch(error){if(generation===App.generation && body.isConnected)body.append(App.empty('发现页暂时离线',error.message,App.el('button',{text:'打开本地音乐库',onClick:App.goLibrary})));}
};
App.renderSearch=function() {
  App.title('搜索','在 QQ、网易云、酷狗和 B站中寻找歌曲');
  const input=App.input('search-keyword',App.keyword);input.placeholder='歌曲、歌手或专辑';input.maxLength=128;
  const form=App.el('form',{className:'search-form'},[input,App.el('button',{text:'搜索',className:'primary',type:'submit'})]);
  form.addEventListener('submit',App.submitSearch);
  const kinds=App.el('div',{className:'tabs'},[App.searchKindButton('songs','歌曲'),App.searchKindButton('playlists','歌单')]);
  App.content(form,App.platformTabs(App.selectSearchPlatform,true),kinds,App.el('section',{id:'search-results'}));
  if(App.keyword)App.search();
};
App.searchKindButton=function(kind,title) {
  const button=App.el('button',{text:title,className:App.kind===kind?'active':''});
  button.addEventListener('click',function(){App.kind=kind;App.page=1;App.renderSearch();});return button;
};
App.submitSearch=function(event){event.preventDefault();App.keyword=document.getElementById('search-keyword').value.trim();App.page=1;App.search();};
App.selectSearchPlatform=function(){const input=document.getElementById('search-keyword');if(input)App.keyword=input.value.trim();App.renderSearch();};
App.search=async function() {
  const body=document.getElementById('search-results');if(!body || !App.keyword)return;
  body.replaceChildren(App.el('div',{className:'loading',text:'正在搜索…'}));const generation=App.generation;const query=App.keyword;const platform=App.platform;const page=App.page;
  try {
    if(platform==='bilibili' && App.kind==='playlists')throw new Error('B站搜索提供视频与音频，请选择歌曲');
    const result=platform==='bilibili'?await App.native('library',{action:'bilibili_search',keyword:query}):await App.api('search',{platform,keyword:query,page,limit:30,kind:App.kind});
    if(generation!==App.generation || query!==App.keyword || platform!==App.platform || page!==App.page || !body.isConnected)return;
    const count=(result.songs || result.playlists || []).length;
    body.replaceChildren(result.playlists?App.playlistCards(result.playlists):App.songList(result.songs || []),
      App.pagination(page,platform!=='bilibili' && count>=30,App.searchPage));
    if(!count)body.prepend(App.empty('没有找到结果','试试更短的关键词，或切换到其他平台。'));
  } catch(error){if(generation===App.generation && body.isConnected)body.replaceChildren(App.empty('搜索暂不可用',error.message,App.el('button',{text:'重试',onClick:App.search})));}
};
App.searchPage=function(page){App.page=page;App.search();};
App.bind=function() {
  for(const button of document.querySelectorAll('[data-route]'))button.addEventListener('click',App.navClick);
  document.getElementById('open-player').addEventListener('click',App.openPlayer);
  document.getElementById('open-queue').addEventListener('click',App.openQueue);
  document.getElementById('play-pause').addEventListener('click',App.togglePlayer);
  document.getElementById('previous').addEventListener('click',App.previousTrack);
  document.getElementById('next').addEventListener('click',App.nextTrack);
  document.getElementById('mini-favorite').addEventListener('click',App.favoriteCurrent);
  document.getElementById('seek').addEventListener('change',App.seekPlayer);
  document.getElementById('user-button').addEventListener('click',App.usersDialog);
  document.getElementById('modal-close').addEventListener('click',App.closeModal);
  document.addEventListener('keydown',App.keyboard);
  matchMedia('(prefers-color-scheme:dark)').addListener(App.systemThemeChanged);
};
App.navClick=function(event){App.go(event.currentTarget.dataset.route);};
App.openPlayer=function(){App.go('player');};
App.openQueue=function(){App.go('queue');};
App.togglePlayer=function(){App.perform('control',{action:'toggle'});};
App.previousTrack=function(){App.perform('control',{action:'previous'});};
App.nextTrack=function(){App.perform('control',{action:'next'});};
App.seekPlayer=function(event){App.perform('control',{action:'seek',position:Number(event.target.value)});};
App.favoriteCurrent=async function(){if(App.state.song){const result=await App.perform('favorite',{song:App.state.song});if(result)App.toast(result.favorite?'已收藏':'已取消收藏');}};
App.systemThemeChanged=function(){App.applyAppearance(App.state.theme || 'system',App.state.fontScale || 1);};
App.keyboard=function(event) {
  if(event.key==='Escape'){event.preventDefault();window.KuzaiHost.back();}
  if(event.key==='Tab' && App.modalOpen) {
    const items=[...document.querySelectorAll('#modal button:not(:disabled),#modal input,#modal select,#modal textarea')];
    const first=items[0],last=items[items.length-1];if(!first)return;
    if(event.shiftKey && document.activeElement===first){event.preventDefault();last.focus();}
    else if(!event.shiftKey && document.activeElement===last){event.preventDefault();first.focus();}
  }
};
App.initialize=async function() {
  App.bind();App.config=App.settings.catalog || App.defaultConfig;
  App.applyAppearance(App.state.theme || 'system',App.state.fontScale || 1);App.updatePlayer(App.state);
  App.go(App.route);
  const results=await Promise.allSettled([App.api('sources',{}),App.native('users',{})]);
  if(results[0].status==='fulfilled')App.config=results[0].value;
  if(results[1].status==='fulfilled') {
    const result=results[1].value;const user=(result.users || []).find(item=>item.id===result.active);
    document.getElementById('user-button').textContent=user?user.name:'用户';
  }
  if(App.route==='settings')App.renderSettings();
};

window.KuzaiHost={
  connect:function(params) {
    if(App.token===params.token)return;
    App.token=params.token;App.version=params.version;App.settings=params.settings || {};App.state=params.state || {};
    const saved=params.restore || {};App.route=saved.route || 'home';App.platform=saved.platform || 'qq';App.page=saved.page || 1;
    App.keyword=saved.keyword || '';App.kind=saved.kind || 'songs';App.libraryTab=saved.libraryTab || 'favorites';App.playlist=saved.playlist || null;
    App.history=(saved.history || []).slice(-12);App.formDraft=saved.formDraft || {};
    window.KuzaiNative.postMessage(JSON.stringify({id:'ready',token:App.token,operation:'ready',data:{}}));
    App.initialize().catch(function(error){App.toast(error.message);});
  },
  accept:function(response) {
    const request=App.pending.get(response.id);if(!request)return;App.pending.delete(response.id);clearTimeout(request.timer);
    if(response.error)request.reject(new Error(response.error.message));else request.resolve(response.result);
  },
  event:function(message) {
    if(message.event==='state') {
      App.updatePlayer(message.data.state);App.runtimeStatus=message.data.runtimeStatus;
      const status=document.getElementById('runtime-status');if(status)status.textContent=App.runtimeStatus;
    } else if(message.event==='backup_ready')App.restoreDialog(message.data);
    else if(message.event==='navigate')App.go(message.data.page);
  },
  prepareUpdate:function() {
    const formDraft={};let defer=false;
    for(const input of document.querySelectorAll('input,textarea,select')) {
      if(!input.id || input.type==='range')continue;
      if(input.type==='password'){if(input.value)defer=true;continue;}
      formDraft[input.id]=input.type==='checkbox'?input.checked:input.value.slice(0,8192);
    }
    return {route:App.route,platform:App.platform,page:App.page,keyword:App.keyword,kind:App.kind,
      libraryTab:App.libraryTab,playlist:App.playlist,history:App.history,formDraft,defer:defer || App.modalOpen};
  },
  back:function() {
    if(App.modalOpen){App.closeModal();return;}
    if(App.history.length){const route=App.history.pop();App.route=route;App.go(route);}
    else if(App.route!=='home')App.go('home');else App.exitApp();
  },
};
App.pollTimer=setInterval(function(){if(document.hidden)return;App.pollDownloads();App.pollAssistant();},2000);
window.addEventListener('pagehide',function(){clearInterval(App.pollTimer);clearTimeout(App.toastTimer);
  for(const request of App.pending.values()){clearTimeout(request.timer);request.reject(new Error('业务页面已更新'));}App.pending.clear();});
