import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';

/** 使用本机已安装的 Chrome 检查业务页面、真实点击和横屏布局。SHIXIAOYANG，2026/11/19。 */
const chrome=process.env.CHROME_TEST_BINARY || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const workspace=process.cwd();const source=path.join(workspace,'remote_app');
const output=path.join(workspace,'tmp/hot_runtime_20261119/ui');fs.mkdirSync(output,{recursive:true});
const profile=fs.mkdtempSync(path.join(os.tmpdir(),'music-runtime-ui-'));
const server=http.createServer((request,response)=>{
  const route=new URL(request.url,'http://localhost').pathname;
  const name=route==='/'?'index.html':route.slice(1);
  if(!/^[a-z_]+\.(html|js|css)$/.test(name)){response.writeHead(404);response.end();return;}
  const file=path.join(source,name);if(!fs.existsSync(file)){response.writeHead(404);response.end();return;}
  response.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html');
  fs.createReadStream(file).pipe(response);
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=spawn(chrome,['--headless=new','--remote-debugging-port=0','--user-data-dir='+profile,'--no-first-run',
  '--no-default-browser-check','--disable-extensions','--disable-background-networking','about:blank'],{windowsHide:true,stdio:'ignore'});
let socket;const pending=new Map();let requestId=0;const exceptions=[];const consoleErrors=[];
const pause=milliseconds=>new Promise(resolve=>setTimeout(resolve,milliseconds));
async function send(method,params={}) {
  const id=++requestId;const result=new Promise((resolve,reject)=>pending.set(id,{resolve,reject}));
  socket.send(JSON.stringify({id,method,params}));return result;
}
async function evaluate(expression) {
  const result=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
  if(result.exceptionDetails)throw new Error(result.exceptionDetails.text+' '+JSON.stringify(result.exceptionDetails.exception));
  return result.result.value;
}
async function until(expression) {
  for(let count=0;count<50;count++){if(await evaluate(expression))return;await pause(50);}
  throw new Error('等待界面状态超时：'+expression);
}
async function screenshot(name) {
  const result=await send('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(output,name+'.png'),Buffer.from(result.data,'base64'));
}
try {
  let debugPort;
  for(let count=0;count<100;count++){const file=path.join(profile,'DevToolsActivePort');if(fs.existsSync(file)){debugPort=fs.readFileSync(file,'utf8').split('\n')[0];break;}await pause(100);}
  assert(debugPort,'Chrome 未启动调试接口');
  const tabs=await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  socket=new WebSocket(tabs.find(tab=>tab.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  socket.addEventListener('message',function(event){const value=JSON.parse(event.data);
    if(value.id){const item=pending.get(value.id);pending.delete(value.id);if(value.error)item.reject(new Error(value.error.message));else item.resolve(value.result);}
    else if(value.method==='Runtime.exceptionThrown')exceptions.push(value.params.exceptionDetails);
    else if(value.method==='Log.entryAdded' && value.params.entry.level==='error')consoleErrors.push(value.params.entry.text);
  });
  await send('Page.enable');await send('Runtime.enable');await send('Log.enable');
  await send('Page.addScriptToEvaluateOnNewDocument',{source:fs.readFileSync(path.join(workspace,'test/runtime_ui_fixture.js'),'utf8')});
  for(const [width,height] of [[640,360],[1280,800],[390,844]]) {
    await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    await send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`});
    await until('!!window.KuzaiHost');
    await evaluate(`window.KuzaiHost.connect({token:'browser-test',version:1,settings:{},state:window.runtimeFixture.state,restore:{}})`);
    await until("document.querySelectorAll('.playlist-card').length>0");
    assert(await evaluate('document.documentElement.scrollWidth<=innerWidth'),'页面出现横向溢出');
    await screenshot(`home-${width}x${height}`);
    await evaluate("document.querySelector('[data-route=search]').click();document.getElementById('search-keyword').value='海阔天空';document.querySelector('.search-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))");
    await until("document.querySelectorAll('.song-row').length===2");
    assert(await evaluate("!document.querySelector('.song-meta img')"),'外部歌曲名称触发 HTML 注入');
    await evaluate("document.querySelector('[aria-label^=收藏]').click();document.querySelector('[aria-label=加入队列]').click();document.querySelector('.song-main').click()");
    await until("window.runtimeFixture.state.playing && window.runtimeFixture.queue.length===1");
    await evaluate("document.getElementById('open-player').click()");
    await until("document.querySelectorAll('.lyric-line').length===2");
    for(const id of ['mini-favorite','play-pause','open-queue']) {
      assert(await evaluate(`(()=>{const rect=document.getElementById('${id}').getBoundingClientRect();return rect.width>=28 && rect.height>=28 && rect.left>=0 && rect.right<=innerWidth && rect.bottom<=innerHeight})()`),`${width} 横屏入口不可操作：${id}`);
    }
    await screenshot(`player-${width}x${height}`);
    await evaluate("document.getElementById('play-pause').click()");await until('!window.runtimeFixture.state.playing');
    await evaluate("document.getElementById('open-queue').click()");await until("document.querySelector('[aria-label=移出队列]')!==null");
    await evaluate("App.go('settings')");await until("document.getElementById('source-qq')!==null");
    assert(await evaluate('document.documentElement.scrollWidth<=innerWidth'),'设置页横向溢出');
    await screenshot(`settings-${width}x${height}`);
    await evaluate("App.applyAppearance('dark',1.5)");
    assert(await evaluate('document.documentElement.scrollWidth<=innerWidth'),'大字号下横向溢出');
    await evaluate(`window.runtimePlaylistApi=App.api;window.runtimePlaylistReplies=new Map();
      App.api=function(operation,data){if(operation==='playlist')return new Promise(function(resolve){window.runtimePlaylistReplies.set(data.page,resolve);});return window.runtimePlaylistApi(operation,data);};
      App.playlist={platform:'qq',id:'test-playlist',name:'歌单'};App.page=1;App.go('playlist');App.page=2;App.renderPlaylist();
      window.runtimePlaylistReplies.get(2)({playlist:{name:'第二页'},songs:[],total:60});`);
    await until("App.playlist.name==='第二页'");
    await evaluate("window.runtimePlaylistReplies.get(1)({playlist:{name:'迟到的第一页'},songs:[],total:60})");
    assert(await evaluate("App.playlist.name==='第二页'"),'迟到的歌单响应覆盖了新页');
    await evaluate('App.api=window.runtimePlaylistApi;window.runtimePlaylistReplies.clear()');
    const pendingBefore=await evaluate('App.pending.size');
    await evaluate(`window.runtimeNativePost=window.KuzaiNative.postMessage;
      window.KuzaiNative.postMessage=function(){throw new Error('模拟桥接已关闭');};
      App.native('state',{}).catch(function(){});window.KuzaiNative.postMessage=window.runtimeNativePost;`);
    assert.equal(await evaluate('App.pending.size'),pendingBefore,'桥接发送失败后留下请求和计时器');
    console.log(`${width}x${height}：搜索、播放、收藏、队列、歌词、设置、旧 DOM 兼容通过`);
  }
  assert.deepEqual(exceptions,[],'页面抛出未处理异常');
  const errors=consoleErrors.filter(message=>!message.includes('favicon.ico'));
  assert.deepEqual(errors,[],'页面出现脚本、资源或 CSP 错误');
  fs.writeFileSync(path.join(output,'result.json'),JSON.stringify({passed:true,sizes:[[640,360],[1280,800],[390,844]],exceptions,consoleErrors},null,2));
} finally {
  if(socket?.readyState===WebSocket.OPEN){try{await send('Browser.close');}catch{}socket.close();}
  browser.kill();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
  for(const item of pending.values())item.reject(new Error('浏览器测试结束'));pending.clear();
  assert(path.resolve(profile).startsWith(path.resolve(os.tmpdir())+path.sep));
  for(let attempt=0;attempt<5;attempt++){try{fs.rmSync(profile,{recursive:true,force:true});break;}catch{await pause(200);}}
}
