import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read=file=>JSON.parse(readFileSync(file,'utf8'));
test('application version edits must not rewrite third-party package versions or dependency ranges',()=>{
 const lock=read('package-lock.json');
 for(const name of ['@malept/flatpak-bundler','asynckit','node-int64','pe-library']){
  const actual=read(`node_modules/${name}/package.json`),entry=lock.packages[`node_modules/${name}`];
  assert.equal(entry.version,actual.version,name);
  assert.ok(entry.resolved.endsWith(`-${actual.version}.tgz`),name+' tarball');
 }
 assert.equal(lock.packages['node_modules/app-builder-lib'].dependencies['@malept/flatpak-bundler'],read('node_modules/app-builder-lib/package.json').dependencies['@malept/flatpak-bundler']);
 assert.equal(lock.version,read('package.json').version);
 assert.equal(lock.packages[''].version,read('package.json').version);
});
