/* 音乐库和备份的界面全部随业务包发布；文件由原生沙箱持有。SHIXIAOYANG，2026/11/19。 */
App.libraryTab='favorites';App.lastDownloads=[];
App.renderLibrary=async function() {
  App.title('音乐库','收藏、历史与离线音乐都保留在本机');
  const generation=App.generation;
  const choices=[{id:'favorites',name:'收藏'},{id:'history',name:'历史'},{id:'downloads',name:'下载'},
    {id:'local',name:'本地音乐'},{id:'cache',name:'缓存'},{id:'backup',name:'备份'}];
  const tabs=App.el('div',{className:'tabs'});
  for(const item of choices)tabs.append(App.libraryTabButton(item));
  const body=App.el('section',{id:'library-body'});App.content(tabs,body);
  try {
    if(App.libraryTab==='backup'){App.renderBackup(body);return;}
    const action=App.libraryTab;const offset=(App.page-1)*50;
    const result=await App.native('library',{action,offset});if(generation!==App.generation || !body.isConnected)return;
    if(action==='favorites') {
      App.knownFavorites=new Set((result.songs || []).map(song=>song.platform+':'+song.id));
      const toolbar=App.el('div',{className:'toolbar'},[App.el('button',{text:'导入歌单',className:'primary',onClick:App.importPlaylistDialog}),
        App.el('button',{text:'播放本页',onClick:App.playCurrentPage})]);
      body.append(toolbar,App.songList(result.songs || []));
      if(result.playlists && result.playlists.length)body.append(App.el('h3',{text:'收藏的歌单',className:'section-head'}),App.playlistCards(result.playlists));
    } else if(action==='history') {
      body.append(App.el('div',{className:'toolbar'},[App.el('button',{text:'清空历史',className:'danger',onClick:App.clearHistory})]),App.songList(result.songs || []));
    } else if(action==='downloads') {App.renderDownloads(result,body);}
    else if(action==='local') {
      body.append(App.el('div',{className:'toolbar'},[App.el('button',{text:'扫描本机音乐',className:'primary',onClick:App.scanLocal})]),
        App.songList(result.songs || []));
      if(result.error)body.append(App.el('p',{text:result.error,className:'notice'}));
    } else if(action==='cache') {
      const buttons=App.el('div',{className:'toolbar'},[App.el('span',{text:result.total+' 首缓存',className:'muted'}),
        App.el('button',{text:'清空缓存',className:'danger',onClick:App.clearCache})]);
      body.append(buttons,App.cacheRows(result.entries || []));
    }
    body.append(App.pagination(App.page,offset+50<result.total,App.libraryPage));
  } catch(error){if(generation===App.generation)body.replaceChildren(App.empty('音乐库暂不可用',error.message,App.el('button',{text:'重试',onClick:App.renderLibrary})));}
};
App.libraryTabButton=function(item) {
  const button=App.el('button',{text:item.name,className:App.libraryTab===item.id?'active':''});
  button.addEventListener('click',function(){App.libraryTab=item.id;App.page=1;App.renderLibrary();});return button;
};
App.libraryPage=function(page){App.page=page;App.renderLibrary();};
App.playCurrentPage=async function(){if(App.songs.length)await App.perform('play',{songs:App.songs,index:0});};
App.clearHistory=function(){App.confirm('清空播放历史','只清除播放历史，收藏和下载继续保留。',async function(){await App.native('library',{action:'history_clear'});App.renderLibrary();});};
App.scanLocal=async function() {
  const result=await App.perform('library',{action:'local_scan'});
  if(result){App.toast(result.error || '扫描到 '+result.total+' 首歌曲');App.renderLibrary();}
};
App.cacheRows=function(entries) {
  const list=App.el('div',{className:'song-list'});
  for(const entry of entries)list.append(App.cacheRow(entry));
  return entries.length?list:App.empty('还没有缓存','播放音乐时会按现有缓存设置保存音频。');
};
App.cacheRow=function(entry) {
  const remove=App.el('button',{text:'删除',className:'danger'});
  remove.addEventListener('click',async function(){const result=await App.perform('library',{action:'cache_remove',platform:entry.platform,id:entry.id});if(result)App.renderLibrary();});
  return App.el('div',{className:'song-row'},[App.el('span',{className:'song-main'},[App.el('span',{className:'song-meta'},
    [App.el('strong',{text:entry.name}),App.el('small',{text:entry.artist+' · '+App.formatBytes(entry.bytes)})])]),remove]);
};
App.clearCache=function(){App.confirm('清空音频缓存','已下载的离线音乐继续保留。',async function(){await App.native('library',{action:'cache_clear'});App.renderLibrary();});};
App.renderDownloads=function(result,body) {
  App.lastDownloads=result.entries || [];
  const wifi=App.el('input',{id:'wifi-downloads',type:'checkbox',checked:result.wifiOnly});
  wifi.addEventListener('change',function(){App.perform('library',{action:'download_wifi',enabled:wifi.checked});});
  body.append(App.el('div',{className:'field-inline'},[App.el('label',{for:wifi.id,text:'仅在 Wi-Fi 下下载'}),wifi]));
  const list=App.el('div',{className:'song-list',id:'download-rows'});
  for(const entry of App.lastDownloads)list.append(App.downloadRow(entry));
  body.append(App.lastDownloads.length?list:App.empty('还没有下载任务','在歌曲的更多操作中选择下载，即可离线播放。'));
};
App.downloadRow=function(entry) {
  const song=entry.song || {};const actions=[];
  if(entry.status==='completed')actions.push(App.downloadAction(entry,'播放','play'));
  else if(['paused','failed'].includes(entry.status))actions.push(App.downloadAction(entry,'继续','download_resume'));
  else actions.push(App.downloadAction(entry,'暂停','download_pause'));
  actions.push(App.downloadAction(entry,'删除','download_remove'));
  const progress=App.el('progress',{className:'download-progress',value:entry.received || 0,max:entry.total || 1});
  return App.el('div',{className:'song-row'},[App.el('span',{className:'song-main'},[App.art(song.coverUrl),App.el('span',{className:'song-meta'},[
    App.el('strong',{text:song.name}),App.el('small',{text:({queued:'排队中',downloading:'下载中',processing:'写入标签',paused:'已暂停',failed:'下载失败',completed:'已完成'})[entry.status]+(entry.error?' · '+entry.error:'')}),progress])]),
    App.el('div',{className:'actions'},actions)]);
};
App.downloadAction=function(entry,title,action) {
  const button=App.el('button',{text:title,className:action==='download_remove'?'danger':''});
  button.addEventListener('click',async function(){const result=await App.perform(action==='play'?'play':'library',action==='play'?{song:entry.offlineSong}:{action,id:entry.id});if(result && action!=='play')App.renderLibrary();});return button;
};
App.pollDownloads=async function() {
  if(App.route!=='library' || App.libraryTab!=='downloads' || App.downloadPolling)return;
  App.downloadPolling=true;
  try {
    const result=await App.native('library',{action:'downloads',offset:(App.page-1)*50});
    const before=JSON.stringify(App.lastDownloads);const after=JSON.stringify(result.entries || []);
    if(before!==after && App.route==='library' && App.libraryTab==='downloads')App.renderLibrary();
  } catch {} finally{App.downloadPolling=false;}
};

