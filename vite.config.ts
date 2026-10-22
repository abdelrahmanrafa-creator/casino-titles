import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwind from '@tailwindcss/vite';
export default defineConfig({plugins:[react(),tailwind()],build:{target:'es2022',rollupOptions:{output:{manualChunks:{supabase:['@supabase/supabase-js'],motion:['framer-motion'],query:['@tanstack/react-query'],react:['react','react-dom','react-router-dom']}}}},server:{strictPort:true}});
