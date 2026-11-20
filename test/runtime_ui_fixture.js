/* 浏览器验证中的原生能力替身，不调用真实账号或音源。SHIXIAOYANG，2026/11/19。 */
window.runtimeFixture={commands:[],favorites:[],queue:[],state:{song:null,playing:false,loading:false,position:0,duration:324000,
  queueCount:0,queueIndex:-1,queueRevision:0,favoriteRevision:0,lyricIndex:1,lyricsLoading:false,theme:'dark',fontScale:1,
  assistant:{active:false,state:'idle',status:'未开始'},userId:'default',mode:'sequence'}};
const fixtureSongs=[{platform:'qq',id:'001yS0N33yPm1B',name:'海阔天空',artist:'BEYOND',album:'乐与怒',duration:324},
  {platform:'qq',id:'0039MnYb0qxYhV',name:'晴天 <img src=x onerror=alert(1)>',artist:'周杰伦',album:'叶惠美',duration:269}];
function fixtureReply(request) {
  const fixture=window.runtimeFixture;fixture.commands.push(request);if(fixture.commands.length>100)fixture.commands.shift();
  switch(request.operation) {
    case 'ready':return;
    case 'state':return fixture.state;
    case 'settings':return {values:{},player:{neteaseLevel:'exhigh',commonLevel:'320k',playbackSources:{qq:'automatic','163':'automatic',kugou:'automatic'}},theme:'dark',fontScale:1};
    case 'credentials':return {configured:{}};
    case 'network':return {proxy:''};
    case 'users':return {users:[{id:'default',name:'默认用户',avatarId:'music',avatarColorIndex:0}],active:'default'};
    case 'api':
      switch(request.data.operation) {
        case 'sources':return window.App.defaultConfig;
        case 'discover':return {playlists:[{platform:'qq',id:'123456',name:'开车听的歌',creator:'库仔音乐'}]};
        case 'search':return {songs:fixtureSongs,total:2};
        case 'playlist':return {playlist:{platform:'qq',id:'123456',name:'开车听的歌'},songs:fixtureSongs,total:2};
        case 'mv':return {url:'https://example.com/video.mp4'};
      }break;
    case 'play':fixture.state.song=request.data.song || request.data.songs[0];fixture.state.playing=true;fixture.state.source='qing_music';return {accepted:true};
    case 'control':
      switch(request.data.action) {
        case 'toggle':fixture.state.playing=!fixture.state.playing;break;
        case 'queue_add':fixture.queue.push(request.data.song);fixture.state.queueCount=fixture.queue.length;break;
        case 'queue_remove':fixture.queue.splice(request.data.index,1);break;
        case 'queue_play':fixture.state.song=fixture.queue[request.data.index];fixture.state.playing=true;break;
        case 'seek':fixture.state.position=request.data.position;break;
      }return fixture.state;
    case 'favorite':fixture.state.favorite=true;fixture.favorites.push(request.data.song);return {favorite:true};
    case 'queue':return {songs:fixture.queue,total:fixture.queue.length,currentIndex:0};
    case 'lyrics':return {lines:[{time:0,text:'今天我',translated:'',words:[]},{time:2000,text:'寒夜里看雪飘过',translated:'',words:[]}],offset:0};
    case 'library':
      if(request.data.action==='effects')return {supported:true,values:{enabled:false,bands:Array(10).fill(0)},failures:[]};
      return {songs:fixture.favorites,playlists:[],total:fixture.favorites.length,entries:[]};
    case 'assistant':return {state:fixture.state.assistant,messages:[]};
    case 'backup':return {cancelled:true};
  }
  return {};
}
window.KuzaiNative={postMessage:function(message) {
  const request=JSON.parse(message);if(request.operation==='ready')return;
  const result=fixtureReply(request);
  setTimeout(function(){window.KuzaiHost.accept({id:request.id,result});
    window.KuzaiHost.event({event:'state',data:{state:window.runtimeFixture.state,runtimeStatus:'业务版本 1 已检查更新'}});},5);
}};
// 模拟最低支持版本中缺少的 DOM 方法，验证业务自己的兼容路径。
Element.prototype.replaceChildren=undefined;DocumentFragment.prototype.replaceChildren=undefined;
