import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

/** 构建并签署远程业务包，私钥保留在发布者本机。SHIXIAOYANG，2026/11/19。 */
export function buildRelease(source, output, keyFile, version) {
  if (!Number.isSafeInteger(version) || version < 1 || version > 999999999999) throw new Error('发布版本必须为 1 至 999999999999 的整数');
  const privateKey = crypto.createPrivateKey(fs.readFileSync(keyFile));
  if(privateKey.asymmetricKeyType!=='ed25519')throw new Error('发布私钥必须使用 Ed25519');
  const files = [];
  let total=0;
  function collect(directory, relative = '') {
    for (const entry of fs.readdirSync(directory, { withFileTypes:true }).sort((a,b)=>a.name.localeCompare(b.name))) {
      if (entry.isSymbolicLink()) throw new Error('业务包不接受符号链接');
      const filePath = relative ? `${relative}/${entry.name}` : entry.name;
      if(!/^[A-Za-z0-9_./-]{1,128}$/.test(filePath) || filePath.split('/').some(part=>part==='.' || part==='..') || ['manifest.json','bundle.json'].includes(filePath))throw new Error('业务资源路径无效');
      if (entry.isDirectory()) collect(path.join(directory,entry.name),filePath);
      else {
        if(!entry.isFile() || files.length>=128)throw new Error('业务文件类型或数量无效');
        const absolute=path.join(directory,entry.name);const size=fs.statSync(absolute).size;total+=size;
        if(size>2*1024*1024 || total>8*1024*1024)throw new Error('业务文件超过大小上限');
        files.push({path:filePath,data:fs.readFileSync(absolute).toString('base64')});
      }
    }
  }
  collect(source);
  if (!files.some(file=>file.path === 'index.html') || files.length > 128) throw new Error('业务包入口或文件数量无效');
  const id = `r${String(version).padStart(6,'0')}`;
  if(fs.existsSync(path.join(output,'releases',id)))throw new Error('该发布编号已存在，请使用更大的版本号');
  const bundle = Buffer.from(JSON.stringify({id,files}));
  if (bundle.length > 12*1024*1024) throw new Error('业务包超过 12 MB');
  const minimumFramework=Number(process.env.MINIMUM_FRAMEWORK || 1);
  const notes=process.env.RELEASE_NOTES || '远程业务更新';
  if(!Number.isSafeInteger(minimumFramework) || minimumFramework<1 || minimumFramework>1000000 || notes.length>2048)throw new Error('发布说明或框架版本无效');
  const payload = Buffer.from(JSON.stringify({
    schema:1,id,version,minimumFramework,
    bundlePath:`releases/${id}/bundle.json`,bundleBytes:bundle.length,
    bundleSha256:crypto.createHash('sha256').update(bundle).digest('hex'),
    publishedAt:new Date().toISOString(),notes,
  }));
  const envelope = {payload:payload.toString('base64'),signature:crypto.sign(null,payload,privateKey).toString('base64')};
  fs.mkdirSync(path.join(output,'releases',id),{recursive:true});
  fs.writeFileSync(path.join(output,'releases',id,'bundle.json'),bundle,{flush:true});
  fs.writeFileSync(path.join(output,'manifest.json.part'),JSON.stringify(envelope),{flush:true});
  fs.renameSync(path.join(output,'manifest.json.part'),path.join(output,'manifest.json'));
  return {id,version,bytes:bundle.length,publicKey:crypto.createPublicKey(privateKey).export({format:'jwk'}).x};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source,output,keyFile,versionText] = process.argv.slice(2);
  if (!source || !output || !keyFile) throw new Error('用法：node tools/build_runtime_release.mjs 业务目录 输出目录 私钥文件 版本号');
  console.log(JSON.stringify(buildRelease(source,output,keyFile,Number(versionText))));
}
