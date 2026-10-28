import {fileURLToPath} from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwind from '@tailwindcss/vite';
export default defineConfig({resolve:{alias:{'ct-i18n':fileURLToPath(new URL('./src/i18n',import.meta.url))}},plugins:[react(),tailwind()],build:{target:'es2022',rollupOptions:{output:{manualChunks:{supabase:['@supabase/supabase-js'],motion:['framer-motion'],query:['@tanstack/react-query'],react:['react','react-dom','react-router-dom']}}}},server:{strictPort:true,watch:{ignored:['**/artifacts/**','**/release/**','**/dist-native/**','**/android/**/build/**','**/android/app/src/main/assets/public/**','**/ios/App/App/public/**']}}});
