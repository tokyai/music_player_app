import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

/** 发布前核验签名、单调版本和全部资源；服务器不接收发布私钥。SHIXIAOYANG，2026/11/19。 */
export function verifyRelease(root,manifestPath=path.join(root,'manifest.next.json')) {
  const envelope=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
  const payload=Buffer.from(envelope.payload,'base64');const signature=Buffer.from(envelope.signature,'base64');
  const publicKey=crypto.createPublicKey(fs.readFileSync(path.join(root,'publisher-public.pem')));
  if(payload.length>32*1024 || signature.length!==64 || !crypto.verify(null,payload,publicKey,signature))throw new Error('发布签名校验失败');
  const release=JSON.parse(payload);
  if(release.schema!==1 || !Number.isSafeInteger(release.version) || release.version<1 ||
    release.id!==`r${String(release.version).padStart(6,'0')}` || !/^r[0-9]{6,12}$/.test(release.id) ||
    release.bundlePath!==`releases/${release.id}/bundle.json` || release.bundleBytes>12*1024*1024)throw new Error('发布描述无效');
  const previous=path.join(root,'manifest.json');
  if(fs.existsSync(previous) && path.resolve(previous)!==path.resolve(manifestPath)) {
    const old=JSON.parse(Buffer.from(JSON.parse(fs.readFileSync(previous,'utf8')).payload,'base64'));
    if(release.version<=old.version)throw new Error('发布编号必须大于当前编号');
  }
  const blob=fs.readFileSync(path.join(root,release.bundlePath));
  if(blob.length!==release.bundleBytes || crypto.createHash('sha256').update(blob).digest('hex')!==release.bundleSha256)throw new Error('业务包摘要不匹配');
  const data=JSON.parse(blob);if(data.id!==release.id || !Array.isArray(data.files) || data.files.length>128)throw new Error('业务包结构无效');
  const names=new Set();let total=0;
  for(const file of data.files) {
    if(typeof file.path!=='string' || !/^[A-Za-z0-9_./-]{1,128}$/.test(file.path) || file.path.startsWith('/') ||
      file.path.split('/').some(part=>!part || part==='.' || part==='..') || names.has(file.path) || ['bundle.json','manifest.json'].includes(file.path))throw new Error('业务包路径无效');
    const decoded=Buffer.from(file.data,'base64');total+=decoded.length;
    if(decoded.length>2*1024*1024 || total>8*1024*1024)throw new Error('业务资源过大');
    names.add(file.path);
  }
  if(!names.has('index.html'))throw new Error('业务包缺少入口');
  return {id:release.id,version:release.version,bytes:blob.length};
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url))console.log(JSON.stringify(verifyRelease(process.argv[2],process.argv[3])));