App.importPlaylistDialog=function() {
  const platform=App.select('import-platform',(App.config || App.defaultConfig).platforms,App.platform==='bilibili'?'qq':App.platform);
  const id=App.input('import-playlist-id');id.placeholder='粘贴歌单链接或 ID';
  App.modal('导入歌单',App.field('音乐平台',platform),App.field('歌单地址',id),
    App.el('button',{text:'打开歌单',className:'primary',onClick:App.importPlaylist}));
};
App.importPlaylist=function() {
  const platform=document.getElementById('import-platform').value;const raw=document.getElementById('import-playlist-id').value.trim();
  let id=raw;
  if(!/^\d+$/.test(id)) {
    try {
      const url=new URL(raw);
      if(platform==='qq')id=url.searchParams.get('id') || url.searchParams.get('disstid') || '';
      else if(platform==='163')id=url.searchParams.get('id') || new URLSearchParams(url.hash.split('?')[1] || '').get('id') || '';
      else id=url.searchParams.get('specialid') || url.searchParams.get('id') || '';
    } catch {const match=raw.match(/(?:id|disstid|specialid)[=:](\d+)/);id=match?match[1]:'';}
  }
  if(!/^\d{1,20}$/.test(id)){App.toast('没有识别到歌单 ID，请选择对应平台');return;}
  App.closeModal();App.openPlaylist({platform,id,name:'导入的歌单'});
};
App.openPlaylist=function(playlist) {App.playlist=playlist;App.page=1;App.go('playlist');};
App.renderPlaylist=async function() {
  const record=App.playlist;if(!record){App.go('library');return;}
  App.title(record.name || '歌单','按页加载歌曲，点击即可播放');const generation=App.generation;const page=App.page;App.loading();
  try {
    const result=await App.api('playlist',{platform:record.platform,id:record.id,page,limit:30});if(generation!==App.generation || page!==App.page)return;
    App.playlist={...record,...result.playlist,platform:record.platform,id:record.id};
    App.title(App.playlist.name,App.playlist.creator || '歌单');
    App.content(App.el('div',{className:'toolbar'},[App.el('button',{text:'收藏歌单',className:'primary',onClick:App.favoritePlaylist}),
      App.el('button',{text:'播放本页',onClick:App.playCurrentPage}),App.el('span',{text:result.total+' 首歌曲',className:'muted'})]),
      App.songList(result.songs || []),App.pagination(App.page,App.page*30<result.total,App.playlistPage));
  } catch(error){if(generation===App.generation)App.error(error,App.renderPlaylist);}
};
App.playlistPage=function(page){App.page=page;App.renderPlaylist();};
App.favoritePlaylist=async function(){const result=await App.perform('library',{action:'favorite_playlist',playlist:App.playlist});if(result)App.toast(result.favorite?'已收藏歌单':'已取消收藏');};
App.playlistCards=function(records) {
  const cards=App.el('div',{className:'cards'});
  for(const record of records.slice(0,100))cards.append(App.playlistCard(record));return cards;
};
App.playlistCard=function(record) {
  const card=App.el('button',{className:'playlist-card'},[App.art(record.coverUrl,'card-cover'),App.el('strong',{text:record.name}),App.el('small',{text:record.creator || '精选歌单'})]);
  card.addEventListener('click',function(){App.openPlaylist(record);});return card;
};

