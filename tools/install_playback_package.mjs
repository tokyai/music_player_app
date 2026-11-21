import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';

const trustedPublicKey = 'ms6EKQj4Rd9CuRDUVvjGrToKNHHT80yog/tMtqw+Pb8=';
const maximumManifestBytes = 64 * 1024;
const maximumPackageBytes = 1024 * 1024;
const packageName = /^p[0-9]{6,9}\.json$/;

function samePath(left, right) {
  return process.platform === 'win32' ? left.toLowerCase() === right.toLowerCase() : left === right;
}

function directory(directoryPath, create = false) {
  const full = path.resolve(directoryPath);
  const parent = path.dirname(full);
  if (!samePath(fs.realpathSync(parent), parent)) throw new Error('更新目录父路径不能包含符号链接');
  let details;
  try { details = fs.lstatSync(full); }
  catch (error) {
    if (error.code !== 'ENOENT' || !create) throw error;
    fs.mkdirSync(full, {mode: 0o755});
    details = fs.lstatSync(full);
  }
  if (!details.isDirectory() || details.isSymbolicLink() || !samePath(fs.realpathSync(full), full)) {
    throw new Error('更新目录必须是实际目录，不能使用符号链接');
  }
  return full;
}

function boundedFile(file, maximum) {
  const details = fs.lstatSync(file);
  if (!details.isFile() || details.isSymbolicLink() || details.size < 1 || details.size > maximum) {
    throw new Error('更新文件类型或大小无效');
  }
  const descriptor = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size !== details.size || opened.size > maximum ||
        opened.dev !== details.dev || opened.ino !== details.ino) throw new Error('更新文件在检查后发生变化');
    // 只分配已核对的大小，文件被并发追加时也不会一直读取到 EOF。
    const bytes = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < bytes.length) {
      const received = fs.readSync(descriptor, bytes, offset, bytes.length - offset, offset);
      if (!received) throw new Error('更新文件读取不完整');
      offset += received;
    }
    if (fs.fstatSync(descriptor).size !== opened.size) throw new Error('更新文件读取时大小发生变化');
    return bytes;
  } finally {
    fs.closeSync(descriptor);
  }
}

function optionalFile(file, maximum) {
  try { return boundedFile(file, maximum); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function decodeBase64(value, maximum) {
  if (typeof value !== 'string' || !value || value.length > maximum * 2) throw new Error('解析包签名编码无效');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length > maximum || bytes.toString('base64') !== value) throw new Error('解析包签名编码无效');
  return bytes;
}

/** 验证原始签名清单，公钥只来自已配置发布身份。SHIXIAOYANG，2026/11/21。 */
export function verifyPackageManifest(bytes, publicKeyBase64 = trustedPublicKey) {
  if (!bytes.length || bytes.length > maximumManifestBytes) throw new Error('解析包清单大小无效');
  let envelope;
  try { envelope = JSON.parse(bytes.toString('utf8')); }
  catch { throw new Error('解析包清单不是有效 JSON'); }
  if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) throw new Error('解析包清单不是有效对象');
  const payload = decodeBase64(envelope.payloadBase64, 32 * 1024);
  const signature = decodeBase64(envelope.signatureBase64, 64);
  const key = decodeBase64(publicKeyBase64, 32);
  if (signature.length !== 64 || key.length !== 32) throw new Error('解析包签名参数无效');
  const publicKey = crypto.createPublicKey({type: 'spki', format: 'der',
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), key])});
  if (!crypto.verify(null, payload, publicKey, signature)) throw new Error('解析包发布者签名不可信');
  let manifest;
  try { manifest = JSON.parse(payload.toString('utf8')); }
  catch { throw new Error('已签清单不是有效 JSON'); }
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) throw new Error('已签清单不是有效对象');
  const version = manifest.packageVersion;
  if (manifest.packageFormat !== 1 || !Number.isInteger(version) || version < 1 || version > 999999999 ||
      manifest.minimumBridgeVersion !== 1 || !Number.isInteger(manifest.bytes) || manifest.bytes < 1 ||
      manifest.bytes > maximumPackageBytes || typeof manifest.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(manifest.sha256) ||
      manifest.packagePath !== 'packages/p' + String(version).padStart(6, '0') + '.json') {
    throw new Error('解析包版本、路径、大小或摘要无效');
  }
  return manifest;
}

function validText(value, maximum, empty = false) {
  return typeof value === 'string' && (empty || value.trim().length > 0) && value.length <= maximum && !/[\x00-\x1f\x7f]/.test(value);
}

function validPlatforms(values) {
  if (!Array.isArray(values) || values.length > 3 || new Set(values).size !== values.length) return false;
  for (const value of values) {
    if (!['qq', '163', 'kugou'].includes(value)) return false;
  }
  return true;
}

