/* 会话、麦克风与 TTS 由框架统一释放；表单和消息展示独立热发布。SHIXIAOYANG，2026/11/19。 */
App.assistantPolling=false;App.assistantSnapshot='';
App.renderAssistant=async function() {
  App.title('音乐助理','聊天、语音对话，也可以让助理帮你选歌');const generation=App.generation;
  const transcript=App.el('p',{id:'assistant-status',className:'notice',text:(App.state.assistant || {}).status || '尚未开始会话'});
  const chat=App.el('div',{className:'chat',id:'chat'});
  const text=App.el('textarea',{id:'assistant-text',placeholder:'想听什么音乐，或者聊聊今天的心情…',maxlength:'8000','aria-label':'发送给助理的消息'});
  const form=App.el('form',{},[text,App.el('div',{className:'actions'},[App.el('button',{text:'发送消息',className:'primary',type:'submit'}),
    App.el('button',{text:'语音',type:'button',onClick:App.assistantListen}),App.el('button',{text:'结束会话',type:'button',onClick:App.assistantStop})])]);
  form.addEventListener('submit',App.sendAssistant);
  App.content(App.el('div',{className:'toolbar'},[App.el('button',{text:'连接与模型设置',className:'primary',onClick:App.assistantConfigDialog}),
    App.el('button',{text:'新会话',onClick:App.assistantNew})]),transcript,chat,form);
  try {const result=await App.native('assistant',{action:'history'});if(generation===App.generation)App.assistantMessages(result);}
  catch(error){if(generation===App.generation)chat.append(App.el('p',{text:error.message,className:'muted'}));}
};
App.assistantMessages=function(result) {
  const chat=document.getElementById('chat');if(!chat)return;
  const messages=(result.messages || []).slice(-40);const signature=JSON.stringify(messages);
  if(signature!==App.assistantSnapshot) {
    const nodes=messages.map(message=>App.el('article',{className:'message '+message.role,text:message.text}));
    chat.replaceChildren(...nodes);App.assistantSnapshot=signature;
  }
  const status=document.getElementById('assistant-status');if(status)status.textContent=(result.state || {}).error || (result.state || {}).status || '音乐助理';
};
App.sendAssistant=async function(event) {
  event.preventDefault();const input=document.getElementById('assistant-text');const value=input.value.trim();if(!value)return;
  const result=await App.perform('assistant',{action:'send',text:value});if(result && input.isConnected){input.value='';App.assistantMessages(result);}
};
App.assistantListen=async function(){const result=await App.perform('assistant',{action:(App.state.assistant || {}).active?'listen':'start'});if(result)App.assistantMessages(result);};
App.assistantStop=async function(){const result=await App.perform('assistant',{action:'stop'});if(result)App.assistantMessages(result);};
App.assistantNew=async function(){const result=await App.perform('assistant',{action:'new'});if(result)App.assistantMessages(result);};
App.pollAssistant=async function() {
  if(App.route!=='assistant' || App.assistantPolling)return;App.assistantPolling=true;
  try {const result=await App.native('assistant',{action:'history'});if(App.route==='assistant')App.assistantMessages(result);}
  catch {} finally{App.assistantPolling=false;}
};
App.assistantConfigDialog=async function() {
  const result=await App.perform('assistant_config',{});if(!result)return;App.aiConfig=result;
  const profile=App.select('ai-profile',(result.profiles || []).map(item=>({id:item.id,name:item.name})),result.active);
  profile.addEventListener('change',App.selectAiProfile);
  const provider=App.select('ai-provider',result.providers,result.config.provider);provider.addEventListener('change',App.changeAiProvider);
  const protocol=App.select('ai-protocol',result.protocols,result.config.protocol);
  const key=App.input('ai-key','','password');key.placeholder=result.configured?'已配置，留空保留':'填写个人 API Key';
  App.modal('AI 连接与模型',App.field('配置档案',profile),App.field('服务提供方',provider),App.field('请求协议',protocol),
    App.field('API 地址',App.input('ai-url',result.config.baseUrl)),App.field('API Key',key),App.field('模型名称',App.input('ai-model',result.config.model)),
    App.el('div',{className:'actions'},[App.el('button',{text:'保存配置',className:'primary',onClick:App.saveAiConfig}),
      App.el('button',{text:'测试连接',onClick:App.checkAiConfig}),App.el('button',{text:'新建档案',onClick:App.newAiProfileDialog}),
      App.el('button',{text:'语音设置',onClick:App.voiceSettingsDialog})]));
};
App.selectAiProfile=async function(){const id=document.getElementById('ai-profile').value;const result=await App.perform('assistant_config',{action:'select',id});if(result)App.assistantConfigDialog();};
App.changeAiProvider=function() {
  const id=document.getElementById('ai-provider').value;const provider=App.aiConfig.providers.find(item=>item.id===id);if(!provider)return;
  document.getElementById('ai-url').value=provider.baseUrl;document.getElementById('ai-protocol').value=provider.protocol;
};
App.saveAiConfig=async function() {
  const values={...App.aiConfig.config,provider:document.getElementById('ai-provider').value,protocol:document.getElementById('ai-protocol').value,
    baseUrl:document.getElementById('ai-url').value,apiKey:document.getElementById('ai-key').value,model:document.getElementById('ai-model').value};
  const result=await App.perform('assistant_config',{action:'save',values});if(result){App.toast('AI 配置已保存');App.closeModal();}
};
App.checkAiConfig=async function(){const result=await App.perform('assistant_config',{action:'check'});if(result)App.toast(result.message);};
App.newAiProfileDialog=function() {
  const name=App.input('ai-profile-name');App.modal('新建 AI 档案',App.field('档案名称',name),App.el('button',{text:'创建',className:'primary',onClick:App.newAiProfile}));
};
App.newAiProfile=async function(){const result=await App.perform('assistant_config',{action:'create',name:document.getElementById('ai-profile-name').value});if(result)App.assistantConfigDialog();};
App.voiceSettingsDialog=function() {
  const voice=App.aiConfig.voice || {};
  const load=App.select('voice-load',[{id:'on-demand',name:'按需加载'},{id:'startup-preload',name:'启动时预加载'}],voice.loadMode || 'on-demand');
  const reduction=App.input('voice-duck',voice.duckingReductionPercent || 50,'range');reduction.min='0';reduction.max='100';
  App.modal('语音设置',App.field('模型加载方式',load),App.field('助理说话时音乐降低比例',reduction),
    App.el('p',{text:'离线语音模型与系统权限由当前原生框架提供。',className:'notice'}),App.el('button',{text:'保存',className:'primary',onClick:App.saveVoice}));
};
App.saveVoice=async function() {
  const values={...App.aiConfig.voice,loadMode:document.getElementById('voice-load').value,duckingReductionPercent:Number(document.getElementById('voice-duck').value)};
  const result=await App.perform('assistant_config',{action:'voice',values});if(result){App.closeModal();App.toast('语音设置已保存');}
};
