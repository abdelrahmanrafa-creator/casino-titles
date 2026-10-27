import {Capacitor} from '@capacitor/core';
// Native services are initialized only in the packaged mobile build.
export async function initializeNative(){
 if(!Capacitor.isNativePlatform())return;
 document.documentElement.classList.add('native-app');
 const [{App},{SplashScreen},{StatusBar,Style},{Browser}]=await Promise.all([import('@capacitor/app'),import('@capacitor/splash-screen'),import('@capacitor/status-bar'),import('@capacitor/browser')]);
 await StatusBar.setStyle({style:Style.Dark}).catch(()=>{});
 await SplashScreen.hide().catch(()=>{});
 App.addListener('backButton',({canGoBack})=>{if(canGoBack)window.history.back();});
 App.addListener('appStateChange',({isActive})=>{if(isActive)window.dispatchEvent(new Event('focus'));});
 document.addEventListener('click',event=>{const link=(event.target as Element)?.closest?.('a');if(!link)return;try{const url=new URL(link.href);if(url.origin!==location.origin&&url.protocol==='https:'){event.preventDefault();void Browser.open({url:url.href});}}catch{/* Internal anchors use the router. */}});
}
