const {app}=require('electron');
function startUpdates(){
 if(!app.isPackaged||process.platform!=='win32')return;
 const {autoUpdater}=require('electron-updater');
 autoUpdater.autoDownload=true;autoUpdater.autoInstallOnAppQuit=true;autoUpdater.allowDowngrade=false;autoUpdater.allowPrerelease=false;autoUpdater.logger=null;
 autoUpdater.on('error',()=>{});
 let checking=false;const check=async()=>{if(checking)return;checking=true;try{await autoUpdater.checkForUpdates();}catch{/* Offline play screens must remain usable. */}finally{checking=false;}};
 void check();const timer=setInterval(()=>void check(),6*60*60*1000);timer.unref();
}
module.exports={startUpdates};