function validateCapabilities(capabilities) {
  if (!capabilities || capabilities.protocolVersion !== 1 || !validText(capabilities.revision, 64) ||
      !Array.isArray(capabilities.sources) || capabilities.sources.length > 32) throw new Error('解析包音源能力无效');
  const ids = new Set();
  for (const source of capabilities.sources) {
    if (!source || !validText(source.id, 64) || !/^[a-z][a-z0-9_]{0,63}$/.test(source.id) || source.id === 'automatic' || ids.has(source.id) ||
        !validText(source.name, 80) || !validText(source.description ?? '', 512, true) ||
        !validPlatforms(source.platforms) || !validPlatforms(source.experimentalPlatforms ?? [])) throw new Error('解析包音源定义无效');
    ids.add(source.id);
    const fields = source.credentials ?? [];
    if (!Array.isArray(fields) || fields.length > 16) throw new Error('解析包音源凭据字段过多');
    const names = new Set();
    for (const field of fields) {
      if (!field || !validText(field.key, 64) || !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(field.key) || names.has(field.key) ||
          !validText(field.label, 80) || !validPlatforms(field.requiredPlatforms ?? [])) throw new Error('解析包凭据定义无效');
      names.add(field.key);
    }
  }
}

function validateBundle(bytes, manifest) {
  if (bytes.length !== manifest.bytes || bytes.length > maximumPackageBytes ||
      crypto.createHash('sha256').update(bytes).digest('hex') !== manifest.sha256) throw new Error('解析包大小或摘要不匹配');
  let bundle;
  try { bundle = JSON.parse(bytes.toString('utf8')); }
  catch { throw new Error('解析包内容不是有效 JSON'); }
  if (!bundle || bundle.packageFormat !== 1 || bundle.packageVersion !== manifest.packageVersion ||
      bundle.minimumBridgeVersion !== manifest.minimumBridgeVersion || typeof bundle.script !== 'string' || !bundle.script.trim()) {
    throw new Error('解析包代码或版本协议无效');
  }
  validateCapabilities(bundle.capabilities);
  if (!Array.isArray(bundle.allowedOrigins) || !bundle.allowedOrigins.length || bundle.allowedOrigins.length > 32) {
    throw new Error('解析包上游地址列表无效');
  }
  const origins = new Set();
  for (const origin of bundle.allowedOrigins) {
    if (typeof origin !== 'string' || origin.length > 2048) throw new Error('解析包上游地址无效');
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash ||
        url.pathname !== '/' || origins.has(url.origin)) throw new Error('解析包上游地址无效');
    origins.add(url.origin);
  }
}

function readRelease(root, manifestName, publicKeyBase64, optional = false) {
  const file = path.join(root, manifestName);
  const envelopeBytes = optional ? optionalFile(file, maximumManifestBytes) : boundedFile(file, maximumManifestBytes);
  if (!envelopeBytes) return null;
  const manifest = verifyPackageManifest(envelopeBytes, publicKeyBase64);
  const packages = directory(path.join(root, 'packages'));
  const bundleBytes = boundedFile(path.join(packages, path.basename(manifest.packagePath)), maximumPackageBytes);
  validateBundle(bundleBytes, manifest);
  return {manifest, envelopeBytes, bundleBytes};
}

function packageEntries(packages) {
  const entries = [];
  const handle = fs.opendirSync(packages);
  try {
    while (true) {
      const entry = handle.readSync();
      if (!entry) break;
      if (entries.length >= 16 || !packageName.test(entry.name)) throw new Error('更新目录文件数量或名称异常，请人工检查');
      const version = Number(entry.name.slice(1, -5));
      if (version < 1 || version > 999999999 || entry.name !== 'p' + String(version).padStart(6, '0') + '.json') {
        throw new Error('更新目录包版本名称无效');
      }
      const file = path.join(packages, entry.name);
      const details = fs.lstatSync(file);
      if (!details.isFile() || details.isSymbolicLink() || details.size < 1 || details.size > maximumPackageBytes) {
        throw new Error('更新目录不能包含符号链接或异常文件');
      }
      entries.push({file, name: entry.name, version});
    }
  } finally {
    handle.closeSync();
  }
  return entries;
}

function writeTemporary(root, prefix, bytes) {
  const file = path.join(root, '.' + prefix + '.' + crypto.randomBytes(8).toString('hex') + '.part');
  const descriptor = fs.openSync(file, 'wx', 0o644);
  let failure;
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); }
  catch (error) { failure = error; }
  finally { fs.closeSync(descriptor); }
  if (failure) { removeOwned(file); throw failure; }
  return file;
}

