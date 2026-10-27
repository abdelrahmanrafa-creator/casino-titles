const {app,BrowserWindow,protocol,net,shell,session}=require('electron');
const path=require('node:path');const {pathToFileURL}=require('node:url');const fs=require('node:fs');
protocol.registerSchemesAsPrivileged([{scheme:'ct-app',privileges:{standard:true,secure:true,supportFetchAPI:true,corsEnabled:true}}]);
const external=url=>{try{const u=new URL(url);if(['https:','mailto:'].includes(u.protocol))return shell.openExternal(u.href);}catch{}return Promise.resolve();};
app.whenReady().then(()=>{
 const root=path.resolve(__dirname,'../dist-native');
 protocol.handle('ct-app',request=>{const u=new URL(request.url);if(u.hostname!=='game')return new Response('Forbidden',{status:403});let file;try{file=path.resolve(root,'.'+decodeURIComponent(u.pathname));}catch{return new Response('Bad request',{status:400});}if(file!==root&&!file.startsWith(root+path.sep))return new Response('Forbidden',{status:403});if(!fs.existsSync(file)||fs.statSync(file).isDirectory()){if(path.extname(file))return new Response('Not found',{status:404});file=path.join(root,'index.html');}return net.fetch(pathToFileURL(file).href);});
 session.defaultSession.setPermissionRequestHandler((_wc,permission,callback)=>callback(permission==='fullscreen'));
 const create=()=>{const win=new BrowserWindow({width:1440,height:950,minWidth:390,minHeight:640,backgroundColor:'#0d0b14',autoHideMenuBar:true,icon:path.join(__dirname,'../assets/icon.png'),webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,webSecurity:true}});win.webContents.setWindowOpenHandler(({url})=>{external(url);return {action:'deny'};});win.webContents.on('will-navigate',(event,url)=>{if(new URL(url).origin!==new URL('ct-app://game').origin||!url.startsWith('ct-app://game/')){event.preventDefault();external(url);}});win.loadURL('ct-app://game/');};create();app.on('activate',()=>{if(!BrowserWindow.getAllWindows().length)create();});
});
app.on('window-all-closed',()=>{if(process.platform!=='darwin')app.quit();});
