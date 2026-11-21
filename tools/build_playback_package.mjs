import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {fileURLToPath, pathToFileURL} from 'node:url';

const workspaceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultPrivateKey = 'E:/work/tools/music-player-repair/remote-runtime-keys/publisher-private.pem';
const maximumPackageBytes = 1024 * 1024;

function validateOrigins(origins) {
  if (!Array.isArray(origins) || !origins.length || origins.length > 32) {
    throw new Error('解析包上游域名列表无效');
  }
  const unique = new Set();
  for (const origin of origins) {
    if (typeof origin !== 'string' || origin.length > 256) throw new Error('解析包上游域名无效');
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
        url.search || url.hash || url.pathname !== '/' || unique.has(url.origin)) {
      throw new Error('解析包上游地址必须为不重复的 HTTP(S) origin');
    }
    unique.add(url.origin);
  }
  return Array.from(unique);
}

function inspectScript(script) {
  // 这里仅运行发布者当前工作区源码，Node vm 不作为不可信脚本安全沙箱。
  const context = vm.createContext({});
  vm.runInContext(script, context, {timeout: 1000, filename: 'playback_package/sources.js'});
  const metadataText = vm.runInContext('JSON.stringify(KuzaiSources.getCapabilities())', context, {timeout: 1000});
  const originsText = vm.runInContext('JSON.stringify(KuzaiSources.allowedOrigins)', context, {timeout: 1000});
  const capabilities = JSON.parse(metadataText);
  if (!capabilities || capabilities.protocolVersion !== 1 || typeof capabilities.revision !== 'string' ||
      !Array.isArray(capabilities.sources) || capabilities.sources.length > 32) {
    throw new Error('解析脚本没有返回兼容的音源能力');
  }
  if (Buffer.byteLength(metadataText) > 512 * 1024) throw new Error('解析包音源能力过大');
  return {capabilities, allowedOrigins: validateOrigins(JSON.parse(originsText))};
}

function writeArtifact(destination, bytes) {
  const temporary = destination + '.part';
  fs.writeFileSync(temporary, bytes);
  fs.renameSync(temporary, destination);
}

/**
 * 生成签名的本地音源解析包，沿用已授权的发布密钥，不生成缺失的密钥。
 * outputDirectory 是本次发布暂存目录，version 是递增的业务包版本。
 * 返回安装和发布所需的清单、包摘要与可信公钥。SHIXIAOYANG，2026/11/21。
 */
export function buildPlaybackPackage({outputDirectory, version, privateKeyFile = defaultPrivateKey}) {
  if (!Number.isInteger(version) || version <= 0 || version > 999999999) {
    throw new Error('解析包版本必须是正整数');
  }
  if (typeof outputDirectory !== 'string' || !outputDirectory.trim()) throw new Error('必须指定发布暂存目录');
  if (!fs.existsSync(privateKeyFile)) throw new Error('未找到已有发布私钥，请恢复原密钥后重试');
  const sourceFile = path.join(workspaceRoot, 'playback_package', 'sources.js');
  const original = fs.readFileSync(sourceFile, 'utf8');
  const marker = '__PACKAGE_REVISION__';
  if (original.split(marker).length !== 2) throw new Error('解析脚本版本标记缺失或重复');
  const script = original.replace(marker, 'p' + String(version).padStart(6, '0'));
  const metadata = inspectScript(script);
  const bundle = {packageFormat: 1, packageVersion: version, minimumBridgeVersion: 1,
    capabilities: metadata.capabilities, allowedOrigins: metadata.allowedOrigins, script};
  const bundleBytes = Buffer.from(JSON.stringify(bundle), 'utf8');
  if (bundleBytes.length > maximumPackageBytes) throw new Error('解析包超过 1 MiB 上限');
  const digest = crypto.createHash('sha256').update(bundleBytes).digest('hex');
  const packagePath = 'packages/p' + String(version).padStart(6, '0') + '.json';
  const payloadBytes = Buffer.from(JSON.stringify({packageFormat: 1, packageVersion: version,
    minimumBridgeVersion: 1, packagePath, sha256: digest, bytes: bundleBytes.length}), 'utf8');
  const privateKey = crypto.createPrivateKey(fs.readFileSync(privateKeyFile));
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error('已有发布密钥必须使用 Ed25519');
  const signature = crypto.sign(null, payloadBytes, privateKey);
  const manifest = {payloadBase64: payloadBytes.toString('base64'), signatureBase64: signature.toString('base64')};
  const publicDer = crypto.createPublicKey(privateKey).export({type: 'spki', format: 'der'});
  if (publicDer.length !== 44) throw new Error('Ed25519 发布公钥格式无效');
  const publicKeyBase64 = publicDer.subarray(12).toString('base64');

  // 所有输出均位于调用方明确指定的暂存目录；原始私钥不写入任何发布产物。
  const outputRoot = path.resolve(outputDirectory);
  const packagesDirectory = path.join(outputRoot, 'packages');
  fs.mkdirSync(packagesDirectory, {recursive: true});
  const bundleFile = path.join(outputRoot, packagePath);
  writeArtifact(bundleFile, bundleBytes);
  writeArtifact(path.join(outputRoot, 'manifest.json'), Buffer.from(JSON.stringify(manifest), 'utf8'));
  return {packageVersion: version, packagePath, sha256: digest, bytes: bundleBytes.length,
    publicKeyBase64, manifestPath: path.join(outputRoot, 'manifest.json'), bundlePath: bundleFile};
}

function main() {
  const outputDirectory = process.argv[2];
  const version = Number(process.argv[3]);
  const privateKeyFile = process.argv[4] || defaultPrivateKey;
  try {
    console.log(JSON.stringify(buildPlaybackPackage({outputDirectory, version, privateKeyFile})));
  } catch (error) {
    console.error('解析包生成失败：' + error.message);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
