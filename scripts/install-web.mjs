import {spawnSync} from 'node:child_process';

// Static web builds need the JavaScript tools, but never the Electron executable.
// npm ci verifies the committed lockfile and still runs required native-tool hooks.
const result=spawnSync(process.platform==='win32'?'npm.cmd':'npm',['ci'],{
 stdio:'inherit',
 shell:process.platform==='win32',
 env:{...process.env,ELECTRON_SKIP_BINARY_DOWNLOAD:'1'},
});
if(result.error)throw result.error;
process.exit(result.status??1);
