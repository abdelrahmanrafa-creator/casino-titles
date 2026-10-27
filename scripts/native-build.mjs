import {spawnSync} from 'node:child_process';
import {existsSync,copyFileSync,mkdirSync,readdirSync} from 'node:fs';
import path from 'node:path';
const run=(command,args)=>{const r=spawnSync(command,args,{stdio:'inherit',shell:process.platform==='win32'});if(r.status!==0)process.exit(r.status||1);};
const localJava='.native-tools/jdk';if(!process.env.JAVA_HOME&&existsSync(localJava)){process.env.JAVA_HOME=path.resolve(localJava,readdirSync(localJava).find(n=>n.startsWith('jdk')));process.env.PATH=path.join(process.env.JAVA_HOME,'bin')+path.delimiter+process.env.PATH;}if(!process.env.ANDROID_HOME&&existsSync('.native-tools/android-sdk'))process.env.ANDROID_HOME=path.resolve('.native-tools/android-sdk');
if(process.env.ANDROID_HOME)process.env.PATH=path.join(process.env.ANDROID_HOME,'platform-tools')+path.delimiter+process.env.PATH;
const task=process.argv[2];
if(task==='windows'){if(process.platform!=='win32')throw Error('Build Windows on Windows.');run('npm',['run','build:native']);run('npx',['electron-builder','--win','--x64']);}
else if(task==='android'){run('npm',['run','build:native']);run('npx',['cap','sync','android']);const gradle=process.platform==='win32'?'android\\gradlew.bat':'./android/gradlew';run(gradle,['-p','android','assembleDebug']);mkdirSync('release/android',{recursive:true});copyFileSync('android/app/build/outputs/apk/debug/app-debug.apk','release/android/Casino-Titles-debug.apk');}
else if(task==='sync'){run('npm',['run','build:native']);run('npx',['cap','sync']);}
else if(task==='doctor'){console.log('Node:',process.version,'Platform:',process.platform);console.log('Public backend configuration:',existsSync('.env.local')?'present (.env.local)':'provide VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY');for(const [cmd,args] of [['java',['-version']],['adb',['version']]]){const r=spawnSync(cmd,args,{encoding:'utf8',shell:process.platform==='win32'});console.log(cmd,r.error?.message||r.stdout||r.stderr);}console.log('Android SDK configured:',Boolean(process.env.ANDROID_HOME||process.env.ANDROID_SDK_ROOT));console.log('iOS archive requires macOS, Xcode and Apple signing.');}
else throw Error('Use windows, android, sync or doctor');
