import {build} from 'esbuild';
await build({entryPoints:['desktop/main.cjs'],outfile:'desktop/main.bundle.cjs',bundle:true,platform:'node',format:'cjs',external:['electron'],target:'node22',logLevel:'warning'});
