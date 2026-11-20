import fs from 'node:fs';
import path from 'node:path';

/** 仅清理当前服务生成的发布文件，保留最近五版。SHIXIAOYANG，2026/11/19。 */
const root=fs.realpathSync(process.argv[2]);
const version=Number(process.argv[3]);
if(root!=='/runtime' || !Number.isSafeInteger(version) || version<1)throw new Error('清理目录或版本无效');
function removeOwned(directory,name) {
  const target=path.resolve(directory,name);
  if(path.dirname(target)!==fs.realpathSync(directory) || fs.lstatSync(target).isSymbolicLink())throw new Error('拒绝越界清理');
  fs.rmSync(target,{recursive:true,force:true});
}
const releases=path.join(root,'releases');
for(const name of fs.readdirSync(releases)) {
  if(/^r[0-9]{6,12}$/.test(name) && Number(name.slice(1))<version-4)removeOwned(releases,name);
}
const staging=path.join(root,'staging');
if(fs.existsSync(staging))for(const name of fs.readdirSync(staging)) {
  if(/^r[0-9]{6,12}$/.test(name) && Number(name.slice(1))<=version)removeOwned(staging,name);
}
for(const name of fs.readdirSync(root)) {
  const match=/^deploy-r([0-9]{6,12})\.tar$/.exec(name);
  if(match && Number(match[1])<version-1)removeOwned(root,name);
}