function replaceOwned(temporary, destination) {
  const existing = optionalFile(destination, maximumManifestBytes);
  if (existing !== null && !fs.lstatSync(destination).isFile()) throw new Error('清单目标类型发生变化');
  fs.renameSync(temporary, destination);
}

function removeOwned(file) {
  let details;
  try { details = fs.lstatSync(file); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (!details.isFile() || details.isSymbolicLink()) throw new Error('不能删除符号链接或未知更新文件');
  fs.unlinkSync(file);
}

/**
 * 将已验证包原子发布到静态目录，版本必须递增，清单最后切换。
 * 仅保留新当前及上一有效包，不执行脚本或重启服务。SHIXIAOYANG，2026/11/21。
 */
export function installPlaybackPackage({stagingRoot, destinationRoot, publicKeyBase64 = trustedPublicKey}) {
  const source = directory(stagingRoot);
  const incoming = readRelease(source, 'manifest.json', publicKeyBase64);
  const root = directory(destinationRoot, true);
  const packages = directory(path.join(root, 'packages'), true);
  const lock = path.join(root, '.publish.lock');
  try { fs.mkdirSync(lock, {mode: 0o700}); }
  catch { throw new Error('已有解析包正在发布或发布锁需要检查'); }
  const temporary = [];
  let addedFile;
  let previousChanged = false;
  let committed = false;
  let oldPrevious;
  try {
    const current = readRelease(root, 'manifest.json', publicKeyBase64, true);
    oldPrevious = readRelease(root, 'previous-manifest.json', publicKeyBase64, true);
    const existing = packageEntries(packages);
    let maximumVersion = Math.max(current && current.manifest.packageVersion || 0,
      oldPrevious && oldPrevious.manifest.packageVersion || 0);
    for (const entry of existing) maximumVersion = Math.max(maximumVersion, entry.version);
    if (incoming.manifest.packageVersion <= maximumVersion) throw new Error('解析包版本必须大于已发布或遗留版本');

    const destination = path.join(packages, path.basename(incoming.manifest.packagePath));
    const packageTemporary = writeTemporary(packages, 'package', incoming.bundleBytes);
    temporary.push(packageTemporary);
    const nextManifest = writeTemporary(root, 'manifest', incoming.envelopeBytes);
    temporary.push(nextManifest);
    const previous = current || oldPrevious;
    let previousTemporary;
    if (previous) {
      previousTemporary = writeTemporary(root, 'previous', previous.envelopeBytes);
      temporary.push(previousTemporary);
    }
    fs.renameSync(packageTemporary, destination);
    addedFile = destination;
    if (previousTemporary) {
      replaceOwned(previousTemporary, path.join(root, 'previous-manifest.json'));
      previousChanged = true;
    }
    // 外部读者始终看到旧的完整清单或新的完整清单，包内容已在切换前准备好。
    replaceOwned(nextManifest, path.join(root, 'manifest.json'));
    committed = true;
    const keep = new Set([path.basename(incoming.manifest.packagePath)]);
    if (previous) keep.add(path.basename(previous.manifest.packagePath));
    for (const entry of existing) {
      if (!keep.has(entry.name)) removeOwned(entry.file);
    }
    return {packageVersion: incoming.manifest.packageVersion,
      previousVersion: previous && previous.manifest.packageVersion || null,
      packagePath: incoming.manifest.packagePath, sha256: incoming.manifest.sha256, bytes: incoming.manifest.bytes};
  } finally {
    if (!committed) {
      if (addedFile) removeOwned(addedFile);
      if (previousChanged) {
        const previousFile = path.join(root, 'previous-manifest.json');
        if (oldPrevious) {
          const restore = writeTemporary(root, 'restore', oldPrevious.envelopeBytes);
          replaceOwned(restore, previousFile);
        } else removeOwned(previousFile);
      }
    }
    for (const file of temporary) removeOwned(file);
    if (!fs.lstatSync(lock).isDirectory() || fs.lstatSync(lock).isSymbolicLink()) throw new Error('发布锁类型发生变化');
    fs.rmdirSync(lock);
  }
}

/** 只读核对已签包，供发布入口读取可信版本及文件路径。 */
export function inspectPlaybackPackage({stagingRoot, publicKeyBase64 = trustedPublicKey}) {
  const source = directory(stagingRoot);
  const release = readRelease(source, 'manifest.json', publicKeyBase64);
  return {packageVersion: release.manifest.packageVersion, packagePath: release.manifest.packagePath,
    sha256: release.manifest.sha256, bytes: release.manifest.bytes, publicKeyBase64};
}

function main() {
  try {
    const result = process.argv[2] === '--verify'
      ? inspectPlaybackPackage({stagingRoot: process.argv[3]})
      : installPlaybackPackage({stagingRoot: process.argv[2], destinationRoot: process.argv[3]});
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error('解析包发布失败：' + error.message);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
