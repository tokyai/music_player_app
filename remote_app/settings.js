/* 业务配置允许使用服务端新增的音源 ID，不在页面依赖原生枚举。SHIXIAOYANG，2026/11/19。 */
App.renderSettings=async function() {
  App.title('设置','音源与界面会在打开应用时检查更新');const generation=App.generation;App.loading();
  try {
    const results=await Promise.all([App.native('settings'),App.native('credentials'),App.native('library',{action:'effects'}),App.native('network')]);
    if(generation!==App.generation)return;
    App.settings=results[0].values || {};App.playerSettings=results[0].player || {};App.credentialFlags=results[1].configured || {};App.effects=results[2];
    const panels=[App.sourceSettings(),App.appearanceSettings(results[0]),App.playbackSettings(),App.effectsSettings(),App.credentialsSettings(),App.updateSettings(),App.networkSettings(results[3]),App.toolsSettings()];
    App.content(App.el('div',{className:'settings-grid'},panels));
    App.restoreDraft();
  } catch(error){if(generation===App.generation)App.error(error,App.renderSettings);}
};
App.sourceSettings=function() {
  const config=App.config || App.defaultConfig;const fields=[];
  for(const platform of config.platforms)fields.push(App.platformSourceFields(platform));
  const disabled=new Set(App.settings.disabledSources || []);
  for(const source of config.sources) {
    const input=App.el('input',{id:'source-enable-'+source.id,type:'checkbox',checked:!disabled.has(source.id)});
    fields.push(App.el('div',{className:'field-inline'},[App.el('label',{text:'自动备用使用 '+source.name,for:input.id}),input]));
  }
  fields.push(App.el('button',{text:'保存音源与音质',className:'primary',onClick:App.saveSources}));
  return App.panel('音源与音质','自动备用会并行尝试主音源，再尝试匹配线路和降低音质。',...fields);
};
App.platformSourceFields=function(platform) {
  const config=App.config || App.defaultConfig;
  const options=[{id:'automatic',name:'自动备用'}];
  for(const source of config.sources) {
    const authorized=(source.authorizedPlatforms || []).includes(platform.id);const experimental=(source.experimentalPlatforms || []).includes(platform.id);
    let suffix='';
    if(authorized)suffix='（需授权）';
    else if(experimental)suffix='（实验线路）';
    if((source.platforms || []).includes(platform.id) || authorized || experimental)options.push({id:source.id,name:source.name+suffix});
  }
  const selection=(App.settings.sources || {})[platform.id] || (App.playerSettings.playbackSources || {})[platform.id] || 'automatic';
  const source=App.select('source-'+platform.id,options,options.some(item=>item.id===selection)?selection:'automatic');
  const quality=App.select('quality-'+platform.id,config.qualities[platform.id] || [],(App.settings.qualities || {})[platform.id] || (platform.id==='163'?App.playerSettings.neteaseLevel || 'exhigh':App.playerSettings.commonLevel || '320k'));
  return App.el('div',{className:'section'},[App.field(platform.name+' 播放音源',source),App.field(platform.name+' 目标音质',quality)]);
};
App.saveSources=async function() {
  const config=App.config || App.defaultConfig;const values={...App.settings,sources:{},qualities:{},disabledSources:[]};
  for(const platform of config.platforms) {values.sources[platform.id]=document.getElementById('source-'+platform.id).value;values.qualities[platform.id]=document.getElementById('quality-'+platform.id).value;}
  for(const source of config.sources)if(!document.getElementById('source-enable-'+source.id).checked)values.disabledSources.push(source.id);
  const result=await App.perform('settings',{values});if(result){App.settings=result.values;App.toast('音源和音质已保存，下次解析生效');}
};
App.appearanceSettings=function(settings) {
  const mode=App.select('theme-mode',[{id:'system',name:'跟随系统'},{id:'light',name:'浅色'},{id:'dark',name:'深色'}],settings.theme);
  const scale=App.input('font-scale',settings.fontScale || 1,'range');scale.min='.5';scale.max='1.5';scale.step='.05';
  const lyric=App.input('lyric-font-size',App.settings.lyricFontSize || 21,'range');lyric.min='14';lyric.max='36';lyric.step='1';
  return App.panel('外观与歌词','页面支持横屏、系统深浅色以及无障碍字号。',App.field('主题模式',mode),App.field('整体字号比例',scale),App.field('歌词字号',lyric),
    App.el('button',{text:'保存外观',className:'primary',onClick:App.saveAppearance}));
};
App.saveAppearance=async function() {
  const mode=document.getElementById('theme-mode').value;const fontScale=Number(document.getElementById('font-scale').value);
  const result=await App.perform('appearance',{mode,fontScale});if(!result)return;
  const values={...App.settings,lyricFontSize:Number(document.getElementById('lyric-font-size').value)};
  await App.perform('settings',{values});App.settings=values;App.applyAppearance(result.theme,result.fontScale);App.toast('外观已保存');
};
App.applyAppearance=function(mode,scale) {
  let theme=mode;
  if(mode==='system')theme=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';
  document.body.dataset.theme=theme;
  document.documentElement.style.setProperty('--font-scale',String(Number(scale)||1));
  document.body.dataset.large=Number(scale)>1.25?'true':'false';
  document.documentElement.style.setProperty('--lyric-size',String(App.settings.lyricFontSize || 21)+'px');
};
App.playbackSettings=function() {
  const mode=App.select('mv-mode',[{id:'automatic',name:'自动兼容'},{id:'exo',name:'ExoPlayer'},{id:'mpv',name:'MPV'}],App.settings.mvMode || 'automatic');
  const step=App.select('lyric-step',[{id:'100',name:'100 毫秒'},{id:'500',name:'500 毫秒'},{id:'1000',name:'1 秒'}],String(App.playerSettings.lyricOffsetStepMs || 500));
  return App.panel('播放体验','音频与系统媒体通知由原生框架运行，退出页面或更新业务包不会重建播放器。',
    App.field('MV 播放内核',mode),App.field('歌词偏移调整步长',step),App.el('button',{text:'保存播放设置',className:'primary',onClick:App.savePlayback}),
    App.el('button',{text:'定时关闭',className:'secondary',onClick:App.sleepDialog}));
};
App.savePlayback=async function() {
  const values={...App.playerSettings,videoPlayerMode:document.getElementById('mv-mode').value,lyricOffsetStepMs:Number(document.getElementById('lyric-step').value)};
  const result=await App.perform('library',{action:'player_settings',values});if(!result)return;
  const settings={...App.settings,mvMode:values.videoPlayerMode};await App.perform('settings',{values:settings});App.settings=settings;App.toast('播放设置已保存');
};
App.effectsSettings=function() {
  const values=App.effects.values || {};
  const enabled=App.el('input',{id:'effects-enabled',type:'checkbox',checked:values.enabled});
  const equalizer=App.el('input',{id:'eq-enabled',type:'checkbox',checked:values.equalizerEnabled});
  const fields=[App.el('div',{className:'field-inline'},[App.el('label',{text:'启用音效',for:enabled.id}),enabled]),
    App.el('div',{className:'field-inline'},[App.el('label',{text:'启用均衡器',for:equalizer.id}),equalizer])];
  const labels=['31','62','125','250','500','1k','2k','4k','8k','16k'];
  for(let index=0;index<10;index++){const input=App.input('eq-'+index,(values.bands || [])[index] || 0,'range');input.min='-12';input.max='12';input.step='1';fields.push(App.field(labels[index]+' Hz',input));}
  fields.push(App.el('button',{text:'保存音效',className:'primary',onClick:App.saveEffects}));
  return App.panel('音效与均衡器',App.effects.supported?'设置会应用到当前原生音频会话。':'当前设备不提供系统音效能力。',...fields);
};
App.saveEffects=async function() {
  const values={...App.effects.values,enabled:document.getElementById('effects-enabled').checked,equalizerEnabled:document.getElementById('eq-enabled').checked,bands:[]};
  for(let index=0;index<10;index++)values.bands.push(Number(document.getElementById('eq-'+index).value));
  const result=await App.perform('library',{action:'effects',values});if(result)App.toast(result.failures && result.failures.length?result.failures.join('，'):'音效已保存');
};
App.credentialsSettings=function() {
  const fields=[];const keys=[{id:'apiKey',name:'ChKSz API Key'},{id:'hywCardKey',name:'HYW 卡密'},{id:'xinghaiLicenseKey',name:'星海 QQ 授权卡密'}];
  for(const key of keys) {
    const input=App.input('credential-'+key.id,'','password');input.placeholder=App.credentialFlags[key.id]?'已配置，留空保留':'未配置，公益线路可留空';fields.push(App.field(key.name,input));
  }
  fields.push(App.el('div',{className:'actions'},[App.el('button',{text:'保存凭据',className:'primary',onClick:App.saveCredentials}),
    App.el('button',{text:'清除个人凭据',className:'danger',onClick:App.clearCredentials})]));
  const statuses=[];for(const source of (App.config || App.defaultConfig).sources)statuses.push(App.sourceStatus(source));
  return App.panel('线路授权与测试','QingMusic 客户端认证由服务器维护。ChKSz 和星海 QQ 仍需要自己的有效授权。',...fields,...statuses);
};
App.saveCredentials=async function() {
  const values={};for(const id of ['apiKey','hywCardKey','xinghaiLicenseKey']){const value=document.getElementById('credential-'+id).value;if(value)values[id]=value;}
  const result=await App.perform('credentials',{values});if(result){App.toast('凭据已保存到系统安全存储');App.renderSettings();}
};
App.clearCredentials=function(){App.confirm('清除个人线路凭据','清除后需要个人授权的线路将不可用。',async function(){await App.native('credentials',{clear:['apiKey','hywCardKey','xinghaiLicenseKey']});App.renderSettings();});};
App.sourceStatus=function(source) {
  const container=App.el('div',{className:'source-status'});const label=App.el('p',{text:source.name+'：'+(source.platforms || []).map(id=>({qq:'QQ','163':'网易云',kugou:'酷狗'})[id] || id).join('、')});
  const buttons=App.el('div',{className:'actions'});
  for(const platform of [...(source.platforms || []),...(source.authorizedPlatforms || []),...(source.experimentalPlatforms || [])])buttons.append(App.sourceProbeButton(source,platform));
  container.append(label,buttons);return container;
};
App.sourceProbeButton=function(source,platform) {
  const name=({'163':'网易云',qq:'QQ',kugou:'酷狗'})[platform] || platform;
  const button=App.el('button',{text:'测试 '+name,className:'secondary'});
  button.addEventListener('click',async function(){button.disabled=true;button.textContent='正在测试…';try {
    const samples=App.probeSongs;const result=await App.native('source_probe',{song:{...samples[platform],source:source.id,quality:platform==='163'?'exhigh':'320k'}});
    button.textContent=name+' '+result.elapsed+'ms';App.toast(source.name+' '+name+' 解析成功，音频读取请实际播放验证');
  } catch(error){button.textContent='测试 '+name;App.toast(source.name+'：'+error.message);}finally{button.disabled=false;}});return button;
};
App.updateSettings=function() {
  return App.panel('业务版本 '+(App.version || 1),'每次启动或返回应用时检查发布版本。断网使用本地版本，加载失败会恢复上一版本。',
    App.el('p',{id:'runtime-status',text:App.runtimeStatus || '正在检查更新…'}),
    App.el('button',{text:'立即检查更新',className:'primary',onClick:App.checkRuntime}),
    App.el('p',{text:'播放器、系统权限及新原生能力的变更需要更新安装包。自用 iOS 的签名有效期仍由签名方式决定。',className:'notice'}));
};
App.checkRuntime=async function(){const result=await App.perform('runtime_check',{});if(result)App.toast(result.status);};
App.networkSettings=function(settings) {
  const proxy=App.input('network-proxy',settings.proxy || '');proxy.placeholder='127.0.0.1:10808 或代理主机:端口';
  return App.panel('更新服务连接','当前网络无法直连更新服务器时，可填写 HTTP 代理地址；留空使用直连。',
    App.field('HTTP 代理',proxy),App.el('button',{text:'保存并检查更新',className:'primary',onClick:App.saveNetwork}));
};
App.saveNetwork=async function(){const result=await App.perform('network',{proxy:document.getElementById('network-proxy').value});if(result)App.toast('连接设置已保存，正在检查更新');};
App.toolsSettings=function() {
  return App.panel('应用与数据','本地数据跟随用户切换，音源凭据不会写入更新服务器的日志。',
    App.el('div',{className:'actions'},[App.el('button',{text:'用户管理',onClick:App.usersDialog}),App.el('button',{text:'音乐助理',onClick:App.goAssistant}),
      App.el('button',{text:'备份与还原',onClick:App.goBackup}),App.el('button',{text:'完全关闭软件',className:'danger',onClick:App.exitApp})]));
};
App.goAssistant=function(){App.go('assistant');};
App.goBackup=function(){App.libraryTab='backup';App.go('library');};
App.exitApp=function(){App.perform('exit',{});};
App.usersDialog=async function() {
  const data=await App.perform('users',{});if(!data)return;
  const list=App.el('div',{className:'song-list'});for(const user of data.users || [])list.append(App.userRow(user,data.active));
  const name=App.input('new-user-name');name.maxLength=32;
  App.modal('用户管理',list,App.field('新用户名称',name),App.el('button',{text:'创建用户',className:'primary',onClick:App.createUser}));
};
App.userRow=function(user,active) {
  const switchButton=App.el('button',{text:user.id===active?'当前用户':'切换',className:user.id===active?'primary':''});switchButton.disabled=user.id===active;
  switchButton.addEventListener('click',function(){App.perform('users',{action:'switch',id:user.id});});
  const rename=App.el('button',{text:'改名'});rename.addEventListener('click',function(){App.renameUserDialog(user);});
  const remove=App.el('button',{text:'删除',className:'danger'});remove.disabled=user.id==='default';
  remove.addEventListener('click',function(){App.confirm('删除用户','删除 '+user.name+' 及其本机数据？',async function(){await App.native('users',{action:'delete',id:user.id});App.usersDialog();});});
  return App.el('div',{className:'song-row'},[App.el('strong',{text:user.name,className:'song-main'}),switchButton,rename,remove]);
};
App.createUser=async function(){const input=document.getElementById('new-user-name');const result=await App.perform('users',{action:'create',name:input.value});if(result)App.usersDialog();};
App.renameUserDialog=function(user) {
  const input=App.input('rename-user',user.name);const save=App.el('button',{text:'保存',className:'primary'});
  save.addEventListener('click',async function(){const result=await App.perform('users',{action:'rename',id:user.id,name:input.value});if(result)App.usersDialog();});App.modal('修改用户名',App.field('用户名称',input),save);
};