App.renderBackup=function(body) {
  body.append(App.panel('备份与还原','备份包含收藏、歌单和当前用户数据；完整备份还包含全部用户与全局设置。',
    App.el('div',{className:'actions'},[App.backupButton('导出当前用户','export'),App.backupButton('导出完整备份','export',true),
      App.backupButton('选择备份文件','import_file'),App.backupButton('从剪贴板导入','import_clipboard')])));
  body.append(App.panel('WebDAV','使用自己的备份账号，密码只保存到本机。',App.el('div',{className:'actions'},[
    App.el('button',{text:'设置 WebDAV',onClick:App.davDialog}),App.backupButton('上传备份','dav_upload'),App.backupButton('下载并预览','dav_download')])));
  body.append(App.panel('局域网传输','同一局域网中的手机可以通过临时地址上传或下载备份；会话十分钟后失效。',
    App.el('div',{className:'actions'},[App.backupButton('开始传输','lan_start'),App.backupButton('停止传输','lan_stop')]),App.el('div',{id:'lan-info'})));
};
App.backupButton=function(title,action,full=false) {
  const button=App.el('button',{text:title});
  button.addEventListener('click',async function(){button.disabled=true;try{const result=await App.native('backup',{action,full});App.backupResult(result);}catch(error){App.toast(error.message);}finally{button.disabled=false;}});return button;
};
App.backupResult=function(result) {
  if(result.ready){App.restoreDialog(result);return;}
  if(result.url){const info=document.getElementById('lan-info');if(info)info.replaceChildren(App.el('p',{text:'地址：'+result.url}),App.el('p',{text:'PIN：'+result.pin}),App.el('small',{text:'仅供同一局域网使用，关闭传输后地址失效。'}));return;}
  if(result.result)App.toast({saved:'备份已保存',copiedToClipboard:'当前平台已将备份复制到剪贴板',cancelled:'已取消导出'}[result.result]);
  else if(result.cancelled)App.toast('已取消');
  else if(result.uploaded)App.toast('备份已上传');
  else App.toast('操作完成');
};
App.restoreDialog=function(result) {
  const labels={songs:'收藏歌曲',bilibili:'B站收藏',playlists:'收藏歌单',searchHistory:'搜索历史',apiKey:'音源凭据',appearance:'外观',playerSettings:'播放器设置',aiAssistant:'AI 配置',globalVoice:'语音设置',fullSnapshot:'完整备份',remoteBusiness:'远程业务配置与音源凭据'};
  const replace=App.el('input',{id:'restore-replace',type:'checkbox'});
  const confirm=App.el('button',{text:'确认恢复',className:'primary'});
  confirm.addEventListener('click',async function(){confirm.disabled=true;const restored=await App.perform('backup',{action:'restore',replace:replace.checked});if(restored){App.closeModal();App.toast('已恢复 '+restored.songs+' 首收藏歌曲');App.renderLibrary();}else confirm.disabled=false;});
  App.modal('备份恢复预览',App.el('p',{text:'包含：'+(result.sections || []).map(key=>labels[key] || key).join('、')}),
    App.el('div',{className:'field-inline'},[App.el('label',{text:'替换当前收藏（默认合并）',for:replace.id}),replace]),
    App.el('div',{className:'actions'},[confirm,App.el('button',{text:'取消',onClick:App.cancelRestore})]));
  App.restorePending=true;
};
App.cancelRestore=async function(){await App.perform('backup',{action:'cancel'});App.restorePending=false;App.closeModal();};
App.davDialog=async function() {
  const data=await App.perform('backup',{action:'dav_config'});if(!data)return;
  App.modal('WebDAV 备份设置',App.field('服务器地址',App.input('dav-url',data.url)),App.field('独立备份账号',App.input('dav-user',data.username)),
    App.field('密码（留空保留原密码）',App.input('dav-password','','password')),App.field('HTTPS 证书 SHA-256',App.input('dav-cert',data.certificateSha256)),
    App.el('button',{text:'保存',className:'primary',onClick:App.saveDav}));
};
App.saveDav=async function() {
  const values={url:document.getElementById('dav-url').value,username:document.getElementById('dav-user').value,
    password:document.getElementById('dav-password').value,certificateSha256:document.getElementById('dav-cert').value};
  const result=await App.perform('backup',{action:'dav_config',values});if(result){App.closeModal();App.toast('WebDAV 设置已保存');}
};
